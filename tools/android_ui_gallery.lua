-- Temporary local-only screenshot gallery in an isolated emulator profile.
local UI=require('ui/uimanager');local DS=require('datastorage')
UI:scheduleIn(3,function()
 local fm=require('apps/filemanager/filemanager').instance;local shelf=assert(fm.gdriveshelf);local core=shelf.core;core:setOffline(true);shelf.settings.sync_enabled=false
 local plan=assert(core.storage:readJSON(DS:getSettingsDir()..'/gdriveshelf-ux-plan.json'))
 local function shot(name)local p=DS:getDataDir()..'/ux-'..name..'.png';UI:forceRePaint();require('device').screen:shot(p);assert(core.storage:exists(p))end
 local function close()local top=UI:getTopmostVisibleWidget();if top and top.onCloseAllMenus then top:onCloseAllMenus()else UI:close(top)end end
 shelf:showFolder(plan.root_id);shot('folder-final');close()
 shelf.settings.folder_view='grid';shelf:showFolder(plan.novels_id);shot('books-list-final');close()
 shelf:showSettings();shot('settings-final');close()
 shelf:showSettingsCategory('catalog');shot('catalog-settings-final');close()
 shelf:showSettingsCategory('experimental');shot('experimental-final');close()
 shelf:showMemory();shot('storage-final');close()
 shelf:showHistory();shot('history-final');close()
 fm.menu:setUpdateItemTable();fm.menu:onShowMenu(#fm.menu.tab_item_table);shot('main-menu-final');fm.menu:onCloseFileManagerMenu()
 local original=core.storage.books_dir
 assert(shelf:moveBooks('/sdcard/koreader/UX UI move Books'))
 if shelf.move_dialog then shot('move-feedback');shelf.move_dialog.buttons[1][1].callback()end
 assert(not core.relocating and core.storage.books_dir==original)
 core.storage:writeJSON(DS:getDataDir()..'/gdriveshelf-ui-gallery.json',{status='passed',move_cancel=true})
end)
