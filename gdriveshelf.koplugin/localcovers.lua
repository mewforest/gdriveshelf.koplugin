-- Cover workers only inspect verified local books. Never open native DocSettings:
-- even a read can repair an empty/corrupt sidecar and change reading progress.
local L={}
local Metadata=require('gdriveshelf/metadata')
local SDR=require('gdriveshelf/sdr')
local MiB=1048576
local supported={cbz=true,cbr=true,epub=true,pdf=true}
local function extension(e)return (e.name or ''):lower():match('%.([^%.]+)$')end
local function failure(code,message)return {code=code,message=message}end
local function inherited(path)
 local registry=package.loaded['document/documentregistry']
 return registry and registry.registry and registry.registry[path]~=nil
end
local function validOutput(path)
 local f=io.open(path,'rb');if not f then return nil end
 local data=f:read(MiB+1);f:close()
 local w,h=require('gdriveshelf/thumbnails').dimensions(data or '')
 return data and #data<=MiB and w and w<=320 and h<=440 and #data or nil
end
function L.build(entry,cached,path)
 if extension(entry)=='cbz'then return require('gdriveshelf/thumbnails').build(entry,cached,nil,path)end
 if not supported[extension(entry)]then return nil,failure('preview','This archive format does not support cover extraction')end
 local document,bb
 local ok,result,why=pcall(function()
  local Registry=require('document/documentregistry')
  if Registry.registry and Registry.registry[cached.path]then return nil,failure('active','Close this document before extracting its cover')end
  -- getProviders never consults per-book preferred-provider settings.
  local providers=Registry:getProviders(cached.path)
  local provider=providers and providers[1]and providers[1].provider
  if not provider then return nil,failure('preview','No safe native cover provider is available')end
  if provider.provider=='mupdf'then
   local original=provider.convertKoptToReflowableFontSize
   if type(original)~='function'or type(provider.extend)~='function'then return nil,failure('preview','Native cover provider is incompatible')end
   -- A class scoped to this worker: explicit 1 means the engine's normal 22pt
   -- baseline and takes its early return before *any* sidecar access.
   provider=provider:extend{convertKoptToReflowableFontSize=function(self,size)return original(self,size or 1)end}
  elseif provider.provider~='crengine'then
   return nil,failure('preview','No safe native cover provider is available')
  end
  document=Registry:openDocument(cached.path,provider)
  if not document then return nil,failure('preview','Cannot open this document for a cover')end
  if document.loadDocument and not document:loadDocument(false)then return nil,failure('preview','Cannot read this document cover')end
  bb=require('apps/filemanager/filemanagerbookinfo'):getCoverImage(document,nil,true)
  if not bb then return nil,failure('preview','This document has no cover')end
  local w,h=bb:getWidth(),bb:getHeight()
  if w<1 or h<1 or w*h>16000000 then return nil,failure('preview','Document cover is too large')end
  local scale=math.min(320/w,440/h,1)
  bb=require('ui/renderimage'):scaleBlitBuffer(bb,math.max(1,math.floor(w*scale+1e-9)),math.max(1,math.floor(h*scale+1e-9)))
  bb:writePNG(path)
  local size=validOutput(path)
  if not size then return nil,failure('preview','Cannot save a bounded document cover')end
  return {path=path,size=size}
 end)
 if bb then pcall(bb.free,bb)end
 if document then pcall(document.close,document)end
 if not ok or not result then os.remove(path);return nil,why or failure('preview','Native cover extraction is unavailable')end
 return result
end
local function localStamp(core,entry,cached)
 if not cached or not cached.ready or not SDR.sameBook(entry,cached)then return nil end
 local attr=core.storage.lfs and core.storage.lfs.attributes(cached.path)
 if not attr or attr.size~=tonumber(entry.size)then return nil end
 return Metadata.fingerprint(entry)..':'..tostring(attr.modification)..':'..tostring(attr.size)..':'..cached.path
end
local function queue(core,entry,cached,callback,force,remote)
 local stamp=cached and localStamp(core,entry,cached)or(remote and Metadata.fingerprint(entry))
 if not stamp or (cached and(inherited(cached.path)or core.active_id==entry.id or core.opening_id==entry.id))then
  local why=failure(stamp and 'active'or 'changed',stamp and 'Close this document before extracting its cover'or 'Cached document changed before extracting its cover')
  if callback then callback(nil,why)end;return false,why
 end
 core.state.local_cover_attempts=core.state.local_cover_attempts or {}
 core.local_cover_waiters=core.local_cover_waiters or {}
 if callback then core.local_cover_waiters[entry.id]=core.local_cover_waiters[entry.id]or{};table.insert(core.local_cover_waiters[entry.id],callback)end
 local key='local-cover:'..entry.id
 if core.jobs.keys[key]then return callback~=nil,key end
 local attempted=core.state.local_cover_attempts[entry.id]
 if not force and attempted and attempted.skipped==true and attempted.fingerprint==stamp then return false end
 local output={id='thumb:'..entry.id,name='preview.png',parent_id=entry.parent_id,pool='meta'}
 local path=core.storage:filePath(output,'meta');local incoming=path..'.incoming-'..tostring(core.jobs.nonce or 'cover')
 core.local_cover_protected=core.local_cover_protected or {};core.local_cover_protected[entry.id]=true
 local function before()
  if cached and localStamp(core,entry,cached)~=stamp then return nil,failure('changed','Cached document changed before extracting its cover')end
  if core.active_id==entry.id or core.opening_id==entry.id or(cached and inherited(cached.path))then return nil,failure('active','Close this document before extracting its cover')end
  local victims,err=core:cache():plan('meta',MiB,core:protected(),output.id)
  if not victims then return nil,failure('space',err)end
  core:evict(victims);return true
 end
 local function finish(result,err)
  if result and cached and localStamp(core,entry,cached)~=stamp then result=nil;err=failure('changed','Cached document changed while extracting its cover')end
  if result and Metadata.fingerprint(core.state.docs[entry.id]or entry)~=Metadata.fingerprint(entry)then result=nil;err=failure('changed','Document changed while extracting its cover')end
  if result then
   local size=validOutput(incoming)
   local victims=size and core:cache():plan('meta',size,core:protected(),output.id)
   if victims then
    core:evict(victims)
    if os.rename(incoming,path)then
     output.path=path;output.size=size;output.ready=true;output.last_access=os.time();output.source_stamp=Metadata.fingerprint(entry);output.local_source_stamp=cached and stamp or nil
     core.state.entries[output.id]=output
    else result=nil;err=failure('io','Cannot publish cover')end
   else result=nil;err=failure('space','Cannot store cover in the metadata cache')end
  end
  core.storage:remove(incoming);core.local_cover_protected[entry.id]=nil
  if result or(err and(err.code=='preview'or err.code=='range'or err.code=='timeout'))then core.state.local_cover_attempts[entry.id]={fingerprint=stamp,skipped=not result}end
  core:save();core:emit('thumbnail',entry,err)
  local callbacks=core.local_cover_waiters[entry.id]or{};core.local_cover_waiters[entry.id]=nil
  for _,fn in ipairs(callbacks)do fn(result and path or nil,err)end
 end
 local accepted
 if remote then
  accepted=core:network(key,function(provider)
   local result,err=require('gdriveshelf/thumbnails').build(entry,nil,provider,incoming)
   if not result then return nil,err end
   local current,why=provider:stat(entry.id)
   if not current or not SDR.sameBook(entry,current)then return nil,why or failure('changed','Archive changed while extracting cover')end
   return result
  end,finish,false,before)
 else
  accepted=core.jobs:enqueue(key,function()return L.build(entry,cached,incoming)end,finish,false,before,nil,true,{timeout=15})
 end
 if not accepted then core.local_cover_protected[entry.id]=nil;core.local_cover_waiters[entry.id]=nil end
 return accepted,key
end
function L.attach(Core)
 local emit=Core.emit
 function Core:emit(kind,entry,err)
  emit(self,kind,entry,err)
  if kind=='downloaded'and entry and not entry.is_folder and supported[extension(entry)]then self:ensureLocalCovers({entry})end
 end
 local protected=Core.protected
 function Core:protected()
  local result=protected(self)
  for id in pairs(self.local_cover_protected or{})do result[id]=true end
  return result
 end
 function Core:localCover(entry)
  local thumb=self:cached('thumb:'..entry.id)
  if not thumb or thumb.source_stamp~=Metadata.fingerprint(entry)then return nil end
  if thumb.local_source_stamp then
   local cached=self.state.entries[entry.id]
   -- A cached cover remains useful after archive eviction. When the archive is
   -- present, however, a changed local file must invalidate the derived image.
   if cached and cached.ready and self.storage:exists(cached.path)and localStamp(self,entry,cached)~=thumb.local_source_stamp then return nil end
  end
  return thumb
 end
 Core.thumbnail=Core.localCover
 function Core:ensureLocalCovers(entries)
  if self.settings.local_covers==false then return 0 end
  local queued=0
  for _,entry in ipairs(entries or{})do
   if not entry.is_folder and supported[extension(entry)]and not self:localCover(entry)then
    local cached=self:cached(entry.id)
    if queue(self,entry,cached,nil,false)then queued=queued+1 end
   end
  end
  return queued
 end
 local titleInfo=Core.titleInfo
 function Core:titleInfo(parent)
  local info=titleInfo(self,parent)
  if not info.cover_path and self.settings.local_covers~=false then
   for _,entry in ipairs(require('gdriveshelf/library').ordered(self:cachedList(parent),'natural'))do
    local cover=self:localCover(entry)
    if cover then info.cover_path=cover.path;break end
   end
  end
  return info
 end
 function Core:extractFolderCover(folder,callback)
  local entries=require('gdriveshelf/library').ordered(self:cachedList(folder.id),'natural')
  for _,entry in ipairs(entries)do
   if require('gdriveshelf/library').supported(entry)then
    local thumb=self:localCover(entry)
    if thumb then if callback then callback(thumb.path)end;return true end
    local cached=self:cached(entry.id)
    if supported[extension(entry)]and localStamp(self,entry,cached)then return queue(self,entry,cached,callback,true)end
    if extension(entry)=='cbz'and self:online()then return queue(self,entry,nil,callback,true,true)end
    break
   end
  end
  local err=failure('preview','Download the first supported chapter or go online for bounded CBZ cover extraction.')
  if callback then callback(nil,err)end;return false,err
 end
end
return L
