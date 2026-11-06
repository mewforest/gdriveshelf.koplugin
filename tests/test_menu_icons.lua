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
print('native menu icon tests passed')
