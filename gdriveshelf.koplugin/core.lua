local Catalog=require('gdriveshelf/catalog')
local Cache=require('gdriveshelf/cache')
local Library=require('gdriveshelf/library')
local Metadata=require('gdriveshelf/metadata')
local SDR=require('gdriveshelf/sdr')
local Sync=require('gdriveshelf/sync')
local Core={};Core.__index=Core
local MiB=1048576
local LIGHT_LIST_TTL=15*60
local function automaticDownload(request)
 return request.automatic==true or (request.automatic==nil and (request.pool=='auto'or request.pool=='meta'))
end
local function remoteEntry(entry)
 local out={};for _,key in ipairs{'id','name','parent_id','is_folder','size','created_time','modified_time','checksum','version','etag','mime_type','first_seen','drive_id','trashed'}do out[key]=entry[key]end
 return out
end
local function errorValue(code,message)return {code=code,message=message}end
function Core.new(o)
 local self=setmetatable({storage=o.storage,jobs=o.jobs,credentials=o.credentials,provider_factory=o.provider_factory,settings=o.settings or {},onchange=o.onchange,logger=o.logger,waiters={},active_id=nil,retry_failures=0},Core)
 self.index_path=self.storage.root..'/index.json'
 local saved,readerr=self.storage:readJSON(self.index_path,256*MiB)
 if not saved and self.storage:exists(self.index_path)then error('Cannot read durable index; existing progress was preserved: '..tostring(readerr))end
 self.state=saved or {}
 if self.state.books_dir and self.storage.books_dir then self.storage.books_dir=self.state.books_dir;self.settings.books_dir=self.state.books_dir end
 if self.storage.cleanupDownloads then self.storage:cleanupDownloads(self.state.entries or {})end
 for _,k in ipairs{'entries','docs','folders','sync','downloads','summaries','last_opened','listings','history','folder_types','folder_pins'}do self.state[k]=self.state[k] or {} end
 for _,k in ipairs{'pending','bases','conflicts'}do self.state.sync[k]=self.state.sync[k] or {} end
 if self.storage.books_dir and self.state.archive_layout~=2 then
  -- Archive layout v1 is intentionally retired; durable reading/sync data stays.
  for id,e in pairs(self.state.entries)do if e.pool~='meta'then self.state.entries[id]=nil end end
  self.state.archive_layout=2
 end
 self.jobs:setOffline(self.settings.offline==true)
 if self.storage.books_dir then require('gdriveshelf/relocation').recover(self,o.current_path)end
 return self
end
function Core:stopRelocation()
 if self.relocating then self.jobs:cancel('relocate')end
end
function Core:save()return self.storage:writeJSON(self.index_path,self.state)end
function Core:emit(kind,entry,err)if self.onchange then self.onchange(kind,entry,err)end end
function Core:networkState()
 if self.retired then return 'auth'end
 if self.settings.offline then return 'offline'end
 if self.sleeping then return 'sleep'end
 if self.auth_error then return 'auth'end
 if os.time()<(self.retry_after or 0)then return 'retry'end
 return 'online'
end
-- Online means work may be queued. Jobs holds network work during a retry delay.
function Core:online()local state=self:networkState();return state=='online'or state=='retry'end
function Core:syncNetworkJobs()
 local state=self:networkState()
 self.jobs.paused=state=='retry'or state=='auth'
 self.jobs:setOffline(self.settings.offline==true or self.sleeping==true)
 if self.last_network_state~=state then self.last_network_state=state;self:emit('network_state')end
end
function Core:resetNetwork(clear_auth,explicit)
 self.retry_after=nil;self.retry_failures=0
 if clear_auth then self.auth_error=nil end
 if self.retry_tick and self.jobs.unschedule then self.jobs.unschedule(self.retry_tick)end
 self:syncNetworkJobs();self:resume(explicit)
end
function Core:suspend()
 self.sleeping=true;self:syncNetworkJobs()
end
function Core:wake()
 self.sleeping=false;self:resetNetwork()
end
function Core:setOffline(value)
 self.settings.offline=value==true
 if not value then self:resetNetwork()else self:syncNetworkJobs()end
 self:emit('offline')
end
function Core:setLightMode(value)
 local enabled=value==true
 if enabled==(self.settings.light_mode==true)then return end
 self.settings.light_mode=enabled
 if enabled then
  local held=self.jobs.hold
  self.jobs.hold=true
  if self.index_job and not self.index_job.explicit then self:cancelIndex(false)end
  self.index_enrichment=nil
  if self.deep_job and self.deep_job.automatic then self:cancelDeepScan()end
  if self.cancelAutomaticCovers then self:cancelAutomaticCovers()end
  if self.cancelAutomaticProgress then self:cancelAutomaticProgress()end
  local pause={code='cancelled',message='Paused in light mode',silent=true}
  for id,request in pairs(self.state.downloads)do
   if automaticDownload(request)and not next(self.waiters[id]or{})then self.jobs:cancel('download:'..id,pause)end
  end
  local implicit={}
  for _,job in ipairs(self.jobs.queue or {})do if job.automatic then implicit[#implicit+1]=job.key end end
  for _,key in ipairs(implicit)do self.jobs:cancel(key,pause)end
  self.jobs.hold=held
  self.jobs:pump()
 else self:resume()end
 self:emit('light_mode')
end
function Core:provider()
 local provider=self.provider_factory(self.credentials)
 if self.logger then provider.trace=function(name,fields)pcall(self.logger.event,self.logger,name,fields)end end
 return provider
end
function Core:sync(provider)
 return Sync.new{provider=provider or {},sdr=SDR,storage=self.storage,state=self.state.sync,offline=self.settings.offline}
end
function Core:network(key,work,done,front,before,progress,local_task,options)
 if self.retired then return false end
 if not local_task and not self:online()then return false end
 self.jobs.logger=self.logger;self:syncNetworkJobs()
 local attempts=0
 local job_options={timeout=options and options.timeout,automatic=options and options.automatic}
 job_options.retry=function(envelope,err)
  if self.retired then return false end
  if self.logger and envelope and type(envelope.trace)=='table'then
   for i=1,math.min(128,#envelope.trace)do pcall(self.logger.event,self.logger,'request',envelope.trace[i])end
  end
  if envelope and envelope.credentials then self.credentials=envelope.credentials;if self.oncredentials then self.oncredentials(self.credentials)end end
  local result=envelope and envelope.result
  if result then
   if not local_task then self.retry_after=nil;self.retry_failures=0 end
   return false
  end
  attempts=attempts+1
  local status=err and tonumber(err.status)
  local transient=not local_task and err and(err.code=='network'or(err.code=='api'and status and(status==408 or status==429 or(status>=500 and status<=599))))
  if transient then
   self.retry_failures=math.min((self.retry_failures or 0)+1,6)
   local delay=math.min(30,2^(self.retry_failures-1));local requested=tonumber(err.retry_after)
   if requested and requested==requested and requested>0 then delay=math.max(delay,math.min(86400,requested))end
   self.retry_after=os.time()+delay;self:syncNetworkJobs()
   if not self.retry_tick then self.retry_tick=function()if self:networkState()=='online'then self:syncNetworkJobs()end end end
   if self.jobs.unschedule then self.jobs.unschedule(self.retry_tick)end
   if self.jobs.schedule then self.jobs.schedule(self.retry_tick,delay)end
  elseif not local_task and err and(err.code=='auth'or err.code=='unauthorized')then
   self.auth_error=true;self:syncNetworkJobs()
  end
  return transient and attempts<3 or false
 end
 return self.jobs:enqueue(key,function(report)
  local p=self:provider();local trace={}
  -- Children return bounded diagnostics through private IPC; only the parent
  -- writes logs, so rotation cannot race a worker request completion.
  if self.logger then p.trace=function(name,fields)
   if name~='request'or type(fields)~='table'or #trace>=128 then return end
   local safe={}
   for _,field in ipairs{'operation','status','bytes','duration','error'}do
    local value=rawget(fields,field)
    if(type(value)=='string'and #value<=40)or(type(value)=='number'and value==value and value>=0 and value<=9007199254740991)then safe[field]=value end
   end
   trace[#trace+1]=safe
  end end
  local value,err=work(p,report)
  if value and type(value)=='table' then value.data=nil end -- Native SDR survives JSON transport as Lua literals.
  return {result=value,credentials=p.credentials,trace=trace},err
 end,function(envelope,err)
  if self.retired then return end
  local result=envelope and envelope.result
  if done then if result then done(result)else done(nil,err or errorValue('network','Network request failed'))end end
 end,front,function()
  if not local_task and self:networkState()~='online'then return nil,{code='paused',message='Waiting for network requests to resume',defer=true}end
  if before then return before()end
  return true
 end,progress,local_task,job_options)
end
function Core:cache()
 return Cache.new{entries=self.state.entries,auto_limit=(self.settings.auto_mib or 3072)*MiB,meta_limit=(self.settings.meta_mib or 256)*MiB,reserve=512*MiB,free_bytes=function(pool)return self.storage:freeBytes(pool=='meta'and self.storage.root or self.storage.books_dir)end,volume=self.storage.volume and function(pool)return self.storage:volume(pool=='meta'and self.storage.root or self.storage.books_dir)end}
end
function Core:protected()
 local p={};if self.active_id then p[self.active_id]=true end
 if self.opening_id then p[self.opening_id]=true end
 if self.downloading_id then p[self.downloading_id]=true end
 return p
end
function Core:evict(ids,deferSave)
 for _,id in ipairs(ids)do local e=self.state.entries[id];if e then
  local ok=self.storage:remove(e.path)
  if e.preview_path then self.storage:remove(e.preview_path)end
  if ok or not self.storage:exists(e.path)then self.state.entries[id]=nil end
 end end
 if deferSave then return true end
 return self:save()
end
function Core:cached(id)
 local e=self.state.entries[id]
 if e and e.ready and self.storage:exists(e.path)then e.last_access=os.time();return e end
 return nil
end
function Core:cachedList(parent)
 local listing=(self.state.listings or {})[parent]
 if listing and listing.complete then
  local entries={};for _,id in ipairs(listing.ids or {})do local e=self.state.docs[id]or self.state.folders[id];if e and e.parent_id==parent then entries[#entries+1]=e end end
  return entries
 end
 local cached=self:cached('list:'..parent)
 if cached then local d=self.storage:readJSON(cached.path);if d then local list={};for _,e in ipairs(d)do list[#list+1]=remoteEntry(e)end;return list end end
 local entries={}
 for _,e in pairs(self.state.docs)do if e.parent_id==parent then entries[#entries+1]=e end end
 for _,e in pairs(self.state.folders)do if e.parent_id==parent then entries[#entries+1]=e end end
 return Library.ordered(entries,self.settings.sort,self.settings.reverse,self.natural)
end
-- Build the same listing for direct reads and for staged index transactions.
-- A draft holds changed records only and resolves unchanged entries through its
-- backing state. No files or live tables are touched while preparing a draft.
function Core:updateListing(state,parent,entries,pulse)
 local clean,ids,stale={},{},{}
 local now=os.time()
 for _,entry in ipairs(entries)do
  local e=remoteEntry(entry)
  e.parent_id=e.parent_id or parent
  clean[#clean+1]=e;ids[#ids+1]=e.id
  if e.is_folder then
   local old=state.folders[e.id];e.first_seen=old and old.first_seen or now
   e.created_time=e.created_time or (old and old.created_time) or os.date('!%Y-%m-%dT%H:%M:%SZ',e.first_seen)
   state.folders[e.id]=e
  else
   local localPath=(state.docs[e.id]or {}).local_path
   local durable=remoteEntry(e);durable.local_path=localPath
   state.docs[e.id]=durable
   local thumb=self.state.entries['thumb:'..e.id]
   if thumb and thumb.source_stamp~=Metadata.fingerprint(e)then stale[#stale+1]='thumb:'..e.id end
  end
  if pulse then pulse()end
 end
 state.listings[parent]={complete=true,checked_at=now,ids=ids}
 return clean,stale
end
function Core:rememberList(parent,entries)
 local clean,stale=self:updateListing(self.state,parent,entries)
 self.listing_epoch=(self.listing_epoch or 0)+1
 if #stale>0 then self:evict(stale,true)end
 local text=self.storage.json.encode(clean);local id='list:'..parent
 local victims=self:cache():plan('meta',#text,self:protected(),id)
 if victims then
  self:evict(victims,true)
  local e={id=id,name='listing.json',parent_id=parent,pool='meta',size=#text,last_access=os.time(),ready=true}
  e.path=self.storage:filePath(e,'meta');local ok=self.storage:write(e.path,text)
  if ok then self.state.entries[id]=e end
 end
 return self:save()
end
function Core:folder(parent,name,callback,force)
 self.state.folders[parent]=self.state.folders[parent] or {id=parent,name=name or parent,is_folder=true}
 self.catalog_folder=parent
 local listing=self.state.listings[parent]
 local cached=self:cachedList(parent);if listing or #cached>0 or not self:online()then callback(cached,true)end
 if not self:online()then return false end
 local ttl=self.settings.light_mode and LIGHT_LIST_TTL or 30
 if not force and listing and listing.complete and not listing.dirty and os.time()-(listing.checked_at or 0)<ttl then
  self:metadata(cached,true)
  if not self.settings.light_mode then self:indexHome(false)end
  return false
 end
 self.folder_waiters=self.folder_waiters or {};self.folder_waiters[parent]=self.folder_waiters[parent]or{}
 self.folder_force=self.folder_force or {};self.folder_force[parent]=(force=='home' or self.folder_force[parent]=='home') and 'home' or force or self.folder_force[parent]
 self.folder_waiters[parent][#self.folder_waiters[parent]+1]=callback
 self:network('list:'..parent,function(p)return p:list(parent)end,function(entries,err)
  local explicit=self.folder_force[parent];self.folder_force[parent]=nil
  local listeners=self.folder_waiters[parent]or{};self.folder_waiters[parent]=nil
  if entries then self:rememberList(parent,entries)end
  for _,fn in ipairs(listeners)do fn(entries,false,err)end
  if not entries then return end
  local current=self.catalog_folder==parent and self.catalog_visible~=false
  if current or not self.settings.light_mode then self:metadata(entries,current)end
  if explicit or not self.settings.light_mode then self:flushPending(explicit)end
  if explicit and self.flushMetadata then self:flushMetadata()end
  if current then
   if not explicit or explicit=='home'then self:indexHome(explicit=='home' and parent==self.settings.home)end
   if parent==self.settings.home and self.settings.beta_auto_scan then self:deepScan({id=parent},true)end
  end
 end,true)
 return self.folder_waiters[parent]~=nil
end
local function metadataKind(entry)
 if entry.is_folder then return end
 local name=entry.name:lower()
 if name=='index.json'then return 'index' end
 if name=='series.json'then return 'series' end
end
local function currentMetadata(core,entry)
 local old=core:cached(entry.id)
 if old and Metadata.fingerprint(old)==Metadata.fingerprint(entry)then return old end
end
function Core:importedMetadata(entries)
 local info={}
 if self.settings.load_metadata==false then return info end
 for _,entry in ipairs(entries)do
  local kind=metadataKind(entry)
  if kind then
   local cached=self:cached(entry.id)
   local parsed=cached and cached.parsed
   if cached and not parsed then
    local data=self.storage:readJSON(cached.path,8*MiB)
    if data then parsed=Metadata.normalize(data,kind);cached.parsed=parsed end
   end
   for k,v in pairs(parsed or {})do
    if v~=nil and v~=''and (k~='cover'or not info.cover or v~='cover.jpg')then info[k]=v end
   end
  end
 end
 return info
end
function Core:coverMetadata(entries,explicit)
 if self.settings.load_covers==false or (self.settings.light_mode and not explicit)then return end
 local preferred=self:importedMetadata(entries).cover
 local cover=Metadata.coverCandidates(entries,preferred)[1]
 if cover then
  local old=currentMetadata(self,cover)
  if not old or not old.preview_path then self:download(cover,'meta',nil,not explicit)end
 end
end
function Core:metadata(entries,explicit)
 if self.settings.light_mode and not explicit then return end
 if self.settings.load_metadata~=false then
  for _,entry in ipairs(entries)do
   if metadataKind(entry)and not currentMetadata(self,entry)then self:download(entry,'meta',nil,not explicit)end
  end
 end
 self:coverMetadata(entries,explicit)
end
function Core:download(entry,pool,callback,automatic,light_prefetch)
 if self.settings.light_mode and automatic and not(light_prefetch and (self.settings.light_prefetch or 0)>0)then return false end
 self:stopRelocation()
 local old=self:cached(entry.id)
 local image=pool=='meta'and Metadata.isImageName(entry.name)
 if old and(pool~='meta'or(Metadata.fingerprint(old)==Metadata.fingerprint(entry)and(not image or old.preview_path)))then
  if pool=='offline' then old.pool='offline'end
  self.state.downloads[entry.id]=nil;self:save()
  if callback then callback(old.path)end;return true
 end
 if callback then self.waiters[entry.id]=self.waiters[entry.id] or {};self.waiters[entry.id][#self.waiters[entry.id]+1]=callback end
 local wanted=self.state.downloads[entry.id]
 local changed=not wanted
 if wanted then
  if pool=='offline'and wanted.pool~='offline'then wanted.pool='offline';changed=true end
  if not automatic and wanted.automatic~=false then wanted.automatic=false;changed=true end
  if light_prefetch and not wanted.light_prefetch then wanted.light_prefetch=true;changed=true end
  if wanted.entry~=entry then wanted.entry=entry;changed=true end
 else self.state.downloads[entry.id]={entry=entry,pool=pool,automatic=automatic==true,light_prefetch=light_prefetch or nil}end
 if changed then self:save()end
 if not wanted then self:emit('queued',entry)end
 if not self:online()then return false end
 local request=self.state.downloads[entry.id]
 entry.parent_name=(self.state.folders[entry.parent_id]or{}).name or entry.parent_name
 self.transfer_seq=(self.transfer_seq or 0)+1
 local suffix='.incoming-'..tostring(self.jobs.nonce or 'test')..'x'..self.transfer_seq
 local path,incoming
 local function before()
  local size=tonumber(entry.size)
  local max=pool=='meta' and 8*MiB or size
  if not size or size<0 or (pool=='meta' and size>max)then return nil,errorValue('limit','File size is unknown or metadata is too large')end
  path=path or(old and old.path)or self.storage:filePath(entry,pool)
  incoming=path..suffix
  self.storage:remove(incoming);self.storage:remove(incoming..'.part');self.storage:remove(incoming..'.png')
  local victims,err=self:cache():plan(request.pool,size,self:protected(),entry.id)
  if not victims then return nil,errorValue('space',err)end
  if #victims>0 then self:evict(victims)end
  self.transfer=self.transfer or {}
  self.transfer[entry.id]={received=0,total=size,started=os.time(),stage='download'}
  self.downloading_id=entry.id;self:emit('download',entry)
  return true
 end
 return self:network('download:'..entry.id,function(p,report)
  local downloaded,err=p:download(entry,incoming,pool=='meta' and 8*MiB or nil,report)
  if not downloaded then return nil,err end
  local current,se=p:stat(entry.id)
  if not current then return nil,se end
  if current.parent_id~=entry.parent_id or current.name~=entry.name or not SDR.sameBook(entry,current)then
   return nil,errorValue('changed','Source changed during download; retry from a refreshed folder')
  end
  local kind=pool=='meta'and metadataKind(entry)
  if kind then
   local data=self.storage:readJSON(incoming,8*MiB);if data then downloaded.parsed=Metadata.normalize(data,kind)end
  end
  if image then
   local data=self.storage:read(incoming,8*MiB)
   local preview,err=require('gdriveshelf/thumbnails').render(data or '',incoming..'.png')
   if not preview then return nil,err end
   downloaded.preview_path=preview.path;downloaded.preview_size=self.storage:size(preview.path)
  end
  downloaded.entry=current;return downloaded
 end,function(result,err)
  if self.downloading_id==entry.id then self.downloading_id=nil end
  if self.transfer then self.transfer[entry.id]=nil end
  if result then
   local renamed,why=os.rename(incoming,path)
   if not renamed then result=nil;err=errorValue('disk',why)end
  end
  if result then
   local e={};for k,v in pairs(result.entry or entry)do e[k]=v end
   if result.preview_path then
    local preview=path:match('^(.*)/')..'/cover-preview.png'
    if os.rename(result.preview_path,preview)then e.preview_path=preview;e.preview_size=result.preview_size end
   end
   e.parsed=result.parsed;e.pool=request.pool;e.path=path;e.ready=true;e.size=(result.size or tonumber(entry.size))+(e.preview_size or 0);e.last_access=os.time()
   self.state.entries[entry.id]=e;self.state.downloads[entry.id]=nil
   if pool~='meta'then entry.local_path=path;self.state.docs[entry.id]=entry end
  else
   if incoming then self.storage:remove(incoming);self.storage:remove(incoming..'.part');self.storage:remove(incoming..'.png')end
   if not (err and err.silent)then request.error=err and err.message end
  end
  if not (err and err.silent)then self:save()end
  local callbacks=self.waiters[entry.id] or {};self.waiters[entry.id]=nil
  for _,fn in ipairs(callbacks)do fn(result and path,err)end
  if not (err and err.silent)then self:emit(result and 'downloaded' or 'error',entry,err)end
  if result and result.parsed and entry.parent_id then
   local explicit=not automaticDownload(request)
   if not self.settings.light_mode or (explicit and self.catalog_folder==entry.parent_id and self.catalog_visible~=false)then
    self:coverMetadata(self:cachedList(entry.parent_id),explicit)
   end
  end
 end,pool~='meta' and callback~=nil,before,function(value)
  self.transfer=self.transfer or {}
  local last=self.transfer[entry.id]
  if last and value.received<last.received then last=nil end
  local now=os.time()
  value.started=last and last.started or now
  value.sampled=now
  value.samples=(last and value.received>last.received and (last.samples or 0)+1) or (last and last.samples) or 0
  self.transfer[entry.id]=value;self:emit('transfer',entry)
 end)
end
function Core:open(entry,callback)
 self:stopRelocation()
 local cached=self:cached(entry.id)
 if cached then self.opening_id=entry.id;self:save();callback(cached.path);return end
 if not self:online()then
  local state=self:networkState()
  local messages={offline='This file is not downloaded. Enable online mode or reconnect.',sleep='Requests will resume when the device wakes.',auth='Import authorization credentials again.'}
  callback(nil,errorValue(state,messages[state]or 'Network requests cannot start.'));return
 end
 self.opening_id=entry.id
 local held=self.jobs.hold
 self.jobs.hold=true
 if self.index_job and not self.index_job.explicit then self:cancelIndex(false)end
 if self.deep_job and self.deep_job.automatic then self:cancelDeepScan()end
 local active=self.jobs.active
 local old_id=active and active.key:match('^download:(.+)$')
 local prefetch=old_id and self.state.downloads[old_id]
 if old_id~=entry.id and prefetch and prefetch.pool=='auto' and automaticDownload(prefetch)and not next(self.waiters[old_id]or{})then
  self.jobs:cancel(active.key,{code='cancelled',message='Paused for a foreground download',silent=true})
 end
 self:download(entry,'auto',function(path,err)if not path then self.opening_id=nil end;callback(path,err)end)
 self.jobs.hold=held
 if self.jobs.pump then self.jobs:pump()end
end
function Core:prefetch(entry,fraction)
 if not self:online()then return end
 local light=self.settings.light_mode
 local allowBooks=not light and self.settings.prefetch_books
 if not allowBooks and Catalog.kind(entry,self.state)=='books'then return end
 local limit
 if light then
  limit=self.settings.light_prefetch or 0
  if not fraction or fraction*100<(self.settings.light_threshold or 95)then return end
 else limit=self.settings.prefetch or 1 end
 limit=math.max(0,math.min(3,limit))
 if limit==0 then return end
 local list=self:cachedList(entry.parent_id)
 for _,next_entry in ipairs(Library.next(list,entry.id,limit,self.settings.sort,self.settings.reverse,self.natural))do
  if (allowBooks or Catalog.kind(next_entry,self.state)=='comics')and not self:cached(next_entry.id)then
   if not self.state.downloads[next_entry.id] or not self.jobs.keys or not self.jobs.keys['download:'..next_entry.id]then
    self:download(next_entry,'auto',nil,true,light)
   end
  end
 end
end
function Core:next(entry)
 return Library.next(self:cachedList(entry.parent_id),entry.id,1,self.settings.sort,self.settings.reverse,self.natural)[1]
end
function Core:cancelDownload(id)
 self.state.downloads[id]=nil;self.jobs:cancel('download:'..id);self.state.downloads[id]=nil;self:save()
end
function Core:clearPool(pool)
 self:stopRelocation()
 local victims={};local keep=self:protected()
 for id,e in pairs(self.state.entries)do if e.pool==pool and not keep[id]then victims[#victims+1]=id end end
 self:evict(victims);self:emit('cleared');return #victims
end
function Core:removeFile(id)
 self:stopRelocation()
 if self:protected()[id]then return nil,'This document is active'end
 self:cancelDownload(id);self:evict({id});return true
end
function Core:thumbnail(entry)
 local thumb=self:cached('thumb:'..entry.id)
 return thumb and thumb.source_stamp==Metadata.fingerprint(entry)and thumb or nil
end
function Core:titleInfo(parent)
 local entries=self:cachedList(parent);local info={title=(self.state.folders[parent]or{}).name or parent,chapters={}}
 info.progress=Library.folderProgress(entries,self.state.summaries,self.state.sync.pending)
 for k,v in pairs(self:importedMetadata(entries))do info[k]=v end
 if self.settings.load_covers~=false then
  for _,entry in ipairs(Metadata.coverCandidates(entries,info.cover))do
   local cached=self:cached(entry.id)
   if cached then info.cover_path=cached.preview_path or cached.path;info.cover_source='imported';break end
  end
 end
 if not info.cover_path and self.settings.load_covers~=false and self.settings.beta_thumbnails then
  for _,entry in ipairs(Library.ordered(entries,'natural'))do
   if entry.name:lower():match('%.cbz$')then
    local thumb=self:thumbnail(entry);if thumb then info.cover_path=thumb.path;info.cover_source='chapter' end;break
   end
  end
 end
 return info
end
function Core:lazyProgress(entries)
 if not self.settings.sync_enabled or not self:online()then return end
 for _,entry in ipairs(entries)do if Library.supported(entry)then
  -- Only visible documents with a known adjacent SDR trigger lazy requests.
  local side=SDR.sidecarName(entry.name);local found=false
  for _,other in ipairs(self:cachedList(entry.parent_id))do if other.is_folder and other.name==side then found=true;break end end
  if found then self:network('progress:'..entry.id,function(p)return self:sync(p):pull(entry)end,function(result,err)
   if result and result.lua then
    local data=SDR.decode(result.lua)
    if data then
     local summary=SDR.summary(data);summary.modified_time=result.stamp and result.stamp.modified_time
     if not self.state.sync.pending[entry.id]then
      self.state.summaries[entry.id]=summary
      self.remote_ready=self.remote_ready or {};self.remote_ready[entry.id]=result.lua
     end
     self:storeRemote(entry,result)
     self:save();self:emit('progress',entry)
    end
   elseif result then
    self:evict({'sdr:'..entry.id});if self.remote_ready then self.remote_ready[entry.id]=nil end
   elseif err then self:emit('sync_error',entry,err)end
  end)end
 end end
end
function Core:storeRemote(entry,result,deferSave)
 local payload={lua=result.lua,stamp=result.stamp,book_stamp=result.book_stamp}
 local text=self.storage.json.encode(payload);local key='sdr:'..entry.id
 local victims=self:cache():plan('meta',#text,self:protected(),key)
 if not victims then return end
 self:evict(victims,deferSave)
 local e={id=key,name='remote-sdr.json',pool='meta',size=#text,parent_id=entry.parent_id,last_access=os.time(),ready=true}
 e.path=self.storage:filePath(e,'meta')
 if self.storage:write(e.path,text)then self.state.entries[key]=e end
end
function Core:remote(entry)
 local c=self:cached('sdr:'..entry.id);return c and self.storage:readJSON(c.path)
end
function Core:resume(explicit)
 if self.retired then return end
 self:syncNetworkJobs()
 if self.relocating then return end
 for _,d in pairs(self.state.downloads)do
  self:download(d.entry,d.pool,nil,not explicit and automaticDownload(d),d.light_prefetch)
 end
 self:flushPending(explicit)
end
function Core:cancelIndex()
 local job=self.index_job;self.index_job=nil
 if job and job.active and self.jobs.cancel then self.jobs:cancel('index:'..job.active)end
 self:emit('indexed')
end
function Core:indexHome(force)
 local home=self.settings.home
 if (not self.settings.index_enabled and not force)or not home or home=='root'or not self:online()then return end
 if self.index_job then return end
 local queue={}
 for _,folder in ipairs(self:cachedList(home))do
  if folder.is_folder and not Metadata.isService(folder)and (force or Catalog.due(self.state.listings[folder.id],os.time(),self.settings))then queue[#queue+1]=folder end
 end
 local job={queue=queue,total=#queue,done=0};self.index_job=job
 local function advance()
  if self.index_job~=job then return end
  if not self:online()or(not self.settings.index_enabled and not force)then self:cancelIndex();return end
  local folder=table.remove(queue,1)
  if not folder then self.index_job=nil;self:emit('indexed');return end
  job.active=folder.id;self:emit('indexing',folder)
  self:network('index:'..folder.id,function(p)return p:list(folder.id)end,function(entries,err)
   if self.index_job~=job then return end
   if entries then self:rememberList(folder.id,entries);self:metadata(entries)end
   job.done=job.done+1;job.error=err;advance()
  end,false)
 end
 advance()
end
function Core:folderStats(parent,downloads)return Catalog.stats(self,parent,downloads)end
function Core:recordOpen(entry)
 Catalog.recordOpen(self.state,entry,os.time());return self:save()
end
function Core:history()return Catalog.history(self.state)end
function Core:cancelFolderScan()
 local job=self.folder_scan;self.folder_scan=nil;if job and job.key then self.jobs:cancel(job.key)end
 self:emit('scan_cancelled')
end
function Core:scanFolder(folder,callback)
 self:cancelFolderScan();local job={done=0,files=0};self.folder_scan=job
 local files,visited,total={}, {},0
 local function visit(entry,done)
  if self.folder_scan~=job then return end
  job.key='scan:'..entry.id;self:emit('folder_scanning',entry)
  if visited[entry.id]then done();return end;visited[entry.id]=true
  self:network('scan:'..entry.id,function(p)return p:list(entry.id)end,function(entries,err)
   if self.folder_scan~=job then return end
   if not entries then self.folder_scan=nil;callback(nil,err);return end
   job.done=job.done+1
   self:rememberList(entry.id,entries)
   local dirs={}
   for _,e in ipairs(entries)do
    if e.is_folder and not Metadata.isService(e)then dirs[#dirs+1]=e
    elseif Library.supported(e)then files[#files+1]=e;total=total+(tonumber(e.size)or 0)end
   end
   local i=0;local function advance()i=i+1;if dirs[i]then visit(dirs[i],advance)else done()end end;advance()
  end)
 end
 if not self:online()then callback(nil,errorValue('offline','Folder discovery requires online mode'));return end
 visit(folder,function()self.folder_scan=nil;callback({files=files,size=total})end)
end
function Core:offlineFolders()
 local groups=Library.offlineGroups(self.state.entries);local out={}
 for parent in pairs(groups)do local folder=self.state.folders[parent]or{id=parent,name=parent,is_folder=true};out[#out+1]=folder end
 return Library.ordered(out,self.settings.sort,self.settings.reverse,self.natural)
end
require('gdriveshelf/scanning')(Core)
require('gdriveshelf/relocation').install(Core)
require('gdriveshelf/indexer')(Core)
require('gdriveshelf/progress')(Core)
require('gdriveshelf/syncqueue')(Core)
require('gdriveshelf/localcovers').attach(Core)
require('gdriveshelf/overrides').attach(Core)
return Core
