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
