-- Temporary userpatch for an isolated AVD. Only plan.root_id descendants may be written.
local UI=require('ui/uimanager');local DS=require('datastorage');local Log=require('logger')
local resultPath=DS:getDataDir()..'/gdriveshelf-ux-result.json'
local shelf,core,store,plan;local stage='start';local checks={};local elapsed=require('socket').gettime
local function report(status)if store then store:writeJSON(resultPath,{status=status,stage=stage,checks=checks})end end
local function guard(fn)return function(...)
 local args={...};local ok= xpcall(function()fn(unpack(args))end,function(err)Log.warn('GDriveShelf UX smoke failed',stage,type(err),debug.traceback('',2));report('failed')end);return ok
end end
local function pass(name)checks[#checks+1]=name;Log.info('GDriveShelf UX: PASS '..name);report('running')end
local function wait(name,condition,done)
 stage=name;report('running');local deadline=elapsed()+240
 local function poll()if condition()then guard(done)()elseif elapsed()>deadline then report('failed')else UI:scheduleIn(.2,guard(poll))end end
 UI:scheduleIn(.1,guard(poll))
end
local function idle()return not core.jobs.active and #core.jobs.queue==0 end
local function reader()return require('apps/reader/readerui').instance end
local function showing(e)local r=reader();return r and core:cached(e.id)and r.document.file==core:cached(e.id).path end
local function shot(name)UI:forceRePaint();local path=DS:getDataDir()..'/ux-'..name..'.png';require('device').screen:shot(path);assert(store:exists(path))end
local function closeMenus()if shelf.folder_menu then shelf.folder_menu:onCloseAllMenus()end end
local function finishPage()
 local r=assert(reader());r:handleEvent(require('ui/event'):new('GotoPage',r.document:getPageCount()))
 for _=1,4 do r.paging:onGotoPageRel(1)end
end
local function finish()
 core:setOffline(true);shelf.settings.beta_auto_scan=false;shelf.settings.index_enabled=false;shelf:saveSettings()
 stage='done';report('passed');Log.info('GDriveShelf UX: ALL PASSED')
end
local function relocation()
 local r=reader();if r then r:showFileManager();r:onClose()end
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
 wait('before-relocation',idle,function()
  local old=core.storage.books_dir;local done,why
  assert(shelf:moveBooks('/sdcard/koreader/UX moved Books'))
  wait('relocation',function()return not core.relocating end,function()
   assert(core.storage.books_dir=='/sdcard/koreader/UX moved Books')
   local e=core:cached(plan.documents[1].id);assert(e and e.path:find('/UX moved Books/',1,true))
   assert(require('docsettings'):hasSidecarFile(e.path));pass('readable document folder relocation preserves native metadata and cached books')
   finish()
  end)
 end)
end
local function books()
 local tasks={};for _,location in ipairs{'doc','dir','hash'}do for _,entry in ipairs(plan.documents)do tasks[#tasks+1]={entry=entry,location=location}end end
 local index=0
 local function nextBook()
  index=index+1;local task=tasks[index];if not task then
   local r=reader();if r then r:showFileManager();r:onClose()end;shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
   shelf.settings.sync_enabled=true;core:setOffline(false);core:flushPending()
   wait('book-cloud-sync',function()return not next(core.state.sync.pending)and idle()end,function()
    assert(not next(core.state.sync.conflicts));local verified=0
    for _,entry in ipairs(plan.documents)do local e=entry
     core:network('verify-book:'..e.id,function(provider)return core:sync(provider):pull(e)end,function(result,err)
      assert(result and result.lua and not err);local data=assert(require('gdriveshelf/sdr').decode(result.lua))
      if e.name:match('%.epub$')then assert(type(data.last_xpointer)=='string')else assert(data.last_page==2)end
      verified=verified+1;if verified==#plan.documents then pass('EPUB xpointer and PDF page roundtrip through native Drive SDR after centralized storage');relocation()end
     end)
    end
   end)
   return
  end
  local r=reader();if r then r:showFileManager();r:onClose()end
  shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
  G_reader_settings:saveSetting('document_metadata_folder',task.location)
  core:setOffline(false);shelf.settings.prefetch_books=false;shelf:openEntry(task.entry)
  wait('book-'..task.location..'-'..task.entry.name,function()return showing(task.entry)end,function()
   local current=reader();assert(core:cached(task.entry.id).path:find('Example books',1,true))
   current:handleEvent(require('ui/event'):new('GotoPage',2));current:saveSettings()
   UI:scheduleIn(.4,guard(function()
    current:showFileManager();current:onClose();shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
    local path=assert(core:cached(task.entry.id)).path;local settings=require('docsettings'):open(path)
    if task.entry.name:match('%.epub$')then assert(type(settings.data.last_xpointer)=='string')else assert(settings.data.last_page==2)end
    assert(core.state.sync.pending[task.entry.id]);pass(task.entry.name..' position and durable pending progress in '..task.location..' metadata mode')
    core:setOffline(true);local seq=core.jobs.seq;local started=elapsed();shelf:openEntry(task.entry)
    wait('book-offline-reopen',function()return showing(task.entry)end,function()
     assert(core.jobs.seq==seq and elapsed()-started<2)
     if task.entry.name:match('%.pdf$')then assert(reader().paging.current_page==2)end
     if index==1 then shot('epub')elseif index==2 then shot('pdf')end
     pass(task.entry.name..' offline reopen without a network job')
     nextBook()
    end)
   end))
  end)
 end
 nextBook()
end
local function synchronization()
 local r=reader();r:saveSettings();r:showFileManager();r:onClose()
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
 core:setOffline(false);shelf.settings.sync_enabled=true;core:flushPending()
 wait('native-progress-sync',function()return not next(core.state.sync.pending)and idle()end,function()
  assert(not next(core.state.sync.conflicts));pass('native comic progress uploads after offline reading')
  shelf.settings.sync_enabled=false;books()
 end)
end
local function popupNext()
 shelf=assert(reader().gdriveshelf)
 shelf:openEntry(plan.books[1]);wait('popup-first',function()return showing(plan.books[1])end,function()
  shelf=assert(reader().gdriveshelf)
  core:removeFile(plan.books[2].id);core:setOffline(false)
  G_reader_settings:saveSetting('end_document_action','pop-up');finishPage()
  local popup=UI:getTopmostVisibleWidget();assert(popup and popup.name=='end_document')
  local original=shelf.openEntry;local invoked=false
  shelf.openEntry=function(owner,entry,...)invoked=true;return original(owner,entry,...)end
  popup.buttons[2][2].callback()
  UI:scheduleIn(.2,guard(function()
   assert(invoked and shelf.download_dialog);shot('popup-next-download');pass('native end popup next action immediately shows download feedback')
   wait('popup-next-opened',function()return showing(plan.books[2])end,function()synchronization()end)
  end))
 end)
end
local function autoNext()
 shelf:openEntry(plan.books[1]);wait('first-comic',function()return showing(plan.books[1])end,function()
  shelf=assert(reader().gdriveshelf);G_reader_settings:saveSetting('end_document_action','next_file')
  reader():handleEvent(require('ui/event'):new('GotoPage',1))
  shelf.settings.prefetch=1;shelf.settings.threshold=0;reader():handleEvent(require('ui/event'):new('GotoPage',2))
  -- The next chapter is already a prefetch task when native EOF asks for it.
  assert(core.state.downloads[plan.books[2].id]);finishPage()
  UI:scheduleIn(.2,guard(function()
   assert(shelf.download_dialog);shot('automatic-next-download');pass('automatic EOF joins active prefetch and immediately shows download feedback')
   wait('automatic-next-opened',function()return showing(plan.books[2])end,function()
    pass('native next opens the right chapter with stable readable paths')
    shelf=assert(reader().gdriveshelf);shelf.settings.prefetch=0;core:setOffline(true);popupNext()
   end)
  end))
 end)
end
local function previews()
 shelf.settings.beta_thumbnails=true;core:deepScan({id=plan.root_id,name='UX test library'})
 wait('deep-preview-scan',function()return not core.deep_job and idle()end,function()
  for _,entry in ipairs(plan.preview_files)do local thumb=assert(core:cached('thumb:'..entry.id));assert(thumb.range_bytes>0 and thumb.range_bytes<entry.size)end
  assert(core:titleInfo(plan.previews_id).cover_path);pass('live Store/Deflate Range thumbnails and first-chapter folder-cover fallback')
  shelf.settings.file_view='grid';shelf:showFolder(plan.previews_id);shot('chapter-tiles');closeMenus()
  core:setOffline(false);shelf.settings.beta_header=true;shelf:showFolder(plan.root_id);shot('expanded-header');closeMenus()
  shelf:openEntry(plan.books[3]);assert(shelf.download_dialog);shot('download-cancel')
  shelf.download_dialog.widget.buttons[1][1].callback()
  UI:scheduleIn(.5,guard(function()
   assert(not reader()and not core.opening_id);pass('cancelled download does not open a stale document')
   autoNext()
  end))
 end)
end
UI:scheduleIn(3,guard(function()
 local oldReader=reader();if oldReader then oldReader:showFileManager();oldReader:onClose()end
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf);core=shelf.core;store=core.storage
 plan=assert(store:readJSON(DS:getSettingsDir()..'/gdriveshelf-ux-plan.json'))
 assert(shelf:importCredentials(DS:getSettingsDir()..'/gdriveshelf-ux-import.json'));core=shelf.core;store=core.storage
 -- Restrict even accidental native-SDR writes to this disposable subtree.
 local Provider=require('gdriveshelf/providers/gdrive');local mkdir,upload=Provider.mkdir,Provider.upload;local allowed={[plan.root_id]=true}
 local function inside(provider,id)
  if allowed[id]then return true end
  local seen={};local current=id
  while current and not seen[current]do if current==plan.root_id then allowed[id]=true;return true end;seen[current]=true;local e=provider:stat(current);current=e and e.parent_id end
  return false
 end
 Provider.mkdir=function(provider,parent,...)assert(inside(provider,parent),'Write outside UX fixture refused');return mkdir(provider,parent,...)end
 Provider.upload=function(provider,parent,...)assert(inside(provider,parent),'Write outside UX fixture refused');return upload(provider,parent,...)end
 shelf.settings.home=plan.root_id;shelf.settings.index_enabled=true;shelf.settings.index_hours=24;shelf.settings.sync_enabled=false;shelf.settings.prefetch=0;shelf.settings.beta_auto_scan=false;shelf.settings.folder_view='grid'
 for _,e in ipairs(plan.books)do core:removeFile(e.id)end
 G_reader_settings:saveSetting('language','ru');core:setOffline(false);shelf:saveSettings()
 core:folder(plan.root_id,'UX test library',guard(function(entries,cached,err)
  assert(entries and not err);if cached then return end
  wait('home-index',function()return not core.index_job and idle()end,function()
   assert(core.state.listings[plan.novels_id]and core.state.listings[plan.previews_id]);pass('one-level home indexing discovers child metadata and counts')
   shelf:showFolder(plan.root_id);shot('home');closeMenus();shelf:showSettings();shot('settings');UI:close(shelf.preview_menu or UI:getTopmostVisibleWidget())
   previews()
  end)
 end))
end))
