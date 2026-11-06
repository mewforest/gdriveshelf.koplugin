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
function Sync:snapshot(entry,data)
    local lua,e=self.sdr.encode(data); if not lua then return nil,err('invalid_local_metadata',e) end
    local old=self.state.pending[entry.id]; local base=self.state.bases[entry.id] or {}
    self.state.next_pending_seq=(self.state.next_pending_seq or 0)+1
    self.state.revision=(self.state.revision or 0)+1
    local pending={entry=copy(entry),lua=lua,book_stamp=stamp(entry),seq=old and old.seq or self.state.next_pending_seq,revision=self.state.revision}
    if old then
        pending.base_lua=old.base_lua; pending.base_stamp=copy(old.base_stamp); pending.base_book_stamp=copy(old.base_book_stamp)
    else pending.base_lua=base.lua; pending.base_stamp=copy(base.stamp); pending.base_book_stamp=copy(base.book_stamp) end
    self.state.pending[entry.id]=pending
    if self.state.conflicts[entry.id] then self.state.conflicts[entry.id].local_lua=lua end
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
        if current.name~=metadata.name or current.parent_id~=metadata.parent_id then return nil,err('metadata_moved','Metadata identity changed') end
        metadata=current
    end
    local lua,re=self.provider:read(metadata,2*1024*1024); if not lua then return nil,re end
    local data,de=self.sdr.decode(lua); if not data then return nil,err('invalid_remote_metadata',de) end
    return {data=data,lua=lua,stamp=stamp(metadata),metadata=metadata,folder=found.folder,book_stamp=stamp(entry)}
end
local function conflict(pending,remote,reason)
    return {action='conflict',conflict={reason=reason or 'both_changed',local_lua=pending.lua,remote_lua=remote.lua,base_lua=pending.base_lua,stamp=copy(remote.stamp),book_stamp=copy(remote.book_stamp)},stamp=remote.stamp,book_stamp=remote.book_stamp}
end
function Sync:push(entry,pending)
    if self:isOffline() then return nil,err('offline','Sync is offline') end
    if not pending or not pending.entry or pending.entry.id~=entry.id then return nil,err('invalid_pending','Pending document identity mismatch') end
    local local_data,le=self.sdr.decode(pending.lua); if not local_data then return nil,err('invalid_pending',le) end
    local base_data
    if pending.base_lua then local be; base_data,be=self.sdr.decode(pending.base_lua); if not base_data then return nil,err('invalid_base',be) end end
    local current=entry
    if self.provider.stat then local se; current,se=self.provider:stat(entry.id); if not current then return nil,se or err('not_found','Source document disappeared') end end
    local remote,re=self:pull(current); if not remote then return nil,re end
    if current.name~=pending.entry.name or current.parent_id~=pending.entry.parent_id
        or changed(self.sdr,pending.book_stamp,stamp(current)) or changed(self.sdr,pending.base_book_stamp,stamp(current)) then return conflict(pending,remote,'book_changed') end
    local action=self.sdr.decide(base_data,local_data,remote.data)
    if action=='conflict' then return conflict(pending,remote) end
    if action=='same' or action=='pull' then
        remote.action=action; return remote
    end
    if remote.metadata and not remote.stamp.etag then return nil,err('unguarded_write','Provider supplied no conditional-write token; remote metadata was preserved') end
    local folder=remote.folder
    if not folder then
        local me; folder,me=self.provider:mkdir(entry.parent_id,self.sdr.sidecarName(entry.name)); if not folder then return nil,me end
        -- A concurrent creator may have made another native folder. Never choose one.
        local verified,ve=self:locate(entry); if not verified then return nil,ve end
        if not verified.folder or verified.folder.id~=folder.id or verified.metadata then return nil,err('concurrent_creation','Remote sidecar changed during creation; retry from fresh state') end
    end
    local path,pe=self.storage:writeTemp(pending.lua); if not path then return nil,pe end
    local ok,uploaded,ue=pcall(self.provider.upload,self.provider,folder.id,self.sdr.metadataName(entry.name),path,remote.metadata and remote.metadata.id,remote.stamp and remote.stamp.etag)
    if self.storage.remove then self.storage:remove(path) end
    if not ok then return nil,err('upload_failed',tostring(uploaded)) end
    if not uploaded then return nil,ue end
    -- Name creation cannot be made unique atomically by every provider. Detect
    -- duplicates after creating; all files remain intact for manual resolution.
    if not remote.metadata then
        local verified,ve=self:locate(entry); if not verified then return nil,ve end
        if not verified.metadata or verified.metadata.id~=uploaded.id then return nil,err('concurrent_creation','Metadata changed during creation; all versions were preserved') end
    end
    return {action='pushed',data=local_data,lua=pending.lua,stamp=stamp(uploaded),book_stamp=stamp(current)}
end
-- Call in the parent, then atomically persist state. A later snapshot is retained.
function Sync:commit(entry,pending,result)
    if result.action=='conflict' then
        local saved=copy(result.conflict); local latest=self.state.pending[entry.id]
        if latest then saved.local_lua=latest.lua end
        self.state.conflicts[entry.id]=saved; return result
    end
    if result.action~='pushed' and result.action~='same' and result.action~='pull' then return nil,err('invalid_result','Unknown synchronization result') end
    local base={lua=result.lua,stamp=copy(result.stamp),book_stamp=copy(result.book_stamp)}
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
        return {data=data,lua=saved.remote_lua,stamp=copy(saved.stamp),action='pull'}
    end
    return nil,err('invalid_choice','Choose local or remote')
end
-- Selection only: the adapter schedules the callback through its shared Jobs.
function Sync:lazy(entries,callback)
    for _,entry in ipairs(entries) do if not entry.is_folder and not entry.name:match('%.sdr$') then callback(entry) end end
end
return Sync
