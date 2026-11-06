-- Native browser presentation regression; no provider, account or document data.
require('setupkoenv')
local root=assert(os.getenv('GDRIVESHELF_ROOT'))
local output=assert(os.getenv('GDRIVESHELF_OUTPUT'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(output..'/browser-reader.lua')
G_reader_settings:saveSetting('language','en_US')
G_reader_settings:saveSetting('sdl_window',{width=tonumber(os.getenv('GDRIVESHELF_LAYOUT_WIDTH'))or 600,height=tonumber(os.getenv('GDRIVESHELF_LAYOUT_HEIGHT'))or 800})
local Screen=require('device').screen
require('document/canvascontext'):init(require('device'));require('ui/bidi').setup('en_US')
dofile(root..'/gdriveshelf.koplugin/bootstrap.lua')(root..'/gdriveshelf.koplugin')
local UI=require('ui/uimanager');local B=require('gdriveshelf/browser')
local function find(widget,predicate)
 if predicate(widget)then return widget end
 for _,child in ipairs(widget)do local match=find(child,predicate);if match then return match end end
end
local function text(widget,value)return find(widget,function(w)return w.text==value end)end
local buttons={};for i=1,6 do buttons[i]={icon='home',callback=function()end}end
local header=B.header{width=Screen:getWidth(),title='Library',status='Offline',buttons=buttons,
 summary={text='A title without a cover',bold=true,height=Screen:scaleBySize(256)},activity='Downloading 1 / 3 · 24%',activity_callback=function()end}
local summary=assert(text(header,'A title without a cover'))
assert(summary:getSize().h<Screen:scaleBySize(100),'coverless summary reserves an empty cover-height block')
assert(type(header.setActivity)=='function','activity has no partial-update method')
local Menu=B.gridClass(require('ui/widget/menu'))
local entries={}
for i=1,11 do entries[i]={text='Document '..i,card_title='A long document title '..i,card_left='25.6 MiB',card_right='5 files',card_fallback='Cache: 25.6 MiB · 5 files',folder_progress=.25,callback=function()end}end
entries[2].card_left='1024.5 GiB cached';entries[2].card_right='100000 documents';entries[2].card_fallback='Cache: 1024 GiB · 100k files'
local menu=Menu:new{title='Library',item_table=entries,width=Screen:getWidth(),height=Screen:getHeight(),custom_title_bar=header,items_per_page=9,is_borderless=true,is_enable_shortcut=false}
UI:show(menu);UI:forceRePaint()
local left=assert(text(menu,'25.6 MiB'),'missing left badge');local right=assert(text(menu,'5 files'),'missing right badge')
local badgeRow=assert(find(menu,function(w)return w[1]==left and w[3]==right end))
assert(badgeRow[2]:getSize().w>=Screen:scaleBySize(8),'card corner badges overlap')
assert(text(menu,entries[2].card_fallback),'long corner badges do not use a compact fallback')
local rows=0
for _,row in ipairs(menu.layout)do if row[1]and row[1].entry then rows=rows+1;assert(#row==3,'grid lost its three full columns')end end
assert(rows==3,'grid lost its three fixed rows')
local activity=assert(text(header,'Downloading 1 / 3 · 24%'))
local dimen=activity[1].dimen:copy();local original=UI.setDirty;local dirty={}
local before=Screen.bb:copy()
UI.setDirty=function(_,widget,mode,region)
 if type(mode)=='function'then mode,region=mode()end
 dirty[#dirty+1]={widget=widget,mode=mode,region=region}
end
local good,why=pcall(header.setActivity,header,'Downloading 1 / 3 · 52%');UI.setDirty=original;assert(good,why)
assert(#dirty==1 and dirty[1].region,'activity must request exactly one bounded repaint')
local region=dirty[1].region
assert(region.x==dimen.x and region.y==dimen.y and region.w==dimen.w and region.h==dimen.h,'activity repaint includes the grid or changes geometry')
local after=Screen.bb:copy();after:blitFrom(before,region.x,region.y,region.x,region.y,region.w,region.h)
assert(require('ffi/blitbuffer').tostring(before)==require('ffi/blitbuffer').tostring(after),'activity update changes pixels outside its button')
before:free();after:free()
UI:forceRePaint();assert(Screen:shot(output..'/browser-'..Screen:getWidth()..'x'..Screen:getHeight()..'.png'))
UI:close(menu)
local image=os.getenv('GDRIVESHELF_LAYOUT_IMAGE')or root..'/gdriveshelf.koplugin/resources/logo.png'
local coverHeader=B.header{width=Screen:getWidth(),title='Library',status='Offline',buttons={},summary={text='A bold series title',bold=true,height=Screen:scaleBySize(256),cover_path=image}}
local cover=assert(find(coverHeader,function(w)return w.file==image end))
assert(cover:getSize().h==Screen:scaleBySize(128),'cover is not enlarged to the bounded 128dp maximum')
local coverMenu=Menu:new{title='Library',item_table=entries,width=Screen:getWidth(),height=Screen:getHeight(),custom_title_bar=coverHeader,items_per_page=9,is_borderless=true,is_enable_shortcut=false}
UI:show(coverMenu);UI:forceRePaint();assert(Screen:shot(output..'/browser-cover-'..Screen:getWidth()..'x'..Screen:getHeight()..'.png'));UI:close(coverMenu)
print('PASS browser summary, corner badges, fixed grid and bounded activity repaint')
