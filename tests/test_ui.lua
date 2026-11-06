local count=0
local function test(name,fn)fn();count=count+1;print('ok '..name)end
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
local shown={}
package.loaded['ui/uimanager']={show=function(_,w)shown[#shown+1]=w end,nextTick=function(_,f)f()end}
local exists=require('ffi').os and true
local f=io.open('gdriveshelf.koplugin/main.lua','rb');assert(f,'KOReader UI adapter is not implemented');f:close()
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local SDR=require('gdriveshelf/sdr')
local function instance(core,ui) return setmetatable({core=core,ui=ui or {}},{__index=Plugin}) end

test('active identity requires the exact cached file path',function()
 local p=instance({state={entries={a={id='a',path='/cache/a.cbz',ready=true,version='cached'}},docs={a={id='a',version='remote'}}}},{document={file='/cache/a.cbz'}})
 assert(p:activeEntry().id=='a' and p:activeEntry().version=='cached');p.ui.document.file='/other/a.cbz';assert(not p:activeEntry())
end)
test('lazy progress only sees current visible page and redraw does not reschedule',function()
 local captured;local calls=0
 local p=instance({lazyProgress=function(_,entries)captured=entries;calls=calls+1 end})
 local menu={page=2,perpage=2,item_table={{entry={id='a'}},{entry={id='b'}},{entry={id='c'}},{entry={id='d'}},{entry={id='e'}}}}
 p:visibleProgress(menu);assert(#captured==2 and captured[1].id=='c' and captured[2].id=='d')
 p:visibleProgress(menu);assert(calls==1)
 menu.page=3;p:visibleProgress(menu);assert(calls==2 and #captured==1 and captured[1].id=='e')
end)
test('remote restore never executes Lua or writes changed book metadata',function()
 local writes=0
 package.loaded.docsettings={open=function()writes=writes+1;return {flush=function()return true end} end}
 local core={state={sync={pending={},conflicts={},bases={}}},save=function()return true end}
 local p=instance(core)
 local e={id='a',version='2'}
 assert(not p:applyRemote(e,{lua='return {last_page=4}',book_stamp={version='1'}},'/cache/a.cbz'))
 assert(not p:applyRemote(e,{lua='return os.execute("bad")',book_stamp={version='2'}},'/cache/a.cbz'))
 assert(writes==0)
end)
test('native restore rewrites doc_path and only advances base after successful flush',function()
 local saved
 package.loaded.docsettings={open=function()return {flush=function(_,data)saved=data;return nil end}end}
 local core={state={sync={pending={},conflicts={},bases={}}},save=function()return true end}
 local p=instance(core);local e={id='a',version='2'};local remote={lua='return {last_page=4,doc_path="remote"}',book_stamp={version='2'},stamp={version='meta'}}
 assert(not p:applyRemote(e,remote,'/cache/a.cbz'));assert(not core.state.sync.bases.a)
 package.loaded.docsettings.open=function()return {flush=function(_,data)saved=data;return '/cache/a.sdr' end}end
 assert(p:applyRemote(e,remote,'/cache/a.cbz'));assert(saved.doc_path=='/cache/a.cbz' and saved.last_page==4)
 assert(core.state.sync.bases.a.lua==remote.lua)
end)
test('active book and newer pending edits block remote application',function()
 local core={state={entries={a={id='a',path='/cache/a.cbz'}},docs={a={id='a'}},sync={pending={a={lua='new local'}},bases={},conflicts={}}}}
 local p=instance(core,{document={file='/cache/a.cbz'}})
 assert(not p:applyRemote({id='a'},{lua='return {}'},'/cache/a.cbz',true))
 p.ui.document=nil;assert(not p:applyRemote({id='a'},{lua='return {}'},'/cache/a.cbz'))
end)
test('end-of-book hook intercepts only this reader cache and cancellation permits another prompt',function()
 local built_in=0;local invoked=0
 local p=instance({state={entries={a={id='a',path='/cache/a.cbz'}},docs={}},next=function()return {id='b',name='Next'}end},
  {document={file='/cache/a.cbz'},status={onEndOfBook=function()built_in=built_in+1 end}})
 p.onEndOfBook=function()invoked=invoked+1;return true end
 p:installEndHook();p.ui.status:onEndOfBook();assert(invoked==1 and built_in==0)
 p.ui.document.file='/ordinary/book.cbz';p.ui.status:onEndOfBook();assert(built_in==1)
end)
test('credentials chooser receives the current native UI context',function()
 local given
 package.loaded['ui/widget/filechooser']={new=function(_,options)given=options;return options end}
 local p=instance({},{});p.settings={import_dir='/tmp'};p:pickCredentials()
 assert(given.ui==p.ui and given.file_filter('credentials.json') and not given.file_filter('book.cbz'))
end)
test('title folders use cached covers and metadata and a separate reading sort',function()
 local core={state={summaries={},last_opened={a=10,b=20}},cached=function()end,
 titleInfo=function(_,id)if id=='a'then return {title='Actual title',author='Author',cover_path='/cache/cover.jpg',chapters={}}end;return {title=id,chapters={}}end}
 local p=instance(core);p.settings={title_sort='read',sort='natural'}
 local rows=p:folderRows('root',{{id='a',name='Folder A',is_folder=true},{id='b',name='Folder B',is_folder=true},{id='c',name='Chapter 2.cbz'},{id='d',name='Chapter 1.cbz'}},false)
 assert(rows[2].entry.id=='b' and rows[3].entry.id=='a')
 assert(rows[3].text=='Actual title · Author' and rows[3].icon_file=='/cache/cover.jpg')
 assert(rows[4].entry.id=='d' and p.settings.sort=='natural')
end)
test('storage screen localizes all three cleanup rows inside its pool loop',function()
 local storage={root='/cache',treeSize=function()return 0 end,freeBytes=function()return 12.4*1024^3 end,size=function()return 0 end,lfs={dir=function()return function()return nil end end}}
 local p=instance({storage=storage,cache=function()return {usage=function()return {auto=1,offline=2,meta=3}end}end});local rows
 p.menu=function(_,_,r)rows=r end;p:showMemory()
 assert(#rows==7 and rows[4].text:find('Automatic reading cache',1,true) and rows[6].callback)
 assert(rows[1].text=='Free disk space: 12.4 GiB')
end)
test('resume last document uses the normal opener with prefetch and persists title sort',function()
 local entry={id='last',name='Book.cbz',parent_id='series'}
 local p=instance({state={last_document='last',docs={last=entry},entries={}}});p.settings={}
 local opened,resume;p.openEntry=function(_,e,r)opened,resume=e,r end
 p:openLastDocument();assert(opened==entry and resume)
 local rows;p.menu=function(_,_,r)rows=r end;local saves=0;p.saveSettings=function()saves=saves+1 end
 p:showTitleSort();rows[3].callback();assert(p.settings.title_sort=='read'and saves==1)
 p.core.state.last_document='deleted';assert(not p:lastDocument())
end)
test('resuming opens the native reader before scheduling next-chapter prefetch',function()
 local entry={id='a',name='Book.cbz',parent_id='series'};local opened,prefetched,saved=false,false,false
 package.loaded.docsettings={hasSidecarFile=function()return true end}
 local core={state={sync={pending={}}},open=function(_,_,done)done('/cache/book.cbz')end,
  save=function(self)saved=self.state.last_document=='a'and self.state.last_opened.series~=nil end,
  prefetch=function(_,e)assert(opened and e==entry);prefetched=true end}
 local p=instance(core,{document={},switchDocument=function(_,path)assert(path=='/cache/book.cbz');opened=true end})
 p:openEntry(entry,true);assert(opened and prefetched and saved)
end)
test('plain core errors use the active Russian locale',function()
 package.loaded.gettext={current_lang='ru'}
 package.loaded['ui/widget/confirmbox']={new=function(_,o)return o end}
 package.loaded['ui/widget/infomessage']={new=function(_,o)return o end}
 local p=instance({cached=function()end,removeFile=function()return nil,'This document is active'end})
 local rows;p.menu=function(_,_,r)rows=r end
 p:fileActions({id='active',name='Book.cbz'});rows[3].callback();shown[#shown].ok_callback()
 assert(shown[#shown].text=='Этот документ открыт')
end)
print(count..' UI adapter tests passed')
