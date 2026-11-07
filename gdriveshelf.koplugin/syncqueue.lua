-- The queue owns durable decisions. Network workers may validate a choice, but
-- only the UI process publishes it or grants a subsequent native restoration.
local SDR=require('gdriveshelf/sdr')
local Storage=require('gdriveshelf/storage')
local function err(code,message)return {code=code,message=message}end
local function copy(value)
 if type(value)~='table'then return value end
 local result={};for k,v in pairs(value)do result[k]=copy(v)end;return result
end
local function queues(core)
 local state=core.state.sync
 state.resolutions=state.resolutions or {}
 state.deferred=state.deferred or {}
 return state
end
local function persist(core,id,update)
 local state=queues(core)
 local previous={}
 for _,key in ipairs{'pending','bases','conflicts','resolutions','deferred','chapter_marks'}do
  if state[key]then previous[#previous+1]={state[key],copy(state[key][id])}end
 end
 local revision,seq=state.revision,state.next_pending_seq
 local summary=core.state.summaries[id]
 local remote_key='sdr:'..id
 local old_remote=core.state.entries[remote_key]
 local old_progress=core.state.progress_cache and core.state.progress_cache[id]
 local result,why=update(state)
 if result then
  local saved,e=core:save();if saved then return result end
  why=err('disk',e or 'Could not save the progress queue')
 end
 for _,pair in ipairs(previous)do pair[1][id]=pair[2]end
 state.revision,state.next_pending_seq=revision,seq
 core.state.summaries[id]=summary
 core.state.entries[remote_key]=old_remote
 if core.state.progress_cache then core.state.progress_cache[id]=old_progress end
 return nil,why
end
local function archive(core,entry,saved,choice,revision)
 local dir=core.storage.root..'/snapshots/'
 local prefix=dir..Storage.key(entry.id)..'-conflict-'..os.time()..'-'..tostring(revision or 0)..'-'
 local attempt=1
 while core.storage:exists(prefix..attempt..'.json')do attempt=attempt+1 end
 local path=prefix..attempt..'.json'
 local intent=copy(saved)
 intent.id=path:match('([^/]+)%.json$')
 intent.choice=choice;intent.revision=revision
 local ok,e=core.storage:writeJSON(path,intent)
 if not ok then return nil,err('disk',e or 'Could not preserve both conflict versions')end
 return intent
end
local function fromResult(pending,result,reason)
 local local_lua=pending.lua
 if not local_lua and pending.status_only and result.lua then
  local data=SDR.decode(result.lua)
  if data then local_lua=SDR.encode(SDR.setReadingStatus(data,pending.chapter_status,pending.chapter_status_date))end
 end
 return {reason=reason or 'both_changed',local_lua=local_lua,remote_lua=result.lua,base_lua=pending.base_lua,
  local_revision=pending.revision,local_time=pending.position_changed_at,stamp=result.stamp,book_stamp=result.book_stamp}
end

return function(Core)
 function Core:resolveProgressConflict(entry,choice,expected,automatic,explicit)
  local state=queues(self)
  local saved,pending=state.conflicts[entry.id],state.pending[entry.id]
  if not saved or (expected and expected~=saved)or not pending
   or (saved.local_revision and saved.local_revision~=pending.revision)then
   return nil,err('no_conflict','Progress changed. Reopen the comparison.')
  end
  local selected=choice=='local' and saved.local_lua or choice=='remote' and saved.remote_lua
  if (choice=='local' and saved.reason=='book_changed')
   or not SDR.sameBook(saved.book_stamp,saved.book_stamp) or not SDR.decode(selected)then
   return nil,err('invalid_choice','This version of progress cannot be applied')
  end
  local intent,e=archive(self,entry,saved,choice,pending.revision)
  if not intent then return nil,e end
  intent.automatic=automatic==true
  local ok
  ok,e=persist(self,entry.id,function(data)
   data.resolutions[entry.id]=intent;data.conflicts[entry.id]=nil
   return true
  end)
  if not ok then return nil,e end
  self:emit('sync_queued',entry,{choice=choice})
  self:flushPending(explicit or not automatic)
  return intent
 end

 local function selectAutomatic(core,entry,pending,saved)
  if saved.reason~='both_changed' or not pending or pending.status_only or pending.chapter_status
   or pending.revision~=saved.local_revision or not pending.base_lua
   or not SDR.sameBook(pending.book_stamp,saved.book_stamp)
   or not SDR.sameBook(pending.base_book_stamp,saved.book_stamp)
   or not saved.stamp or not saved.stamp.etag then return nil end
  return SDR.automaticChoice(entry,SDR.decode(saved.local_lua),SDR.decode(saved.remote_lua),
   core.settings.sync_conflict_policy or 'farthest',saved.local_time,saved.stamp.modified_time)
 end

 local function publishDeferred(core,entry,pending,result,intent)
  local id=entry.id
  local staged={lua=result.lua,stamp=copy(result.stamp),book_stamp=copy(result.book_stamp),id=intent.id,
   expected_local_lua=intent.local_lua,base_lua=intent.base_lua,local_time=intent.local_time,
   resolved_revision=pending.revision}
  local ok,e=persist(core,id,function(data)
   data.conflicts[id],data.resolutions[id]=nil,nil
   data.deferred[id]=staged
   core.state.summaries[id]=SDR.summary(SDR.decode(result.lua))
   return staged
  end)
  if not ok then return nil,e end
  core:emit('sync_resolved',entry,{choice='remote',action='deferred',automatic=intent.automatic})
  return staged
 end

 function Core:flushPending(explicit)
  if not self.settings.sync_enabled or not self:online()or (self.settings.light_mode and not explicit)then return end
  local state=queues(self)
  for _,pending in ipairs(self:sync():pendingList())do
   local entry,id=pending.entry,pending.entry.id
   local intent=state.resolutions[id]
   if not state.conflicts[id] and not state.deferred[id]then
    local function current()
     local latest=state.pending[id]
     return latest and latest.revision==pending.revision and state.resolutions[id]==intent
    end
    local function durable()
     local saved=self.storage:readJSON(self.index_path,256*1048576)
     local data=saved and saved.sync
     local last=data and data.pending and data.pending[id]
     local choice=data and data.resolutions and data.resolutions[id]
     return last and choice and last.revision==pending.revision and choice.id==intent.id
    end
    local function publish(result,failure)
     if intent and state.resolutions[id]~=intent then
      if not state.conflicts[id] then self:flushPending(explicit)end
      return
     end
     if not result then
      if not(failure and failure.silent)then self:emit('sync_error',entry,failure)end
      return
     end
     if (result.action=='pull' and current())or result.action=='deferred' then
      if current() and result.lua and SDR.sameBook(result.book_stamp,intent and intent.book_stamp or pending.book_stamp) then
       local chosen,e=intent
       if not chosen then
        chosen,e=archive(self,entry,fromResult(pending,result,'remote_updated'),'remote',pending.revision)
        if chosen then chosen.automatic=true end
       end
       if not chosen then self:emit('sync_error',entry,e);return end
       local ok
       ok,e=publishDeferred(self,entry,pending,result,chosen)
       if not ok then self:emit('sync_error',entry,e)end
       return
      end
     end
     if result.action=='pull' or result.action=='deferred' then
      result={action='conflict',conflict=fromResult(pending,result,'remote_updated')}
     end
     local base=state.bases[id]
     local advances=result.action=='pushed' or (result.action=='same'
      and (not base or base.lua~=result.lua or not SDR.equal(base.stamp,result.stamp)))
     local remote_key='sdr:'..id
     local obsolete=advances and self.state.entries[remote_key]
     local committed,e=persist(self,id,function(data)
      if intent then data.resolutions[id]=nil end
      local outcome,why=self:sync():commit(entry,pending,result)
      if outcome and advances then
       self.state.entries[remote_key]=nil
       if self.state.progress_cache then self.state.progress_cache[id]=nil end
      end
      return outcome,why
     end)
     if not committed then self:emit('sync_error',entry,e);return end
     if result.action=='conflict' then
      local saved=state.conflicts[id]
      local choice=not intent and selectAutomatic(self,entry,state.pending[id],saved)
      if choice and self:resolveProgressConflict(entry,choice,saved,true,explicit) then return end
      self:emit('conflict',entry)
     else
      if obsolete and obsolete.path then self.storage:remove(obsolete.path)end
      if advances and self.remote_ready then self.remote_ready[id]=nil end
      if pending.chapter_status and self.chapterSyncCommitted then self:chapterSyncCommitted(entry,pending,result);self:save()end
      if intent then self:emit('sync_resolved',entry,{choice=intent.choice,action=result.action,automatic=intent.automatic})end
      if state.pending[id]then self:flushPending(explicit)end
     end
    end
    self:network('sync:'..id,function(provider)
     return self:sync(provider):push(entry,pending,intent,intent and durable or nil)
    end,publish,false,intent and function()
     if not current()then return nil,{code='cancelled',silent=true}end
     return true
    end or nil,nil,false,{automatic=not explicit})
   end
  end
 end

 -- A latest native snapshot invalidates an in-flight choice before the new
 -- index becomes visible to workers. The original pair is still archived.
 function Core:invalidateProgressChoice(entry,pending)
  local state=queues(self)
  local id=entry.id
  local intent=state.resolutions[id]
  local staged=state.deferred[id]
  if intent and pending.revision~=intent.revision then
   state.conflicts[id]=fromResult(pending,{lua=intent.remote_lua,stamp=intent.stamp,book_stamp=intent.book_stamp},
    'changed_during_resolution')
   state.resolutions[id]=nil
   return true
  elseif staged then
   local data=SDR.decode(pending.lua)
   local expected=staged.expected_local_lua and SDR.decode(staged.expected_local_lua)
   if pending.status_only or (not SDR.sameMetadata(data,expected) and not SDR.sameMetadata(data,SDR.decode(staged.lua)))then
    state.conflicts[id]=fromResult(pending,staged,'changed_during_resolution')
    state.deferred[id]=nil
    return true
   end
  end
 end

 function Core:snapshot(entry,data)
  local conflict
  local pending,e=persist(self,entry.id,function()
   local saved,why=self:sync():snapshot(entry,data)
   if not saved then return nil,why end
   self.state.summaries[entry.id]=SDR.summary(data)
   conflict=self:invalidateProgressChoice(entry,saved)
   return saved
  end)
  if not pending then return nil,e end
  if conflict then self:emit('conflict',entry)end
  if self.settings.sync_enabled then self:flushPending()end
  return pending
 end

 local function supersedes(latest,older)
  if not latest or not older then return false end
  local av,bv=tostring(latest.version or ''),tostring(older.version or '')
  if latest.id==older.id and av:match('^%d+$') and bv:match('^%d+$')then
   if #av~=#bv then return #av>#bv end
   return av>bv
  end
  local a,b=SDR.utcTime(latest.modified_time),SDR.utcTime(older.modified_time)
  return a and b and a>b
 end

 function Core:deferredProgress(entry,native_data,observed)
  local state=queues(self)
  local id=entry.id
  local staged=state.deferred[id]
  if self.settings.sync_enabled==false or not staged or state.conflicts[id]then return nil end
  if self.active_id==id then return nil end
  if not SDR.sameBook(staged.book_stamp,entry)then return nil,err('book_changed','The book version has changed or cannot be verified. Progress was not applied.')end
  local cloud=SDR.decode(staged.lua)
  local expected=staged.expected_local_lua and SDR.decode(staged.expected_local_lua)
  local cloud_changed=observed and SDR.sameBook(observed.book_stamp,entry)
   and supersedes(observed.stamp,staged.stamp) and observed.lua~=staged.lua and SDR.decode(observed.lua)
  if cloud_changed or (native_data and not SDR.sameMetadata(native_data,expected) and not SDR.sameMetadata(native_data,cloud))then
   local pending,e=persist(self,id,function(data)
    local local_pending,why=self:sync():snapshot(entry,native_data or expected or cloud)
    if not local_pending then return nil,why end
    data.conflicts[id]=fromResult(local_pending,cloud_changed and observed or staged,'changed_during_resolution')
    data.deferred[id]=nil
    return local_pending
   end)
   if not pending then return nil,e end
   self:emit('conflict',entry)
   return nil,err('conflict','Progress changed. Compare the saved versions.')
  end
  local pending=state.pending[id]
  if pending and not pending.status_only and not SDR.sameMetadata(SDR.decode(pending.lua),cloud)
   and not SDR.sameMetadata(SDR.decode(pending.lua),expected) then return nil end
  return staged
 end

 function Core:completeDeferredProgress(entry,record)
  local id=entry.id
  local state=queues(self)
  if state.deferred[id]~=record then return nil,err('conflict','Progress changed. Reopen the comparison.')end
  local ok,e=persist(self,id,function(data)
   data.deferred[id]=nil
   data.bases[id]={lua=record.lua,stamp=record.stamp,book_stamp=record.book_stamp}
   local pending=data.pending[id]
   if pending and (not pending.status_only or pending.revision==record.resolved_revision)then data.pending[id]=nil end
   if data.chapter_marks and not data.pending[id]then data.chapter_marks[id]=nil end
   self.state.summaries[id]=SDR.summary(SDR.decode(record.lua))
   return true
  end)
  if not ok then return nil,e end
  self:emit('progress',entry)
  if state.pending[id]then self:flushPending()end
  return true
 end

 function Core:stageRemoteProgress(entry,record,native_data)
  local state=queues(self)
  local id=entry.id
  if self.settings.sync_enabled==false or self.active_id==id then return nil end
  if state.deferred[id] then return self:deferredProgress(entry,native_data,record) end
  local pending=state.pending[id]
  if state.conflicts[id] or state.resolutions[id] or (pending and not pending.status_only)then return nil end
  local base=state.bases[id]
  local verified=record and record.lua and SDR.sameBook(record.book_stamp,entry)
  if base and (not verified or record.lua==base.lua or not supersedes(record.stamp,base.stamp))then
   -- A native sidecar already has a position. An incomparable or older cache
   -- cannot supersede the synchronized base, even if its Lua differs.
   if native_data then return nil end
   if base.lua and SDR.sameBook(base.book_stamp,entry)then record=base
   elseif not verified or record.lua~=base.lua then return nil end
  end
  if not record or not record.lua or not SDR.sameBook(record.book_stamp,entry)then return nil end
  local cloud=SDR.decode(record.lua)
  if not cloud then return nil,err('invalid_remote_metadata','Could not read cloud progress')end
  local base_data=base and base.lua and SDR.decode(base.lua)
  local action=native_data and SDR.decide(base_data,native_data,cloud)or 'pull'
  if action=='push'then return nil end
  if action=='same'then
   local ok,e=persist(self,id,function(data)
    data.bases[id]={lua=record.lua,stamp=record.stamp,book_stamp=record.book_stamp}
    return true
   end)
   return nil,not ok and e or nil
  end
  if action=='conflict' then
   local snapshot,e=persist(self,id,function(data)
    local local_pending,why=self:sync():snapshot(entry,native_data)
    if not local_pending then return nil,why end
    -- A timestamp observed on open is not when the native reader changed position.
    local_pending.position_changed_at=nil
    data.conflicts[id]=fromResult(local_pending,record)
    return local_pending
   end)
   if not snapshot then return nil,e end
   local saved=state.conflicts[id]
   local choice=selectAutomatic(self,entry,snapshot,saved)
   if choice and self:resolveProgressConflict(entry,choice,saved,true)then return nil end
   self:emit('conflict',entry)
   return nil,err('conflict','Local progress changed. Compare the saved versions.')
  end
  local saved={local_lua=native_data and SDR.encode(native_data),remote_lua=record.lua,base_lua=base and base.lua,
   stamp=record.stamp,book_stamp=record.book_stamp}
  if native_data and not saved.local_lua then return nil,err('invalid_local_metadata','Could not preserve local progress')end
  local intent,e=archive(self,entry,saved,'remote',pending and pending.revision)
  if not intent then return nil,e end
  return persist(self,id,function(data)
   local staged={lua=record.lua,stamp=copy(record.stamp),book_stamp=copy(record.book_stamp),
    id=intent.id,expected_local_lua=saved.local_lua,base_lua=saved.base_lua}
   data.deferred[id]=staged
   return staged
  end)
 end
end
