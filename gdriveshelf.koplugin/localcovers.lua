-- Cover workers only inspect verified local books. Never open native DocSettings:
-- even a read can repair an empty/corrupt sidecar and change reading progress.
local L={}
local Metadata=require('gdriveshelf/metadata')
local SDR=require('gdriveshelf/sdr')
local Zip=require('gdriveshelf/zipcover')
local Thumbnails=require('gdriveshelf/thumbnails')
local MiB=1048576
local supported={cbz=true,cbr=true,epub=true,pdf=true}
local paged={cbz=true,cbr=true,cb7=true,pdf=true}
local function extension(e)return (e.name or ''):lower():match('%.([^%.]+)$')end
local function failure(code,message)return {code=code,message=message}end
local function inherited(path)
 local registry=package.loaded['document/documentregistry']
 return registry and registry.registry and registry.registry[path]~=nil
end
local function validOutput(path,max_w,max_h)
 local f=io.open(path,'rb');if not f then return nil end
 local data=f:read(MiB+1);f:close()
 local w,h=Thumbnails.dimensions(data or '')
 return data and data:sub(1,8)=='\137PNG\r\n\26\n'and #data<=MiB and w and w<=(max_w or 320)and h<=(max_h or 440)and #data or nil
end
local function preparedCover(core,path)
 core.prepared_cover_paths=core.prepared_cover_paths or {}
 core.prepared_cover_paths[path]=true
 return function()
  core.prepared_cover_paths[path]=nil
  os.remove(path)
 end
end
local function openNative(cached,paged_only)
 local Registry=require('document/documentregistry')
 if inherited(cached.path)then return nil,failure('active','Close this document before extracting its cover')end
 -- getProviders never consults per-book preferred-provider settings.
 local providers=Registry:getProviders(cached.path)
 local provider=providers and providers[1]and providers[1].provider
 if provider and provider.provider=='mupdf'then
  local original=provider.convertKoptToReflowableFontSize
  if type(original)~='function'or type(provider.extend)~='function'then return nil,failure('preview','Native cover provider is incompatible')end
  -- Explicit 1 means the default 22pt and returns before any sidecar access.
  provider=provider:extend{convertKoptToReflowableFontSize=function(self,size)return original(self,size or 1)end}
 elseif not provider or paged_only or provider.provider~='crengine'then
  return nil,failure('preview','No safe native cover provider is available')
 end
 local document=Registry:openDocument(cached.path,provider)
 if not document then return nil,failure('preview','Cannot open this document for a cover')end
 return document
end
function L.build(entry,cached,path)
 if extension(entry)=='cbz'then return Thumbnails.build(entry,cached,nil,path)end
 if not supported[extension(entry)]then return nil,failure('preview','This archive format does not support cover extraction')end
 local document,bb
 local ok,result,why=pcall(function()
  local why;document,why=openNative(cached,false)
  if not document then return nil,why end
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
local function nativePage(document,number,path,max_w,max_h)
 local page,bb
 local ok=pcall(function()
  local context=require('ffi/drawcontext').new()
  page=document._document:openPage(number)
  local w,h=page:getSize(context)
  assert(w>0 and h>0 and w<math.huge and h<math.huge)
  local zoom=math.min(max_w/w,max_h/h,1)
  context:setZoom(zoom)
  bb=page:draw_new(context,math.max(1,math.floor(w*zoom)),math.max(1,math.floor(h*zoom)),0,0)
  bb:writePNG(path)
 end)
 if bb then pcall(bb.free,bb)end
 if page then pcall(page.close,page)end
 if not ok then return nil,failure('preview','Cannot render this page')end
 return true
end
function L.galleryPages(entry,cached,first,count,paths,max_w,max_h)
 local pages={}
 local function add(number,path,ok,err)
  if ok and validOutput(path,max_w,max_h)then pages[#pages+1]={number=number,path=path}
  else os.remove(path);pages[#pages+1]={number=number,error=err or failure('preview','Cannot save a bounded page preview')}end
 end
 local result,why
 if extension(entry)=='cbz'then
  local file=io.open(cached.path,'rb')
  if not file then return nil,failure('preview','Cannot read local archive')end
  result,why=Zip.pages(entry,function(a,b)
   if file:seek('set',a)then return file:read(b-a+1)end
  end,first,count,function(number,data,err)
   local path=paths[number-first+1]
   local ok;if data then ok,err=Thumbnails.render(data,path,max_w,max_h)end
   add(number,path,ok,err)
  end)
  file:close()
 else
  local document
  local ok
  ok,result,why=pcall(function()
   local err;document,err=openNative(cached,true)
   if not document then return nil,err end
   if document.is_locked or document.is_reflowable or not document._document then return nil,failure('preview','This document does not support page selection')end
   local total=document:getPageCount()
   local last=type(total)=='number'and total<=100000 and Zip.pageWindow(total,first,count)
   if not last then return nil,failure('preview','Document pages are unavailable')end
   for number=first,last do
    local path=paths[number-first+1]
    local rendered,problem=nativePage(document,number,path,max_w,max_h)
    add(number,path,rendered,problem)
   end
   return {total=total,first=first}
  end)
  if document then pcall(document.close,document)end
  if not ok then return nil,failure('preview','Native page extraction is unavailable')end
 end
 if result then result.pages=pages end
 return result,why
end
local function localStamp(core,entry,cached)
 if not cached or not cached.ready or not SDR.sameBook(entry,cached)then return nil end
 local attr=core.storage.lfs and core.storage.lfs.attributes(cached.path)
 if not attr or attr.size~=tonumber(entry.size)then return nil end
 return Metadata.fingerprint(entry)..':'..tostring(attr.modification)..':'..tostring(attr.size)..':'..cached.path
end
local Gallery={};Gallery.__index=Gallery
local function removeOutputs(paths)
 for _,path in ipairs(paths or{})do os.remove(path)end
end
function Gallery:checkSource()
 local core,entry=self.core,self.entry
 local cached=core.state.entries[entry.id]
 local current=core.state.docs[entry.id]or entry
 if not SDR.sameBook(entry,current)or localStamp(core,entry,cached)~=self.stamp then
  return nil,failure('changed','Cached document changed before extracting its cover')
 end
 if core.active_id==entry.id or core.opening_id==entry.id or inherited(cached.path)then
  return nil,failure('active','Close this document before extracting its cover')
 end
 return true
end
function Gallery:cancelJob()
 local job=self.job;self.job=nil
 if job then
  local jobs=self.core.jobs
  jobs:cancel(job.key);removeOutputs(job.paths)
  -- Also clean a file opened immediately before the worker received SIGKILL.
  if jobs.schedule then jobs.schedule(function()removeOutputs(job.paths)end,1)end
 end
end
function Gallery:request(first,count,max_w,max_h,callback)
 if self.released or not Zip.pageWindow(self.total or math.huge,first,count)then
  callback(nil,failure('preview','Document pages are unavailable'));return
 end
 self:cancelJob()
 self.generation=self.generation+1
 local key=self.key..'-'..self.generation
 local paths={}
 for slot=1,count do paths[slot]=self.core.storage.root..'/jobs/result-'..key..'-'..slot..'.png'end
 local job={key=key,paths=paths};self.job=job
 local function finish(result,err)
  if self.job~=job then removeOutputs(paths);return end
  self.job=nil
  local good,why=self:checkSource()
  if not result or not good then removeOutputs(paths);callback(nil,err or why);return end
  callback(result,nil,paths)
 end
 if not self.core.jobs:enqueue(key,function()
  return L.galleryPages(self.entry,self.cached,first,count,paths,max_w,max_h)
 end,finish,true,function()return self:checkSource()end,nil,true,{timeout=25})then
  finish(nil,failure('worker','Cannot start page preview'))
 end
end
function Gallery:load(first,callback)
 removeOutputs(self.page_paths);self.page_paths=nil
 self:request(first,6,150,210,function(result,err,paths)
  if result then self.total=result.total;self.page_paths=paths end
  callback(result,err)
 end)
end
function Gallery:select(page,callback)
 self:request(page,1,320,440,function(result,err,paths)
  if not result then callback(nil,err);return end
  local selected=result.pages[1]
  if not selected or not selected.path then
   removeOutputs(paths);callback(nil,selected and selected.error or failure('preview','Cannot render this page'));return
  end
  if self.clean_selected then self.clean_selected()end
  self.clean_selected=preparedCover(self.core,selected.path)
  callback(selected.path)
 end)
end
function Gallery:release()
 if self.released then return end
 self.released=true
 self:cancelJob();removeOutputs(self.page_paths);self.page_paths=nil
 if self.core.cover_gallery_session==self then self.core.cover_gallery_session=nil end
end
function Gallery:close()
 self:release()
 if self.clean_selected then self.clean_selected();self.clean_selected=nil end
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
 core.local_cover_automatic=core.local_cover_automatic or {}
 if not force then core.local_cover_automatic[entry.id]=key end
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
  core.storage:remove(incoming);core.local_cover_protected[entry.id]=nil;core.local_cover_automatic[entry.id]=nil
  if result or(err and(err.code=='preview'or err.code=='preview_limit'or err.code=='preview_format'or err.code=='range'or err.code=='timeout'))then
   core.state.local_cover_attempts[entry.id]={fingerprint=stamp,skipped=not result};core:save()
  end
  if not err or err.code~='cancelled'then core:emit('thumbnail',entry,err)end
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
 if not accepted then core.local_cover_protected[entry.id]=nil;core.local_cover_waiters[entry.id]=nil;core.local_cover_automatic[entry.id]=nil end
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
  if self.cover_gallery_session then result[self.cover_gallery_session.entry.id]=true end
  if self.quick_preview_session and self.quick_preview_session.path then result[self.quick_preview_session.entry.id]=true end
  return result
 end
 function Core:coverGallerySupported(entry)
  return not entry.is_folder and paged[extension(entry)]==true
 end
 function Core:coverGallery(entry)
  if not self:coverGallerySupported(entry)then return nil,failure('preview','This document does not support page selection')end
  local cached=self:cached(entry.id)
  local stamp=localStamp(self,entry,cached)
  if not stamp then return nil,failure('missing','Download this document before choosing a page')end
  local session=setmetatable({core=self,entry=entry,cached=cached,stamp=stamp,generation=0},Gallery)
  local good,why=session:checkSource();if not good then return nil,why end
  if self.cover_gallery_session then self.cover_gallery_session:close()end
  self.cover_gallery_sequence=(self.cover_gallery_sequence or 0)+1
  session.key='cover-gallery-'..tostring(self.jobs.nonce or 'test')..'-'..self.cover_gallery_sequence
  self.cover_gallery_session=session
  return session
 end
 function Core:prepareFolderCover(path,callback)
  self.cover_import_sequence=(self.cover_import_sequence or 0)+1
  local key='prepare-cover-'..tostring(self.jobs.nonce or 'test')..'-'..self.cover_import_sequence
  local output=self.storage.root..'/jobs/result-'..key..'.png'
  local accepted=self.jobs:enqueue(key,function()
   local data=self.storage:read(path,8*MiB)
   if not data then return nil,failure('preview','Cannot read the selected cover image')end
   return Thumbnails.render(data,output)
  end,function(result,err)
   if result and validOutput(output)then callback(output,nil,preparedCover(self,output));return end
   os.remove(output)
   if err and err.code=='cancelled'and self.jobs.schedule then self.jobs.schedule(function()os.remove(output)end,1)end
   callback(nil,err or failure('preview','Cannot prepare the selected cover image'))
  end,true,nil,nil,true,{timeout=15})
  if accepted then return key end
  callback(nil,failure('worker','Cannot start image preview'))
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
  if self.settings.light_mode or self.settings.local_covers==false then return 0 end
  local queued=0
  for _,entry in ipairs(entries or{})do
   if not entry.is_folder and supported[extension(entry)]and not self:localCover(entry)then
    local cached=self:cached(entry.id)
    if queue(self,entry,cached,nil,false)then queued=queued+1 end
   end
  end
  return queued
 end
 function Core:cancelAutomaticCovers()
  local keys={}
  for id,key in pairs(self.local_cover_automatic or{})do
   if not self.local_cover_waiters[id]then keys[#keys+1]=key end
  end
  for _,key in ipairs(keys)do self.jobs:cancel(key)end
 end
 local titleInfo=Core.titleInfo
 function Core:titleInfo(parent)
  local info=titleInfo(self,parent)
  if not info.cover_path and self.settings.local_covers~=false then
   local candidates={}
   for _,entry in ipairs(self:cachedList(parent))do
    local preview=self.state.entries['thumb:'..entry.id]
    if preview and (preview.local_source_stamp or self.state.entries[entry.id])then candidates[#candidates+1]=entry end
   end
   for _,entry in ipairs(require('gdriveshelf/library').ordered(candidates,'natural'))do
    local cover=self:localCover(entry)
    if cover then info.cover_path=cover.path;info.cover_source='chapter';break end
   end
  end
  return info
 end
 function Core:extractFolderCover(folder,callback)
  local Library=require('gdriveshelf/library')
  local entries=Library.ordered(self:cachedList(folder.id),'natural')
  local function refuse(code,message)
   local err=failure(code,message)
   if callback then callback(nil,err)end
   return false,err
  end
  for _,entry in ipairs(entries)do
   if Library.supported(entry)then
    local thumb=self:localCover(entry)
    if thumb then if callback then callback(thumb.path)end;return true end
    local cached=self:cached(entry.id)
    local format=extension(entry)
    if supported[format]and localStamp(self,entry,cached)then return queue(self,entry,cached,callback,true)end
    if format=='cbr'then return refuse('download_cbr','Download the CBR volume before choosing a cover.')end
    if format=='cbz'then
     if self:online()then return queue(self,entry,nil,callback,true,true)end
     return refuse('offline','Connect to extract the CBZ cover or download the volume first.')
    end
    if supported[format]then return refuse('missing','Download this document before choosing a page')end
    return refuse('preview_format','This archive format does not support cover extraction')
   end
  end
  return refuse('missing','There are no documents to use as a cover.')

 end
end
return L
