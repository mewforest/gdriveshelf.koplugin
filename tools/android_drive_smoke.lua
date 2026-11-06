-- Opt-in emulator userpatch. Needs a private plan + credentials prepared by
-- android_drive_setup.lua, with all writes confined to that fresh test subtree.
local UI=require('ui/uimanager');local Logger=require('logger');local Socket=require('socket')
local DS=require('datastorage');local base=DS:getSettingsDir()..'/gdriveshelf-avd-'
local shelf,core,plan,SDR,store;local passed={};local stage='starting'
local function report(status,detail)
 if store then store:writeJSON(DS:getDataDir()..'/gdriveshelf-avd-result.json',{stage=stage,status=status,detail=detail,passed=passed})end
end
local function fail()Logger.warn('GDriveShelf AVD live: FAIL at '..stage);report('failed','See test stage; no credentials logged')end
local function guarded(fn)return function(...)
 local args={...}
 xpcall(function()fn(unpack(args))end,function()
  Logger.warn('GDriveShelf AVD live code locations:',debug.traceback('',2));fail()
 end)
end end
local function pass(label)passed[#passed+1]=label;Logger.info('GDriveShelf AVD live: PASS '..label);report('running')end
local function wait(label,predicate,nextfn,seconds)
 stage=label;report('running');local deadline=Socket.gettime()+(seconds or 180)
 local function poll()
  local ok,result=pcall(predicate);if not ok then fail();return end
  if result then guarded(nextfn)();return end
  if Socket.gettime()>deadline then fail();return end
  UI:scheduleIn(0.25,poll)
 end
 UI:scheduleIn(0.05,poll)
end
local function ready(id)local e=core:cached(id);return e and e.ready end
local function idle()return not core.jobs.active and #core.jobs.queue==0 end
local function currentShelf()
 local reader=assert(require('apps/reader/readerui').instance);return reader,assert(reader.gdriveshelf)
end
local function changePage(page)
 local reader;reader,shelf=currentShelf();reader:handleEvent(require('ui/event'):new('GotoPage',page));reader:saveSettings()
end
local final,recursive,syncOffline,offline,evict,readSecond,firstOpened,loaded
final=function()
 core:clearPool('auto');core:clearPool('meta');core:clearPool('offline')
 assert(ready(plan.books[1].id),'Active book was removed')
 assert(not ready(plan.books[2].id)and not ready(plan.nested_book.id))
 assert(require('docsettings'):hasSidecarFile(store:filePath(plan.books[2],'offline')))
 pass('manual pool cleanup protects the open book and preserves SDR')
 local original=store.freeBytes;store.freeBytes=function()return 512*1048576 end
 local denied
 core:download(plan.books[2],'auto',function(path,e)denied=not path and e and e.code=='space'end)
 store.freeBytes=original;assert(denied);core:cancelDownload(plan.books[2].id)
 pass('512 MiB floor rejects downloads without crashing')
 local returned=pcall(function()shelf:runAction(function()error('synthetic-sensitive-error-content')end)end)
 assert(returned and store:exists(DS:getDataDir()..'/gdriveshelf-diagnostic.log'))
 local diagnostic=assert(store:read(DS:getDataDir()..'/gdriveshelf-diagnostic.log'))
 assert(not diagnostic:find('synthetic-sensitive-error-content',1,true))
 pass('unexpected action errors remain inside the plugin and redact payloads')
 core:setOffline(true);shelf:saveSettings();stage='done';report('passed');Logger.info('GDriveShelf AVD live: ALL PASS')
end
recursive=function()
 shelf.settings.auto_mib=3072
 core:scanFolder({id=plan.root_id,name='AVD test',is_folder=true},guarded(function(result,e)
  assert(result and not e and #result.files==4)
  for _,entry in ipairs(result.files)do core:download(entry,'offline')end
  wait('recursive-pinning',function()for _,entry in ipairs(result.files)do local c=core:cached(entry.id);if not c or c.pool~='offline'then return false end end;return idle()end,function()
   local groups=require('gdriveshelf/library').offlineGroups(core.state.entries)
   assert(#groups[plan.root_id]==3 and #groups[plan.nested_id]==1)
   assert(not core:next(plan.books[3])and not core:next(plan.nested_book))
   pass('recursive offline download and strict parent-folder queues');final()
  end)
 end))
end
syncOffline=function()
 pass('radios-off cached browsing/open and durable pending progress')
 stage='await-network-on';report('running')
 wait('await-network-on',function()return store:exists(base..'network-on.flag')end,function()
  core:setOffline(false)
  wait('pending-sync',function()return not next(core.state.sync.pending)and idle()end,function()
   core:network('verify-native-sdr',function(p)return core:sync(p):pull(plan.books[2])end,guarded(function(result,e)
    assert(result and not e and SDR.decode(result.lua).last_page==2)
    pass('automatic deferred native SDR sync for an evicted archive')
    -- Wrong credentials must fail inside a worker, leaving live credentials intact.
    core:network('bad-auth',function()
     local p=core.provider_factory{client_id='demo-client',refresh_token='demo-refresh',access_token='demo-access',expires_at=1}
     local value,why=p:list(plan.root_id);return {rejected=not value and why~=nil}
    end,guarded(function(result2,e2)
     assert(result2 and result2.rejected and not e2)
     pass('invalid OAuth credentials fail without terminating KOReader');recursive()
    end))
   end))
  end,240)
 end,240)
end
offline=function()
 stage='await-network-off';report('running')
 wait('await-network-off',function()return store:exists(base..'network-off.flag')end,function()
  core:setOffline(true);shelf.settings.sync_enabled=true;shelf:saveSettings()
  local seq=core.jobs.seq;local start=Socket.gettime();local opened
  core:open(plan.books[1],function(path)opened=path end)
  assert(opened and Socket.gettime()-start<0.2)
  core.opening_id=nil
  local missing;core:open(plan.books[2],function(path,e)missing=not path and e and e.code=='offline'end);assert(missing)
  shelf:showFolder(plan.root_id,true);assert(core.jobs.seq==seq and idle())
  local durable=assert(store:readJSON(core.index_path));assert(durable.sync.pending[plan.books[2].id])
  syncOffline()
 end,240)
end
evict=function()
 local a=plan.books[2];local b=plan.books[3]
 shelf.settings.auto_mib=math.ceil(math.max(a.size,b.size)/1048576)
 assert(a.size+b.size>shelf.settings.auto_mib*1048576,'Fixture chapters too small for LRU test')
 core:download(b,'auto')
 wait('auto-lru',function()return ready(b.id)and idle()end,function()
  assert(not ready(a.id));assert(require('docsettings'):hasSidecarFile(store:filePath(a,'auto')))
  assert(core.state.sync.pending[a.id]);pass('auto LRU eviction preserves SDR and pending sync; pinned files survive');offline()
 end)
end
readSecond=function()
 shelf:openEntry(plan.books[2])
 wait('reader-second',function()local r=require('apps/reader/readerui').instance;return r and r.document.file==store:filePath(plan.books[2],'auto')end,function()
  changePage(2)
  UI:scheduleIn(0.5,guarded(function()
   assert(core.state.sync.pending[plan.books[2].id]);shelf:openEntry(plan.books[1])
   wait('reader-first-again',function()local r=require('apps/reader/readerui').instance;return r and r.document.file==store:filePath(plan.books[1],'offline')end,function()local r;r,shelf=currentShelf();evict()end)
  end))
 end)
end
firstOpened=function()
 local reader;reader,shelf=currentShelf();assert(reader.document:getPageCount()>2)
 core:download(plan.books[1],'offline')
 changePage(math.max(2,math.floor(reader.document:getPageCount()*0.8)))
 wait('prefetch-next',function()return ready(plan.books[2].id)and idle()end,function()
  assert(core.state.entries[plan.books[2].id].pool=='auto');assert(not ready(plan.books[3].id))
  pass('native reading threshold prefetches exactly the next chapter');readSecond()
 end)
end
loaded=function()
 wait('metadata-pool',function()local info=core:titleInfo(plan.root_id);return info.cover_path and core:cache():usage().meta>0 and idle()end,function()
  assert(core:cache():usage().auto==0 and core:cache():usage().offline==0)
  pass('cover/index/listing use the independent metadata pool')
  shelf:showFolder(plan.root_id);shelf:openEntry(plan.books[1])
  wait('first-download-open',function()local r=require('apps/reader/readerui').instance;return r and r.document.file==store:filePath(plan.books[1],'auto')end,function()pass('live Drive CBZ download, checksum validation and native open');firstOpened()end)
 end)
end
UI:scheduleIn(3,guarded(function()
 local reader=require('apps/reader/readerui').instance
 if reader then reader:showFileManager();reader:onClose()end
 local owner=require('apps/filemanager/filemanager').instance
 shelf=assert(owner and owner.gdriveshelf);store=shelf.core.storage
 plan=assert(store:readJSON(base..'plan.json'));assert(plan.nested_id and #plan.books==3)
 stage='import';report('running')
 shelf.settings.home=plan.root_id;shelf.settings.sync_enabled=false;shelf.settings.prefetch=1;shelf.settings.threshold=75;shelf.settings.immediate=false;shelf.settings.auto_mib=3072
 local imported,why=shelf:importCredentials(base..'import.json')
 if not imported then report('failed',why);return end
 core=shelf.core;store=core.storage;SDR=require('gdriveshelf/sdr')
 local factory=core.provider_factory
 core.provider_factory=function(credentials)
  local p=factory(credentials)
  local function inside(id)
   for depth=1,5 do if id==plan.root_id then return true end;local e=p:stat(id);if not e then return false end;id=e.parent_id end
   return false
  end
  local mkdir,upload=p.mkdir,p.upload
  p.mkdir=function(self,parent,...)assert(inside(parent),'Test write escaped its subtree');return mkdir(self,parent,...)end
  p.upload=function(self,parent,name,path,id,etag)
   assert(inside(parent),'Test write escaped its subtree')
   if id then local e=self:stat(id);assert(e and e.parent_id==parent,'Mismatched overwrite parent')end
   return upload(self,parent,name,path,id,etag)
  end
  return p
 end
 core:setOffline(false);shelf:saveSettings()
 core:folder(plan.root_id,'Android test',guarded(function(entries,cached,e)
  assert(entries and not e);if cached then return end
  assert(#entries>=6);loaded()
 end))
end))
