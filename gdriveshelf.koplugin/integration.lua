local I={}
function I.chooseStartup(shelf)
 local settings=G_reader_settings
 shelf:menu(require('gdriveshelf/i18n').gettext('Start with'),{
  {text='Google Drive Shelf',callback=function()settings:saveSetting('start_with','gdriveshelf')end},
  {text=require('gdriveshelf/i18n').gettext('File browser'),callback=function()settings:saveSetting('start_with','filemanager')end},
  {text=require('gdriveshelf/i18n').gettext('Most recent document'),callback=function()settings:saveSetting('start_with','last')end},
 })
end
function I.install(shelf,shared)
 if shared.integration then return end;shared.integration=true
 local ok,FMMenu=pcall(require,'apps/filemanager/filemanagermenu')
 if ok and FMMenu.getStartWithMenuTable then
  local original=FMMenu.getStartWithMenuTable
  FMMenu.getStartWithMenuTable=function(owner,...)
   local item=original(owner,...);local text=item.text_func
   item.sub_item_table[#item.sub_item_table+1]={text='Google Drive Shelf',radio=true,checked_func=function()return G_reader_settings:readSetting('start_with')=='gdriveshelf'end,callback=function()G_reader_settings:saveSetting('start_with','gdriveshelf')end}
   item.text_func=function()if G_reader_settings:readSetting('start_with')=='gdriveshelf'then return require('gdriveshelf/i18n').gettext('Start with')..': Google Drive Shelf'end;return text()end
   return item
  end
 end
 if G_reader_settings:readSetting('start_with')~='gdriveshelf'or shelf.ui.document then return end
 -- Explicit filesystem launch arguments take priority over this startup view.
 for _,value in ipairs(arg or {})do
  if type(value)=='string'and value:sub(1,1)~='-'then
   local ok,lfs=pcall(require,'libs/libkoreader-lfs');if ok and lfs.attributes(value)then return end
  end
 end
 require('ui/uimanager'):nextTick(function()shelf:runAction(function()if not shelf.ui.tearing_down then shelf:showLibrary()end end)end)
end
return I
