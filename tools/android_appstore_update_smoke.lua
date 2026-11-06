-- Temporary userpatch for the isolated AVD only. Install after all Drive tests
-- finish. Fixture input is public code + synthetic assets; account data from
-- the existing profile is never copied, replaced, imported, or exported.
local UI=require('ui/uimanager')
UI:scheduleIn(3,function()
 local android=require('android');local ffi=require('ffi');local util=require('util')
 local external=android.getExternalStoragePath()..'/koreader/appstore-native-fixtures'
 local source=external..'/source'
 local profile=android.dir..'/gdriveshelf-appstore-reliability-20261107-v2'
 local Storage=dofile(source..'/gdriveshelf.koplugin/storage.lua')
 local original_ds=package.loaded.datastorage
 local output=Storage.new{root=external}
 assert(util.makePath(profile))
 local phase=output:exists(profile..'/fixture-manifest.json')and 'restart'or 'install'
 local reader_settings,defaults=G_reader_settings,G_defaults
 local old_path=package.path;local old_home=os.getenv('KO_HOME')
 local old_http=require('socket.http').request
 local saved_loaded,saved_preload={},{}
 local function owned(name)return name:match('^gdriveshelf/')or name:match('^appstore_')end
 for name,value in pairs(package.loaded)do if owned(name)then saved_loaded[name]=value;package.loaded[name]=nil end end
 for name,value in pairs(package.preload)do if owned(name)then saved_preload[name]=value;package.preload[name]=nil end end
 pcall(ffi.cdef,'int setenv(const char *,const char *,int); int unsetenv(const char *);')
 local function restore()
  require('socket.http').request=old_http
  if old_home then ffi.C.setenv('KO_HOME',old_home,1)else ffi.C.unsetenv('KO_HOME')end
  package.loaded.datastorage=original_ds;G_reader_settings=reader_settings;G_defaults=defaults;package.path=old_path
  for name in pairs(package.loaded)do if owned(name)then package.loaded[name]=nil end end
  for name in pairs(package.preload)do if owned(name)then package.preload[name]=nil end end
  for name,value in pairs(saved_loaded)do package.loaded[name]=value end
  for name,value in pairs(saved_preload)do package.preload[name]=value end
  require('gettext').changeLang(reader_settings:readSetting('language')or 'en_US')
  _G.GDriveShelfAppStoreFixture=nil
 end
 output:writeJSON(external..'/android-status.json',{status='running',phase=phase})
 local ok,why=xpcall(function()
  assert(ffi.C.setenv('KO_HOME',profile,1)==0)
  -- Reload the actual DataStorage implementation under a real private KO_HOME.
  -- This is fixture configuration, not a replacement storage/installer API.
  package.loaded.datastorage=nil
  local owner=require('apps/reader/readerui').instance or require('apps/filemanager/filemanager').instance
  assert(owner,'Wait for the native file manager before running this patch')
  _G.GDriveShelfAppStoreFixture={embedded=true,source=source,artifacts=external,mode='legacy',phase=phase,route='release',ui=owner}
  dofile(source..'/tools/appstore_update_smoke.lua')
  for _,name in ipairs{phase..'-results.json','appstore-update-available.png','appstore-up-to-date.png','appstore-restarted-up-to-date.png'}do
   local bytes=output:read(profile..'/'..name,8*1048576)
   if bytes then assert(output:write(external..'/android-'..name,bytes))end
  end
 end,debug.traceback)
 restore()
 if ok then
  assert(output:writeJSON(external..'/android-status.json',{status='pass',phase=phase,version='0.1.701',real_network_requests=0,upstream_installer='unmodified',only_mock='GitHub HTTP transport',profile='app-private isolated fixture'}))
  require('logger').info('GDriveShelf AppStore Android: PASS '..phase)
 else
  output:writeJSON(external..'/android-status.json',{status='failed',phase=phase,detail=tostring(why)})
  require('logger').warn('GDriveShelf AppStore Android: failed '..phase)
 end
end)
