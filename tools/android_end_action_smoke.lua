-- Live native EndOfBook regression against fresh isolated Drive copies.
local UI=require('ui/uimanager');local DS=require('datastorage');local Log=require('logger')
local source=DS:getSettingsDir()..'/gdriveshelf-avd-';local output=DS:getDataDir()..'/gdriveshelf-avd-end-result.json'
local core,store,plan,shelf;local passed={};local stage='start'
local function report(status)store:writeJSON(output,{status=status,stage=stage,passed=passed})end
local function pass(name)passed[#passed+1]=name;Log.info('GDriveShelf AVD end action: PASS '..name);report('running')end
local function guard(fn)return function(...)
 local args={...};xpcall(function()fn(unpack(args))end,function()Log.warn('GDriveShelf AVD end action code locations',debug.traceback('',2));report('failed')end)
end end
local function wait(name,condition,thenfn)
 stage=name;report('running');local deadline=require('socket').gettime()+180
 local function poll()if condition()then guard(thenfn)()elseif require('socket').gettime()>deadline then report('failed')else UI:scheduleIn(0.2,guard(poll))end end
 UI:scheduleIn(0.05,guard(poll))
end
local function reader()local r=assert(require('apps/reader/readerui').instance);shelf=assert(r.gdriveshelf);return r end
local function showing(book)local r=require('apps/reader/readerui').instance;return r and r.document.file==store:filePath(book,'auto')end
local function finishPage()
 local r=reader();r:handleEvent(require('ui/event'):new('GotoPage',r.document:getPageCount()))
 -- Tall comic pages can require a second view-pan before the EOF event.
 for i=1,4 do r.paging:onGotoPageRel(1)end
end
local function finalChecks()
 local r=reader();finishPage()
 UI:scheduleIn(0.4,guard(function()
  assert(showing(plan.books[3]));pass('last chapter never crosses into another title')
  -- A one-file budget must refuse safely while preserving the open archive.
  core:removeFile(plan.books[1].id);shelf.settings.auto_mib=math.ceil(math.max(plan.books[1].size,plan.books[3].size)/1048576)
  local blocked
  core:open(plan.books[1],function(path,e)blocked=not path and e and e.code=='space'end)
  assert(blocked and showing(plan.books[3]));core:cancelDownload(plan.books[1].id)
  shelf.settings.auto_mib=3072;core.opening_id=nil
  pass('undersized cache window refuses safely without deleting the open chapter')
  r:handleEvent(require('ui/event'):new('GotoPage',2));r:saveSettings()
  core:setOffline(true);shelf.settings.prefetch=1;shelf:saveSettings()
  G_reader_settings:saveSetting('start_with','last');G_reader_settings:flush()
  stage='restart';report('restart-needed')
 end))
end
local function uncachedNext()
 assert(not core:cached(plan.books[3].id));G_reader_settings:saveSetting('end_document_action','next_file')
 finishPage();assert(showing(plan.books[2]),'Reader destroyed inside its own end event')
 wait('uncached-auto-next',function()return showing(plan.books[3])end,function()
  assert(core:cached(plan.books[3].id));pass('native automatic next downloads and opens an uncached chapter');finalChecks()
 end)
end
local function popupNext()
 shelf:openEntry(plan.books[1])
 wait('popup-test-first',function()return showing(plan.books[1])end,function()
  G_reader_settings:saveSetting('end_document_action','pop-up');finishPage()
  local popup=UI:getTopmostVisibleWidget();assert(popup and popup.name=='end_document')
  assert(showing(plan.books[1]),'Popup mode advanced automatically')
  popup.buttons[2][2].callback();assert(showing(plan.books[1]))
  wait('popup-next',function()return showing(plan.books[2])end,function()pass('native end popup keeps its actions and opens the next Drive chapter');uncachedNext()end)
 end)
end
UI:scheduleIn(3,guard(function()
 local previousReader=require('apps/reader/readerui').instance
 local owner=previousReader or require('apps/filemanager/filemanager').instance
 shelf=assert(owner and owner.gdriveshelf);core=shelf.core;store=core.storage
 plan=assert(store:readJSON(source..'plan.json'))
 local old=store:readJSON(output)
 if old and old.status=='restart-needed'then
  passed=old.passed
  assert(previousReader and showing(plan.books[3])and previousReader.paging.current_page==2)
  assert(shelf:activeEntry().id==plan.books[3].id and core.active_id==plan.books[3].id)
  assert(shelf._native_end and core.jobs.offline)
  pass('native restart reopens the last cached chapter at page 2 and reinstalls Drive hooks')
  local info=core:titleInfo(plan.root_id);assert(info.progress and info.progress.total==3 and info.progress.started>0)
  local sequence=core.jobs.seq;shelf:showOffline();UI:forceRePaint();assert(core.jobs.seq==sequence)
  pass('approximate folder bar renders on Android using cached listings only')
  stage='done';report('passed');return
 end
 if previousReader then previousReader:showFileManager();previousReader:onClose()end
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf)
 shelf.settings.home=plan.root_id;shelf.settings.sync_enabled=false;shelf.settings.prefetch=0;shelf.settings.immediate=false;shelf.settings.sort='natural';shelf.settings.reverse=false
 assert(shelf:importCredentials(source..'import.json'));core=shelf.core;store=core.storage
 for _,book in ipairs(plan.books)do core:removeFile(book.id)end
 G_reader_settings:saveSetting('end_document_auto_mark',true)
 core:setOffline(false);shelf:saveSettings()
 core:folder(plan.root_id,'EOF test',guard(function(entries,cached,e)
  assert(entries and not e);if cached then return end
  for i=1,2 do core:download(plan.books[i],'auto')end
  wait('initial-cache',function()return core:cached(plan.books[1].id)and core:cached(plan.books[2].id)and not core.jobs.active and #core.jobs.queue==0 end,function()
   shelf:openEntry(plan.books[1])
   wait('first-reader',function()return showing(plan.books[1])end,function()
    G_reader_settings:saveSetting('end_document_action','nothing');finishPage()
    UI:scheduleIn(0.3,guard(function()
     assert(showing(plan.books[1]));pass('native do-nothing end action does not advance')
     G_reader_settings:saveSetting('end_document_action','next_file');finishPage();assert(showing(plan.books[1]))
     wait('cached-auto-next',function()return showing(plan.books[2])end,function()
      assert(require('docsettings'):open(store:filePath(plan.books[1],'auto')):readSetting('summary').status=='complete')
      pass('native automatic next opens cached chapter and preserves auto-mark-finished');popupNext()
     end)
    end))
   end)
  end)
 end))
end))
