-- Native widget geometry regression: no Drive access or account data.
require('setupkoenv')
local root=assert(os.getenv('GDRIVESHELF_ROOT'))
local output=assert(os.getenv('GDRIVESHELF_OUTPUT'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(output..'/layout-reader.lua')
G_reader_settings:saveSetting('language','en_US')
local Device=require('device');require('document/canvascontext'):init(Device);require('ui/bidi').setup('en_US')
dofile(root..'/gdriveshelf.koplugin/bootstrap.lua')(root..'/gdriveshelf.koplugin')
local UI=require('ui/uimanager');local B=require('gdriveshelf/browser')
local image=os.getenv('GDRIVESHELF_LAYOUT_IMAGE')or root..'/gdriveshelf.koplugin/resources/logo.png'
local Menu=B.gridClass(require('ui/widget/menu'))
for _,count in ipairs{5,9,11}do
 local entries={}
 for i=1,count do entries[i]={text='Example document '..i,card_title='A very long example document title '..i,card_details='5 files\n✓ 25.6 MiB',folder_progress=.25,icon_file=i%2==1 and image or nil,callback=function()end}end
 local buttons={};for i=1,6 do buttons[i]={icon='home',callback=function()end}end
 local header=B.header{width=Device.screen:getWidth(),title='Library',status='Google Drive Shelf',buttons=buttons,summary=count==5 and {cover_path=image,text='Long title\nExample author\nA short description of the current folder.',height=math.floor(Device.screen:getHeight()*.16)}or nil,close=function()end}
 local m=Menu:new{title='Library',item_table=entries,width=Device.screen:getWidth(),height=Device.screen:getHeight(),custom_title_bar=header,items_per_page=9,is_borderless=true,is_enable_shortcut=false}
 UI:show(m);UI:forceRePaint()
 local function check()
  local first
  for _,row in ipairs(m.layout)do
   if row[1]and row[1].entry then
   first=first or row[1].dimen
   assert(math.abs(row[1].dimen.x-first.x)<=1,'incomplete row is centered instead of aligned to the first column')
   for x,cell in ipairs(row)do
    assert(cell.dimen.x>=Device.screen:scaleBySize(8),'missing outer grid margin')
    assert(cell.dimen.x+cell:getSize().w<=Device.screen:getWidth(),'card outside screen')
    local center=cell[1][1];assert(center[1]:getSize().h<=center.dimen.h,'card text and image overflow the inner height')
    if x>1 then local previous=row[x-1];assert(cell.dimen.x-previous.dimen.x-previous:getSize().w>=Device.screen:scaleBySize(4),'cards touch without a gutter')end
   end
   end
  end
 end
 check();if count>9 then m:onGotoPage(2);UI:forceRePaint();check()end
 UI:close(m)
 print('PASS native grid geometry: '..count..' entries')
end
print('PASS native layout regression')
