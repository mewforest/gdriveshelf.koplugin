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
print(count..' UI adapter tests passed')
