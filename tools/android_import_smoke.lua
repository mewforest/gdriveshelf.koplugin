-- Isolated emulator userpatch: install as patches/2-gdriveshelf-import-test.lua.
-- Requires plugin + synthetic fixture and offline settings; never use real tokens.
local UI=require('ui/uimanager')
UI:scheduleIn(3,function()
 local owner=require('apps/reader/readerui').instance or require('apps/filemanager/filemanager').instance
 local shelf=assert(owner and owner.gdriveshelf,'GDriveShelf not loaded')
 assert(shelf.settings.offline,'This regression must run offline')
 shelf.core.credentials={}
 shelf:showLibrary()
 local chooser=shelf:pickCredentials()
 chooser:changeToPath('/storage/emulated/0/Download')
 local selected
 for _,item in ipairs(chooser.item_table)do if item.text=='gdriveshelf-credentials.json'then selected=item end end
 assert(selected,'Synthetic credential fixture not found')
 require('logger').info('GDriveShelf Android smoke: selecting synthetic JSON')
 chooser:onFileSelect(selected)
 assert(shelf:hasCredentials(),'Credential import failed')
 assert(shelf.folder_menu and not shelf.connection_menu,'Library transition failed')
 assert(not shelf.core.jobs.active and #shelf.core.jobs.queue==0,'Offline test started network work')
 local ffi=require('ffi')
 assert(ffi.C.fchmod,'Missing fchmod declaration')
 require('logger').info('GDriveShelf Android smoke: PASS import and library transition')
 -- Exercise the real Android subprocess/IPC path without contacting Drive.
 local core=shelf.core;local factory=core.provider_factory;local beats=0;local finished=false
 local function beat()beats=beats+1;if not finished then UI:scheduleIn(0.05,beat)end end
 core.provider_factory=function(credentials)return {credentials=credentials,list=function()
  require('socket').sleep(0.4)
  return {{id='android-smoke-item',name='Background smoke',is_folder=true,parent_id='android-smoke-parent'}}
 end}end
 UI:scheduleIn(0.01,beat);core:setOffline(false)
 core:folder('android-smoke-parent','Background test',function(entries,cached,e)
  assert(entries and not e and entries[1].id=='android-smoke-item','Background listing failed')
  if cached then return end
  finished=true;assert(beats>=3,'Android UI timer blocked during worker')
  core:setOffline(true);core.provider_factory=factory;shelf:saveSettings()
  require('logger').info('GDriveShelf Android smoke: PASS real worker/IPC and responsive UI')
  -- Optional local archive supplied by adb; no network or Drive IDs are used.
  local fixture='/storage/emulated/0/Download/GDriveShelf-smoke.cbz'
  local input=io.open(fixture,'rb');if not input then return end
  local entry={id='android-smoke-book',name='Android smoke.cbz',parent_id='android-smoke-title'}
  local path=core.storage:filePath(entry,'offline');local output=assert(io.open(path,'wb'))
  while true do local chunk=input:read(65536);if not chunk then break end;assert(output:write(chunk))end
  input:close();output:close()
  entry.path=path;entry.pool='offline';entry.ready=true;entry.size=core.storage:size(path)
  core.state.entries[entry.id]=entry;core.state.docs[entry.id]=entry
  core.state.folders[entry.parent_id]={id=entry.parent_id,name='Android smoke',is_folder=true}
  core:rememberList(entry.parent_id,{entry});core:save();shelf:openEntry(entry)
  UI:scheduleIn(2,function()
   local reader=assert(require('apps/reader/readerui').instance)
   assert(reader.document.file==path and reader.document:getPageCount()>1,'Native CBZ did not open')
   reader:handleEvent(require('ui/event'):new('GotoPage',2));reader:saveSettings()
   assert(require('docsettings'):hasSidecarFile(path),'Native SDR was not saved')
   require('logger').info('GDriveShelf Android smoke: PASS native CBZ, page navigation and SDR save')
  end)
 end)
end)
