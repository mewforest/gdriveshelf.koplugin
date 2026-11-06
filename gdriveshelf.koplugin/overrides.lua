-- User-owned folder metadata and its durable upload outbox live outside the
-- evictable metadata cache. Original index/series/cover and native SDR are inputs
-- only; the sole mutable cloud file is our own guarded gdriveshelf.json.
local O={}
local Metadata=require('gdriveshelf/metadata')
local Storage=require('gdriveshelf/storage')
local JSON_LIMIT=65536
local COVER_LIMIT=1048576
local function errorValue(code,message)return {code=code,message=message}end
local function reject(callback,err)if callback then callback(nil,err)end;return nil,err end
local function clone(value)
 if type(value)~='table'then return value end
 local out={};for k,v in pairs(value)do out[k]=clone(v)end;return out
end
local function folderId(folder)return type(folder)=='table'and folder.id or folder end
local function coverName(name)return type(name)=='string'and name:match('^gdriveshelf%-cover%-[0-9a-f]+%.png$')and #name==86 end
function O.normalize(data)
 if type(data)~='table'or data.schema~=1 then return nil,errorValue('metadata','Unsupported folder metadata schema')end
 local result={schema=1}
 for _,key in ipairs{'title','description'}do
  local value=data[key]
  if value~=nil and(type(value)~='string'or #value>(key=='title'and 4096 or 60000)or value:find('%z'))then return nil,errorValue('metadata','Folder metadata text is invalid or too large')end
  if value~=nil and(key~='title'or value~='')then result[key]=value end
 end
 if data.cover~=nil then
  if not coverName(data.cover)then return nil,errorValue('metadata','Folder cover must name an immutable GDriveShelf PNG')end
  result.cover=data.cover
 end
 return result
end
local function paths(core,id)
 local root=core.storage.root..'/folder-metadata/'..Storage.key(id)
 return root,root..'/gdriveshelf.json'
end
local function load(core)
 if core.folder_metadata then return core.folder_metadata end
 if not core.storage or type(core.storage.root)~='string'then return nil,errorValue('metadata','Folder metadata storage is unavailable')end
 local records_path=core.storage.root..'/folder-overrides.json'
 local pending_path=core.storage.root..'/metadata-outbox.json'
 local function read(path)
  local value=core.storage:readJSON(path,16*1048576)
  if not value and core.storage:exists(path)then return nil,errorValue('metadata','Cannot read saved folder metadata; existing edits were preserved')end
  if value and(value.schema~=1 or type(value.folders)~='table')then return nil,errorValue('metadata','Saved folder metadata has an unsupported format')end
  return value and value.folders or{}
 end
 local records,err=read(records_path);if not records then return nil,err end
 local pending;pending,err=read(pending_path);if not pending then return nil,err end
 -- Outbox is written first. If shutdown interrupted the second write, its full
 -- record restores the visible edit without losing the unsent operation.
 for id,request in pairs(pending)do if type(request)=='table'and request.record then records[id]=clone(request.record)end end
 local store={records=records,pending=pending,records_path=records_path,pending_path=pending_path}
 core.folder_metadata=store;return store
end
local function persist(core,store)
 local ok,err=core.storage:writeJSON(store.pending_path,{schema=1,folders=store.pending})
 if not ok then return nil,errorValue('io',err or 'Cannot save metadata upload queue'),false end
 -- With pending edits the first file is sufficient for recovery. A failed
 -- records write is still reported, so a completed upload is never forgotten.
 ok,err=core.storage:writeJSON(store.records_path,{schema=1,folders=store.records})
 if not ok then return nil,errorValue('io',err or 'Cannot save folder metadata'),true end
 return true
end
local function matching(entries,name,parent)
 local found
 for _,entry in ipairs(entries or{})do
  if not entry.is_folder and entry.name==name and(not parent or entry.parent_id==parent)then
   if found then return nil,errorValue('ambiguous_metadata','More than one '..name..' exists in this folder; keep both and resolve the duplicate on Drive')end
   found=entry
  end
 end
 return found
end
local function sameRemote(a,b)
 if not a or not b or a.id~=b.id then return false end
 if a.etag and b.etag then return a.etag==b.etag end
 return Metadata.fingerprint(a)==Metadata.fingerprint(b)
end
local function decode(core,body)
 if type(body)~='string'or #body>JSON_LIMIT then return nil,errorValue('metadata','Folder metadata is missing or too large')end
 local ok,data=pcall(core.storage.json.decode,body)
 if not ok then local err=errorValue('metadata','Folder metadata contains invalid JSON');err.reason='invalid_json';return nil,err end
 return O.normalize(data)
end
local function hash(data)return require('ffi/sha2').sha256(data)end
local function storeCover(core,id,data)
 if not data or #data>COVER_LIMIT then return nil,errorValue('metadata','Folder cover exceeds the size limit')end
 local w,h=require('gdriveshelf/thumbnails').dimensions(data)
 if not w or w>320 or h>440 then return nil,errorValue('metadata','Folder cover must be a bounded PNG thumbnail')end
 local name='gdriveshelf-cover-'..hash(data)..'.png'
 local dir=paths(core,id);local path=dir..'/'..name
 if core.storage:exists(path)then
  if core.storage:read(path,COVER_LIMIT)~=data then return nil,errorValue('conflict','An immutable cover name has different contents')end
 else
  local ok,why=core.storage:write(path,data);if not ok then return nil,errorValue('io',why or 'Cannot save folder cover')end
 end
 return {name=name,path=path}
end
local function importCover(core,id,path)
 local data,err=core.storage:read(path,8*1048576)
 if not data then return nil,errorValue('metadata',err or 'Cannot read the selected cover image')end
 local dir=paths(core,id);core.storage:mkdir(dir)
 local temporary=dir..'/cover.incoming-'..tostring(core.jobs and core.jobs.nonce or 'edit')
 local result,why=require('gdriveshelf/thumbnails').render(data,temporary)
 if not result then core.storage:remove(temporary);return nil,why end
 local rendered=core.storage:read(temporary,COVER_LIMIT)
 local cover;cover,why=storeCover(core,id,rendered);core.storage:remove(temporary)
 return cover,why
end
local function remoteSnapshot(core,provider,id,entry,entries)
 local body,err=provider:read(entry,JSON_LIMIT);if not body then return nil,err end
 local values;values,err=decode(core,body);if not values then return nil,err,body end
 local snapshot={values=values,entry=entry}
 if values.cover then
  local source;source,err=matching(entries,values.cover,id)
  if err then return nil,err end
  if source then
   local data;data,err=provider:read(source,COVER_LIMIT)
   if not data then return nil,err end
   if 'gdriveshelf-cover-'..hash(data)..'.png'~=values.cover then return nil,errorValue('metadata','Remote immutable cover does not match its content hash')end
   local cover;cover,err=storeCover(core,id,data);if not cover then return nil,err end
   snapshot.cover_path=cover.path
  end
 end
 return snapshot
end
local function conflict(request,code,message,snapshot)
 return {code=code or 'conflict',message=message or 'Folder metadata changed on Drive; both versions were preserved',local_values=clone(request.record.values),remote_values=snapshot and snapshot.values,remote_entry=snapshot and snapshot.entry,remote_cover_path=snapshot and snapshot.cover_path}
end
local function readForWrite(core,provider,id,entry,entries,request)
 if entry.parent_id~=id or entry.name~='gdriveshelf.json'then
  return nil,errorValue('changed','Folder metadata moved or was renamed; refresh before uploading')
 end
 local snapshot,err,raw=remoteSnapshot(core,provider,id,entry,entries)
 if snapshot then return snapshot end
 if err and err.code~='metadata'and err.code~='ambiguous_metadata'and err.code~='conflict'then return nil,err end
 local issue=conflict(request,'conflict','Existing folder metadata could not be safely read; both versions were preserved',{entry=entry})
 if err and err.reason=='invalid_json'and type(entry.etag)=='string'and entry.etag~=''then
  local recovery=request.recovery
  if recovery and sameRemote(entry,recovery.entry)then
   local backup=core.storage:read(recovery.backup_path,JSON_LIMIT)
   if not backup then return nil,errorValue('io','The preserved remote JSON backup is missing; no cloud file was replaced')end
   if backup==raw then return {entry=entry}end -- explicit acknowledgement of these exact unreadable bytes
  end
  -- Preserve unreadable bytes before offering local recovery. Separate immutable
  -- paths bind each backup to the exact file ID + conditional token; no raw JSON
  -- is logged, evaluated, normalized, or overwritten in place.
  local dir=paths(core,id)
  local path=dir..'/conflicts/'..Storage.key(entry.id)..'/'..Storage.key(entry.etag)..'.json.raw'
  if core.storage:exists(path)then
   if core.storage:read(path,JSON_LIMIT)~=raw then return nil,errorValue('io','The preserved remote JSON backup differs; no cloud file was replaced')end
  else
   local ok,why=core.storage:write(path,raw)
   if not ok or core.storage:read(path,JSON_LIMIT)~=raw then return nil,errorValue('io',why or 'Cannot preserve the remote JSON before recovery')end
  end
  issue.unreadable_json=true;issue.remote_backup_path=path
 end
 return nil,nil,issue
end
local function upload(core,provider,id,request)
 local entries,err=provider:list(id);if not entries then return nil,err end
 local existing;existing,err=matching(entries,'gdriveshelf.json')
 if err then return {conflict=conflict(request,err.code,err.message)}end
 local current,snapshot
 if existing then
  current,err=provider:stat(existing.id);if not current then return nil,err end
  local issue;snapshot,err,issue=readForWrite(core,provider,id,current,entries,request)
  if err then return nil,err end
  if issue then return {conflict=issue}end
  if not sameRemote(current,request.base)then
   -- Recovery after a successful upload whose response was lost is idempotent.
   if snapshot.values and core.storage.json.encode(snapshot.values)==core.storage.json.encode(request.record.values)then return {entry=current,snapshot=snapshot}end
   return {conflict=conflict(request,nil,nil,snapshot)}
  end
 elseif request.base then
  local issue=conflict(request,'conflict','The original folder metadata was removed; the local version was preserved')
  issue.confirmed_absent=true;return {conflict=issue}
 end
 local record=request.record
 if record.values.cover then
  local remote_cover;remote_cover,err=matching(entries,record.values.cover)
  if err then return {conflict=conflict(request,err.code,err.message,snapshot)}end
  if remote_cover then
   local bytes;bytes,err=provider:read(remote_cover,COVER_LIMIT)
   if not bytes then return nil,err end
   if 'gdriveshelf-cover-'..hash(bytes)..'.png'~=record.values.cover then return {conflict=conflict(request,'conflict','An immutable cloud cover has different contents',snapshot)}end
  else
   if not record.cover_path then return nil,errorValue('metadata','The selected local cover is missing')end
   local cover;cover,err=provider:upload(id,record.values.cover,record.cover_path)
   if not cover then return nil,err end
  end
 end
 local dir,path=paths(core,id);core.storage:mkdir(dir)
 local ok;ok,err=core.storage:writeJSON(path,record.values);if not ok then return nil,errorValue('io',err or 'Cannot prepare folder metadata upload')end
 -- Re-list immediately before creating a new pointer. Drive has no atomic
 -- create-by-filename operation; the post-write check detects concurrent creates.
 if not current then
  local latest;latest,err=provider:list(id);if not latest then return nil,err end
  local appeared;appeared,err=matching(latest,'gdriveshelf.json')
  if err or appeared then
   local remote=appeared and provider:stat(appeared.id)
   local snap,why,issue
   if remote then snap,why,issue=readForWrite(core,provider,id,remote,latest,request)end
   if why then return nil,why end
   return {conflict=issue or conflict(request,err and err.code or 'conflict',err and err.message or nil,snap)}
  end
 end
 if current and not current.etag then return {conflict=conflict(request,'conflict','Drive supplied no conditional-write token',snapshot)}end
 local uploaded;uploaded,err=provider:upload(id,'gdriveshelf.json',path,current and current.id,current and current.etag)
 if not uploaded then
  if err and err.code=='conflict'then
   local newer=existing and provider:stat(existing.id)
   local snap,why,issue
   if newer then snap,why,issue=readForWrite(core,provider,id,newer,provider:list(id)or entries,request)end
   if why then return nil,why end
   return {conflict=issue or conflict(request,nil,nil,snap)}
  end
  return nil,err
 end
 local latest;latest,err=provider:list(id);if not latest then return nil,err end
 local _,duplicate=matching(latest,'gdriveshelf.json')
 if duplicate then return {conflict=conflict(request,duplicate.code,duplicate.message)}end
 return {entry=uploaded,snapshot={values=record.values,entry=uploaded,cover_path=record.cover_path}}
end
function O.attach(Core)
 local titleInfo=Core.titleInfo
 function Core:titleInfo(parent)
  local info=titleInfo(self,parent);local store=load(self);local record=store and store.records[parent]
  if record then
   for _,key in ipairs{'title','description'}do if record.values[key]~=nil then info[key]=record.values[key]end end
   if record.values.cover and record.cover_path and self.storage:exists(record.cover_path)then info.cover_path=record.cover_path end
   info.metadata_provenance={source='gdriveshelf.json',local_edit=store.pending[parent]~=nil,version=record.remote_entry and record.remote_entry.version}
  end
  return info
 end
 function Core:saveFolderMetadata(folder,values,coverpath,callback)
  local id=folderId(folder)
  if type(id)~='string'or id==''or type(values)~='table'then return reject(callback,errorValue('metadata','Select a folder and metadata values'))end
  local store,err=load(self);if not store then if callback then callback(nil,err)end;return nil,err end
  local previous_record=store.records[id];local old=previous_record or{};local previous=store.pending[id]
  local wire={schema=1,title=values.title,description=values.description,cover=old.values and old.values.cover}
  local cover_path=old.cover_path
  if coverpath==false then wire.cover=nil;cover_path=nil
  elseif coverpath then
   local cover;cover,err=importCover(self,id,coverpath)
   if not cover then if callback then callback(nil,err)end;return nil,err end
   wire.cover=cover.name;cover_path=cover.path
  end
  wire,err=O.normalize(wire);if not wire then if callback then callback(nil,err)end;return nil,err end
  if #self.storage.json.encode(wire)>JSON_LIMIT then return reject(callback,errorValue('metadata','Folder metadata is too large'))end
  local record={values=wire,cover_path=cover_path,remote_entry=clone(old.remote_entry),remote_values=clone(old.remote_values),preserved_remote_backup_path=old.preserved_remote_backup_path,revision=(old.revision or 0)+1}
  local request={record=clone(record),base=clone(previous and previous.base or old.remote_entry),conflict=previous and clone(previous.conflict),recovery=previous and clone(previous.recovery)}
  if request.conflict then request.conflict.local_values=clone(wire)end
  store.records[id]=record;store.pending[id]=request
  local ok,committed;ok,err,committed=persist(self,store)
  if not ok then
   if not committed then store.records[id]=previous_record;store.pending[id]=previous end
   if callback then callback(nil,err)end;return nil,err
  end
  self:emit('metadata',folder)
  if callback then callback({queued=true,folder_id=id})end
  self:flushMetadata();return true
 end
 function Core:flushMetadata()
  if not self:online()then return false end
  local store,err=load(self);if not store then return false,err end
  local queued=false
  for id,pending in pairs(store.pending)do
   if not pending.conflict then
    local request=clone(pending)
    local accepted=self:network('metadata-upload:'..id,function(provider)return upload(self,provider,id,request)end,function(result,why)
     local current=store.pending[id];local newer=false
     if not current then return end
     if result and result.conflict then
      current.conflict=result.conflict;current.conflict.local_values=clone(current.record.values)
     elseif result and result.entry then
      local record=store.records[id]
      record.remote_entry=clone(result.entry);record.remote_values=clone(request.record.values)
      if current.record.revision==request.record.revision then store.pending[id]=nil
      else
       -- A newer edit was made while this job was running; its next conditional
       -- write starts from the version that this worker successfully published.
       current.base=clone(result.entry);current.record.remote_entry=clone(result.entry);newer=true
      end
     else current.last_error=why and why.message or 'Folder metadata upload failed'end
     local saved,se=persist(self,store)
     self:emit(result and result.conflict and 'metadata-conflict'or 'metadata', {id=id},saved and why or se)
     if saved and newer then self:flushMetadata()end
    end,false)
    queued=accepted or queued
   end
  end
  return queued
 end
 function Core:metadataConflict(folder)
  local store=load(self);local pending=store and store.pending[folderId(folder)]
  return pending and clone(pending.conflict)or nil
 end
 function Core:resolveMetadataConflict(folder,choice,callback)
  local id=folderId(folder);local store,err=load(self);local pending=store and store.pending[id]
  local issue=pending and pending.conflict
  if not issue then return reject(callback,errorValue('metadata','No folder metadata conflict is pending'))end
  if issue.code=='ambiguous_metadata'then return reject(callback,errorValue('ambiguous_metadata','Resolve duplicate metadata filenames on Drive first'))end
  local record=store.records[id]
  if choice=='remote'then
   if not issue.remote_values then return reject(callback,errorValue('metadata','The remote version cannot be safely read'))end
   record.preserved_local={values=clone(record.values),cover_path=record.cover_path}
   record.values=clone(issue.remote_values);record.cover_path=issue.remote_cover_path;record.remote_entry=clone(issue.remote_entry);record.remote_values=clone(issue.remote_values)
   store.pending[id]=nil
  elseif choice=='local'then
   if issue.unreadable_json then
    if not issue.remote_entry or not issue.remote_entry.etag or not issue.remote_backup_path or not self.storage:read(issue.remote_backup_path,JSON_LIMIT)then return reject(callback,errorValue('io','The original remote JSON backup is unavailable; no cloud file was replaced'))end
   elseif not issue.confirmed_absent and not issue.remote_values then return reject(callback,errorValue('metadata','This remote metadata format is unsupported; keep it or resolve it on Drive first'))
   elseif not issue.confirmed_absent and not issue.remote_entry then return reject(callback,errorValue('metadata','Refresh folder metadata before choosing the local version'))end
   record.preserved_remote=clone(issue.remote_values);record.remote_entry=clone(issue.remote_entry);record.revision=(record.revision or 0)+1
   if issue.unreadable_json then
    record.preserved_remote_backup_path=issue.remote_backup_path
    pending.recovery={entry=clone(issue.remote_entry),backup_path=issue.remote_backup_path}
   else pending.recovery=nil end
   pending.base=clone(issue.remote_entry);pending.record=clone(record);pending.conflict=nil
  else return reject(callback,errorValue('metadata','Choose the local or remote version'))end
  local ok;ok,err=persist(self,store);if not ok then if callback then callback(nil,err)end;return nil,err end
  self:emit('metadata',{id=id});if callback then callback({queued=choice=='local',folder_id=id})end
  if choice=='local'then self:flushMetadata()end;return true
 end
 local metadata=Core.metadata
 function Core:metadata(entries)
  metadata(self,entries)
  if not self:online()then return end
  local store=load(self);if not store then return end
  local seen={}
  for _,entry in ipairs(entries or{})do
   if not entry.is_folder and entry.name=='gdriveshelf.json'then
    local id=entry.parent_id
    if id and not seen[id]then
     seen[id]=true
     local source,duplicate=matching(entries,'gdriveshelf.json',id)
     if duplicate then
      local pending=store.pending[id];if pending then pending.conflict=conflict(pending,duplicate.code,duplicate.message);persist(self,store)end
     else
      local record=store.records[id]
      local pending=store.pending[id];local ambiguous=pending and pending.conflict and pending.conflict.code=='ambiguous_metadata'
      if ambiguous or not record or not sameRemote(entry,record.remote_entry)then
       self:network('metadata-read:'..id,function(provider)
        local current,why=provider:stat(source.id);if not current then return nil,why end
        return remoteSnapshot(self,provider,id,current,entries)
       end,function(snapshot,why)
        if snapshot then
         local pending=store.pending[id]
         if pending then
          if not sameRemote(snapshot.entry,pending.base)then pending.conflict=conflict(pending,nil,nil,snapshot)
          elseif pending.conflict and pending.conflict.code=='ambiguous_metadata'then pending.conflict=nil end
         else store.records[id]={values=snapshot.values,cover_path=snapshot.cover_path,remote_entry=snapshot.entry,remote_values=clone(snapshot.values),revision=record and record.revision or 0}end
         local saved=persist(self,store);self:emit('metadata',{id=id},why)
         if saved and pending and not pending.conflict then self:flushMetadata()end
        end
       end,false)
      end
     end
    end
   end
  end
 end
 local resume=Core.resume
 function Core:resume(...)
  local result=resume(self,...);self:flushMetadata();return result
 end
end
return O
