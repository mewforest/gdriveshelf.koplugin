local H=require('tests/helper')
local Manage=require('gdriveshelf/manage')
local function fixture()
 local entries={
  a={id='a',path='/Books/A/1.cbz',pool='auto',parent_id='alpha',ready=true,size=99},
  b={id='b',path='/Books/A/2.cbz',pool='offline',parent_id='alpha',ready=true,size=99},
  c={id='c',path='/Books/B/3.cbz',pool='offline',parent_id='beta',ready=true,size=99},
  meta={id='meta',path='/meta/value',pool='meta',ready=true},
 }
 local sizes={a=200,b=400,c=20,meta=1,e=300}
 local protected={}
 local core={state={entries=entries,folders={alpha={id='alpha',name='Alpha',parent_id='home'},beta={id='beta',name='Beta'}},downloads={a={pool='offline'}}},storage={
  bookRegistry=function()return {}end,
  managedPath=function(_,entry)return true,{mode='file',size=sizes[entry.id]}end},
  protected=function()return protected end,evict=function(self,ids)
   for _,id in ipairs(ids)do self.state.entries[id]=nil end
  end,save=function()return true end,emit=function()end}
 return core,protected
end
H.test('download inventory groups both archive pools by folder and actual on-disk bytes',function()
 local core=fixture()
 local inventory=Manage.inventory(core)
 H.eq(#inventory,2);H.eq(inventory[1].id,'alpha');H.eq(inventory[1].size,600)
 H.eq(inventory[1].entries[1].id,'b')
 assert(Manage.inBranch(core.state.folders,'alpha','home'))
 assert(not Manage.inBranch(core.state.folders,'beta','home'))
end)
H.test('selective deletion rechecks protection and identity and preserves queued work',function()
 local core,protected=fixture()
 local targets=Manage.inventory(core)[1].entries
 local pending={};local result
 assert(Manage.remove(core,targets,function(fn)pending[#pending+1]=fn end,function(stats)result=stats end))
 protected.a=true
 core.state.entries.b.path='/Books/A/new.cbz'
 pending[1]()
 H.eq(result.removed,0);H.eq(result.skipped,2);assert(core.state.downloads.a)
 protected.a=nil
 assert(Manage.remove(core,{{id='a',path='/Books/A/1.cbz',pool='auto',size=200}},function(fn)fn()end,function(stats)result=stats end))
 H.eq(result.removed,1);assert(core.state.downloads.a);assert(core.state.entries.meta)
end)
H.test('account switching restores distinct home/index preferences and adopts legacy settings',function()
 local s={home='legacy',books_dir='/legacy-books',index_enabled=true,index_recursive_confirmed=true,keep_read_chapters=0}
 Manage.accountHome(s,'one');H.eq(s.home,'legacy')
 Manage.accountHome(s,'two');H.eq(s.home,'root');H.eq(s.index_enabled,nil);H.eq(s.books_dir,nil)
 H.eq(s.keep_read_chapters,nil)
 s.home='two-home';s.books_dir='/second-books'
 Manage.accountHome(s,'one');H.eq(s.home,'legacy');H.eq(s.books_dir,'/legacy-books');assert(s.index_recursive_confirmed)
 H.eq(s.keep_read_chapters,0)
 Manage.accountHome(s,'two');H.eq(s.home,'two-home');H.eq(s.books_dir,'/second-books')
end)
local function retentionFixture()
 local core,protected=fixture()
 local statuses={a='complete',b='complete',c='complete',d='reading',e='complete'}
 local entries=core.state.entries
 entries.a.name='Chapter 1.cbz'
 entries.b.name='Chapter 10.cbz'
 entries.c.name='Chapter 3.cbz'
 entries.d={id='d',name='Chapter 9.cbz',parent_id='alpha'}
 entries.e={id='e',name='Chapter 20.cbz',parent_id='alpha',pool='auto',ready=true,path='/Books/A/20.cbz',size=300}
 core.state.docs={a=entries.a,b=entries.b,c=entries.c,d=entries.d,e=entries.e}
 core.state.downloads={}
 core.state.listings={alpha={complete=true}}
 core.settings={sort='size',reverse=true}
 core.cachedList=function(_,parent)return parent=='alpha' and {entries.e,entries.a,entries.d,entries.b} or {entries.c}end
 core.chapterSummary=function(_,entry)return {status=statuses[entry.id]}end
 return core,protected,statuses
end
H.test('read cache retention uses a natural chapter window and separate protection',function()
 local core,protected,statuses=retentionFixture()
 H.eq(#Manage.readCacheTargets(core,nil),0)
 local targets=Manage.readCacheTargets(core,2)
 H.eq(#targets,1);H.eq(targets[1].id,'a');H.eq(targets[1].size,200)
 H.eq(#Manage.readCacheTargets(core,0,core.state.entries.a.path),1)
 protected.e=true
 H.eq(#Manage.readCacheTargets(core,0,core.state.entries.a.path),0)
 protected.e=nil
 statuses.e='reading'
 H.eq(#Manage.readCacheTargets(core,0),1)
 core.state.listings.alpha.complete=false
 H.eq(#Manage.readCacheTargets(core,1),0)
end)
H.test('read cache uses imported chapter numbers before filenames',function()
 local core=retentionFixture()
 core.importedMetadata=function()return {chapter_numbers={['Chapter 20.cbz']=1,['Chapter 1.cbz']=3,['Chapter 9.cbz']=2,['Chapter 10.cbz']=4}}end
 local victims=Manage.readCacheTargets(core,2)
 H.eq(#victims,1);H.eq(victims[1].id,'e')
end)
H.test('read-retention preview protects the native last file and commits only the confirmed plan',function()
 local core=retentionFixture()
 local last,start='','last'
 local menus,tasks={},{}
 local oldUI,oldSettings=package.loaded['ui/uimanager'],G_reader_settings
 package.loaded['ui/uimanager']={
  close=function(_,menu)menu._closed=true end,
  scheduleIn=function(_,_,action)tasks[#tasks+1]=action end,
 }
 G_reader_settings={readSetting=function(_,key)return key=='lastfile' and last or start end}
 local prototype={}
 Manage.install(prototype,{bytes=tostring,message=function()end})
 local commits=0
 local shelf=setmetatable({core=core,settings=core.settings,
  menu=function(_,_,rows)
   local menu={item_table=rows}
   menus[#menus+1]=menu
   return menu
  end,
  replaceMenu=function(_,menu,rows)menu.item_table=rows end,
  input=function(_,_,_,save)assert(save('0'))end,
  saveSettings=function()commits=commits+1 end,
 },{__index=prototype})
 local limits=shelf:showCacheLimits()
 local function preview()
  limits.item_table[3].callback()
  menus[#menus].item_table[2].callback()
  return menus[#menus]
 end
 local first=preview()
 H.eq(first.item_table[1].text,'Chapters to remove: 2 · Space to free: 500')
 first.item_table[3].callback()
 H.eq(commits,0);H.eq(core.settings.keep_read_chapters,nil);assert(core.state.entries.a and core.state.entries.e)
 local second=preview()
 last=core.state.entries.e.path
 second.item_table[2].callback()
 H.eq(second.item_table[1].text,'Chapters to remove: 1 · Space to free: 200')
 H.eq(commits,0);H.eq(#tasks,0)
 second.item_table[2].callback()
 while #tasks>0 do table.remove(tasks,1)()end
 H.eq(commits,1);H.eq(core.settings.keep_read_chapters,0);H.eq(core.state.entries.a,nil)
 assert(core.state.docs.a and core.state.entries.b and core.state.entries.e)
 last='/some/other/document'
 shelf:scheduleReadCacheCleanup()
 while #tasks>0 do table.remove(tasks,1)()end
 assert(core.state.docs.e and core.state.entries.b)
 H.eq(core.state.entries.e,nil)
 package.loaded['ui/uimanager'],G_reader_settings=oldUI,oldSettings
end)
H.test('memory stats render on the existing menu after asynchronous storage work',function()
 local prototype={}
 local format=function(n)return tostring(n or '?')end
 Manage.install(prototype,{root='/plugin',bytes=format,binaryBytes=format,message=function()end,problem=function()end})
 local pending={}
 local core=fixture()
 core.storage.books_dir='/Books'
 core.jobs={enqueue=function(_,key,_,done,_,_,_,local_task)
  assert(local_task)
  H.eq(key,'storage-stats');pending[#pending+1]=done
  return true
 end}
 local headers,menus,updates=0,0,0
 local function menu(_,_,rows,options)
  menus=menus+1
  return {item_table=rows,close=options.close}
 end
 local p=setmetatable({core=core,settings={},menu=menu,
  whenVisible=function()return true end,replaceMenu=function(self,widget,rows)
   assert(widget==self.memory_menu);widget.item_table=rows;updates=updates+1
  end},{__index=prototype})
 package.loaded.device={screen={getWidth=function()return 600 end}}
 package.loaded['gdriveshelf/browser']={header=function(options)
  headers=headers+1;H.eq(#options.bars,6);H.eq(options.bars[5].detail,'/Books')
  return {setBars=function(_,bars)H.eq(bars[6].detail,'4 · index and queue: 5')end,setSubTitle=function(_,value)H.eq(value,'Free space: 80')end}
 end}
 local memory=p:showMemory()
 assert(p:showMemory()==memory)
 H.eq(menus,1);H.eq(headers,1);H.eq(updates,0)
 local data={disk={free=80,total=100},usage={auto=1,offline=2,meta=3},progress=4,index=5}
 pending[1](data)
 H.eq(updates,1);H.eq(memory.item_table[1].text,'Choose downloads to remove');H.eq(memory.item_table[4].mandatory,'2')
 memory.refreshMemory();pending[2](data)
 H.eq(updates,2);H.eq(menus,1);H.eq(headers,1)
end)
