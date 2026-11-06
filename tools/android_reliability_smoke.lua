-- Temporary startup patch for the exclusive disposable AVD. Requires a fresh
-- android_drive_setup + ux_drive_fixtures plan. Original library writes refused.
local UI=require('ui/uimanager');local DS=require('datastorage');local Log=require('logger')
local shelf,core,store,plan;local stage='init';local checks={};local screenshots={};local expectedPages={}
local now=require('socket').gettime;local started=now();local resultPath=DS:getDataDir()..'/gdriveshelf-reliability-result.json'
local function report(status)
 if store then store:writeJSON(resultPath,{status=status,stage=stage,checks=checks,screenshots=screenshots,elapsed=now()-started})end
end
local function guard(fn)return function(...)
 local args={...};local ok=xpcall(function()fn(unpack(args))end,function(err)
  Log.warn('GDriveShelf reliability failed',stage,type(err),debug.traceback('',2));report('failed')
 end);return ok
end end
local function pass(name)checks[#checks+1]=name;Log.info('GDriveShelf reliability: PASS '..name);report('running')end
local function wait(name,condition,done)
 stage=name;report('running');local deadline=now()+240
 local function poll()
  if condition()then guard(done)()elseif now()>deadline then report('failed');Log.warn('GDriveShelf reliability timeout',stage)else UI:scheduleIn(.2,guard(poll))end
 end
 UI:scheduleIn(.1,guard(poll))
end
local function idle()return not core.jobs.active and #core.jobs.queue==0 and not core.jobs.stopping end
local function reader()return require('apps/reader/readerui').instance end
local function closeMenus()if shelf.folder_menu then shelf.folder_menu:onCloseAllMenus()end end
local function shot(name)
 local path=DS:getDataDir()..'/reliability-'..name..'.png';UI:forceRePaint();require('device').screen:shot(path);assert(store:exists(path));screenshots[#screenshots+1]=path
end
local function diagnostics()
 stage='diagnostics';shelf.settings.diagnostics=true;store:mkdir(core.logger.dir)
 assert(core.logger:event('request',{operation='list',status=200,url='secret-smoke-canary',token='secret-smoke-canary',filename='secret-smoke-canary'}))
 local path=store.root..'/diagnostics-export.txt';assert(core.logger:export(path))
 local text=assert(store:read(path,2*1048576));assert(not text:find('secret-smoke-canary',1,true));assert(not text:find(plan.root_id,1,true));assert(not text:find(plan.source_parent,1,true))
 pass('opt-in diagnostics exports bounded safe fields without URLs IDs filenames or credentials')
 shelf.settings.diagnostics=false;shelf.settings.sync_enabled=false;core:setOffline(true);shelf:saveSettings()
 G_reader_settings:saveSetting('start_with','filemanager');G_reader_settings:flush()
 stage='done';report('passed');Log.info('GDriveShelf reliability: ALL PASSED')
end
local function summaries()
 local readCount=0;local original=core.logger.event
 core.logger.event=function(owner,name,fields)if name=='request'and fields and fields.operation=='read'then readCount=readCount+1 end;return original(owner,name,fields)end
 core.progress_fresh={};core:lazyProgress(plan.preview_files)
 wait('visible-summaries',function()return not core.progress_job and idle()end,function()
  for _,entry in ipairs(plan.preview_files)do local remote=assert(core:remote(entry));assert(not remote.stamp.etag);assert(require('gdriveshelf/sdr').decode(remote.lua))end
  assert(readCount==#plan.preview_files);pass('visible native SDR cache stores safe snapshots without conditional-write guards')
  local reads=readCount;core.progress_fresh={};core:lazyProgress(plan.preview_files)
  wait('unchanged-summaries',function()return not core.progress_job and idle()end,function()
   assert(readCount==reads);core.logger.event=original;pass('fresh grouped SDR version recheck downloads zero unchanged Lua')
   shelf.settings.file_view='grid';shelf:showFolder(plan.previews_id,true);shot('final-grid');closeMenus();diagnostics()
  end)
 end)
end
local function synchronize()
 shelf.settings.sync_enabled=true;core:setOffline(false);core:flushPending()
 wait('native-sync',function()return not next(core.state.sync.pending)and idle()end,function()
  assert(not next(core.state.sync.conflicts));pass('native CBZ EPUB and PDF progress uploads only within the disposable child')
  local verified=0
  for _,entry in ipairs({plan.preview_files[1],plan.documents[1],plan.documents[2]})do local e=entry
   core:network('reliability-verify:'..e.id,function(p)return core:sync(p):pull(e)end,guard(function(remote,err)
    assert(remote and remote.lua and not err);local data=assert(require('gdriveshelf/sdr').decode(remote.lua))
    if e.name:match('%.epub$')then assert(type(data.last_xpointer)=='string')else assert(data.last_page==expectedPages[e.id])end
    verified=verified+1;if verified==3 then pass('fresh conditional native SDR readback preserves EPUB xpointer and paged positions');summaries()end
   end))
  end
 end)
end
local function finishPage()
 local r=assert(reader());r:handleEvent(require('ui/event'):new('GotoPage',r.document:getPageCount()))
 for _=1,4 do r.paging:onGotoPageRel(1)end
end
local function automaticNext()
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
 shelf.settings.prefetch=0;shelf.settings.threshold=0;shelf.settings.immediate=false;shelf.settings.sync_enabled=false;core:setOffline(false)
 for i=1,2 do assert(core:removeFile(plan.books[i].id))end
 local function showing(entry)local r=reader();local cached=core:cached(entry.id);return r and cached and r.document.file==cached.path end
 local function finish()
  local r=reader();r:saveSettings();r:showFileManager();r:onClose();shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
  shelf.settings.prefetch=0;shelf.settings.threshold=75;G_reader_settings:saveSetting('end_document_action','nothing');synchronize()
 end
 local function popupNext()
  shelf=assert(reader().gdriveshelf);shelf.settings.prefetch=0
  if core.state.downloads[plan.books[3].id]then core:cancelDownload(plan.books[3].id)end
  G_reader_settings:saveSetting('end_document_action','pop-up');shelf:openEntry(plan.books[1])
  wait('native-popup-first',function()return showing(plan.books[1])end,function()
   shelf=assert(reader().gdriveshelf)
   wait('native-popup-idle',idle,function()
    assert(core:removeFile(plan.books[2].id));finishPage();local popup=UI:getTopmostVisibleWidget();assert(popup and popup.name=='end_document');popup.buttons[2][2].callback()
   UI:scheduleIn(.1,guard(function()
    assert(shelf.download_dialog);shot('popup-next-feedback');pass('native EOF popup next action immediately shows foreground download feedback')
    wait('native-popup-next',function()return showing(plan.books[2])end,finish)
   end))
   end)
  end)
 end
 G_reader_settings:saveSetting('end_document_action','next_file');shelf:openEntry(plan.books[1])
 wait('native-auto-first',function()return showing(plan.books[1])end,function()
  shelf=assert(reader().gdriveshelf);shelf.settings.prefetch=1;reader():handleEvent(require('ui/event'):new('GotoPage',2))
  assert(core.state.downloads[plan.books[2].id],'Native page update did not queue next chapter');finishPage()
  UI:scheduleIn(.1,guard(function()
   assert(shelf.download_dialog);shot('automatic-next-feedback');pass('native automatic EOF joins existing prefetch with immediate download feedback')
   wait('native-auto-next',function()return showing(plan.books[2])end,function()
    assert(plan.books[2].parent_id==plan.root_id and core:next(plan.books[3])==nil);pass('automatic next opens the correct real chapter and never crosses folder boundary');popupNext()
   end)
  end))
 end)
end
local function reading()
 local tasks={{entry=plan.preview_files[1],location='doc'},{entry=plan.preview_files[2],location='dir'},{entry=plan.documents[1],location='hash'},{entry=plan.documents[2],location='dir'}}
 local i=0
 local function advance()
  i=i+1;local task=tasks[i];if not task then automaticNext();return end
  shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
  G_reader_settings:saveSetting('document_metadata_folder',task.location);G_reader_settings:saveSetting('end_document_action','nothing')
  shelf.settings.sync_enabled=false;core:setOffline(true);local sequence=core.jobs.seq
  shelf:openEntry(task.entry)
  wait('native-reader-'..i,function()local r=reader();return r and r.document.file==assert(core:cached(task.entry.id)).path end,function()
   assert(core.jobs.seq==sequence);local r=reader();task.page=math.min(2,r.document:getPageCount());expectedPages[task.entry.id]=task.page;r:handleEvent(require('ui/event'):new('GotoPage',task.page));r:saveSettings()
   if i==1 then shot('native-cbz')elseif i==3 then shot('native-epub')elseif i==4 then shot('native-pdf')end
   UI:scheduleIn(.4,guard(function()
    r:showFileManager();r:onClose();shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
    local settings=require('docsettings'):open(assert(core:cached(task.entry.id)).path)
    if task.entry.name:match('%.epub$')then assert(type(settings.data.last_xpointer)=='string')else assert(settings.data.last_page==task.page)end
    assert(core.state.sync.pending[task.entry.id]);pass('offline native reader and durable progress in '..task.location..' metadata mode ('..i..')')
    advance()
   end))
  end)
 end
 advance()
end
local function retryAndWake()
 local marker=store.root..'/reliability-retry.flag';local first,second=0,0;core:setOffline(false)
 store:remove(marker) -- The same disposable profile may be rerun after a harness fix.
 core:network('reliability:retry',function(p)
  if not store:exists(marker)then assert(store:write(marker,'once'));return nil,{code='api',status=503,retry_after=2}end
  return p:list(plan.root_id)
 end,guard(function(value,err)assert(value and not err);first=first+1 end))
 core:network('reliability:queued',function(p)return p:list(plan.root_id)end,guard(function(value,err)assert(value and not err);second=second+1 end))
 wait('retry-state',function()return core:networkState()=='retry'end,function()
  assert(not shelf.settings.offline and core.jobs.keys['reliability:retry']and core.jobs.keys['reliability:queued']);pass('temporary API cooldown preserves requests without changing manual offline mode')
  core:suspend();assert(core:networkState()=='sleep');core:wake()
  wait('wake-drain',function()return first==1 and second==1 and idle()end,function()
   assert(not core.retry_after);pass('sleep and wake preserve both callbacks and resume queued browsing once');reading()
  end)
 end)
end
local function localCovers()
 local all={plan.preview_files[1],plan.preview_files[2],plan.documents[1],plan.documents[2]}
 for _,entry in ipairs(all)do core:download(entry,'offline')end
  core:ensureLocalCovers(all)
 wait('download-and-local-covers',function()
  for _,entry in ipairs(all)do if not core:cached(entry.id)or not core:localCover(entry)then return false end end;return idle()
 end,function()
  for _,entry in ipairs(all)do
   local cover=assert(core:localCover(entry));local text=assert(store:read(cover.path,1048576));local w,h=require('gdriveshelf/thumbnails').dimensions(text);assert(w and w<=320 and h<=440)
  end
  pass('default-on downloaded CBZ EPUB and PDF covers are bounded native background work')
  local DocSettings=require('docsettings');local candidates={}
  for index,entry in ipairs(plan.documents)do
   local path=assert(core:cached(entry.id)).path;local dir=DocSettings:getSidecarDir(path,'doc');assert(store:mkdir(dir))
   local metadata=dir..'/'..DocSettings.getSidecarFilename(path);local text=index==1 and ''or 'not valid Lua\n'
   assert(store:write(metadata,text));candidates[#candidates+1]={path=metadata,text=text}
   core:evict({'thumb:'..entry.id});core.state.local_cover_attempts[entry.id]=nil
  end
  core:setOffline(true);assert(core:ensureLocalCovers(plan.documents)==2)
  wait('offline-cover-sdr-preservation',function()return idle()and core:localCover(plan.documents[1])and core:localCover(plan.documents[2])end,function()
   for _,candidate in ipairs(candidates)do assert(store:read(candidate.path,1048576)==candidate.text);assert(store:remove(candidate.path))end
   pass('offline cover workers preserve empty and malformed existing native SDR bytes')
   shelf.settings.file_view='grid';shelf:showFolder(plan.previews_id,true)
   local view=shelf:browserPresentation(plan.previews_id,shelf.folder_entries);assert(view.header and shelf.settings.info_header~=false and not shelf.settings.beta_thumbnails)
   shot('stable-header-local-grid');closeMenus();assert(not core.progress_job);pass('stable comic header and local cover grid need no remote beta previews');retryAndWake()
  end)
 end)
end
UI:scheduleIn(3,guard(function()
 local r=reader();if r then r:showFileManager();r:onClose()end
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf);core=shelf.core;store=core.storage
 plan=assert(store:readJSON(DS:getSettingsDir()..'/gdriveshelf-reliability-plan.json'))
 assert(type(plan.run_key)=='string'and plan.run_key:match('^%d+$'))
 shelf.settings.cache_dir=DS:getDataDir()..'/reliability-cache-'..plan.run_key;shelf.settings.books_dir=DS:getDataDir()..'/Reliability Books '..plan.run_key
 shelf.settings.diagnostics=false;shelf.settings.offline=true;shelf.settings.sync_enabled=false;shelf.settings.home=plan.root_id
 shelf.settings.index_enabled=false;shelf.settings.index_recursive_confirmed=nil;shelf.settings.local_covers=true;shelf.settings.info_header=true;shelf.settings.beta_header=nil;shelf.settings.beta_thumbnails=false;shelf.settings.beta_auto_scan=false;shelf.settings.prefetch=0
 assert(shelf:importCredentials(DS:getSettingsDir()..'/gdriveshelf-reliability-import.json'));core=shelf.core;store=core.storage
 local Provider=require('gdriveshelf/providers/gdrive');local mkdir,upload=Provider.mkdir,Provider.upload;local allowed={[plan.root_id]=true}
 local function inside(p,id)
  if allowed[id]then return true end;local seen={};local current=id
  while current and not seen[current]do
   if current==plan.root_id then allowed[id]=true;return true end
   seen[current]=true;local e=p:stat(current);current=e and e.parent_id
  end;return false
 end
 Provider.mkdir=function(p,parent,...)assert(inside(p,parent),'Write outside reliability fixture refused');return mkdir(p,parent,...)end
 Provider.upload=function(p,parent,...)assert(inside(p,parent),'Write outside reliability fixture refused');return upload(p,parent,...)end
 local logPath=core.logger.dir..'/diagnostics.log';local before=store:size(logPath)
 assert(core.logger:event('request',{operation='list',status=200})==false);assert(store:size(logPath)==before);pass('diagnostics is off by default and performs no log write')
 G_reader_settings:saveSetting('language','en_US');shelf:saveSettings();core:setOffline(false);core.catalog_visible=true
 shelf.settings.index_enabled=true;assert(core:indexHome()==false and not core.index_job);shelf.settings.index_recursive_confirmed=true;assert(core:reindexHome())
 wait('recursive-catalog',function()return not core.index_job and idle()end,function()
  assert(core.state.catalog.phase=='ready'and core.state.listings[plan.nested_id]and core.state.listings[plan.novels_id]and core.state.listings[plan.previews_id]);assert(core.state.catalog.members[plan.nested_book.id])
  pass('recursive catalog requires confirmation and discovers nested folders before catch-up')
  -- Drive can advance metadata versions while processing new uploads. Use the
  -- catalog's current identities instead of stale host setup snapshots.
  for _,group in ipairs{plan.books,plan.documents,plan.preview_files}do for i,entry in ipairs(group)do group[i]=assert(core.state.docs[entry.id])end end
  local original=Provider.listParents;Provider.listParents=function()error('Unchanged refresh must only poll changes')end
  assert(core:catalogRefresh(true));wait('incremental-catalog',function()return not core.index_job and idle()end,function()
   Provider.listParents=original;assert(core.state.catalog.phase=='ready');pass('ordinary refresh replays Drive changes without another full catalog walk')
   shelf.settings.folder_view='grid';shelf:showFolder(plan.root_id);shot('recursive-home');closeMenus();localCovers()
  end)
 end)
end))
