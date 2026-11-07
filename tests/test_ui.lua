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
test('accepting a confirmation cannot let an action exception escape',function()
 local confirmation
 package.loaded['ui/widget/confirmbox']={new=function(_,o)confirmation=o;return o end}
 package.loaded['ui/widget/infomessage']={new=function(_,o)return o end}
 local p=instance({})
 local ok=pcall(function()
  local dialog=p:confirmation{ok_callback=function()error('confirmation failure')end}
  dialog.ok_callback()
 end)
 assert(ok and confirmation,'Confirmation exception escaped into KOReader')
end)
test('lazy progress only sees current visible page and redraw does not reschedule',function()
 local captured;local calls=0
 local p=instance({lazyProgress=function(_,entries)captured=entries;calls=calls+1 end})
 local menu={page=2,perpage=2,item_table={{entry={id='a'}},{entry={id='b'}},{entry={id='c'}},{entry={id='d'}},{entry={id='e'}}}}
 p:visibleProgress(menu);assert(#captured==2 and captured[1].id=='c' and captured[2].id=='d')
 p:visibleProgress(menu);assert(calls==1)
 menu.page=3;p:visibleProgress(menu);assert(calls==2 and #captured==1 and captured[1].id=='e')
 menu.item_table[5]={entry={id='fresh'}};p:visibleProgress(menu);assert(calls==3 and captured[1].id=='fresh','Newly arrived visible entries were not checked')
end)
test('folder-only visible page cancels summaries from the prior document page',function()
 local cancelled=0;local p=instance({cancelProgress=function()cancelled=cancelled+1 end})
 p:visibleProgress({page=1,perpage=7,item_table={{entry={id='folder',is_folder=true}}}})
 assert(cancelled==1)
end)
test('closing the current folder menu cancels progress without cancelling a newer menu',function()
 local savedMenu,savedDevice=package.loaded['ui/widget/menu'],package.loaded.device
 package.loaded['ui/widget/menu']={new=function(_,options)options.page=1;options.perpage=7;return options end}
 package.loaded.device={screen={getWidth=function()return 600 end,getHeight=function()return 800 end}}
 local cancelled=0;local p=instance({lazyProgress=function()end,cancelProgress=function()cancelled=cancelled+1 end})
 local m=p:menu('Folder',{{entry={id='book',name='Book.cbz'}}},{lazy=true});p.folder_menu=m;m.close_callback();assert(cancelled==1 and p.folder_menu==nil)
 p.folder_menu={};m.close_callback();assert(cancelled==1)
 package.loaded['ui/widget/menu'],package.loaded.device=savedMenu,savedDevice
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
 local old_settings=G_reader_settings
 G_reader_settings={readSetting=function()return 'next_file'end,isTrue=function()return false end}
 local p=instance({state={entries={a={id='a',path='/cache/a.cbz'}},docs={}},next=function()return {id='b',name='Next'}end},
  {document={file='/cache/a.cbz'},status={onEndOfBook=function()built_in=built_in+1 end}})
 p.advanceChapter=function()invoked=invoked+1;return true end
 p:installEndHook();p.ui.status:onEndOfBook();assert(invoked==1 and built_in==0)
 p.ui.document.file='/ordinary/book.cbz';p.ui.status:onEndOfBook();assert(built_in==1)
 G_reader_settings=old_settings
end)
test('native end actions are preserved and automatic next is deferred inside the current title',function()
 assert(Plugin.onEndOfBook==nil,'Plugin must not independently consume native EndOfBook events')
 local old_settings=G_reader_settings;local action='nothing';local deferred={};local native,marked,opened=0,0,0
 G_reader_settings={readSetting=function()return action end,isTrue=function()return true end}
 package.loaded['ui/uimanager'].nextTick=function(_,fn)deferred[#deferred+1]=fn end
 local nextbook={id='b',name='2.cbz',parent_id='x'}
 local p=instance({state={entries={a={id='a',parent_id='x',path='/cache/a.cbz'}}},next=function()return nextbook end},
  {document={file='/cache/a.cbz'},status={onEndOfBook=function()native=native+1 end,markBook=function()marked=marked+1 end,onOpenNextOrPreviousFileInFolder=function()native=native+1 end}})
 p.openEntry=function(_,entry)assert(entry==nextbook);opened=opened+1 end;p:installEndHook()
 p.ui.status:onEndOfBook();assert(native==1 and opened==0)
 action='next_file';p.ui.status:onEndOfBook();p.ui.status:onEndOfBook()
 assert(marked>=1 and opened==0 and #deferred==1)
 deferred[1]();assert(opened==1)
 p._end_dialog=nil;p.ui.status:onOpenNextOrPreviousFileInFolder();assert(#deferred==2);deferred[2]();assert(opened==2)
 p._end_dialog=nil;nextbook=nil;p.ui.status:onEndOfBook();assert(#deferred==2 and opened==2)
 G_reader_settings=old_settings;package.loaded['ui/uimanager'].nextTick=function(_,fn)fn()end
end)
test('credentials chooser receives the current native UI context',function()
 local given
 package.loaded['ui/widget/filechooser']={new=function(_,options)given=options;return options end}
 local p=instance({},{});p.settings={import_dir='/tmp'};p:pickCredentials()
 assert(given.ui==p.ui and given.file_filter('credentials.json') and not given.file_filter('book.cbz'))
end)
test('title folders use cached covers and metadata and a separate reading sort',function()
 local core={state={entries={},summaries={},last_opened={a=10,b=20}},folderStats=function()return {bytes=0}end,cached=function()end,
 titleInfo=function(_,id)if id=='a'then return {title='Actual title',author='Author',cover_path='/cache/cover.jpg',progress={ratio=0.5},chapters={}}end;return {title=id,chapters={}}end}
 local p=instance(core);p.settings={title_sort='read',sort='natural'}
 local rows=p:folderRows('root',{{id='a',name='Folder A',is_folder=true},{id='b',name='Folder B',is_folder=true},{id='c',name='Chapter 2.cbz'},{id='d',name='Chapter 1.cbz'}},false)
 assert(rows[1].entry.id=='b' and rows[2].entry.id=='a')
 assert(rows[2].text=='Actual title\nAuthor' and rows[2].icon_file=='/cache/cover.jpg')
 assert(rows[2].folder_progress==0.5 and rows[3].folder_progress==nil)
 assert(rows[3].entry.id=='d' and p.settings.sort=='natural')
end)
test('storage screen localizes all three cleanup rows inside its pool loop',function()
 local storage={root='/cache',treeSize=function()return 0 end,freeBytes=function()return 12.4*1024^3 end,size=function()return 0 end,lfs={attributes=function()return nil end,dir=function()return function()return nil end end}}
 local p=instance({storage=storage,cache=function()return {usage=function()return {auto=1,offline=2,meta=3}end}end});local rows
 p.menu=function(_,_,r)rows=r end;p:showMemory()
 assert(#rows==7 and rows[4].text:find('Temporary reading cache',1,true) and rows[6].callback)
 assert(rows[1].text=='Free disk space: 13.3 GB')
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
 local core={state={docs={},sync={pending={}}},cached=function()return {path='/cache/book.cbz'}end,recordOpen=require('gdriveshelf/core').recordOpen,open=function(_,_,done)done('/cache/book.cbz')end,
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
test('file sorting is reachable in folder actions and persists independently of title sort',function()
 package.loaded.gettext={current_lang='C'}
 local p=instance({});p.settings={title_sort='read'}
 local rows;p.menu=function(_,_,r)rows=r end;local saved=0;p.saveSettings=function()saved=saved+1 end
 p:showFileSort();assert(rows[1].text:find('Natural',1,true))
 rows[3].callback();assert(p.settings.sort=='size'and p.settings.title_sort=='read'and saved==1)
 rows[#rows].callback();assert(p.settings.reverse and saved==2)
end)
test('Drive parent navigation is visible before a native Menu path stack exists',function()
 local originalMenu,originalDevice=package.loaded['ui/widget/menu'],package.loaded.device
 local Menu={}
 function Menu:extend(t)return setmetatable(t,{__index=self})end
 function Menu:updatePageInfo()self.page_return_arrow:showHide(self.onReturn~=nil)end
 function Menu:new(options)
  local arrow={showHide=function(a,v)a.visible=v end,enableDisable=function(a,v)a.enabled=v end}
  options.page_return_arrow=arrow;setmetatable(options,{__index=self});options:updatePageInfo();return options
 end
 package.loaded['ui/widget/menu']=Menu;package.loaded.device={screen={getWidth=function()return 600 end,getHeight=function()return 800 end}}
 local p=instance({});local child=p:menu('Drive folder',{}, {parent_enabled=true})
 assert(child.page_return_arrow.visible and child.page_return_arrow.enabled,'Up arrow hidden until an unrelated native redraw')
 package.loaded['ui/widget/menu'],package.loaded.device=originalMenu,originalDevice
end)
