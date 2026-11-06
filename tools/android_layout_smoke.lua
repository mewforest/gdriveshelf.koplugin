-- Temporary local-only userpatch for the isolated AVD after live UX tests.
-- Reuses disposable cached fixtures, without importing OAuth credentials.
local UI=require('ui/uimanager');local DS=require('datastorage')
UI:scheduleIn(3,function()
 local ok,err=xpcall(function()
 local shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
 shelf.core.storage:writeJSON(DS:getDataDir()..'/gdriveshelf-layout-result.json',{status='running'})
 shelf.core:setOffline(true);shelf.settings.offline=true;shelf.settings.sync_enabled=false
 local Storage=require('gdriveshelf/storage');local Core=require('gdriveshelf/core');local Jobs=require('gdriveshelf/jobs')
 local lfs=require('libs/libkoreader-lfs');local base=shelf.settings.cache_dir
 local core,parent
 for name in lfs.dir(base)do if name:match('^drive%-')then
  local store=Storage.new{root=base..'/'..name,json=require('json')}
  local state=store:readJSON(store.root..'/index.json')
  for id,folder in pairs(state and state.folders or {})do if folder.name=='UX test library'then
   local settings={};for k,v in pairs(shelf.settings)do settings[k]=v end;settings.offline=true;settings.sync_enabled=false
   core=Core.new{storage=store,jobs=Jobs.new{storage=store,dir=store.root..'/jobs'},settings=settings,credentials={},provider_factory=function()error('Network forbidden in local layout test')end};parent=id
  end end
 end end
 assert(core and parent,'cached disposable UX fixtures missing')
 shelf.core=core;shelf.settings=core.settings
 core.credentials={client_id='local-layout-fixture',refresh_token='not-a-real-token',access_token='not-a-real-token'}
 local function shot(name)
  UI:forceRePaint();local path=DS:getDataDir()..'/polish-'..name..'.png';require('device').screen:shot(path);assert(core.storage:exists(path))
 end
 local function close()if shelf.preview_menu and not shelf.preview_menu._closed then shelf.preview_menu:onCloseAllMenus()end end
 local menu=shelf.menu;shelf.menu=function(owner,...)local m=menu(owner,...);shelf.preview_menu=m;return m end
 shelf.settings.folder_view='grid';shelf.settings.file_view='grid';shelf.settings.beta_thumbnails=true;shelf.settings.beta_header=true
 local m=shelf:showFolder(parent,false);assert(m==shelf.folder_menu,'expected the cached folder browser');shot('folder')
 local first
 for _,row in ipairs(m.layout)do if row[1]and row[1].entry then
  first=first or row[1].dimen.x;assert(math.abs(first-row[1].dimen.x)<=1,'incomplete grid row is not aligned')
  for _,cell in ipairs(row)do assert(cell.dimen.x>0 and cell.dimen.x+cell:getSize().w<require('device').screen:getWidth(),'grid margin missing')end
 end end
 close();shelf:showMemory();shot('storage');close();shelf:showSettings();shot('settings');close()
 shelf:showFolderActions(parent,true);shot('actions');close();shelf:showInfo(parent);shot('information')
 assert(not core.jobs.active and #core.jobs.queue==0,'unexpected background task in offline layout test')
 core.storage:writeJSON(DS:getDataDir()..'/gdriveshelf-layout-result.json',{status='passed',grid_alignment=true,offline_no_jobs=true})
 end,debug.traceback)
 if not ok then require('logger').warn('GDriveShelf layout smoke failed',err)end
end)
