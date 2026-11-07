local H=require('tests/helper')
local Fixture=require('catalog_fixture')

local function library(folderCount, bookCount)
 local tree={home={}}
 for folder=1,folderCount do
  local id='folder-'..folder
  tree.home[#tree.home+1]={id=id,parent_id='home',name=id,is_folder=true}
  tree[id]={}
  for book=1,bookCount do
   local bookId=id..'-'..book
   tree[id][#tree[id]+1]={id=bookId,parent_id=id,name=bookId..'.cbz',size=100,version='1'}
  end
 end
 return {
  stat=function(_,id)return{id=id,name=id,is_folder=true}end,
  getStartToken=function()return 'first'end,
  listParents=function(_,ids)
   local result={}
   for _,id in ipairs(ids)do result[id]=tree[id] end
   return result
  end,
  changes=function()return{changes={},new_start_token='latest'}end,
 }
end

H.test('recursive indexing saves a bounded number of atomic checkpoints for 40 folders',function()
 local core,_,drain=Fixture.new(nil,library(40,20))
 local saves,writes=0,0
 local save,write=core.save,core.storage.write
 core.save=function(self,...)saves=saves+1;return save(self,...)end
 core.storage.write=function(self,...)writes=writes+1;return write(self,...)end
 assert(core:catalogRefresh())
 drain()
 assert(saves<=8,'full index saves: '..saves)
 H.eq(writes,0)
 H.eq(core.state.catalog.phase,'ready')
 H.eq(#core:cachedList('folder-40'),20)
 local metrics=core:indexStatus().metrics
 H.eq(metrics.writes,saves)
 assert(metrics.max_apply_ms>=0 and metrics.max_save_ms>=0)
end)

H.test('pausing a cooperative apply retains the exact group across restart',function()
 local provider=library(40,20)
 local core,step,_,jobs=Fixture.new(nil,provider)
 local ticks={}
 core.jobs.schedule=function(fn)ticks[#ticks+1]=fn end
 assert(core:catalogRefresh(true))
 step() -- Capture the change token.
 step() -- List home.
 while #ticks>0 do table.remove(ticks,1)()end -- Commit its 40 child IDs.
 step() -- Start applying 20 children with 400 documents.
 H.eq(core:indexStatus().phase,'applying')
 assert(#ticks>0 and not core.state.listings['folder-1'] and not core.state.docs['folder-1-1'])
 core:cancelIndex()
 H.eq(core:indexStatus().phase,'paused')
 H.eq(core.state.catalog.token,'first')
 H.eq(#core.state.catalog.queue,40)
 for _,tick in ipairs(ticks)do tick()end
 H.eq(#jobs,0)
 assert(not core.state.listings['folder-1'])
 local resumed,_,drain=Fixture.new(core.settings,provider,core.state)
 assert(not resumed:catalogRefresh())
 assert(resumed:catalogRefresh(true))
 drain()
 H.eq(resumed.state.catalog.token,'latest')
 H.eq(#resumed:cachedList('folder-1'),20)
end)

H.test('a failed group save rolls back listings and queue before retry',function()
 local core,step,drain=Fixture.new(nil,library(2,2))
 assert(core:catalogRefresh())
 step()
 step()
 local save=core.save
 core.save=function()return nil,'disk full'end
 step()
 H.eq(core:indexStatus().phase,'error')
 H.eq(core.state.catalog.token,'first')
 H.eq(#core.state.catalog.queue,2)
 assert(not core.state.listings['folder-1'] and not core.state.docs['folder-2-1'])
 core.save=save
 assert(core:catalogRefresh(true))
 drain()
 H.eq(core.state.catalog.token,'latest')
 H.eq(#core:cachedList('folder-2'),2)
end)

H.test('light mode disables implicit indexing but preserves explicit indexing',function()
 local settings={home='home',index_enabled=true,index_recursive_confirmed=true,light_mode=true}
 local core,_,drain,jobs=Fixture.new(settings,library(1,1))
 assert(not core:catalogRefresh())
 H.eq(#jobs,0)
 assert(core:catalogRefresh(true))
 drain()
 H.eq(core.state.catalog.phase,'ready')
end)

H.test('light mode only refreshes a stale or explicitly refreshed folder and gates sync',function()
 local direct=0
 local provider=library(1,1)
 provider.list=function(_,id)direct=direct+1;return {{id='one',parent_id=id,name='one.cbz',size=100,version='1'}}end
 local core,_,drain=Fixture.new({home='home',light_mode=true,sync_enabled=true},provider)
 local sync={}
 core.flushPending=function(_,explicit)sync[#sync+1]=explicit==true end
 core:rememberList('title',{{id='one',parent_id='title',name='one.cbz',size=100,version='1'}})
 local cached
 assert(not core:folder('title','Title',function(_,value)cached=value end))
 assert(cached)
 drain()
 H.eq(direct,0)
 H.eq(#sync,0)
 core.state.listings.title.checked_at=os.time()-901
 assert(core:folder('title','Title',function()end))
 drain()
 H.eq(direct,1)
 H.eq(#sync,0)
 assert(core:folder('title','Title',function()end,true))
 drain()
 H.eq(direct,2)
 H.eq(#sync,1)
 assert(sync[1])
end)

H.test('light mode does not schedule prefetch or auto-sync until explicit synchronization',function()
 local core,_,_,jobs=Fixture.new({home='home',light_mode=true,sync_enabled=true},{})
 local entry={id='one',parent_id='home',name='one.cbz',size=100,version='1'}
 core:rememberList('home',{entry,{id='two',parent_id='home',name='two.cbz',size=100,version='1'}})
 assert(core:snapshot(entry,{summary={status='reading'}}))
 core:prefetch(entry)
 H.eq(#jobs,0)
 core:flushPending(true)
 H.eq(#jobs,1)
 H.eq(jobs[1].key,'sync:one')
end)

H.test('folder metadata imports use a declared image before a standard WebP cover',function()
 local core=Fixture.new({home='home',light_mode=true},{})
 local entries={
  {id='manifest',name='index.json',parent_id='title',version='1'},
  {id='standard',name='cover.webp',parent_id='title',version='1'},
  {id='custom',name='Key Art.png',parent_id='title',version='1'},
 }
 core:rememberList('title',entries)
 core.state.entries.manifest={path='/manifest',ready=true,version='1',parsed={cover='Key Art.png'}}
 local exists=core.storage.exists
 core.storage.exists=function(self,path)return path=='/manifest'or path=='/custom'or exists(self,path)end
 local selected
 core.download=function(_,entry,pool,callback,automatic)
  H.eq(pool,'meta')
  assert(not automatic)
  selected=entry.id
 end
 core:metadata(entries)
 H.eq(selected,nil)
 core:metadata(entries,true)
 H.eq(selected,'custom')
 core.state.entries.custom={path='/custom',preview_path='/custom-preview.png',ready=true,version='1'}
 local info=core:titleInfo('title')
 H.eq(info.cover_path,'/custom-preview.png')
 H.eq(info.cover_source,'imported')
 core.settings.load_metadata=false
 core:metadata(entries,true)
 H.eq(selected,'standard')
end)

H.test('normal visits reuse a fresh folder listing unless explicitly invalidated',function()
 local calls=0
 local core,_,drain=Fixture.new({home='home'},{
  list=function()calls=calls+1;return {}end,
 })
 core:rememberList('warm',{})
 assert(not core:folder('warm','Warm',function(rows,cached)assert(cached and #rows==0)end))
 core.state.listings.warm.dirty=true
 assert(core:folder('warm','Warm',function()end));drain()
 H.eq(calls,1);assert(not core.state.listings.warm.dirty)
end)

H.test('light prefetch uses its own threshold and queues only selected chapters',function()
 local core,_,_,jobs=Fixture.new({home='home',light_mode=true,light_prefetch=1,light_threshold=95},{})
 local a={id='a',parent_id='home',name='1.cbz',size=100,version='1'}
 local b={id='b',parent_id='home',name='2.cbz',size=100,version='1'}
 core:rememberList('home',{a,b})
 core:prefetch(a,.94);H.eq(#jobs,0)
 core:prefetch(a,.95);H.eq(#jobs,1)
 H.eq(jobs[1].key,'download:b')
end)
