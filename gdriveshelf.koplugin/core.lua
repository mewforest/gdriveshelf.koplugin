local Catalog=require('gdriveshelf/catalog')
local Cache=require('gdriveshelf/cache')
local Library=require('gdriveshelf/library')
local Metadata=require('gdriveshelf/metadata')
local SDR=require('gdriveshelf/sdr')
local Sync=require('gdriveshelf/sync')
local Core={};Core.__index=Core
local MiB=1048576
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
function Core:resetNetwork(clear_auth)
 self.retry_after=nil;self.retry_failures=0
 if clear_auth then self.auth_error=nil end
 if self.retry_tick and self.jobs.unschedule then self.jobs.unschedule(self.retry_tick)end
 self:syncNetworkJobs();self:resume()
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
function Core:provider()
 local provider=self.provider_factory(self.credentials)
 if self.logger then provider.trace=function(name,fields)pcall(self.logger.event,self.logger,name,fields)end end
 return provider
end
function Core:sync(provider)
 return Sync.new{provider=provider or {},sdr=SDR,storage=self.storage,state=self.state.sync,offline=self.settings.offline}
end
function Core:network(key,work,done,front,before,progress,local_task,options)
 if not local_task and not self:online()then return false end
 self.jobs.logger=self.logger;self:syncNetworkJobs()
 local attempts=0
 local job_options={timeout=options and options.timeout}
 job_options.retry=function(envelope,err)
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
function Core:evict(ids)
 for _,id in ipairs(ids)do local e=self.state.entries[id];if e then
  local ok=self.storage:remove(e.path)
  if e.preview_path then self.storage:remove(e.preview_path)end
  if ok or not self.storage:exists(e.path)then self.state.entries[id]=nil end
 end end
 return self:save()
end
function Core:cached(id)
 local e=self.state.entries[id]
 if e and e.ready and self.storage:exists(e.path)then e.last_access=os.time();return e end
 return nil
end
function Core:cachedList(parent)
 local cached=self:cached('list:'..parent)
 if cached then local d=self.storage:readJSON(cached.path);if d then local list={};for _,e in ipairs(d)do list[#list+1]=remoteEntry(e)end;return list end end
 local listing=(self.state.listings or {})[parent]
 if listing and listing.complete then
  local entries={};for _,id in ipairs(listing.ids or {})do local e=self.state.docs[id]or self.state.folders[id];if e then entries[#entries+1]=e end end
  return entries
 end
 local entries={}
 for _,e in pairs(self.state.docs)do if e.parent_id==parent then entries[#entries+1]=e end end
 for _,e in pairs(self.state.folders)do if e.parent_id==parent then entries[#entries+1]=e end end
 return Library.ordered(entries,self.settings.sort,self.settings.reverse,self.natural)
end
function Core:rememberList(parent,entries)
 local stale={}
 local clean={};for _,e in ipairs(entries)do clean[#clean+1]=remoteEntry(e)end;entries=clean
 local ids={};for _,e in ipairs(entries)do ids[#ids+1]=e.id end
 self.state.listings[parent]={complete=true,checked_at=os.time(),ids=ids}
 for _,e in ipairs(entries)do e.parent_id=e.parent_id or parent
  if e.is_folder then
   local old=self.state.folders[e.id];e.first_seen=old and old.first_seen or os.time()
   e.created_time=e.created_time or (old and old.created_time) or os.date('!%Y-%m-%dT%H:%M:%SZ',e.first_seen)
   self.state.folders[e.id]=e
  else
   local localPath=(self.state.docs[e.id]or {}).local_path
   local durable=remoteEntry(e);durable.local_path=localPath
   self.state.docs[e.id]=durable
   local thumb=self.state.entries['thumb:'..e.id]
   if thumb and thumb.source_stamp~=Metadata.fingerprint(e)then stale[#stale+1]='thumb:'..e.id end
  end
 end
 if #stale>0 then self:evict(stale)end
 local text=self.storage.json.encode(entries);local id='list:'..parent
 local victims=self:cache():plan('meta',#text,self:protected(),id)
 if victims then
  self:evict(victims)
  local e={id=id,name='listing.json',parent_id=parent,pool='meta',size=#text,last_access=os.time(),ready=true}
  e.path=self.storage:filePath(e,'meta');local ok=self.storage:write(e.path,text)
  if ok then self.state.entries[id]=e end
 end
 self:save()
end
function Core:folder(parent,name,callback,force)
 self.state.folders[parent]=self.state.folders[parent] or {id=parent,name=name or parent,is_folder=true}
 local cached=self:cachedList(parent);if self.state.listings[parent]or #cached>0 or not self:online()then callback(cached,true)end
 if not self:online()then return end
 self.folder_waiters=self.folder_waiters or {};self.folder_waiters[parent]=self.folder_waiters[parent]or{}
 self.folder_waiters[parent][#self.folder_waiters[parent]+1]=callback
 self:network('list:'..parent,function(p)return p:list(parent)end,function(entries,err)
  local listeners=self.folder_waiters[parent]or{};self.folder_waiters[parent]=nil
  if entries then self:rememberList(parent,entries)end
  for _,fn in ipairs(listeners)do fn(entries,false,err)end
  if entries then self:metadata(entries);self:flushPending();if parent==self.settings.home then self:indexHome(force);if self.settings.beta_auto_scan then self:deepScan({id=parent},true)end end end
 end,true)
end
function Core:metadata(entries)
 for _,e in ipairs(entries)do
  local n=e.name:lower()
  if not e.is_folder and ((n=='cover.jpg'and self.settings.load_covers~=false)or ((n=='index.json'or n=='series.json')and self.settings.load_metadata~=false))then
   local old=self:cached(e.id)
   if not old or old.modified_time~=e.modified_time or old.version~=e.version or(n=='cover.jpg'and not old.preview_path)then self:download(e,'meta')end
  end
 end
end
function Core:download(entry,pool,callback)
 self:stopRelocation()
 local old=self:cached(entry.id)
 if old and(pool~='meta'or(old.modified_time==entry.modified_time and old.version==entry.version and(entry.name:lower()~='cover.jpg'or old.preview_path)))then
  if pool=='offline' then old.pool='offline'end;self.state.downloads[entry.id]=nil;self:save()
  if callback then callback(old.path)end;return true
 end
 if callback then self.waiters[entry.id]=self.waiters[entry.id] or {};self.waiters[entry.id][#self.waiters[entry.id]+1]=callback end
 local wanted=self.state.downloads[entry.id]
 if wanted then if pool=='offline' then wanted.pool='offline'end else self.state.downloads[entry.id]={entry=entry,pool=pool}end
 self:save()
 if not wanted then self:emit('queued',entry)end
 if not self:online()then return false end
 local request=self.state.downloads[entry.id]
 entry.parent_name=(self.state.folders[entry.parent_id]or{}).name or entry.parent_name
 local path=(old and old.path) or self.storage:filePath(entry,pool)
 local incoming=path..'.incoming-'..tostring(self.jobs.nonce or 'test')
 local function before()
  self.storage:remove(incoming);self.storage:remove(incoming..'.part');self.storage:remove(incoming..'.png')
  local size=tonumber(entry.size)
  local max=pool=='meta' and 8*MiB or size
  if not size or size<0 or (pool=='meta' and size>max)then return nil,errorValue('limit','File size is unknown or metadata is too large')end
  local victims,err=self:cache():plan(request.pool,size,self:protected(),entry.id)
  if not victims then return nil,errorValue('space',err)end
  self:evict(victims);self.downloading_id=entry.id;self:emit('download',entry)
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
  if pool=='meta'and (entry.name=='index.json'or entry.name=='series.json')then
   local data=self.storage:readJSON(incoming,8*MiB);if data then downloaded.parsed=Metadata.normalize(data,entry.name=='index.json'and 'index'or 'series')end
  end
  if pool=='meta'and entry.name:lower()=='cover.jpg'then
   local data=self.storage:read(incoming,8*MiB)
   local preview,err=require('gdriveshelf/thumbnails').render(data or '',incoming..'.png')
   if not preview then return nil,err end
   downloaded.preview_path=preview.path;downloaded.preview_size=self.storage:size(preview.path)
  end
  downloaded.entry=current;return downloaded
 end,function(result,err)
  self.downloading_id=nil
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
  else self.storage:remove(incoming);self.storage:remove(incoming..'.part');self.storage:remove(incoming..'.png');request.error=err and err.message end
  self:save()
  local callbacks=self.waiters[entry.id] or {};self.waiters[entry.id]=nil
  for _,fn in ipairs(callbacks)do fn(result and path,err)end
  self:emit(result and 'downloaded' or 'error',entry,err)
 end,pool~='meta' and callback~=nil,before,function(value)
  self.transfer=self.transfer or {};self.transfer[entry.id]=value;self:emit('transfer',entry)
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
 if self.index_job then self:cancelIndex()end
 if self.deep_job then self:cancelDeepScan()end
 local active=self.jobs.active
 local old_id=active and active.key:match('^download:(.+)$')
 local prefetch=old_id and self.state.downloads[old_id]
 local suspended
 if old_id~=entry.id and prefetch and prefetch.pool=='auto' and not next(self.waiters[old_id]or{})then
  suspended=self.jobs.offline;self.jobs.offline=true;self.jobs:cancel(active.key)
 end
 self:download(entry,'auto',function(path,err)if not path then self.opening_id=nil end;callback(path,err)end)
 if suspended~=nil then self.jobs.offline=suspended;self.jobs:pump()end
end
function Core:prefetch(entry)
 if not self:online()or (Catalog.kind(entry,self.state)=='books'and not self.settings.prefetch_books)then return end
 local list=self:cachedList(entry.parent_id)
 for _,next_entry in ipairs(Library.next(list,entry.id,self.settings.prefetch or 1,self.settings.sort,self.settings.reverse,self.natural))do
  if (self.settings.prefetch_books or Catalog.kind(next_entry,self.state)=='comics')and not self:cached(next_entry.id)then self:download(next_entry,'auto')end
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
 for _,e in ipairs(entries)do
  if self.settings.load_metadata~=false and (e.name=='index.json' or e.name=='series.json')then
   local c=self:cached(e.id);local data=c and not c.parsed and self.storage:readJSON(c.path)
   if c and(c.parsed or data)then local parsed=c.parsed or Metadata.normalize(data,e.name=='index.json' and 'index' or 'series');for k,v in pairs(parsed)do if v~=nil and v~=''then info[k]=v end end end
  elseif self.settings.load_covers~=false and e.name:lower()=='cover.jpg'then local c=self:cached(e.id);if c then info.cover_path=c.preview_path or c.path end end
 end
 if not info.cover_path and self.settings.load_covers~=false and self.settings.beta_thumbnails then
  for _,entry in ipairs(Library.ordered(entries,'natural'))do
   if entry.name:lower():match('%.cbz$')then
    local thumb=self:thumbnail(entry);if thumb then info.cover_path=thumb.path end;break
   end
  end
 end
 return info
end
function Core:snapshot(entry,data)
 local p,e=self:sync():snapshot(entry,data)
 if not p then return nil,e end
 self.state.summaries[entry.id]=SDR.summary(data)
 local ok,err=self:save();if not ok then return nil,errorValue('disk',err)end
 if self.settings.sync_enabled then self:flushPending()end
 return p
end
function Core:flushPending()
 if not self.settings.sync_enabled or not self:online()then return end
 for _,pending in ipairs(self:sync():pendingList())do
  local entry=pending.entry
  if not self.state.sync.conflicts[entry.id]then
   self:network('sync:'..entry.id,function(provider)return self:sync(provider):push(entry,pending)end,function(result,err)
    if result then
     if result.action=='pull'then
      -- A remote base is acknowledged only after native restoration succeeds.
      result={action='conflict',conflict={reason='remote_updated',local_lua=pending.lua,remote_lua=result.lua,base_lua=pending.base_lua,stamp=result.stamp,book_stamp=result.book_stamp}}
     end
     self:sync():commit(entry,pending,result)
     if result.action=='conflict'then self:emit('conflict',entry)end
     self:save()
     if result.action~='conflict' and self.state.sync.pending[entry.id]then self:flushPending()end
    else self:emit('sync_error',entry,err)end
   end)
  end
 end
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
function Core:storeRemote(entry,result)
 local payload={lua=result.lua,stamp=result.stamp,book_stamp=result.book_stamp}
 local text=self.storage.json.encode(payload);local key='sdr:'..entry.id
 local victims=self:cache():plan('meta',#text,self:protected(),key)
 if not victims then return end
 self:evict(victims)
 local e={id=key,name='remote-sdr.json',pool='meta',size=#text,parent_id=entry.parent_id,last_access=os.time(),ready=true}
 e.path=self.storage:filePath(e,'meta')
 if self.storage:write(e.path,text)then self.state.entries[key]=e end
end
function Core:remote(entry)
 local c=self:cached('sdr:'..entry.id);return c and self.storage:readJSON(c.path)
end
function Core:resume()
 self:syncNetworkJobs()
 if self.relocating then return end
 for _,d in pairs(self.state.downloads)do self:download(d.entry,d.pool)end
 self:flushPending()
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
function Core:folderStats(parent)return Catalog.stats(self,parent)end
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
require('gdriveshelf/localcovers').attach(Core)
require('gdriveshelf/overrides').attach(Core)
return Core
