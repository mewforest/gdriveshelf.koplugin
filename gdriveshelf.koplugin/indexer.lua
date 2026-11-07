-- Drive catalog checkpoints are published one group at a time. A draft never
-- mutates the visible library or advances the token until the whole group saves.
return function(Core)
 if Core._recursive_catalog_installed then return end
 Core._recursive_catalog_installed=true
 local Metadata=require('gdriveshelf/metadata')
 local haveSocket,socket=pcall(require,'socket')
 local clock=haveSocket and socket.gettime or os.clock

 local function enabled(self)
  local settings=self.settings
  return settings.index_enabled and settings.index_recursive_confirmed
   and settings.home and settings.home~='root'
 end

 local function identity(self)
  return self.storage.account or self.storage.root
 end

 local function matches(self,catalog)
  return catalog and catalog.schema==1 and catalog.home==self.settings.home
   and catalog.account==identity(self)
 end

 local function mapCopy(source,pulse)
  local result={}
  for key,value in pairs(source)do
   result[key]=value
   if pulse then pulse()end
  end
  return result
 end

 local function draft(self,catalog,pulse)
  local copy=mapCopy(catalog)
  copy.members={}
  local children={}
  for id in pairs(catalog.members)do
   copy.members[id]=true
   local item=self.state.docs[id]or self.state.folders[id]
   local parent=item and item.parent_id
   if parent then
    children[parent]=children[parent]or{}
    children[parent][#children[parent]+1]=id
   end
   pulse()
  end
  copy.seen=mapCopy(catalog.seen,pulse)
  copy.queue=mapCopy(catalog.queue,pulse)
  local queued={}
  for _,id in ipairs(copy.queue)do queued[id]=true;pulse()end
  return {
   catalog=copy,queued=queued,children=children,
   docs=setmetatable({},{__index=self.state.docs}),
   folders=setmetatable({},{__index=self.state.folders}),
   listings=setmetatable({},{__index=self.state.listings}),
   staleThumbs={},invalidated={},dirtyBooks={},
  }
 end

 local function queue(batch,id,again)
  local catalog=batch.catalog
  if batch.queued[id] or(not again and catalog.seen[id])then return end
  batch.queued[id]=true
  catalog.queue[#catalog.queue+1]=id
 end

 local function removeQueued(batch,ids,pulse)
  local remaining={}
  for _,id in ipairs(batch.catalog.queue)do
   if ids[id]then batch.queued[id]=nil
   else remaining[#remaining+1]=id end
   pulse()
  end
  batch.catalog.queue=remaining
 end

 local function entry(state,id)
  return state.docs[id] or state.folders[id]
 end

 local function rows(state,parent,pulse)
  local listing=state.listings[parent]
  local ids=listing and listing.complete and listing.ids or(state.children or{})[parent]
  local out={}
  for _,id in ipairs(ids or{})do
   local item=entry(state,id)
   if item and item.parent_id==parent then out[#out+1]=item end
   if pulse then pulse()end
  end
  return out
 end

 local function belongs(state,id,ancestor)
  local seen={}
  while id and not seen[id]do
   if id==ancestor then return true end
   seen[id]=true
   local item=entry(state,id)
   id=item and item.parent_id
  end
  return false
 end

 local function replaceListing(self,batch,parent,entries,pulse)
  local _,stale=self:updateListing(batch,parent,entries,pulse)
  for _,key in ipairs(stale)do batch.staleThumbs[key]=true end
 end

 local function forget(self,batch,id,touched,pulse)
  -- Retain durable file identities, paths and pending SDR after unlisting.
  local catalog=batch.catalog
  local removed={[id]=true}
  if batch.folders[id] or id==catalog.home then
   for member in pairs(catalog.members)do
    if belongs(batch,member,id)then removed[member]=true end
    pulse()
   end
  end
  for member in pairs(removed)do
   local old=entry(batch,member)
   if old and old.parent_id then touched[old.parent_id]=true end
   catalog.members[member]=nil
   catalog.seen[member]=nil
   batch.invalidated[member]=true
   if batch.folders[member]then replaceListing(self,batch,member,{},pulse)end
   pulse()
  end
  removeQueued(batch,removed,pulse)
 end

 local function cleanParents(self,batch,touched,additions,pulse)
  for parent in pairs(touched)do
   local listing=batch.listings[parent]
   if listing and listing.complete then
    local out,seen={},{}
    for _,item in ipairs(rows(batch,parent,pulse))do
     if batch.catalog.members[item.id]then
      out[#out+1]=item
      seen[item.id]=true
     end
     pulse()
    end
    for id in pairs(additions[parent]or{})do
     local item=entry(batch,id)
     if not seen[id] and batch.catalog.members[id] and item and item.parent_id==parent then
      out[#out+1]=item
     end
     pulse()
    end
    replaceListing(self,batch,parent,out,pulse)
    batch.listings[parent].dirty=true
   end
   pulse()
  end
 end

 local function replace(self,batch,parent,entries,pulse)
  local present,touched,normalized={},{},{}
  for _,item in ipairs(entries)do
   local copy=mapCopy(item)
   copy.parent_id=parent
   normalized[#normalized+1]=copy
   present[copy.id]=true
   pulse()
  end
  for _,old in ipairs(rows(batch,parent,pulse))do
   if batch.catalog.members[old.id] and not present[old.id]then
    forget(self,batch,old.id,touched,pulse)
   end
   pulse()
  end
  for _,item in ipairs(normalized)do
   batch.catalog.members[item.id]=true
   if item.is_folder and not Metadata.isService(item)then queue(batch,item.id)end
   pulse()
  end
  replaceListing(self,batch,parent,normalized,pulse)
  touched[parent]=nil
  cleanParents(self,batch,touched,{},pulse)
 end

 local function applyChanges(self,batch,page,pulse)
  local catalog=batch.catalog
  local touched,additions={},{}
  -- New folders are relisted, including children that precede their parent in
  -- the feed. Obsolete membership is removed without touching offline books.
  for _,change in ipairs(page.changes)do
   local item=change.entry
   local id=change.file_id
   local old=entry(batch,id)
   batch.invalidated[id]=true
   if item and item.parent_id then batch.invalidated[item.parent_id]=true end
   if id==catalog.home and(change.removed or(item and item.drive_id~=(catalog.scope and catalog.scope.drive_id)))then
    catalog.scope_changed=true
   end
   if change.removed or(item and(item.trashed or(id~=catalog.home and not catalog.members[item.parent_id])))then
    if catalog.members[id] or id==catalog.home or(old and catalog.members[old.parent_id])then
     forget(self,batch,id,touched,pulse)
     if id==catalog.home then catalog.unavailable=true end
    end
   elseif item and(id==catalog.home or(catalog.members[item.parent_id] and not Metadata.isService(batch.folders[item.parent_id]or{})))then
    if old and old.parent_id then touched[old.parent_id]=true end
    catalog.members[id]=true
    if item.is_folder then
     batch.folders[id]=mapCopy(item)
     if not Metadata.isService(item)then
      -- Permissions can change on a parent without descendant feed events.
      for member in pairs(catalog.members)do
       local folder=batch.folders[member]
       if folder and belongs(batch,member,id)and not Metadata.isService(folder)then queue(batch,member,true)end
       pulse()
      end
     end
    else
     batch.docs[id]=mapCopy(item)
     batch.staleThumbs['thumb:'..id]=true
    end
    if item.parent_id then
     local parent=item.parent_id
     touched[parent]=true
     additions[parent]=additions[parent]or{}
     additions[parent][id]=true
     local listing=batch.listings[parent]
     if not listing or not listing.complete then queue(batch,parent,true)end
    end
   end
   pulse()
  end
  if page.scope_changed then queue(batch,catalog.home,true)end
  cleanParents(self,batch,touched,additions,pulse)
 end

 local function collectDirtyProgress(self,batch,pulse)
  if not next(batch.invalidated)then return end
  for id,record in pairs(self.state.progress_cache or{})do
   local changed=batch.invalidated
   if changed[id] or changed[record.sidecar_id] or changed[record.metadata_id]then
    batch.dirtyBooks[id]=true
   end
   pulse()
  end
 end

 local function save(self,job)
  local started=clock()
  local ran,ok=pcall(self.save,self)
  local elapsed=(clock()-started)*1000
  local metrics=job.metrics
  metrics.writes=metrics.writes+1
  metrics.save_ms=metrics.save_ms+elapsed
  metrics.max_save_ms=math.max(metrics.max_save_ms,elapsed)
  return ran and ok
 end

 local function commit(self,job,batch)
  local state=self.state
  local undo,removed={},{}
  local function publish(map,key,value)
   undo[#undo+1]={map,key,map[key]}
   map[key]=value
  end
  for id,value in pairs(batch.docs)do
   value.local_path=state.docs[id] and state.docs[id].local_path
   publish(state.docs,id,value)
  end
  for id,value in pairs(batch.folders)do publish(state.folders,id,value)end
  for id,value in pairs(batch.listings)do publish(state.listings,id,value)end
  for id in pairs(batch.dirtyBooks)do
   local record=(state.progress_cache or{})[id]
   if record then publish(record,'dirty',true)end
  end
  for key in pairs(batch.staleThumbs)do
   local thumbnail=state.entries[key]
   local document=state.docs[key:sub(7)]
   if thumbnail and document and thumbnail.source_stamp~=Metadata.fingerprint(document)then
    removed[#removed+1]=thumbnail
    publish(state.entries,key,nil)
   end
  end
  publish(state,'catalog',batch.catalog)
  if not save(self,job)then
   for i=#undo,1,-1 do
    local item=undo[i]
    item[1][item[2]]=item[3]
   end
   return false
  end
  self.listing_epoch=(self.listing_epoch or 0)+1
  for id in pairs(batch.listings)do
   if self.progress_fresh then self.progress_fresh[id]=nil end
  end
  for _,thumbnail in ipairs(removed)do
   self.storage:remove(thumbnail.path)
   if thumbnail.preview_path then self.storage:remove(thumbnail.preview_path)end
  end
  return true
 end

 local function schedule(self,callback,delay)
  if self.jobs.schedule then self.jobs.schedule(callback,delay)else callback()end
 end

 local function updateStatus(self,job,phase)
  job.phase=phase
  job.total=job.done+#self.state.catalog.queue
  local recent=job.recent
  recent[#recent+1]={phase=phase,done=job.done,discovered=job.total}
  if #recent>3 then table.remove(recent,1)end
  self:emit('indexing')
 end

 function Core:indexStatus()
  local job=self.index_job or self.last_index_job
  local catalog=self.state.catalog
  if not matches(self,catalog)then return {phase='idle',done=0,discovered=0,elapsed=0,recent={}}end
  if job and job.home~=catalog.home then job=nil end
  local running=self.index_job==job and job~=nil
  return {
   phase=running and job.phase or(catalog.paused and 'paused' or(job and job.phase)or(catalog.phase=='ready'and 'complete'or'idle')),
   running=running,paused=catalog.paused==true,
   done=job and job.done or(catalog.processed or 0),
   discovered=job and job.total or((catalog.processed or 0)+#catalog.queue),
   elapsed=job and math.max(0,(job.finished or os.time())-job.started)or 0,
   recent=job and job.recent or{},error=job and job.error,
   metrics=job and job.metrics,
  }
 end

 function Core:cancelIndex(explicit)
  local job=self.index_job
  self.index_job=nil
  self.index_enrichment=nil
  if job then
   if job.key and self.jobs.cancel then self.jobs:cancel(job.key)end
   if job.apply_tick and self.jobs.unschedule then self.jobs.unschedule(job.apply_tick)end
   job.finished=os.time()
   job.phase='paused'
   self.last_index_job=job
  end
  local catalog=self.state.catalog
  if explicit~=false and matches(self,catalog)and not catalog.paused then
   catalog.paused=true
   self:save()
  end
  if job or explicit~=false then self:emit('indexed')end
 end

 function Core:reindexHome()
  if not enabled(self)or not self:online()then return false end
  self:cancelIndex(false)
  self.state.catalog=nil
  return self:catalogRefresh(true)
 end

 function Core:indexHome(force)return self:catalogRefresh(force)end

 function Core:catalogRefresh(force)
  local catalog=self.state.catalog
  if self.index_job and(not enabled(self)or not matches(self,catalog))then self:cancelIndex(false)end
  if not enabled(self)or not self:online()or self.index_job then return false end
  if not force and(self.settings.light_mode or self.catalog_visible==false)then return false end
  if matches(self,catalog) and not force then
   if catalog.paused or(catalog.phase=='ready'and os.time()-(catalog.checked_at or 0)<30)then return false end
  end
  self.index_enrichment=nil
  if not matches(self,catalog)then
   catalog={schema=1,home=self.settings.home,account=identity(self),phase='prepare',queue={},seen={},members={}}
   self.state.catalog=catalog
  end
  local done=catalog.phase~='ready'and(catalog.processed or 0)or 0
  local job={home=catalog.home,done=done,total=done+#catalog.queue,steps=0,started=os.time(),recent={},metadata={},
   phase='prepare',explicit=force==true,metrics={writes=0,apply_ms=0,max_apply_ms=0,save_ms=0,max_save_ms=0}}
  self.index_job=job
  local function active()
   return self.index_job==job and self.state.catalog==catalog and matches(self,catalog)
  end

  local function stop(error)
   if not active()then return end
   self.index_job=nil
   job.error=error
   job.phase=error and 'error'or'complete'
   job.finished=os.time()
   self.last_index_job=job
   self:emit('indexed',nil,error)
   if error or self.settings.light_mode or self.catalog_visible==false then return end
   -- A completed scan may have many covers. Feed one folder at a time instead
   -- of expanding all metadata requests synchronously in the completion callback.
   local parent=next(job.metadata)
   if not parent then return end
   self.index_enrichment=job
   local function enrich()
    if self.index_enrichment~=job or not enabled(self)or not matches(self,catalog)
     or self.settings.light_mode or self.catalog_visible==false then return end
    if not parent then self.index_enrichment=nil;return end
    if self.jobs.schedule and self.jobs.active then schedule(self,enrich,.25);return end
    if catalog.members[parent]then self:metadata(rows(self.state,parent))end
    parent=next(job.metadata,parent)
    schedule(self,enrich,.10)
   end
   schedule(self,enrich,.10)
  end

  local advance
  local function stage(epoch,work,complete)
   updateStatus(self,job,'applying')
   local ticks,slice=0,clock()
   local function pulse()
    ticks=ticks+1
    if self.jobs.schedule and(ticks>=96 or clock()-slice>=.008)then coroutine.yield()end
   end
   local builder=coroutine.create(function()
    local batch=draft(self,catalog,pulse)
    batch.catalog.paused=nil
    work(batch,pulse)
    collectDirtyProgress(self,batch,pulse)
    return batch
   end)
   local function step()
    job.apply_tick=nil
    if not active()then return end
    -- A directly opened folder may have completed a fresher listing while the
    -- grouped request or its draft was in flight. Retry from the last checkpoint.
    if epoch~=(self.listing_epoch or 0)then advance();return end
    ticks,slice=0,clock()
    local ok,batch=coroutine.resume(builder)
    local elapsed=(clock()-slice)*1000
    job.metrics.apply_ms=job.metrics.apply_ms+elapsed
    job.metrics.max_apply_ms=math.max(job.metrics.max_apply_ms,elapsed)
    if not ok then stop({code='index',message='Could not prepare the catalog checkpoint'});return end
    if coroutine.status(builder)~='dead'then
     job.apply_tick=step
     schedule(self,step,.01)
     return
    end
    if not commit(self,job,batch)then stop({code='io',message='Cannot save catalog checkpoint'});return end
    catalog=batch.catalog
    complete(batch)
   end
   step()
  end

  local function request(key,phase,work,done)
   job.key=key
   updateStatus(self,job,phase)
   if not active()then return end
   local epoch=self.listing_epoch or 0
   local queued=self:network(key,work,function(value,error)
    if not active()then return end
    job.key=nil
    if not value then
     if key=='catalog:changes'and error and(error.status==400 or error.status==410)and not job.rebuilt then
      job.rebuilt=true
      stage(epoch,function(batch)
       local c=batch.catalog
       c.phase='prepare';c.token=nil;c.queue={};c.seen={};c.members={};c.processed=0
      end,function()job.done=0;advance()end)
     else stop(error)end
     return
    end
    done(value,epoch)
   end,false)
   if queued==false then stop({code='paused',message='Catalog work is paused'})end
  end

  advance=function()
   if not active()then return end
   if not enabled(self)or not self:online()then self:cancelIndex(false);return end
   job.steps=job.steps+1
   if job.steps>100 then stop({code='paused',message='Catalog checkpoint saved; continue on next refresh'});return end
   if catalog.phase=='prepare'then
    request('catalog:prepare','prepare',function(provider)
     local home,error=provider:stat(catalog.home)
     if not home then return nil,error end
     if not home.is_folder or home.trashed then return nil,{code='not_found',message='Home folder is unavailable'}end
     local scope={drive_id=home.drive_id}
     local token
     token,error=provider:getStartToken(scope)
     if not token then return nil,error end
     return {home=home,scope=scope,token=token}
    end,function(result,epoch)
     stage(epoch,function(batch)
      local c=batch.catalog
      batch.folders[c.home]=result.home
      c.scope=result.scope;c.token=result.token;c.phase='bootstrap';c.queue={c.home};c.members[c.home]=true
     end,function()advance()end)
    end)
   elseif #catalog.queue>0 then
    local ids={}
    for i=1,math.min(20,#catalog.queue)do ids[i]=catalog.queue[i]end
    request('catalog:list','listing',function(provider)
     return provider:listParents(ids,catalog.scope)
    end,function(buckets,epoch)
     for _,id in ipairs(ids)do
      if type(buckets[id])~='table'then stop({code='invalid_response',message='Incomplete grouped catalog listing'});return end
     end
     stage(epoch,function(batch,pulse)
      local processed={}
      for _,id in ipairs(ids)do
       if batch.catalog.members[id]then
        batch.catalog.seen[id]=true
        replace(self,batch,id,buckets[id],pulse)
       end
       processed[id]=true
       pulse()
      end
      removeQueued(batch,processed,pulse)
      batch.catalog.processed=(batch.catalog.processed or 0)+#ids
     end,function(batch)
      for id in pairs(batch.listings)do job.metadata[id]=true end
      job.done=job.done+#ids
      advance()
     end)
    end)
   else
    local token=catalog.token
    request('catalog:changes','changes',function(provider)
     local page,error=provider:changes(token,catalog.scope)
     if not page then return nil,error end
     -- My Drive feeds are account-wide. Exclude unrelated names before IPC.
     local relevant={}
     for _,change in ipairs(page.changes)do
      local item=change.entry
      local old=entry(self.state,change.file_id)
      if catalog.members[change.file_id] or change.file_id==catalog.home
       or(item and catalog.members[item.parent_id])or(old and catalog.members[old.parent_id])then
       relevant[#relevant+1]=change
      end
     end
     page.changes=relevant
     return page
    end,function(page,epoch)
     if not page.next_page_token and not page.new_start_token then
      stop({code='invalid_response',message='Missing catalog checkpoint'});return
     end
     job.tokens=job.tokens or{}
     if page.next_page_token and(job.tokens[page.next_page_token]or page.next_page_token==token)then
      stop({code='pagination',message='Repeated catalog checkpoint'});return
     end
     stage(epoch,function(batch,pulse)
      local c=batch.catalog
      applyChanges(self,batch,page,pulse)
      if c.scope_changed then
       c.scope_changed=nil;c.phase='prepare';c.token=nil;c.queue={};c.seen={};c.members={};c.processed=0
      else
       c.token=page.next_page_token or page.new_start_token
       if page.next_page_token or #c.queue>0 then c.phase='bootstrap'
       else c.phase='ready';c.checked_at=os.time()end
      end
     end,function(batch)
      if page.next_page_token then job.tokens[page.next_page_token]=true end
      for id in pairs(batch.listings)do job.metadata[id]=true end
      if catalog.phase=='ready'then stop()
      else
       if catalog.phase=='prepare'then job.done=0 end
       advance()
      end
     end)
    end)
   end
  end

  advance()
  return true
 end
end
