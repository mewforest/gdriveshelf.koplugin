-- Offline final-paint check for the Drive-parent Up control on Android 2026.07.
local UI=require('ui/uimanager');local DS=require('datastorage');local Log=require('logger')
UI:scheduleIn(3,function()
 local core,store
 local ok=xpcall(function()
  local shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf);core=shelf.core;store=core.storage
  local plan=assert(store:readJSON(DS:getSettingsDir()..'/gdriveshelf-reliability-plan.json'))
  local metadata=assert(store:readJSON(DS:getDataDir()..'/gdriveshelf-reliability-metadata-result.json'));assert(metadata.status=='passed')
  shelf.settings.sync_enabled=false;core:setOffline(true);shelf.settings.file_view='grid'
  assert(core.state.folders[plan.previews_id].parent_id==plan.root_id)
  local menu=shelf:showFolder(plan.previews_id,true);local arrow=assert(menu.page_return_arrow)
  assert(arrow.enabled and not arrow.hidden,'Drive parent arrow is not visible from first paint')
  UI:forceRePaint();local shot=DS:getDataDir()..'/reliability-up-first-paint.png';require('device').screen:shot(shot)
  arrow.callback();assert(shelf.folder_id==plan.root_id,'Up did not navigate to Drive parent')
  assert(core.settings.offline and not core.index_job,'Offline Up started a catalog scan')
  if shelf.folder_menu then shelf.folder_menu:onCloseAllMenus()end
  local path=DS:getDataDir()..'/gdriveshelf-reliability-navigation-result.json'
  assert(store:writeJSON(path,{status='passed',checks={'Drive parent Up visible and enabled on first offline paint','Up navigates to Drive parent without online catalog work'},screenshot=shot}))
  Log.info('GDriveShelf navigation reliability: ALL PASSED')
 end,function(err)Log.warn('GDriveShelf navigation reliability failed',type(err),debug.traceback('',2))end)
 if not ok and store then store:writeJSON(DS:getDataDir()..'/gdriveshelf-reliability-navigation-result.json',{status='failed'})end
end)
