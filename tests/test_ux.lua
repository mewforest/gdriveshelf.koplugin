local H=require('tests/helper')
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local function instance()
 local p=setmetatable({settings={},core={state={folders={},entries={},folder_pins={},folder_types={},listings={},summaries={}},cached=function()return nil end,folderStats=function()return {bytes=0}end,titleInfo=function()return {title='Title',chapters={}}end}},{__index=Plugin})
 p.menu=function(_,title,rows,options)return {title=title,item_table=rows,options=options}end
 p.saveSettings=function()end;return p
end
H.test('main menu opens the library directly and keeps settings separate',function()
 local p=instance();local items={};p:addToMainMenu(items)
 assert(items.gdriveshelf and items.gdriveshelf.callback and not items.gdriveshelf.sub_item_table)
 assert(items.gdriveshelf_settings and items.gdriveshelf_settings.callback)
end)
H.test('settings have categories and a single explicit offline checkbox',function()
 local p=instance();local m=p:showSettings();assert(m and #m.item_table==7)
 assert(m.item_table[1].checked~=nil and not m.item_table[1].icon)
end)
H.test('folder contents have no navigation or action pseudo-file',function()
 local p=instance();local rows=p:folderRows('p',{{id='a',name='1.cbz',parent_id='p'}},false)
 H.eq(#rows,1);H.eq(rows[1].entry.id,'a')
end)
H.test('only confirmed empty folders are hidden, containers and unknown folders stay',function()
 local p=instance();p.core.folderStats=function(_,id)return ({empty={bytes=0,count=0,folders=0,empty=true},container={bytes=0,count=0,folders=2,empty=false},unknown={bytes=0}})[id]end
 local input={{id='empty',name='Empty',is_folder=true},{id='container',name='Container',is_folder=true},{id='unknown',name='Unknown',is_folder=true}}
 local rows=p:folderRows('p',input,false);H.eq(#rows,2)
 for _,row in ipairs(rows)do assert(row.entry.id~='empty');assert(not row.text:find('Empty folder',1,true))end
 p.settings.hide_empty=false;H.eq(#p:folderRows('p',input,false),3)
end)
H.test('local covers and file sizes do not require remote beta previews',function()
 local p=instance();p.core.localCover=function()return {path='/safe/preview.png'}end;p.core.storage={exists=function()return true end}
 local row=p:folderRows('p',{{id='a',name='1.cbz',parent_id='p',size=6291456}},false)[1]
 H.eq(row.icon_file,'/safe/preview.png');assert(row.mandatory and row.mandatory:find('6',1,true))
end)
H.test('transfer progress updates status without rebuilding the folder body',function()
 local p=instance();p.folder_menu={};local statusOnly
 p.refreshBrowser=function(_,value)statusOnly=value end
 p:onCoreChange('transfer',{id='a'});H.eq(statusOnly,true)
end)
H.test('stable comic header and file grid do not depend on remote beta features',function()
 local p=instance();p.settings.file_view='grid';p.core.state.folders.p={name='Comics',id='p',parent_id='home'}
 local view=p:browserPresentation('p',{{id='a',name='1.cbz',parent_id='p'}})
 assert(view.header and view.grid)
 p.settings.info_header=false;assert(not p:browserPresentation('p',{{id='a',name='1.cbz',parent_id='p'}}).header)
end)
H.test('catalog settings expose explicit recursive consent and stable cover controls',function()
 local p=instance();local rows=p:showSettingsCategory('catalog').item_table;local text={}
 for _,row in ipairs(rows)do text[#text+1]=row.text end
 local all=table.concat(text,'\n');assert(all:find('recursively',1,true));assert(all:find('Hide empty',1,true));assert(all:find('downloaded documents',1,true))
 local beta=p:showSettingsCategory('experimental').item_table
 for _,row in ipairs(beta)do assert(not row.text:find('information header',1,true))end
end)
H.test('hiding known empty children does not mislabel their parent as empty',function()
 local p=instance();p.core.state.listings.p={complete=true};p.core.folderStats=function()return{empty=true,bytes=0}end
 local rows=p:folderRows('p',{{id='e',name='Empty',is_folder=true}},false)
 assert(rows[1].text:find('display settings',1,true))
end)
