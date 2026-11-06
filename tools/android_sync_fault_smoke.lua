-- Follow-up to android_drive_smoke.lua in the same isolated emulator/subtree.
local UI=require('ui/uimanager');local DS=require('datastorage');local Logger=require('logger')
UI:scheduleIn(3,function()
 local owner=require('apps/reader/readerui').instance or require('apps/filemanager/filemanager').instance
 local shelf=assert(owner and owner.gdriveshelf);local core=shelf.core;local storage=core.storage
 local plan=assert(storage:readJSON(DS:getSettingsDir()..'/gdriveshelf-avd-plan.json'))
 shelf.settings.sync_enabled=false;core:setOffline(false)
 core:network('android-sync-conflict-test',function(provider)
  local SDR=require('gdriveshelf/sdr');local Sync=require('gdriveshelf/sync')
  local book=plan.books[2];assert(provider:stat(book.id).parent_id==plan.root_id)
  local state={};local sync=Sync.new{provider=provider,storage=storage,sdr=SDR,state=state}
  local function check(value,e)assert(value,e and e.code);return value end
  local remote=check(sync:pull(book));assert(provider:stat(remote.folder.id).parent_id==plan.root_id)
  local upload=provider.upload
  provider.upload=function(self,parent,name,path,id,etag)
   assert(parent==remote.folder.id and (not id or id==remote.metadata.id),'Overwrite escaped isolated metadata')
   return upload(self,parent,name,path,id,etag)
  end
  state.bases[book.id]={lua=remote.lua,stamp=remote.stamp,book_stamp=remote.book_stamp}
  local function data(page)local d=assert(SDR.decode(remote.lua));d.last_page=page;d.percent_finished=page/(d.doc_pages or 100);return d end
  local stale=remote.stamp.etag
  local pending=assert(sync:snapshot(book,data(3)));local result=check(sync:push(book,pending));assert(result.action=='pushed');sync:commit(book,pending,result)
  remote=check(sync:pull(book));assert(remote.data.last_page==3)
  local path=assert(storage:writeTemp(assert(SDR.encode(data(99)))))
  local rejected,e=provider:upload(remote.folder.id,'metadata.cbz.lua',path,remote.metadata.id,stale)
  assert(not rejected and e.code=='conflict');assert(check(sync:pull(book)).data.last_page==3)
  local external=assert(storage:writeTemp(assert(SDR.encode(data(4)))))
  check(provider:upload(remote.folder.id,'metadata.cbz.lua',external,remote.metadata.id,remote.stamp.etag))
  pending=assert(sync:snapshot(book,data(5)));result=check(sync:push(book,pending));assert(result.action=='conflict');sync:commit(book,pending,result)
  assert(state.pending[book.id]and state.conflicts[book.id]);assert(check(sync:pull(book)).data.last_page==4)
  check(sync:resolve(book.id,'local'));pending=state.pending[book.id]
  result=check(sync:push(book,pending));assert(result.action=='pushed');sync:commit(book,pending,result)
  remote=check(sync:pull(book));assert(remote.data.last_page==5)
  local good=remote.lua
  local unsafe=assert(storage:writeTemp('return os.execute("touch /sdcard/koreader/unsafe-parser-was-executed")'))
  check(provider:upload(remote.folder.id,'metadata.cbz.lua',unsafe,remote.metadata.id,remote.stamp.etag))
  local invalid,why=sync:pull(book);assert(not invalid and why.code=='invalid_remote_metadata')
  assert(not storage:exists('/sdcard/koreader/unsafe-parser-was-executed'))
  local latest=check(provider:stat(remote.metadata.id));local restored=assert(storage:writeTemp(good))
  check(provider:upload(remote.folder.id,'metadata.cbz.lua',restored,remote.metadata.id,latest.etag))
  return {passed={'native SDR update','HTTP 412 stale-write rejection','both-side conflict preservation','explicit conflict resolution','safe rejection of executable remote Lua'}}
 end,function(result,e)
  if not result then Logger.warn('GDriveShelf AVD follow-up: FAIL',e and e.code);return end
  for _,label in ipairs(result.passed)do Logger.info('GDriveShelf AVD follow-up: PASS '..label)end
  local menu;local original=shelf.menu
  shelf.menu=function(self,...)menu=original(self,...);return menu end
  shelf:showFileSort();menu:onMenuSelect(menu.item_table[3]);assert(shelf.settings.sort=='size')
  local saved=require('luasettings'):open(DS:getSettingsDir()..'/gdriveshelf.lua');assert(saved:readSetting('sort')=='size')
  menu:onMenuSelect(menu.item_table[1]);assert(shelf.settings.sort=='natural');shelf.menu=original
  Logger.info('GDriveShelf AVD follow-up: PASS native file-sort UI and persistence')
  local row={text='Fault injection',callback=function()error('synthetic-secret-payload')end}
  local fault=shelf:menu('Fault handling test',{row});assert(pcall(fault.onMenuSelect,fault,row))
  assert(not assert(storage:read(DS:getDataDir()..'/gdriveshelf-diagnostic.log')):find('synthetic-secret-payload',1,true))
  Logger.info('GDriveShelf AVD follow-up: PASS menu exception does not terminate KOReader')
  local confirmation=shelf:confirmation{ok_callback=function()error('synthetic-confirmation-payload')end}
  assert(pcall(confirmation.ok_callback))
  Logger.info('GDriveShelf AVD follow-up: PASS confirmation exception does not terminate KOReader')
  local jobs=require('gdriveshelf/jobs').new{storage=storage,dir=storage.root..'/jobs'}
  jobs:enqueue('cancel-fault',function()require('socket').sleep(1);return true end,function()error('synthetic-cancel-payload')end)
  assert(pcall(jobs.cancel,jobs,'cancel-fault'));assert(not jobs.active and not next(jobs.keys))
  local failure
  jobs:enqueue('prepare-fault',function()end,function(_,e)failure=e end,false,function()error('synthetic-prepare-payload')end)
  assert(failure and failure.code=='prepare'and not jobs.active)
  Logger.info('GDriveShelf AVD follow-up: PASS worker cancellation and preparation exceptions stay isolated')
  core:setOffline(true);shelf:saveSettings()
  storage:writeJSON(DS:getDataDir()..'/gdriveshelf-avd-followup.json',{status='passed',passed=result.passed,file_sort=true,menu_fault=true,confirmation_fault=true,worker_faults=true})
 end)
end)
