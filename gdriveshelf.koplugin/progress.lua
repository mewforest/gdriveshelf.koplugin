-- Read-only visible summaries. Sync.pull/push remain the fresh, guarded write path.
return function(Core)
 if Core._visible_progress_installed then return end;Core._visible_progress_installed=true
 local SDR=require('gdriveshelf/sdr');local Library=require('gdriveshelf/library')
 local function copy(e)local t={};for k,v in pairs(e or{})do if type(v)~='table'then t[k]=v end end;return t end
 local function stamp(e)
  return{id=e.id,version=e.version,checksum=e.checksum,modified_time=e.modified_time,size=e.size}
 end
 local function fingerprint(e)
  if not e or not(e.version or e.checksum or(e.modified_time and e.size))then return nil end
  return table.concat({tostring(e.id),tostring(e.version or''),tostring(e.checksum or''),tostring(e.modified_time or''),tostring(e.size or'')},':')
 end
 local function sameBook(a,b)return a.name==b.name and a.parent_id==b.parent_id and SDR.sameBook(a,b)end
 local remember=Core.rememberList
 function Core:rememberList(parent,entries)
  local result=remember(self,parent,entries)
  self.progress_fresh=self.progress_fresh or{};self.progress_fresh[parent]={at=os.time(),entries=entries}
  return result
 end
 function Core:cancelProgress()
  local job=self.progress_job;self.progress_job=nil
  if job and self.jobs.cancel then self.jobs:cancel(job.key)end
  self:emit('progress_state')
 end
 function Core:lazyProgress(entries)
  if not self.settings.sync_enabled or not self:online()then return false end
  local selected,ids={},{}
  for _,entry in ipairs(entries or{})do if Library.supported(entry)and not ids[entry.id]then ids[entry.id]=true;selected[#selected+1]=copy(entry)end end
  if #selected==0 then if self.progress_job then self:cancelProgress()end;return false end
  local key={};for _,entry in ipairs(selected)do key[#key+1]=entry.id..':'..tostring(fingerprint(entry))end;key=table.concat(key,'|')
  if self.progress_job then if self.progress_job.selection==key then return false end;self:cancelProgress()end
  self.state.progress_cache=self.state.progress_cache or{}
  local previous,fresh,scopes={},{},{};local now=os.time()
  for parent,record in pairs(self.progress_fresh or{})do if now-record.at<30 then fresh[parent]=record.entries end end
  for _,entry in ipairs(selected)do
   local catalog=self.state.catalog
   scopes[entry.parent_id]=entry.drive_id or(self.state.folders[entry.parent_id]or{}).drive_id or(catalog and catalog.members[entry.id]and catalog.scope and catalog.scope.drive_id)
   local record=self.state.progress_cache[entry.id]
   if record then
    local cached=self:remote(entry)
    previous[entry.id]={record=copy(record),remote=cached}
    if record.dirty then fresh[entry.parent_id]=nil;if record.sidecar_id then fresh[record.sidecar_id]=nil end end
   end
  end
  local job={key='visible-progress',selection=key,done=0,total=#selected,parent_id=selected[1].parent_id};self.progress_job=job
  self:emit('progress_state')
  local queued=self:network(job.key,function(p)
   local parents,sidecar_ids,records,listed={},{},{},{}
   local function add(list,id)for _,old in ipairs(list)do if old==id then return end end;list[#list+1]=id end
   local function list(ids_to_get)
    local by_scope={};for _,id in ipairs(ids_to_get)do if not fresh[id]then
     local scope=scopes[id]or'';by_scope[scope]=by_scope[scope]or{};by_scope[scope][#by_scope[scope]+1]=id
    end end
    for drive,missing in pairs(by_scope)do for i=1,#missing,20 do
     local group={};for j=i,math.min(#missing,i+19)do group[#group+1]=missing[j]end
     local scope=drive~=''and{drive_id=drive}or nil
     local buckets,e
     if p.listParents then buckets,e=p:listParents(group,scope)
     else
      buckets={};for _,id in ipairs(group)do local rows;rows,e=p:list(id);if not rows then return nil,e end;buckets[id]=rows end
     end
     if not buckets then return nil,e end
     for _,id in ipairs(group)do
      if type(buckets[id])~='table'then return nil,{code='invalid_response',message='Incomplete progress discovery'}end
      fresh[id]=buckets[id];listed[id]=buckets[id]
     end
    end end
    return true
   end
   for _,entry in ipairs(selected)do add(parents,entry.parent_id)end
   local good,e=list(parents);if not good then return nil,e end
   for _,entry in ipairs(selected)do
    local item={entry=entry};records[#records+1]=item
    local stem=SDR.sidecarName(entry.name);local matches,stems,book={},0,nil
    for _,child in ipairs(fresh[entry.parent_id])do
     if child.parent_id==entry.parent_id then
      if child.id==entry.id then book=child end
      if child.name==stem then matches[#matches+1]=child end
      if not child.is_folder and SDR.sidecarName(child.name)==stem then stems=stems+1 end
     end
    end
    if not book or not sameBook(book,entry)then item.error='book_changed'
    elseif stems>1 then item.error='ambiguous_stem'
    elseif #matches>1 or(#matches==1 and not matches[1].is_folder)then item.error='ambiguous_sidecar'
    elseif matches[1]then item.sidecar=matches[1];scopes[matches[1].id]=matches[1].drive_id or scopes[entry.parent_id];add(sidecar_ids,matches[1].id)
    else item.missing=true end
   end
   good,e=list(sidecar_ids);if not good then return nil,e end
   local bytes=0
   for _,item in ipairs(records)do if item.sidecar and not item.error then
    local expected=SDR.metadataName(item.entry.name);local matches={}
    for _,child in ipairs(fresh[item.sidecar.id])do if child.parent_id==item.sidecar.id and child.name==expected then matches[#matches+1]=child end end
    if #matches>1 or(#matches==1 and matches[1].is_folder)then item.error='ambiguous_metadata'
    elseif not matches[1]then item.missing=true
    else
     local metadata=matches[1];item.metadata=metadata;item.signature=fingerprint(metadata)
     local old=previous[item.entry.id];local payload=old and old.remote
     local reusable=old and old.record.metadata_id==metadata.id and item.signature and old.record.signature==item.signature and old.record.book_signature==fingerprint(item.entry)
     if reusable and old.record.failed then item.error='invalid_remote_metadata';item.failed=true
     elseif reusable and payload and payload.lua and fingerprint(payload.stamp)==item.signature and SDR.sameBook(payload.book_stamp,item.entry)then
      local data=SDR.decode(payload.lua)
      if data then item.unchanged=true;item.summary=SDR.summary(data)end
     end
     if not item.unchanged and not item.error then
      if metadata.size and metadata.size>2*1048576 then item.error='invalid_remote_metadata';item.failed=true
      else
       local lua,re=p:read(metadata,2*1048576)
       if not lua then
        -- Transport failures are retried by Core; malformed/oversized data is per book.
        if re and(re.code=='network'or re.code=='api'or re.code=='unauthorized'or re.code=='auth')then return nil,re end
        item.error='invalid_remote_metadata';item.failed=true
       else
        local data=SDR.decode(lua)
        if not data then item.error='invalid_remote_metadata';item.failed=true
        elseif bytes+#lua>8*1048576 then item.error='limit'
        else bytes=bytes+#lua;item.lua=lua;item.summary=SDR.summary(data);item.stamp=stamp(metadata);item.book_stamp=stamp(item.entry)end
       end
      end
     end
    end
   end end
   return{records=records,listings=listed}
  end,function(result,e)
   if self.progress_job~=job then return end
   if result then
    local eligible,blocked={},{ }
    for _,item in ipairs(result.records)do
     local current=self.state.docs[item.entry.id]or item.entry
     eligible[item.entry.id]=sameBook(current,item.entry)
     if not eligible[item.entry.id]then blocked[item.entry.parent_id]=true end
    end
    -- Parent discovery is useful even with recursive indexing disabled.
    for parent,rows in pairs(result.listings)do if not blocked[parent]then self:rememberList(parent,rows)end end
    for _,item in ipairs(result.records)do
     local entry=item.entry;local current=self.state.docs[entry.id]or entry
     if eligible[entry.id]and sameBook(current,entry)then
      local record={sidecar_id=item.sidecar and item.sidecar.id,metadata_id=item.metadata and item.metadata.id,signature=item.signature,book_signature=fingerprint(entry),failed=item.failed,checked_at=os.time()}
      self.state.progress_cache[entry.id]=record
      if item.lua then
       self:storeRemote(entry,item)
       if not self.state.sync.pending[entry.id]then
        self.state.summaries[entry.id]=item.summary;self.remote_ready=self.remote_ready or{};self.remote_ready[entry.id]=item.lua
       end
       self:emit('progress',entry)
      elseif item.unchanged then
       if not self.state.sync.pending[entry.id]then
        self.state.summaries[entry.id]=item.summary
        local remote=self:remote(entry)
        if remote and remote.lua then self.remote_ready=self.remote_ready or{};self.remote_ready[entry.id]=remote.lua end
       end
      elseif item.missing or item.failed then
       self:evict({'sdr:'..entry.id});if self.remote_ready then self.remote_ready[entry.id]=nil end
      end
      if item.error then self:emit('sync_error',entry,{code=item.error,message='Visible reading summary is unavailable'})end
     end
     job.done=job.done+1
    end
    self:save()
   end
   self.progress_job=nil;self:emit('progress_state',nil,e)
  end,false)
  if queued==false and self.progress_job==job then self.progress_job=nil;self:emit('progress_state')end
  return queued
 end
end
