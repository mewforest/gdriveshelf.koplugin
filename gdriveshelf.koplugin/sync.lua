-- Network operations return snapshots; only snapshot/commit/resolve mutate parent state.
local Sync = {}
Sync.__index = Sync
local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for k,v in pairs(value) do result[k]=copy(v) end; return result
end
local function err(code,message) return {code=code,message=message} end
local function stamp(entry)
    if not entry then return nil end
    return {id=entry.id,modified_time=entry.modified_time,checksum=entry.checksum,version=entry.version,etag=entry.etag,size=entry.size}
end
local function sameMetadataVersion(a,b)
    if not a or not b or a.id~=b.id then return false end
    if a.etag and b.etag then return a.etag==b.etag end
    if a.version~=nil and b.version~=nil then return tostring(a.version)==tostring(b.version) end
    return a.checksum and b.checksum and a.checksum==b.checksum and a.modified_time==b.modified_time
end
local function changed(sdr,a,b)
    if not a or not b then return false end
    if sdr.sameBook(a,b) then return false end
    if a.id~=nil and b.id~=nil and a.id~=b.id then return true end
    for _,key in ipairs({'checksum','version','modified_time','size'}) do
        if a[key]~=nil and b[key]~=nil and tostring(a[key])~=tostring(b[key]) then return true end
    end
    -- Unknown stamps alone do not prove an edit; restoration uses sameBook's
    -- stricter affirmative identity check instead. A missing base is valid.
    return false
end
function Sync.new(opts)
    local self=setmetatable({},Sync)
    self.provider=assert(opts.provider); self.storage=assert(opts.storage); self.state=opts.state or {}
    self.sdr=opts.sdr or require('sdr'); self.offline=opts.offline
    self.state.pending=self.state.pending or {}; self.state.bases=self.state.bases or {}; self.state.conflicts=self.state.conflicts or {}
    return self
end
function Sync:isOffline() return type(self.offline)=='function' and self.offline() or self.offline==true end
function Sync:snapshot(entry,data,force)
    local lua,e=self.sdr.encode(data); if not lua then return nil,err('invalid_local_metadata',e) end
    local old=self.state.pending[entry.id]; local base=self.state.bases[entry.id] or {}
    if old and old.chapter_status and (old.entry.name~=entry.name or old.entry.parent_id~=entry.parent_id or not self.sdr.sameBook(old.book_stamp,entry)) then
        return nil,err('book_changed','This chapter has changed; its pending progress was preserved')
    end
    if not force and old and old.lua==lua and old.entry.name==entry.name and old.entry.parent_id==entry.parent_id
        and self.sdr.sameBook(old.book_stamp,entry) then return old end
    local previous=old and old.lua or base.lua
    previous=previous and self.sdr.decode(previous)
    local position_changed=not previous or previous.last_page~=data.last_page or previous.last_xpointer~=data.last_xpointer
        or (data.last_page==nil and data.last_xpointer==nil and previous.percent_finished~=data.percent_finished)
    self.state.next_pending_seq=(self.state.next_pending_seq or 0)+1
    self.state.revision=(self.state.revision or 0)+1
    local pending={entry=copy(entry),lua=lua,book_stamp=stamp(entry),seq=old and old.seq or self.state.next_pending_seq,revision=self.state.revision}
    pending.position_changed_at=position_changed and os.time() or (old and old.position_changed_at or base.position_changed_at)
    if old then
        pending.base_lua=old.base_lua; pending.base_stamp=copy(old.base_stamp); pending.base_book_stamp=copy(old.base_book_stamp)
        if old.chapter_status and self.sdr.summary(data).status==old.chapter_status then
            pending.chapter_status=old.chapter_status; pending.chapter_status_date=old.chapter_status_date
        end
    else pending.base_lua=base.lua; pending.base_stamp=copy(base.stamp); pending.base_book_stamp=copy(base.book_stamp) end
    self.state.pending[entry.id]=pending
    local saved=self.state.conflicts[entry.id]
    if saved then
        local updated=copy(saved)
        updated.local_lua=lua;updated.local_revision=pending.revision;updated.local_time=pending.position_changed_at
        self.state.conflicts[entry.id]=updated
    end
    return pending
end
function Sync:markChapter(entry,read)
    local old=self.state.pending[entry.id]
    if old and (old.entry.name~=entry.name or old.entry.parent_id~=entry.parent_id or not self.sdr.sameBook(old.book_stamp,entry)) then
        return nil,err('book_changed','This chapter has changed; its pending progress was preserved')
    end
    local status=read and 'complete' or 'reading'
    local date=os.date('%Y-%m-%d')
    local data={}
    if old and not old.status_only then
        local e; data,e=self.sdr.decode(old.lua)
        if not data then return nil,err('invalid_pending',e) end
    end
    local pending,e=self:snapshot(entry,self.sdr.setReadingStatus(data,status,date),true)
    if not pending then return nil,e end
    pending.chapter_status=status
    pending.chapter_status_date=date
    if not old or old.status_only then
        pending.status_only=true
        pending.lua=nil
        local saved=self.state.conflicts[entry.id]
        if saved then
            local remote=saved.remote_lua and self.sdr.decode(saved.remote_lua) or {}
            saved.local_lua=self.sdr.encode(self.sdr.setReadingStatus(remote,status,date))
        end
    end
    return pending
end
function Sync:pendingList()
    local result={}; for _,pending in pairs(self.state.pending) do result[#result+1]=pending end
    table.sort(result,function(a,b) if a.seq~=b.seq then return a.seq<b.seq end; return a.entry.id<b.entry.id end)
    return result
end
-- Fresh parent discovery also detects two source books mapping to one native stem.
function Sync:locate(entry)
    if self:isOffline() then return nil,err('offline','Sync is offline') end
    if type(entry.name)~='string' or entry.name:find('[/\\%z]') or entry.name=='.' or entry.name=='..' then return nil,err('invalid_name','Unsafe native metadata filename') end
    local entries,e=self.provider:list(entry.parent_id); if not entries then return nil,e end
    local sidecar=self.sdr.sidecarName(entry.name)
    local folders,stems={},0
    for _,child in ipairs(entries) do
        if child.parent_id==entry.parent_id then
            if child.name==sidecar then folders[#folders+1]=child end
            if not child.is_folder and self.sdr.sidecarName(child.name)==sidecar then stems=stems+1 end
        end
    end
    if stems>1 then return nil,err('ambiguous_stem','Multiple documents share this native sidecar name') end
    if #folders>1 or (#folders==1 and not folders[1].is_folder) then return nil,err('ambiguous_sidecar','Native sidecar is ambiguous or is not a folder') end
    local folder=folders[1]
    if not folder then return {parent_entries=entries} end
    local children,ce=self.provider:list(folder.id); if not children then return nil,ce end
    local matches={}; local name=self.sdr.metadataName(entry.name)
    for _,child in ipairs(children) do if child.parent_id==folder.id and child.name==name then matches[#matches+1]=child end end
    if #matches>1 or (#matches==1 and matches[1].is_folder) then return nil,err('ambiguous_metadata','Native metadata filename is ambiguous or is a folder') end
    return {folder=folder,metadata=matches[1],parent_entries=entries}
end
function Sync:pull(entry)
    local found,e=self:locate(entry); if not found then return nil,e end
    local metadata=found.metadata
    if not metadata then return {folder=found.folder,book_stamp=stamp(entry)} end
    -- Obtain a guard BEFORE reading. A stale guard makes an update fail safely.
    if self.provider.stat then
        local current,se=self.provider:stat(metadata.id); if not current then return nil,se or err('not_found','Metadata disappeared') end
        if current.id~=metadata.id or current.name~=metadata.name or current.parent_id~=metadata.parent_id then return nil,err('metadata_moved','Metadata identity changed') end
        metadata=current
    end
    local lua,re=self.provider:read(metadata,2*1024*1024); if not lua then return nil,re end
    if self.provider.stat then
        local after,se=self.provider:stat(metadata.id);if not after then return nil,se or err('not_found','Metadata disappeared') end
        if after.name~=metadata.name or after.parent_id~=metadata.parent_id or not sameMetadataVersion(metadata,after) then
            return nil,err('metadata_changed','Cloud progress changed while it was being read')
        end
    end
    local data,de=self.sdr.decode(lua); if not data then return nil,err('invalid_remote_metadata',de) end
    return {data=data,lua=lua,stamp=stamp(metadata),metadata=metadata,folder=found.folder,book_stamp=stamp(entry)}
end
local function conflict(pending,remote,reason)
    return {action='conflict',conflict={reason=reason or 'both_changed',local_lua=pending.lua,remote_lua=remote.lua,
        base_lua=pending.base_lua,local_time=pending.position_changed_at,local_revision=pending.revision,
        stamp=copy(remote.stamp),book_stamp=copy(remote.book_stamp)},stamp=remote.stamp,book_stamp=remote.book_stamp}
end
function Sync:push(entry,pending,intent,guard)
    if self:isOffline() then return nil,err('offline','Sync is offline') end
    if not pending or not pending.entry or pending.entry.id~=entry.id then return nil,err('invalid_pending','Pending document identity mismatch') end
    local local_data,write_lua=nil,pending.lua
    if pending.status_only then
        if pending.chapter_status~='complete' and pending.chapter_status~='reading' then return nil,err('invalid_pending','Invalid chapter status') end
    else
        local le; local_data,le=self.sdr.decode(write_lua)
        if not local_data then return nil,err('invalid_pending',le) end
    end
    local base_data
    if pending.base_lua then local be; base_data,be=self.sdr.decode(pending.base_lua); if not base_data then return nil,err('invalid_base',be) end end
    local current=entry
    if self.provider.stat then local se; current,se=self.provider:stat(entry.id); if not current then return nil,se or err('not_found','Source document disappeared') end end
    if pending.chapter_status and not self.provider.stat then return nil,err('unguarded_write','Source chapter could not be verified') end
    if pending.chapter_status and (current.id~=entry.id or current.name~=pending.entry.name or current.parent_id~=pending.entry.parent_id) then
        return conflict(pending,{book_stamp=stamp(current)},'book_changed')
    end
    local remote,re=self:pull(current)
    if not remote and intent and re and re.code=='metadata_changed'then remote,re=self:pull(current)end
    if not remote then return nil,re end
    if current.id~=entry.id or current.name~=pending.entry.name or current.parent_id~=pending.entry.parent_id then return conflict(pending,remote,'book_changed') end
    local action
    if intent then
        if not self.provider.stat or not self.sdr.sameBook(intent.book_stamp,current) then return conflict(pending,remote,'book_changed') end
        if not guard or not guard() then return conflict(pending,remote,'changed_during_resolution') end
        if intent.choice=='local' and remote.lua==intent.local_lua then
            remote.action='same';return remote
        end
        if remote.lua~=intent.remote_lua or (remote.metadata and (not intent.stamp
            or not remote.stamp or not remote.stamp.etag or not sameMetadataVersion(intent.stamp,remote.stamp)))
            or (not remote.metadata and intent.stamp) then return conflict(pending,remote,'changed_during_resolution') end
        if intent.choice=='remote' then remote.action='deferred';return remote end
        if intent.choice~='local' then return nil,err('invalid_choice','Choose local or remote') end
        write_lua=intent.local_lua
        local_data=self.sdr.decode(write_lua)
        if not local_data then return nil,err('invalid_pending','Could not validate saved local progress') end
        action='push'
    elseif (pending.chapter_status and not self.sdr.sameBook(pending.book_stamp,current))
        or changed(self.sdr,pending.book_stamp,current) or changed(self.sdr,pending.base_book_stamp,current) then
        return conflict(pending,remote,'book_changed')
    elseif pending.status_only then
        local remote_status=self.sdr.summary(remote.data).status
        local base_status=self.sdr.summary(base_data).status
        if remote_status==pending.chapter_status or (not remote.data and pending.chapter_status=='reading') then
            remote.action='same'; return remote
        end
        local_data=self.sdr.setReadingStatus(copy(remote.data) or {},pending.chapter_status,pending.chapter_status_date)
        local le; write_lua,le=self.sdr.encode(local_data)
        if not write_lua then return nil,err('invalid_local_metadata',le) end
        if base_data and remote_status~=base_status then
            local local_change=copy(pending)
            local_change.lua=write_lua
            return conflict(local_change,remote)
        end
        action='push'
    else
        action=self.sdr.decide(base_data,local_data,remote.data)
    end
    if action=='conflict' then return conflict(pending,remote) end
    if action=='same' or action=='pull' then
        remote.action=action; return remote
    end
    if remote.metadata and not remote.stamp.etag then return nil,err('unguarded_write','Provider supplied no conditional-write token; remote metadata was preserved') end
    local folder=remote.folder
    if not folder then
        if intent and not guard() then return conflict(pending,remote,'changed_during_resolution') end
        local me; folder,me=self.provider:mkdir(entry.parent_id,self.sdr.sidecarName(entry.name)); if not folder then return nil,me end
        -- A concurrent creator may have made another native folder. Never choose one.
        local verified,ve=self:locate(entry); if not verified then return nil,ve end
        if not verified.folder or verified.folder.id~=folder.id or verified.metadata then return nil,err('concurrent_creation','Remote sidecar changed during creation; retry from fresh state') end
    end
    local path,pe=self.storage:writeTemp(write_lua); if not path then return nil,pe end
    if intent then
        local latest,se=self.provider:stat(entry.id)
        local same=latest and self.sdr.sameBook(intent.book_stamp,latest)
            and latest.name==current.name and latest.parent_id==current.parent_id
        if not same or not guard() then
            if self.storage.remove then self.storage:remove(path) end
            if not latest then return nil,se end
            return conflict(pending,remote,same and 'changed_during_resolution' or 'book_changed')
        end
    end
    local ok,uploaded,ue=pcall(self.provider.upload,self.provider,folder.id,self.sdr.metadataName(entry.name),path,remote.metadata and remote.metadata.id,remote.stamp and remote.stamp.etag)
    if self.storage.remove then self.storage:remove(path) end
    if not ok then return nil,err('upload_failed',tostring(uploaded)) end
    if not uploaded then
        if intent and ue and tonumber(ue.status)==412 then
            local fresh,fe=self:pull(current)
            if not fresh then return nil,fe end
            return conflict(pending,fresh,'changed_during_resolution')
        end
        return nil,ue
    end
    -- Name creation cannot be made unique atomically by every provider. Detect
    -- duplicates after creating; all files remain intact for manual resolution.
    if not remote.metadata then
        local verified,ve=self:locate(entry); if not verified then return nil,ve end
        if not verified.metadata or verified.metadata.id~=uploaded.id then return nil,err('concurrent_creation','Metadata changed during creation; all versions were preserved') end
    end
    return {action='pushed',data=local_data,lua=write_lua,stamp=stamp(uploaded),book_stamp=stamp(current)}
end
-- Call in the parent, then atomically persist state. A later snapshot is retained.
function Sync:commit(entry,pending,result)
    if result.action=='conflict' then
        local saved=copy(result.conflict); local latest=self.state.pending[entry.id]
        if latest then saved.local_revision=latest.revision;saved.local_time=latest.position_changed_at end
        if latest and latest.lua then saved.local_lua=latest.lua
        elseif latest and latest.status_only and saved.remote_lua then
            local remote=self.sdr.decode(saved.remote_lua)
            if remote then
                saved.local_lua=self.sdr.encode(self.sdr.setReadingStatus(remote,latest.chapter_status,latest.chapter_status_date))
            end
        end
        self.state.conflicts[entry.id]=saved; return result
    end
    if result.action~='pushed' and result.action~='same' and result.action~='pull' then return nil,err('invalid_result','Unknown synchronization result') end
    local base={lua=result.lua,stamp=copy(result.stamp),book_stamp=copy(result.book_stamp),
        position_changed_at=result.action~='pull' and pending and pending.position_changed_at or nil}
    self.state.bases[entry.id]=base; self.state.conflicts[entry.id]=nil
    local latest=self.state.pending[entry.id]
    if latest and pending and latest.revision==pending.revision then self.state.pending[entry.id]=nil
    elseif latest and result.action~='pull' then latest.base_lua=base.lua; latest.base_stamp=copy(base.stamp); latest.base_book_stamp=copy(base.book_stamp) end
    return result
end
function Sync:resolve(id,choice)
    local saved=self.state.conflicts[id]; if not saved then return nil,err('no_conflict','No saved conflict') end
    local pending=self.state.pending[id]
    if choice=='local' then
        if not pending then return nil,err('no_pending','Local snapshot is missing') end
        pending.base_lua=saved.remote_lua; pending.base_stamp=copy(saved.stamp); pending.base_book_stamp=copy(saved.book_stamp)
        pending.book_stamp=copy(saved.book_stamp)
        self.state.revision=(self.state.revision or 0)+1; pending.revision=self.state.revision
        self.state.conflicts[id]=nil; return pending
    elseif choice=='remote' then
        local data,e
        if saved.remote_lua then data,e=self.sdr.decode(saved.remote_lua); if not data then return nil,err('invalid_conflict',e) end end
        self.state.bases[id]={lua=saved.remote_lua,stamp=copy(saved.stamp),book_stamp=copy(saved.book_stamp)}
        self.state.pending[id]=nil; self.state.conflicts[id]=nil
        if self.state.chapter_marks then self.state.chapter_marks[id]=nil end
        return {data=data,lua=saved.remote_lua,stamp=copy(saved.stamp),book_stamp=copy(saved.book_stamp),action='pull'}
    end
    return nil,err('invalid_choice','Choose local or remote')
end
-- Selection only: the adapter schedules the callback through its shared Jobs.
function Sync:lazy(entries,callback)
    for _,entry in ipairs(entries) do if not entry.is_folder and not entry.name:match('%.sdr$') then callback(entry) end end
end
return Sync
