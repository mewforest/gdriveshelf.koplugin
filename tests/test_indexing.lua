local H=require('tests/helper');local Core=require('core')
local function setup(settings)
 local state={};local records={};local work={}
 local fs={root='/cache',json={encode=function()return '{}'end},readJSON=function(_,p)if p=='/cache/index.json'then return state end;return records[p]end,writeJSON=function()return true end,write=function()return true end,exists=function()return false end,remove=function()return true end,mkdir=function()return true end,freeBytes=function()return 1e12 end,filePath=function(_,e)return '/meta/'..e.id end}
 local c=Core.new{storage=fs,jobs={setOffline=function()end},settings=settings or {},provider_factory=function()end}
 c.network=function(_,key,run,done)work[#work+1]={key=key,run=run,done=done};return true end
 return c,work
end
H.test('confirmed empty listings are durable and deleted entries no longer reappear',function()
 local c=setup();c:rememberList('p',{{id='old',name='1.cbz',parent_id='p'}})
 c:rememberList('p',{});H.eq(#c:cachedList('p'),0);assert(c.state.listings.p.complete)
 assert(c.state.docs.old,'Durable document identity/history must remain')
end)
H.test('home indexing visits only direct unseen non-service folders',function()
 local c,work=setup({home='home',index_enabled=true,index_hours=0})
 c:rememberList('home',{{id='a',name='A',is_folder=true},{id='b',name='B',is_folder=true},{id='s',name='1.sdr',is_folder=true}})
 c:rememberList('b',{})
 c:indexHome();H.eq(#work,1);H.eq(work[1].key,'index:a')
 work[1].done({{id='nested',name='Nested',is_folder=true,parent_id='a'}})
 H.eq(#work,1);assert(c.state.listings.a.complete)
end)
H.test('disabled metadata toggles prevent cover and JSON downloads',function()
 local c=setup({load_covers=false,load_metadata=false});local downloads=0;c.download=function()downloads=downloads+1 end
 c:metadata({{id='a',name='cover.jpg'},{id='b',name='index.json'}});H.eq(downloads,0)
end)
H.test('books are not prefetched by default but comic chapters still are',function()
 local c=setup();local downloads=0;c.download=function()downloads=downloads+1 end
 c:rememberList('p',{{id='a',name='1.epub'},{id='b',name='2.epub'}})
 c:prefetch(c.state.docs.a);H.eq(downloads,0)
 c:rememberList('p',{{id='a',name='1.cbz'},{id='b',name='2.cbz'}})
 c:prefetch(c.state.docs.a);H.eq(downloads,1)
end)
H.test('folder refresh preserves the local identity of an evicted document',function()
 local c=setup();c.state.docs.a={id='a',name='1.cbz',parent_id='p',local_path='/Books/Title/1.cbz'}
 c:rememberList('p',{{id='a',name='1.cbz',parent_id='p',version='2'}})
 H.eq(c.state.docs.a.local_path,'/Books/Title/1.cbz')
end)
H.test('thumbnail from an older archive version is invalidated during listing refresh',function()
 local c=setup();c.state.entries['thumb:a']={id='thumb:a',name='preview.png',pool='meta',path='/meta/old',source_stamp='old',ready=true}
 c:rememberList('p',{{id='a',name='1.cbz',parent_id='p',version='2'}})
 assert(not c.state.entries['thumb:a'])
end)
H.test('cancelled recursive download discovery cannot show a late confirmation',function()
 local c,work=setup();local completed=false;c.jobs.cancel=function()end
 c:scanFolder({id='p'},function()completed=true end);c:cancelFolderScan()
 work[1].done({{id='nested',name='Nested',is_folder=true}})
 assert(not completed and #work==1)
end)
