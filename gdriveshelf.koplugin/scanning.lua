-- Low-priority cover discovery. Cancelling invalidates the traversal before jobs.
return function(Core)
 local Metadata=require('gdriveshelf/metadata');local Catalog=require('gdriveshelf/catalog');local SDR=require('gdriveshelf/sdr')
 local fingerprint=Metadata.fingerprint
 function Core:cancelDeepScan()
  local job=self.deep_job;self.deep_job=nil
  if job and job.key then self.jobs:cancel(job.key)end
  self:emit('scanned')
 end
 function Core:deepScan(folder,automatic)
  if not self.settings.beta_thumbnails or not self:online()or (automatic and(self.settings.light_mode or not self.settings.beta_auto_scan or folder.id=='root'))then return false end
  if self.deep_job then return false end
  self.state.preview_attempts=self.state.preview_attempts or {};self.state.deep_checked=self.state.deep_checked or {}
  if automatic and not Catalog.due(self.state.deep_checked[folder.id],os.time(),self.settings)then return false end
  local job={root=folder.id,automatic=automatic,dirs={folder},files={},seen={},done=0,skipped=0,total=0};self.deep_job=job
  local function advance()
   if self.deep_job~=job then return end
   if not self:online()or not self.settings.beta_thumbnails then self:cancelDeepScan();return end
   local entry=table.remove(job.files,1)
   if entry then
    local stamp=fingerprint(entry);local attempted=self.state.preview_attempts[entry.id]
    local cachedThumb=self:thumbnail(entry)
    if attempted and attempted.fingerprint==stamp and(cachedThumb or(attempted.skipped and automatic))then job.done=job.done+1;return advance()end
    local output={id='thumb:'..entry.id,name='preview.png',parent_id=entry.parent_id,pool='meta'}
    local path=self.storage:filePath(output,'meta');local incoming=path..'.incoming-'..tostring(self.jobs.nonce or 'scan')
    local cached=self:cached(entry.id);if cached and not SDR.sameBook(entry,cached)then cached=nil end;job.key='thumb:'..entry.id;self:emit('scanning',entry)
    self:network(job.key,function(provider)
     local result,err=require('gdriveshelf/thumbnails').build(entry,cached,provider,incoming)
     if not result then return nil,err end
     local current,why=provider:stat(entry.id)
     if not current or not SDR.sameBook(entry,current)then os.remove(incoming);return nil,why or {code='preview',message='Archive changed while extracting cover'}end
     result.size=self.storage:size(incoming);return result
    end,function(result,err)
     if self.deep_job~=job then self.storage:remove(incoming);return end
     if result then
      local victims=self:cache():plan('meta',result.size,self:protected(),output.id)
      if victims then
       self:evict(victims)
       if os.rename(incoming,path)then output.path=path;output.size=result.size;output.ready=true;output.last_access=os.time();output.source_stamp=stamp;output.range_bytes=result.range_bytes;self.state.entries[output.id]=output else result=nil end
      else result=nil end
     end
     self.storage:remove(incoming)
     -- Cancellation/network failures are retryable; unsupported formats wait for
     -- a changed source, preventing repeated expensive failures on every visit.
     if result or(err and(err.code=='preview'or err.code=='preview_limit'or err.code=='preview_format'or err.code=='range'))then self.state.preview_attempts[entry.id]={fingerprint=stamp,skipped=not result}end
     if not result then job.skipped=job.skipped+1 end
     job.done=job.done+1;self:save();self:emit('thumbnail',entry);advance()
    end,false,function()
     local victims,err=self:cache():plan('meta',1048576,self:protected(),output.id)
     if not victims then return nil,{code='space',message=err}end;self:evict(victims);return true
    end)
    return
   end
   local dir=table.remove(job.dirs,1)
   if not dir then
    self.state.deep_checked[folder.id]={complete=true,checked_at=os.time()};self.deep_job=nil;self:save();self:emit('scanned');return
   end
   if job.seen[dir.id]then return advance()end;job.seen[dir.id]=true;job.key='deep-list:'..dir.id;self:emit('scanning',dir)
   self:network(job.key,function(provider)return provider:list(dir.id)end,function(entries,err)
    if self.deep_job~=job then return end
    if entries then
     self:rememberList(dir.id,entries);self:metadata(entries,not automatic)
     for _,e in ipairs(entries)do
      if e.is_folder and not Metadata.isService(e)then job.dirs[#job.dirs+1]=e
      elseif not e.is_folder and e.name:lower():match('%.cbz$')then job.files[#job.files+1]=e;job.total=job.total+1 end
     end
     job.files=require('gdriveshelf/library').ordered(job.files,'natural')
    else job.skipped=job.skipped+1;job.error=err end
    advance()
   end,false)
  end
  advance();return true
 end
end
