-- One-shot final installed-ZIP check. Removes its own startup patch immediately.
local DS=require('datastorage');local UI=require('ui/uimanager');local Log=require('logger')
os.remove(DS:getDataDir()..'/patches/2-gdriveshelf-final-offline.lua')
UI:scheduleIn(5,function()
 local result={status='failed'};local core
 local ok=xpcall(function()
  local owner=require('apps/reader/readerui').instance or require('apps/filemanager/filemanager').instance
  local shelf=assert(owner and owner.gdriveshelf);core=assert(shelf.core)
  local plugin=DS:getDataDir()..'/plugins/gdriveshelf.koplugin'
  local f=assert(io.open(plugin..'/PACKAGE_VERSION','rb'));local version=(f:read(64)or''):gsub('%s+$','');f:close()
  local meta=assert(loadfile(plugin..'/_meta.lua'))()
  assert(version=='0.1.7'and meta.version=='0.1.7');assert(core:networkState()=='offline')
  assert(not core.storage:exists(DS:getSettingsDir()..'/gdriveshelf-credentials.json'))
  result={status='passed',package_version=version,metadata_version=meta.version,offline=true,credentials_absent=true,plugin_loaded=true}
  Log.info('GDriveShelf final offline boot: ALL PASSED')
 end,function(err)Log.warn('GDriveShelf final offline boot failed',type(err),debug.traceback('',2))end)
 if core then core.storage:writeJSON(DS:getDataDir()..'/gdriveshelf-final-offline-boot.json',result)end
end)
