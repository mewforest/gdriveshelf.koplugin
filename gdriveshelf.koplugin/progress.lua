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
 local function sameBook(a,b)
  return SDR.sameBook(a,b) and a.name==b.name and a.parent_id==b.parent_id
 end
 local function pendingMark(core,entry)
  local mark=(core.state.sync.chapter_marks or {})[entry.id]
  if mark and sameBook(mark.entry,entry) then return mark end
 end
 local FRESH_SECONDS=30
 local remember=Core.rememberList
 function Core:rememberList(parent,entries,...)
  local result,err=remember(self,parent,entries,...)
  if result or (result==nil and err==nil) then
   -- Only the immediately preceding folder listing is needed by its
   -- visible/Continue progress request. Avoid retaining the whole tree here.
   self.progress_fresh={[parent]={at=os.time(),entries=entries}}
  end
  return result,err
 end
 function Core:cancelProgress()
  local job=self.progress_job
  if not job then return end
  self.progress_job=nil
  if self.jobs.cancel then self.jobs:cancel(job.key)end
  self:emit('progress_state')
 end
 function Core:cancelAutomaticProgress()
  if self.progress_job and self.progress_job.mode=='visible' then self:cancelProgress() end
 end
 local function readBatch(self,job,selected,done)
  local previous,fresh,scopes={},{},{};local now=os.time()
  for _,entry in ipairs(selected)do
   local saved=(self.progress_fresh or {})[entry.parent_id]
   if saved and now-saved.at<FRESH_SECONDS then fresh[entry.parent_id]=saved.entries end
  end
  for _,entry in ipairs(selected)do
   local catalog=self.state.catalog
   scopes[entry.parent_id]=entry.drive_id or(self.state.folders[entry.parent_id]or{}).drive_id or(catalog and catalog.members[entry.id]and catalog.scope and catalog.scope.drive_id)
   local record=self.state.progress_cache[entry.id]
   if record then
    local cached=(job.mode=='resume' or not record.summary) and self:remote(entry) or nil
    previous[entry.id]={record=copy(record),remote=cached}
    if record.dirty then fresh[entry.parent_id]=nil;if record.sidecar_id then fresh[record.sidecar_id]=nil end end
   end
  end
  return self:network(job.key,function(p)
   local parents,sidecar_ids,records,listed={},{},{},{}
   local function add(list,id)for _,old in ipairs(list)do if old==id then return end end;list[#list+1]=id end
   local function list(ids_to_get,remember_parent)
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
      fresh[id]=buckets[id]
      if remember_parent then listed[id]=buckets[id] end
     end
    end end
    return true
   end
   for _,entry in ipairs(selected)do add(parents,entry.parent_id)end
   local good,e=list(parents,true);if not good then return nil,e end
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
    elseif reusable and job.mode~='resume' and old.record.summary then
     item.unchanged=true;item.summary=old.record.summary
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
        local status=re and tonumber(re.status)
        if re and(re.code=='network'or re.code=='unauthorized'or re.code=='auth'
           or (re.code=='api'and status and(status==408 or status==429 or(status>=500 and status<=599))))then return nil,re end
        if status==404 then item.missing=true
        elseif re and re.code=='api' then item.error='progress_unavailable'
        else item.error='invalid_remote_metadata';item.failed=true end
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
    local eligible,blocked={},{}
    for _,item in ipairs(result.records)do
     local current=self.state.docs[item.entry.id]or item.entry
     eligible[item.entry.id]=sameBook(current,item.entry)
     if not eligible[item.entry.id]then blocked[item.entry.parent_id]=true end
    end
    -- Retain only the direct document listing. SDR children are discovery
    -- results and do not belong in the durable catalog.
    local saved_parents={}
    for _,entry in ipairs(selected)do
     local parent=entry.parent_id
     if result.listings[parent] and not blocked[parent] and not saved_parents[parent] then
      self:rememberList(parent,result.listings[parent])
      saved_parents[parent]=true
     end
    end
    local changed=false
    for _,item in ipairs(result.records)do
     local entry=item.entry;local current=self.state.docs[entry.id]or entry
     if eligible[entry.id]and sameBook(current,entry)then
      local previous=self.state.summaries[entry.id]
      local record={sidecar_id=item.sidecar and item.sidecar.id,metadata_id=item.metadata and item.metadata.id,signature=item.signature,book_signature=fingerprint(entry),failed=item.failed,missing=item.missing,checked_at=os.time(),summary=item.summary,modified_time=item.metadata and item.metadata.modified_time}
      self.state.progress_cache[entry.id]=record
      if item.lua then self:storeRemote(entry,item,true) end
      if item.summary then
       if not self.state.sync.pending[entry.id]then
        self.state.summaries[entry.id]=item.summary
        local mark=pendingMark(self,entry)
        if item.lua and mark and mark.status~=item.summary.status then
         self.state.sync.chapter_marks[entry.id]=nil
        end
       end
      elseif item.missing or item.failed then
       self:evict({'sdr:'..entry.id},true)
       if not self.state.sync.pending[entry.id] and not self.state.history[entry.id] then self.state.summaries[entry.id]=nil end
      end
      local summary=self.state.summaries[entry.id]
      if previous~=summary and (not previous or not summary or previous.status~=summary.status or previous.percent~=summary.percent or previous.page~=summary.page)then changed=true end
      if item.error then job.last_error={code=item.error,message='Reading summary is unavailable'} end
     end
     job.done=job.done+1
    end
    self:save()
    if changed then self:emit('progress')end
   end
   done(result,e)
  end,job.mode=='resume',function()
   if self.progress_job~=job then return nil,{code='cancelled',message='Cancelled'} end
   return true
  end)
 end
 local function currentRecord(core,entry)
  local signature=fingerprint(entry)
  local record=(core.state.progress_cache or {})[entry.id]
  if signature and record and not record.dirty and record.book_signature==signature then return record end
 end
 local function runProgress(core,selected,mode,onDone)
  if not core.settings.sync_enabled or not core:online() or #selected==0 then return false end
  local selection={}
  for _,entry in ipairs(selected)do selection[#selection+1]=entry.id..':'..tostring(fingerprint(entry)) end
  local key=table.concat(selection,'|')
  local active=core.progress_job
  if active then
   if active.mode==mode and active.selection==key then
    if onDone then active.listeners[#active.listeners+1]=onDone end
    return true
   end
   if mode=='visible' and active.mode~='visible' then return false end
   if mode=='resume' and active.mode=='all' and active.parent_id==selected[1].parent_id then return false end
   core:cancelProgress()
  end
  core.state.progress_cache=core.state.progress_cache or {}
  local job={key='visible-progress',mode=mode,selection=key,done=0,total=#selected,parent_id=selected[1].parent_id,listeners={onDone}}
  core.progress_job=job
  core:emit('progress_state')
  local function finish(err)
   if core.progress_job~=job then return end
   core.progress_job=nil
   core:emit('progress_state',nil,err)
   for _,listener in ipairs(job.listeners)do listener(err) end
  end
  local advance
  advance=function()
   if core.progress_job~=job then return false end
   local batch={}
   local last=mode=='all' and math.min(job.done+4,#selected) or #selected
   for i=job.done+1,last do batch[#batch+1]=selected[i] end
   local queued=readBatch(core,job,batch,function(result,err)
    if not result or job.done>=#selected then finish(err or job.last_error)
    else
     core:emit('progress_state')
     advance()
    end
   end)
   if not queued and core.progress_job==job then
    core.progress_job=nil
    core:emit('progress_state')
   end
   return queued
  end
  return advance()
 end
 function Core:lazyProgress(entries)
  if self.settings.light_mode then return false end
  local selected,seen,byParent={},{},{}
  for _,entry in ipairs(entries or {})do
   if entry.parent_id and Library.supported(entry) and not seen[entry.id] then
    seen[entry.id]=true
    local record=currentRecord(self,entry)
    if not record or os.time()-(record.checked_at or 0)>=FRESH_SECONDS then
     local parent=entry.parent_id
     local listing=self.state.listings[parent]
     if listing and listing.complete and not byParent[parent] then
      local saved=(self.progress_fresh or {})[parent]
      byParent[parent]=Library.matchedSidecars(saved and saved.entries or self:cachedList(parent),parent)
     end
     if not byParent[parent] or byParent[parent][entry.id] then selected[#selected+1]=copy(entry) end
    end
   end
  end
  if #selected==0 and self.progress_job and self.progress_job.mode=='visible' then self:cancelProgress() end
  return runProgress(self,selected,'visible')
 end
 function Core:loadFolderProgress(parent,entries,callback)
  local matched=Library.matchedSidecars(entries,parent)
  local selected={}
  for _,entry in ipairs(entries or {})do
   if matched[entry.id] then selected[#selected+1]=copy(entry) end
  end
  return runProgress(self,selected,'all',callback)
 end

 function Core:chapterMark(entry)
  local mark=pendingMark(self,entry)
  if mark then return mark.status=='complete' end
 end
 function Core:chapterSummary(entry)
  local summary=self.state.summaries[entry.id]
  local mark=pendingMark(self,entry)
  local record=(self.state.progress_cache or {})[entry.id]
  local history=self.state.history[entry.id]
  local pending=self.state.sync.pending[entry.id]
  if summary and not mark and not (history and sameBook(history.entry,entry)) and not (pending and sameBook(pending.entry,entry)) then
   local signature=summary.book_signature or (record and record.book_signature)
   if signature and signature~=fingerprint(entry) then summary=nil end
  end
  if mark and (not summary or summary.status~=mark.status) then
   summary=copy(summary)
   summary.status=mark.status
  end
  return summary
 end
 function Core:setChapterRead(entry,read)
  local current=entry and self.state.docs[entry.id]
  if not entry or not Library.supported(entry) or not entry.id or not entry.parent_id
    or type(read)~='boolean' or (current and not sameBook(current,entry)) then
   return nil,{code='book_changed',message='This chapter has changed; its progress was preserved'}
  end
  local state,id=self.state.sync,entry.id
  state.chapter_marks=state.chapter_marks or {}
  local oldPending,oldMark,oldSummary=state.pending[id],state.chapter_marks[id],self.state.summaries[id]
  local oldConflict=state.conflicts[id]
  local oldResolution=state.resolutions and state.resolutions[id]
  local oldDeferred=state.deferred and state.deferred[id]
  local oldRevision,oldSeq=state.revision,state.next_pending_seq
  local summary=copy(self:chapterSummary(entry))
  local pending,err=self:sync():markChapter(entry,read)
  if not pending then return nil,err end
  summary.status=pending.chapter_status
  summary.book_signature=fingerprint(entry)
  self.state.summaries[id]=summary
  state.chapter_marks[id]={entry=copy(entry),status=pending.chapter_status,date=pending.chapter_status_date}
  local conflict=self:invalidateProgressChoice(entry,pending)
  local ok,why=self:save()
  if not ok then
   state.pending[id],state.chapter_marks[id],self.state.summaries[id]=oldPending,oldMark,oldSummary
   state.conflicts[id],state.resolutions[id],state.deferred[id]=oldConflict,oldResolution,oldDeferred
   state.revision,state.next_pending_seq=oldRevision,oldSeq
   return nil,{code='disk',message=why or 'Could not save the chapter status'}
  end
  if conflict then self:emit('conflict',entry)end
  self:emit('progress',entry)
  if self.settings.sync_enabled then self:flushPending() end
  return pending
 end
 function Core:applyChapterMark(entry,data)
  local mark=pendingMark(self,entry)
  if not mark then return false end
  SDR.setReadingStatus(data,mark.status,mark.date)
  return true
 end
 function Core:chapterMarkApplied(entry)
  local mark=pendingMark(self,entry)
  if not mark then return true end
  self.state.sync.chapter_marks[entry.id]=nil
  local ok,err=self:save()
  if not ok then self.state.sync.chapter_marks[entry.id]=mark end
  return ok,err
 end
 function Core:chapterSyncCommitted(entry,pending,result)
  if not pending.chapter_status or result.action=='conflict' or self.state.sync.pending[entry.id] then return end
  if not result.lua or not SDR.sameBook(entry,result.book_stamp) then return end
  local current=self.state.docs[entry.id]
  if current and not sameBook(current,entry) then return end
  local data=result.data or SDR.decode(result.lua)
  if not data then return end
  self:storeRemote(entry,result,true)
  local summary=SDR.summary(data)
  local displayed=self:chapterSummary(entry)
  local history=self.state.history[entry.id]
  if history and sameBook(history.entry,entry) and displayed and displayed.page then
   summary.page=displayed.page
   summary.percent=displayed.percent
  end
  self.state.summaries[entry.id]=summary
  local mark=pendingMark(self,entry)
  if mark and mark.status~=summary.status then self.state.sync.chapter_marks[entry.id]=nil end
  if self.state.progress_cache then self.state.progress_cache[entry.id]=nil end
 end
 function Core:chapterCloudResolved(entry,result)
  if result.lua then self:storeRemote(entry,result,true) end
  self.state.summaries[entry.id]=result.data and SDR.summary(result.data) or nil
  if self.state.progress_cache then self.state.progress_cache[entry.id]=nil end
 end

 function Core:resumeChapter(parent,entries,callback,cached_only)
  local books={}
  for _,entry in ipairs(entries or {})do
   if entry.parent_id==parent and Library.supported(entry) then books[#books+1]=entry end
  end
  local numbers=self:importedMetadata(self:cachedList(parent)).chapter_numbers
  books=Library.ordered(books,'natural',false,self.natural,numbers)
  local sidecars=Library.matchedSidecars(entries,parent)
  local opened={}
  local recent,lastSidecar,lastLocal,recentAt
  for i,entry in ipairs(books)do
   local history=self.state.history[entry.id]
   if history and not sameBook(history.entry,entry) then history=nil end
   local summary=self:chapterSummary(entry)
   opened[i]=history~=nil or summary~=nil or sidecars[entry.id]~=nil
   if summary then lastLocal=i end
   if sidecars[entry.id] then lastSidecar=i end
   local time=history and tonumber(history.time)
   if time and (not recentAt or time>recentAt or (time==recentAt and entry.id==self.state.last_document)) then
    recent,recentAt=i,time
   end
  end
  local index=recent or lastSidecar or lastLocal
  if not index then return {entry=books[1],waiting=false,resume=false,completed=false} end
  local localIndex=index
  local function resolved(selected)
   selected=selected or localIndex
   local candidate=books[selected]
   local summary=self:chapterSummary(candidate)
   local complete=summary and summary.status=='complete' or false
   if complete and books[selected+1] and not opened[selected+1] then
    return {entry=books[selected+1],waiting=false,resume=false,completed=false}
   end
   local record=currentRecord(self,candidate)
   local remoteTime=record and record.modified_time and SDR.utcTime(record.modified_time)
   return {entry=candidate,summary=summary,waiting=false,resume=true,completed=complete,remote_time=remoteTime}
  end
  local function protected(i)
   local entry=books[i]
   return self.state.sync.pending[entry.id] or pendingMark(self,entry)
  end
  local function choose()
   if not recent or not lastSidecar or lastSidecar==recent or protected(recent)then return resolved()end
   local other=books[lastSidecar]
   local record=currentRecord(self,other)
   local date=record and record.modified_time
   local timestamp=date and SDR.utcTime and SDR.utcTime(date)
   if timestamp and timestamp>recentAt and timestamp<=os.time()+300 and record.summary then return resolved(lastSidecar)end
   return resolved()
  end
  local candidate=books[index]
  if cached_only then return choose()end
  if self.settings.sync_enabled and self:online() then
   if recent and lastSidecar and lastSidecar~=recent and not protected(recent)then index=lastSidecar;candidate=books[index]end
   if not sidecars[candidate.id]then return choose()end
   local summary=self:chapterSummary(candidate)
   local pending=self.state.sync.pending[candidate.id]
   local record=currentRecord(self,candidate)
   local fresh=record and os.time()-(record.checked_at or 0)<FRESH_SECONDS
   local hasLocal=pending or pendingMark(self,candidate)
   local advances=summary and summary.status=='complete' and books[index+1] and not opened[index+1]
   local ready=fresh and (record.missing or record.failed or advances)
   if fresh and not ready and not hasLocal then
    local payload=self:remote(candidate)
    ready=payload and payload.lua and fingerprint(payload.stamp)==record.signature and SDR.sameBook(payload.book_stamp,candidate)
   end
   if not hasLocal and not ready then
    local queued=runProgress(self,{copy(candidate)},'resume',function(err)
     if callback then callback(choose(),err) end
    end)
    if queued then local known=choose();known.waiting=true;return known end
   end
  end
  return choose()
 end
end
