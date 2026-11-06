-- A disposable, selected-tree catalog. Native books and sync queues are never removed.
return function(Core)
 if Core._recursive_catalog_installed then return end;Core._recursive_catalog_installed=true
 local Metadata=require('gdriveshelf/metadata')
 local function identity(self)return self.storage.account or self.storage.root end
 local function enabled(self)
  return self.settings.index_enabled and self.settings.index_recursive_confirmed and self.settings.home and self.settings.home~='root'
 end
 local function matches(self,c)return c and c.schema==1 and c.home==self.settings.home and c.account==identity(self)end
 local function rows(self,parent)
  local listing=self.state.listings[parent]
  if not listing or not listing.complete then return self:cachedList(parent)end
  local out={};for _,id in ipairs(listing.ids or{})do local e=self.state.docs[id]or self.state.folders[id];if e and e.parent_id==parent then out[#out+1]=e end end
  return out
 end
 local function queue(c,id,again)
  if not again and c.seen[id]then return end
  for _,pending in ipairs(c.queue)do if pending==id then return end end
  c.queue[#c.queue+1]=id
 end
 local function belongs(self,id,ancestor)
  local seen={};while id and not seen[id]do
   if id==ancestor then return true end;seen[id]=true
   local e=self.state.folders[id]or self.state.docs[id];id=e and e.parent_id
  end
  return false
 end
 local function forget(self,c,id,touched)
  -- Keep durable identities/local paths for offline reading and pending native SDR.
  local removed={};for member in pairs(c.members)do if belongs(self,member,id)then removed[member]=true end end
  removed[id]=true
  local folders={}
  for member in pairs(removed)do
   local old=self.state.docs[member]or self.state.folders[member]
   if old and old.parent_id then touched[old.parent_id]=true end
   c.members[member]=nil;c.seen[member]=nil
   if self.state.folders[member]then folders[#folders+1]=member end
   if self.state.progress_cache then
    for book,record in pairs(self.state.progress_cache)do if member==book or member==record.sidecar_id or member==record.metadata_id then record.dirty=true end end
   end
  end
  local pending={};for _,folder in ipairs(c.queue)do if not removed[folder]then pending[#pending+1]=folder end end;c.queue=pending
  -- Publish no partial descendant membership during rememberList's own saves.
  for _,folder in ipairs(folders)do self:rememberList(folder,{})end
 end
 local function cleanParents(self,c,touched)
  for parent in pairs(touched)do
   local out={};for _,e in ipairs(rows(self,parent))do if c.members[e.id]and e.parent_id==parent then out[#out+1]=e end end
   self:rememberList(parent,out)
  end
 end
 local function replace(self,c,parent,entries)
  local present,touched={},{}
  for _,e in ipairs(entries)do present[e.id]=true end
  for _,old in ipairs(rows(self,parent))do if c.members[old.id]and not present[old.id]then forget(self,c,old.id,touched)end end
  for _,e in ipairs(entries)do
   e.parent_id=parent;c.members[e.id]=true
   if e.is_folder and not Metadata.isService(e)then queue(c,e.id)end
  end
  self:rememberList(parent,entries);touched[parent]=nil;cleanParents(self,c,touched)
 end
 local function invalidateProgress(self,change)
  for book,record in pairs(self.state.progress_cache or{})do
   local e=change.entry
   if change.file_id==book or change.file_id==record.metadata_id or change.file_id==record.sidecar_id or(e and e.parent_id==record.sidecar_id)then record.dirty=true end
  end
 end
 local function apply(self,c,page)
  local touched={}
  -- New folders are discovered by relisting their tree, so children that precede
  -- their new parent in this page (or an earlier page) are not lost.
  for _,change in ipairs(page.changes)do
   invalidateProgress(self,change)
   local e=change.entry;local old=self.state.docs[change.file_id]or self.state.folders[change.file_id]
   if change.file_id==c.home and(change.removed or(e and e.drive_id~=(c.scope and c.scope.drive_id)))then c.scope_changed=true end
   if change.removed or(e and(e.trashed or(e.id~=c.home and not c.members[e.parent_id])))then
    if c.members[change.file_id]or change.file_id==c.home or(old and c.members[old.parent_id])then
     forget(self,c,change.file_id,touched)
     if change.file_id==c.home then c.unavailable=true end
    end
   elseif e and(e.id==c.home or(c.members[e.parent_id]and not Metadata.isService(self.state.folders[e.parent_id]or{})))then
    if old and old.parent_id then touched[old.parent_id]=true end
    c.members[e.id]=true
    if e.is_folder then
     self.state.folders[e.id]=e
     if not Metadata.isService(e)then
      -- A parent access/membership change need not generate descendant events.
      for id in pairs(c.members)do if self.state.folders[id]and belongs(self,id,e.id)and not Metadata.isService(self.state.folders[id])then queue(c,id,true)end end
     end
    else
     e.local_path=old and old.local_path;self.state.docs[e.id]=e
     local thumb=self.state.entries['thumb:'..e.id]
     if thumb and thumb.source_stamp~=Metadata.fingerprint(e)then self:evict({'thumb:'..e.id})end
    end
    if e.parent_id then
     touched[e.parent_id]=true
     local listing=self.state.listings[e.parent_id]
     if listing and listing.complete then
      local found=false;for _,id in ipairs(listing.ids or{})do if id==e.id then found=true end end
      if not found then listing.ids[#listing.ids+1]=e.id end
     else queue(c,e.parent_id,true)end
    end
   end
  end
  if page.scope_changed then queue(c,c.home,true)end
  cleanParents(self,c,touched)
  return touched
 end
 function Core:cancelIndex()
  local job=self.index_job;self.index_job=nil
  if job and job.key and self.jobs.cancel then self.jobs:cancel(job.key)end
  local c=self.state.catalog;if c then c.paused=true;self:save()end
  self:emit('indexed')
 end
 function Core:reindexHome()
  self:cancelIndex();self.state.catalog=nil;self:save()
  return self:catalogRefresh(true)
 end
 function Core:indexHome(force)return self:catalogRefresh(force)end
 function Core:catalogRefresh(force)
  local c=self.state.catalog
  if self.index_job and(not enabled(self)or not matches(self,c))then self:cancelIndex()end
  if not enabled(self)or not self:online()or self.index_job or(self.catalog_visible==false and not force)then return false end
  if matches(self,c)and c.phase=='ready'and not force and os.time()-(c.checked_at or 0)<30 then return false end
  if not matches(self,c)then
   c={schema=1,home=self.settings.home,account=identity(self),phase='prepare',queue={},seen={},members={}}
   self.state.catalog=c
  end
  c.paused=nil;c.unavailable=nil
  local job={done=0,total=#c.queue,steps=0,metadata={}};self.index_job=job
  local function active()return self.index_job==job and self.state.catalog==c and matches(self,c)end
  local function stop(e)
   if not active()then return end
   self.index_job=nil;c.paused=e and true or nil;job.error=e
   self:save();self:emit('indexed',nil,e)
   -- Enqueue optional descriptions/covers only after catalog and visible work
   -- have had priority. Core.metadata never opens books or native SDR content.
   if not e and self.catalog_visible~=false then
    for parent in pairs(job.metadata)do if c.members[parent]then self:metadata(rows(self,parent))end end
   end
  end
  local function persist()
   local saved=self:save()
   if not saved then stop({code='io',message='Cannot save catalog checkpoint'});return false end
   return true
  end
  local advance
  local function request(key,work,done)
   job.key=key;self:emit('indexing',self.state.folders[c.queue[1]or c.home])
   local queued=self:network(key,work,function(value,e)
    if not active()then return end
    if not value then
     if key=='catalog:changes'and e and(e.status==400 or e.status==410)and not job.rebuilt then
      job.rebuilt=true;c.phase='prepare';c.token=nil;c.queue={};c.seen={};c.members={}
      if persist()then advance()end
     else stop(e)end
     return
    end
    done(value)
   end,false)
   if queued==false then stop({code='paused',message='Catalog work is paused'})end
  end
  advance=function()
   if not active()then return end
   if not enabled(self)or not self:online()then self:cancelIndex();return end
   job.steps=job.steps+1
   if job.steps>100 then stop({code='paused',message='Catalog checkpoint saved; continue on next refresh'});return end
   if c.phase=='prepare'then
    request('catalog:prepare',function(p)
     local home,e=p:stat(c.home);if not home then return nil,e end
     if not home.is_folder or home.trashed then return nil,{code='not_found',message='Home folder is unavailable'}end
     local scope={drive_id=home.drive_id};local token;token,e=p:getStartToken(scope);if not token then return nil,e end
     return{home=home,scope=scope,token=token}
    end,function(result)
     self.state.folders[c.home]=result.home;c.scope=result.scope;c.token=result.token;c.phase='bootstrap';c.queue={c.home};c.members[c.home]=true
     if persist()then advance()end
    end)
   elseif #c.queue>0 then
    local ids={};for i=1,math.min(20,#c.queue)do ids[i]=c.queue[i]end
    request('catalog:list',function(p)return p:listParents(ids,c.scope)end,function(buckets)
     for _,id in ipairs(ids)do if type(buckets[id])~='table'then stop({code='invalid_response',message='Incomplete grouped catalog listing'});return end end
     -- Keep every in-flight parent queued during rememberList's own durable
     -- writes. A crash between buckets must replay all unfinished buckets.
     for _,id in ipairs(ids)do c.seen[id]=true;replace(self,c,id,buckets[id]);job.metadata[id]=true;job.done=job.done+1 end
     for _=1,#ids do table.remove(c.queue,1)end
     job.total=job.done+#c.queue
     if persist()then advance()end
    end)
   else
    local token=c.token
    request('catalog:changes',function(p)
     local page,e=p:changes(token,c.scope);if not page then return nil,e end
     -- A user feed is account-wide. Do not write unrelated names into worker IPC.
     local relevant={}
     for _,change in ipairs(page.changes)do
      local entry=change.entry;local old=self.state.docs[change.file_id]or self.state.folders[change.file_id]
      if c.members[change.file_id]or change.file_id==c.home or(entry and c.members[entry.parent_id])or(old and c.members[old.parent_id])then relevant[#relevant+1]=change end
     end
     page.changes=relevant;return page
    end,function(page)
     if not page.next_page_token and not page.new_start_token then stop({code='invalid_response',message='Missing catalog checkpoint'});return end
     job.tokens=job.tokens or{}
     if page.next_page_token and(job.tokens[page.next_page_token]or page.next_page_token==token)then stop({code='pagination',message='Repeated catalog checkpoint'});return end
     if page.next_page_token then job.tokens[page.next_page_token]=true end
     local touched=apply(self,c,page);for parent in pairs(touched)do job.metadata[parent]=true end
     if c.scope_changed then
      c.scope_changed=nil;c.phase='prepare';c.token=nil;c.queue={};c.seen={};c.members={}
      if persist()then advance()end;return
     end
     c.token=page.next_page_token or page.new_start_token
     if page.next_page_token or #c.queue>0 then c.phase='bootstrap';if persist()then advance()end
     else c.phase='ready';c.checked_at=os.time();if persist()then stop()end end
    end)
   end
  end
  if persist()then advance()end
  return true
 end
end
