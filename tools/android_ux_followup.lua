-- Native UX and interrupted-move recovery in the disposable emulator profile.
local UI=require('ui/uimanager');local DS=require('datastorage');local Log=require('logger')
local path=DS:getDataDir()..'/gdriveshelf-ux-followup.json';local store,core,shelf,plan;local checks={};local stage='init'
local function save(status,extra)store:writeJSON(path,{status=status,stage=stage,checks=checks,extra=extra})end
local function pass(name)checks[#checks+1]=name;Log.info('GDriveShelf UX followup: PASS '..name);save('running')end
local function guard(fn)return function(...)
 local args={...};xpcall(function()fn(unpack(args))end,function(err)Log.warn('GDriveShelf UX followup failed',stage,type(err),debug.traceback('',2));save('failed')end)
end end
local function wait(name,condition,done)
 stage=name;save('running');local deadline=require('socket').gettime()+180
 local function poll()if condition()then guard(done)()elseif require('socket').gettime()>deadline then save('failed')else UI:scheduleIn(.2,guard(poll))end end
 UI:scheduleIn(.1,guard(poll))
end
local function shot(name)local output=DS:getDataDir()..'/ux-'..name..'.png';UI:forceRePaint();require('device').screen:shot(output);assert(store:exists(output))end
local function reader()return require('apps/reader/readerui').instance end
local function idle()return not core.jobs.active and #core.jobs.queue==0 end
local function crashCommit()
 local Relocation=require('gdriveshelf/relocation');local finalize=Relocation.finalize
 Relocation.finalize=function()error('simulated process interruption after index commit')end
 local oldPDF=core:cached(plan.documents[2].id).path
 local destination='/sdcard/koreader/UX recovery '..os.time()..' Books'
 assert(core:relocateBooks(destination,function()end))
 wait('interrupted-commit',function()return not core.relocating and idle()end,function()
  Relocation.finalize=finalize
  assert(core.state.books_dir:match('/UX recovery .* Books$')~=nil and store:exists(oldPDF))
  assert(store:readJSON(store.root..'/relocation.json').phase=='committing')
  G_reader_settings:saveSetting('quickstart_shown_version',2026070000);G_reader_settings:saveSetting('start_with','last');G_reader_settings:saveSetting('lastfile',oldPDF);G_reader_settings:flush()
  stage='commit-restart';save('restart-needed',{oldPDF=oldPDF});Log.info('GDriveShelf UX followup: RESTART NEEDED commit')
 end)
end
local function resumeMove()
 local start=core.jobs.backend.start
 core.jobs.backend.start=function(task,resultPath)
  return start(function()
   local ok,value,err=xpcall(task,debug.traceback)
   if not ok then Log.warn('GDriveShelf relocation worker probe',value);error('Relocation probe failed')end
   return value,err
  end,resultPath)
 end
 local old=core.storage.books_dir;local pdf=assert(core:cached(plan.documents[2].id));local originalPDF=pdf.path
 assert(core:relocateBooks('/sdcard/koreader/UX resume Books',function()end));assert(core.relocating)
 local opened;core:open(plan.documents[2],function(p)opened=p end);core.opening_id=nil
 assert(opened==originalPDF and not core.relocating and core.storage.books_dir==old)
 pass('opening a cached book cancels an unfinished move before path changes')
 local doc=require('docsettings'):open(originalPDF);doc.data.last_page=3;assert(doc:flush(doc.data))
 local done,err;assert(core:relocateBooks('/sdcard/koreader/UX resume Books',function(ok,why)done=ok;err=why end))
 wait('resume-offline-move',function()return not core.relocating and idle()end,function()
  if not done then Log.warn('GDriveShelf relocation result',err and err.code,err and err.message)end
  assert(done and not err);local newPDF=core:cached(plan.documents[2].id).path
  assert(newPDF~=originalPDF and require('docsettings'):open(newPDF).data.last_page==3)
  pass('offline interrupted move resumes and refreshes newer native reading metadata')
  -- Refresh + eviction must retain identity for the next relocation.
  local e=plan.books[1];core:rememberList(e.parent_id,core:cachedList(e.parent_id))
  local archived=core:cached(e.id)
  if archived then core:removeFile(e.id);assert(core.state.docs[e.id].local_path and not core:cached(e.id))end
  pass('folder refresh and archive eviction retain durable document paths')
  crashCommit()
 end)
end
local function screens()
 local fm=require('apps/filemanager/filemanager').instance
 fm.menu:setUpdateItemTable();local tab=fm.menu.tab_item_table[#fm.menu.tab_item_table];local direct
 for _,item in ipairs(tab)do if item.text=='Google Drive Shelf'then assert(item.callback and not item.sub_item_table);direct=item end end
 assert(direct);fm.menu:onShowMenu(#fm.menu.tab_item_table);shot('main-menu');fm.menu:onCloseFileManagerMenu();pass('direct library entry is in the native right-hand menu without NEW prefix')
 shelf.settings.folder_view='grid';shelf:showFolder(plan.root_id);shot('home-final');shelf.folder_menu:onCloseAllMenus()
 shelf:showSettings();shot('settings-final');UI:getTopmostVisibleWidget():onCloseAllMenus()
 shelf:showMemory();shot('storage-final');UI:getTopmostVisibleWidget():onCloseAllMenus()
 core:setOffline(false);shelf.settings.sync_enabled=false
 core:folder(plan.root_id,'UX test library',guard(function(entries,cached)
  if cached then return end
  wait('cover-worker',idle,function()
   local cover
   for _,e in ipairs(plan.metadata)do if e.name=='cover.jpg'then cover=core:cached(e.id)end end
   assert(cover and cover.preview_path and store:exists(cover.preview_path));pass('folder cover is bounded and resized in the background worker')
   core:setOffline(true);resumeMove()
  end)
 end))
end
UI:scheduleIn(3,guard(function()
 local r=reader();shelf=assert((r or require('apps/filemanager/filemanager').instance).gdriveshelf);core=shelf.core;store=core.storage
 plan=assert(store:readJSON(DS:getSettingsDir()..'/gdriveshelf-ux-plan.json'))
 local previous=store:readJSON(path)
 if previous then checks=previous.checks or {}end
 shelf.settings.sync_enabled=false;core:setOffline(true)
 G_reader_settings:saveSetting('document_metadata_folder','doc')
 if previous and previous.stage=='commit-restart'and previous.status=='restart-needed'then
  Log.warn('GDriveShelf recovery identity',r~=nil,shelf:activeEntry()~=nil,r and r.document.file==previous.extra.oldPDF,(core.state.relocation_aliases or {})[previous.extra.oldPDF]~=nil)
  assert(r and shelf:activeEntry()and r.document.file==previous.extra.oldPDF)
  pass('startup journal recovery recognizes an already-open old path')
  r:handleEvent(require('ui/event'):new('GotoPage',4));r:saveSettings();r:showFileManager();r:onClose()
  shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
  local current=assert(core:cached(plan.documents[2].id)).path
  assert(require('docsettings'):open(current).data.last_page==4)
  assert(not store:readJSON(store.root..'/relocation.json'));pass('closing recovered old reader preserves its latest progress at the new path')
  G_reader_settings:saveSetting('start_with','filemanager');G_reader_settings:flush();shelf:saveSettings();stage='done';save('passed');return
 end
 if previous and previous.status=='failed'and previous.stage=='init'then
  if r then r:showFileManager();r:onClose()end;shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf);crashCommit();return
 end
 if previous and previous.status=='failed'and previous.stage=='resume-offline-move'then resumeMove();return end
 if previous and previous.stage=='startup-restart'and previous.status=='restart-needed'then
  assert(shelf.folder_menu and shelf.folder_id==plan.root_id);shelf.folder_menu:onCloseAllMenus()
  pass('native Start with Google Drive Shelf opens the configured home folder')
  G_reader_settings:saveSetting('start_with','filemanager');G_reader_settings:flush();screens();return
 end
 local fm=require('apps/filemanager/filemanager').instance
 local startup=fm.menu:getStartWithMenuTable();local option
 for _,item in ipairs(startup.sub_item_table)do if item.text=='Google Drive Shelf'then option=item end end
 assert(option);option.callback();G_reader_settings:flush();stage='startup-restart';save('restart-needed');Log.info('GDriveShelf UX followup: RESTART NEEDED startup')
end))
