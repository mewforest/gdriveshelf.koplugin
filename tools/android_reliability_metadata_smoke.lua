-- Temporary follow-up patch: user-owned metadata only in the fresh fixture's
-- Example books folder. Install AFTER android_reliability_smoke passes.
local UI=require('ui/uimanager');local DS=require('datastorage');local Log=require('logger')
local core,store,shelf,plan;local stage='init';local checks={};local target
local path=DS:getDataDir()..'/gdriveshelf-reliability-metadata-result.json'
local function report(status)if store then store:writeJSON(path,{status=status,stage=stage,checks=checks})end end
local function guard(fn)return function(...)
 local args={...};xpcall(function()fn(unpack(args))end,function(err)Log.warn('GDriveShelf metadata reliability failed',stage,type(err),debug.traceback('',2));report('failed')end)
end end
local function pass(name)checks[#checks+1]=name;Log.info('GDriveShelf metadata reliability: PASS '..name);report('running')end
local function idle()return not core.jobs.active and #core.jobs.queue==0 and not core.jobs.stopping end
local function wait(name,condition,done)
 stage=name;report('running');local deadline=require('socket').gettime()+180
 local function poll()if condition()then guard(done)()elseif require('socket').gettime()>deadline then report('failed')else UI:scheduleIn(.2,guard(poll))end end
 UI:scheduleIn(.1,guard(poll))
end
local function snapshot(p)
 local entries,e=p:list(target);if not entries then return nil,e end
 local metadata
 for _,entry in ipairs(entries)do if entry.name=='gdriveshelf.json'then assert(not metadata,'Duplicate pointer');metadata=entry end end
 assert(metadata,'Missing pointer');local body,why=p:read(metadata,65536);if not body then return nil,why end
 return{entry=metadata,values=store.json.decode(body)}
end
UI:scheduleIn(3,guard(function()
 local r=require('apps/reader/readerui').instance;if r then r:showFileManager();r:onClose()end
 shelf=assert(require('apps/filemanager/filemanager').instance.gdriveshelf);core=shelf.core;store=core.storage
 local previous=assert(store:readJSON(DS:getDataDir()..'/gdriveshelf-reliability-result.json'));assert(previous.status=='passed','Broad regression must finish first')
 plan=assert(store:readJSON(DS:getSettingsDir()..'/gdriveshelf-reliability-plan.json'));target=plan.novels_id
 local Provider=require('gdriveshelf/providers/gdrive');local upload=Provider.upload
 Provider.upload=function(p,parent,name,...)
  assert(parent==target and(name=='gdriveshelf.json'or name:match('^gdriveshelf%-cover%-[0-9a-f]+%.png$')),'Metadata write outside fixture refused')
  assert(assert(p:stat(target)).parent_id==plan.root_id);assert(assert(p:stat(plan.root_id)).parent_id==plan.source_parent)
  return upload(p,parent,name,...)
 end
 Provider.mkdir=function()error('Unexpected folder creation in metadata-only regression')end
 shelf.settings.sync_enabled=false;core.catalog_visible=false;core:setOffline(true)
 local sequence=core.jobs.seq;local cover=assert(core:localCover(assert(core.state.docs[plan.documents[1].id])))
 assert(core:saveFolderMetadata(target,{title='Offline fixture title',description='Offline fixture description'},cover.path))
 assert(core.jobs.seq==sequence and core:titleInfo(target).title=='Offline fixture title')
 core.folder_metadata=nil;assert(core:titleInfo(target).description=='Offline fixture description');pass('offline folder title description and cover survive protected-store reload without network')
 core:setOffline(false);core:flushMetadata()
 wait('metadata-flush',function()return core.folder_metadata and not next(core.folder_metadata.pending)and idle()end,function()
  core:network('metadata-live-verify',snapshot,guard(function(first,err)
   assert(first and not err and first.values.title=='Offline fixture title'and first.values.cover:match('^gdriveshelf%-cover%-[0-9a-f]+%.png$'));assert(not first.values.tree and not first.values.progress)
   pass('online metadata flush publishes immutable cover before its own schema-1 JSON pointer')
   -- Model a second client while online, without importing its newer version
   -- into this client's cached base. The next local edit is made offline.
   core:network('metadata-external-client',function(p)
    local current=assert(p:stat(first.entry.id));local body=store.json.encode({schema=1,title='External fixture version',description='External description',cover=first.values.cover})
    local temp=assert(store:writeTemp(body));local value,e=p:upload(target,'gdriveshelf.json',temp,current.id,current.etag);store:remove(temp);return value,e
   end,guard(function(external,why)
    assert(external and not why);core:setOffline(true);assert(core:saveFolderMetadata(target,{title='Local conflict version',description='Kept local description'}));assert(core:titleInfo(target).title=='Local conflict version')
    core:setOffline(false);core:flushMetadata()
    wait('metadata-conflict',function()return core:metadataConflict(target)and idle()end,function()
     local issue=assert(core:metadataConflict(target));assert(issue.local_values.title=='Local conflict version'and issue.remote_values.title=='External fixture version');pass('concurrent folder metadata preserves both local and remote versions before an explicit choice')
     assert(core:resolveMetadataConflict(target,'local'))
     wait('metadata-resolved',function()return not next(core.folder_metadata.pending)and idle()end,function()
      assert(core.folder_metadata.records[target].preserved_remote.title=='External fixture version')
      core:network('metadata-final-verify',snapshot,guard(function(final,e)
       assert(final and not e and final.entry.id==first.entry.id and final.values.title=='Local conflict version');assert(not core:metadataConflict(target));pass('explicit local resolution updates the same JSON with a fresh conditional guard and preserves the remote values')
       core:setOffline(true);shelf:saveSettings();stage='done';report('passed');Log.info('GDriveShelf metadata reliability: ALL PASSED')
      end))
     end)
    end)
   end))
  end))
 end)
end))
