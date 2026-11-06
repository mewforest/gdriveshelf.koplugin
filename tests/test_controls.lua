local H=require('tests/helper')
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local function instance()
 return setmetatable({settings={home='library'},core={state={downloads={},entries={},folders={},sync={pending={},conflicts={}}},jobs={queue={}},transfer={}}},{__index=Plugin})
end
H.test('background activity shows document and progress rather than internal task identifiers',function()
 local p=instance();H.eq(p:downloadActivity(),nil)
 p.core.state.downloads['private-id']={entry={name='Example.cbz'}}
 p.core.jobs.active={key='download:private-id'};p.core.transfer['private-id']={received=50,total=100}
 local text=p:downloadActivity();assert(text:find('Example.cbz',1,true)and text:find('50%',1,true));assert(not text:find('private-id',1,true))
 p.core.networkState=function()return 'retry'end
 assert(p:downloadActivity():find('Waiting',1,true))
end)
H.test('recursive indexing requires explicit confirmation',function()
 local p=instance();local dialog;local started=0
 p.core.reindexHome=function()started=started+1 end
 p.saveSettings=function()end;p.showSettingsCategory=function()end
 p.confirmation=function(_,options)dialog=options;return options end
 package.loaded['ui/uimanager']={show=function()end}
 p:enableRecursiveIndex();assert(not p.settings.index_enabled and started==0)
 dialog.ok_callback();assert(p.settings.index_enabled and p.settings.index_recursive_confirmed and started==1)
end)
H.test('metadata editor abbreviates descriptions without cutting UTF-8 characters',function()
 local p=instance();p.core.titleInfo=function()return{title='Title',description=string.rep('Я',101)}end
 p.menu=function(_,title,rows)return {item_table=rows}end
 local menu=p:editFolderMetadata({id='folder',name='Folder'})
 H.eq(menu.item_table[2].text,'Description: '..string.rep('Я',100)..'…')
end)
