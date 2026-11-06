local H=require('tests/helper')
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
local rows={{icon='home'},{icon='wifi.open.0'},{icon='bookmark'},{icon_file='/plugin/resources/logo.png'}}
local Base={item_shortcuts={'Q','W'},perpage=2,page=1,item_table=rows,updateItems=function()end}
function Base:new(o)return setmetatable(o,{__index=self})end
function Base:extend(o)return setmetatable(o,{__index=self})end
function Base:getItemShortCutIcon()error('Native fallback should not be used for semantic icons')end
package.loaded['ui/widget/menu']=Base
package.loaded['device']={screen={getWidth=function()return 600 end,getHeight=function()return 800 end}}
package.loaded['ui/widget/container/centercontainer']={new=function(_,o)return o end}
package.loaded['ui/widget/iconwidget']={new=function(_,o)return o end}
package.loaded['ui/uimanager']={show=function()end}
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local p=setmetatable({},{__index=Plugin})
local menu=p:menu('Settings',rows,{icons=true})
H.test('settings icons use the current page without altering row actions',function()
 local a=menu:getItemShortCutIcon({w=32,h=32},'Q','square');H.eq(a[1].icon,'home')
 menu.page=2;local b=menu:getItemShortCutIcon({w=32,h=32},'Q','square');H.eq(b[1].icon,'bookmark')
 local c=menu:getItemShortCutIcon({w=32,h=32},'W','square');H.eq(c[1].file,'/plugin/resources/logo.png')
 H.eq(menu.item_shortcuts[1],'Q');H.eq(menu.item_table,rows)
end)
H.test('folder progress is a native bar under its icon without numeric labels',function()
 package.loaded['ui/widget/verticalgroup']={new=function(_,o)return o end}
 package.loaded['ui/widget/verticalspan']={new=function(_,o)return o end}
 package.loaded['ui/widget/progresswidget']={new=function(_,o)return o end}
 local menu=p:menu('Library',{{icon='home',folder_progress=0.5,text='Series'}},{icons=true})
 local slot=menu:getItemShortCutIcon({w=64,h=64},'Q','square')
 assert(slot[1][1].icon=='home'and slot[1][3].percentage==0.5)
 assert(menu.item_table[1].text=='Series'and not menu.item_table[1].mandatory)
end)
print('native menu icon tests passed')
H.test('unexpected action failures keep KOReader running and never log error payloads',function()
 local diagnostic,notice
 package.loaded.datastorage={getDataDir=function()return '/profile'end}
 package.loaded['ui/widget/infomessage']={new=function(_,o)notice=o.text;return o end}
 p.core={storage={write=function()error('A disabled or bounded logger must replace the old diagnostic file')end},logger={event=function(_,event,fields)diagnostic=event..' '..tostring(fields.module)..' '..tostring(fields.line)end}}
 local broken=p:menu('Test',{{text='Broken action',callback=function()error('demo-sensitive-token-must-not-appear')end}})
 local ok=pcall(broken.onMenuSelect,broken,broken.item_table[1]);assert(ok,'Action exception escaped into KOReader')
 assert(diagnostic and diagnostic:find('ui_error',1,true))
 assert(not diagnostic:find('demo-sensitive-token-must-not-appear',1,true))
 assert(notice and notice:lower():find('diagnostic',1,true))
end)
