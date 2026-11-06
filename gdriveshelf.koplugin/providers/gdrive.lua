-- Google Drive boundary: v3 browsing; v2 conditional updates with real ETags. Credentials and untrusted response bodies are never logged.
local Provider = {}
Provider.__index = Provider
local API = 'https://www.googleapis.com/drive/v3/files'
local UPLOAD = 'https://www.googleapis.com/upload/drive/v3/files'
local API_V2 = 'https://www.googleapis.com/drive/v2/files'
local UPLOAD_V2 = 'https://www.googleapis.com/upload/drive/v2/files'
local TOKEN = 'https://oauth2.googleapis.com/token'
local FIELDS = 'id,name,parents,mimeType,size,createdTime,modifiedTime,md5Checksum,version,driveId,trashed'
local FIELDS_V2 = 'id,title,parents(id),mimeType,fileSize,modifiedDate,md5Checksum,version,etag,driveId,labels(trashed)'
local JSON_LIMIT = 4 * 1024 * 1024
local function err(code, message, status) return {code=code,message=message,status=status} end
local function escape(s) return (tostring(s):gsub('[^%w%-._~]',function(c) return string.format('%%%02X',c:byte()) end)) end
local function query(t)
    local keys, out = {}, {}
    for k in pairs(t) do keys[#keys+1]=k end; table.sort(keys)
    for _,k in ipairs(keys) do out[#out+1]=escape(k)..'='..escape(t[k]) end
    return table.concat(out,'&')
end
local function quote(s) return "'" .. tostring(s):gsub('\\','\\\\'):gsub("'","\\'") .. "'" end
local function header(h, key)
    for k,v in pairs(h or {}) do if k:lower()==key:lower() then return v end end
end
local function byte_limit(n) return type(n)=='number' and n>=0 and n==n and n<=9007199254740991 end
local function valid(s) return type(s)=='string' and #s>0 and not s:find('[%z\r\n]') end
local function array(t)
    if type(t)~='table'then return false end
    local n=#t;for k in pairs(t)do if type(k)~='number'or k<1 or k>n or k~=math.floor(k)then return false end end
    for i=1,n do if t[i]==nil then return false end end;return true
end
local function normalize(f, parent, headers)
    if type(f)~='table' or not valid(f.id) or type(f.name or f.title)~='string' then return nil,err('invalid_response','Invalid Drive file metadata') end
    local size = tonumber(f.size or f.fileSize)
    if size and (size<0 or size~=size or size>9007199254740991) then return nil,err('invalid_response','Invalid file size') end
    local first_parent=type(f.parents)=='table' and f.parents[1]
    if type(first_parent)=='table' then first_parent=first_parent.id end
    return {id=f.id,name=f.name or f.title,parent_id=first_parent or parent,
        is_folder=f.mimeType=='application/vnd.google-apps.folder',size=size,created_time=f.createdTime or f.createdDate,modified_time=f.modifiedTime or f.modifiedDate,
        checksum=f.md5Checksum,version=f.version,etag=header(headers,'etag') or f.etag,mime_type=f.mimeType,
        drive_id=f.driveId,trashed=f.trashed==true or(type(f.labels)=='table'and f.labels.trashed==true)}
end

-- LuaSec verifies the chain, but its HTTPS helper does not verify hostnames.
-- Wrap its TLS connection and check SAN before LuaSocket sends any HTTP headers.
local function default_transport(ca_file)
    local http = require('socket.http')
    local https = require('ssl.https')
    local socketutil = require('socketutil')
    local ltn12 = require('ltn12')
    return function(r)
        local host = r.url:match('^https://([%w.-]+)/')
        if host~='www.googleapis.com' and host~='oauth2.googleapis.com' then return nil,'untrusted endpoint' end
        if http.PROXY then return nil,'proxy unsupported' end
        local old_b, old_t = socketutil.block_timeout, socketutil.total_timeout
        socketutil:set_timeout(15,120)
        local make_tls = https.tcp{protocol='any',verify='peer',cafile=ca_file,
            options={'all','no_sslv2','no_sslv3','no_tlsv1','no_tlsv1_1'}}
        local connection
        local function create()
            connection = make_tls()
            local connect = connection.connect
            function connection:connect(name, port)
                if name~=host or tonumber(port)~=443 then return nil,'untrusted endpoint' end
                local ok = connect(self,name,port)
                if not ok then return nil,'TLS handshake failed' end
                local cert = self:getpeercertificate()
                local exts = cert and cert:extensions()
                local san = exts and exts['2.5.29.17']
                for _,dns in ipairs(san and san.dNSName or {}) do
                    dns=dns:lower()
                    if dns==host or (dns:sub(1,2)=='*.' and host:match('^[^.]+%.(.+)$')==dns:sub(3)) then return 1 end
                end
                self:close(); return nil,'TLS hostname mismatch'
            end
            return connection
        end
        local source=r.source or (r.body and ltn12.source.string(r.body))
        local started=os.time()
        if source then
            local original_source=source
            source=function()
                if os.time()-started>120 then return nil,'transfer timeout' end
                return original_source()
            end
        end
        local function sink(chunk, why)
            if os.time()-started>120 then return nil,'transfer timeout' end
            return r.sink(chunk,why)
        end
        -- Use LuaSocket's public low-level API so status is known before media
        -- enters the file sink. Error/redirect bodies are never downloaded.
        local ok, status, headers = pcall(function()
            local h=http.open(host,443,create)
            local headers={host=host,connection='close',['user-agent']=socketutil.USER_AGENT or 'GDriveShelf'}
            for k,v in pairs(r.headers) do headers[k:lower()]=v end
            h:sendrequestline(r.method,r.url:match('^https://[^/]+(/.*)$'))
            h:sendheaders(headers)
            if source then h:sendbody(headers,source) end
            local status=h:receivestatusline()
            local interim=0
            while status and status>=100 and status<200 do
                interim=interim+1; if interim>4 then error('too many interim responses') end
                h:receiveheaders(); status=h:receivestatusline()
            end
            if not status then error('invalid HTTP status') end
            local response_headers=h:receiveheaders()
            if r.validate_headers and not r.validate_headers(status,response_headers)then h:close();return status,response_headers end
            if status>=200 and status<300 and status~=204 then h:receivebody(response_headers,sink) end
            h:close()
            return status,response_headers
        end)
        if connection then pcall(function() connection:close() end) end
        socketutil:set_timeout(old_b,old_t)
        if not ok then return nil,'TLS or network request failed' end
        return tonumber(status),headers,nil
    end
end

function Provider.new(options)
    options=options or {}
    local credentials={}; for k,v in pairs(options.credentials or {}) do credentials[k]=v end
    local self=setmetatable({credentials=credentials,json=options.json or require('json'),ca_file=options.ca_file},Provider)
    if not self.ca_file then
        local here=debug.getinfo(1,'S').source:sub(2):match('^(.*)/providers/gdrive%.lua$')
        self.ca_file=(here or 'plugins/gdriveshelf.koplugin')..'/cacert.pem'
    end
    -- Lazy network dependencies keep pure consumers testable outside KOReader.
    self.transport=options.transport or function(r)
        self.transport=default_transport(self.ca_file); return self.transport(r)
    end
    return self
end

function Provider:_decode(body)
    if type(body)~='string' or #body>JSON_LIMIT then return nil,err('invalid_response','Invalid or oversized JSON response') end
    local ok, value=pcall(self.json.decode,body)
    if not ok or type(value)~='table' then return nil,err('invalid_response','Invalid JSON response') end
    return value
end

-- Every response goes through a bounded sink, including API error responses.
-- transport(r) -> status, headers, body OR nil, error. A streaming transport
-- calls r.sink(chunk), returns body=nil and must stop if the sink rejects data.
function Provider:_send(r, limit, consumer)
    local chunks,total,sink_error={},0,nil
    local started=os.time()
    local operation=r.operation or (r.url==TOKEN and 'auth') or(r.url:find('alt=media',1,true)and(consumer and 'download'or 'read'))or(r.method=='POST'and 'mkdir')or(r.method=='PUT'and 'upload')or(r.url:find('/files?',1,true)and 'list')or(r.url:find('/changes?',1,true)and 'list')or 'stat'
    local response_status
    local function finish(value,e)
        if self.trace then pcall(self.trace,'request',{operation=operation,status=response_status,bytes=total,duration=math.max(0,os.time()-started),error=e and e.code})end
        return value,e
    end
    r.redirect=false
    r.headers=r.headers or {}; r.headers['Accept-Encoding']='identity'
    r.sink=function(chunk, why)
        if not chunk then if why then sink_error=err('network','Incomplete network response') end; return sink_error and nil or 1 end
        if r.validate_headers and not r._headers_validated then sink_error=err('range','Range response headers were not validated');return nil,'invalid range headers'end
        total=total+#chunk
        if total>limit then sink_error=err('too_large','Response exceeds the size limit'); return nil,'response too large' end
        if consumer then
            if not consumer(chunk) then sink_error=err('io','Cannot write download'); return nil,'file write failed' end
        else chunks[#chunks+1]=chunk end
        return 1
    end
    local ok,status,headers,body=pcall(self.transport,r)
    if not ok or not tonumber(status) then return finish(nil,sink_error or err('network','Network request failed')) end
    status=tonumber(status)
    response_status=status
    if status>=300 and status<400 then return finish(nil,err('redirect','Unexpected redirect refused',status)) end
    if status<200 or status>=300 then
        local code=status==412 and 'conflict' or (status==401 and 'unauthorized' or (status==404 and 'not_found' or 'api'))
        local e=err(code,status==412 and 'Remote file changed; preserve both versions' or ('Drive request failed (HTTP '..status..')'),status)
        local delay=tonumber(header(headers,'retry-after')or '')
        if delay and delay>=0 and delay<math.huge then e.retry_after=math.min(86400,math.ceil(delay))end
        return finish(nil,e)
    end
    if r.validate_headers and not r.validate_headers(status,headers or {})then return finish(nil,err('range','Partial download is unavailable or invalid',status))end
    if type(body)=='string' and not sink_error then r.sink(body) end
    if sink_error then return finish(nil,sink_error) end
    return finish({body=consumer and nil or table.concat(chunks),headers=headers or {},size=total})
end

function Provider:_refresh()
    local c=self.credentials
    if not valid(c.refresh_token) or not valid(c.client_id) then return nil,err('auth','Import authorization credentials again') end
    local form={grant_type='refresh_token',refresh_token=c.refresh_token,client_id=c.client_id}
    if c.client_secret then form.client_secret=c.client_secret end
    local body=query(form)
    local result,e=self:_send({url=TOKEN,method='POST',body=body,headers={['Content-Type']='application/x-www-form-urlencoded',['Content-Length']=tostring(#body)}},JSON_LIMIT)
    if not result then
        if e and(e.status==400 or e.status==401 or e.status==403)then return nil,err('auth','Import authorization credentials again',e.status)end
        return nil,e
    end
    local data; data,e=self:_decode(result.body)
    if not data or not valid(data.access_token) then return nil,e or err('auth','Token refresh failed') end
    c.access_token=data.access_token
    if valid(data.refresh_token) then c.refresh_token=data.refresh_token end
    c.expires_at=os.time()+(tonumber(data.expires_in) or 3600)
    return true
end

function Provider:_request(r, limit, consumer, reset)
    local c=self.credentials
    if not valid(c.access_token) or (tonumber(c.expires_at) and c.expires_at<=os.time()+30) then
        local ok,e=self:_refresh(); if not ok then return nil,e end
    end
    r.headers=r.headers or {}; r.headers.Authorization='Bearer '..c.access_token
    local result,e=self:_send(r,limit or JSON_LIMIT,consumer)
    if not result and e.status==401 then
        local ok; ok,e=self:_refresh(); if not ok then return nil,e end
        if reset then local reset_ok=reset(); if not reset_ok then return nil,err('io','Cannot restart transfer') end end
        r.headers.Authorization='Bearer '..c.access_token
        result,e=self:_send(r,limit or JSON_LIMIT,consumer)
    end
    return result,e
end

function Provider:list(parent_id)
    if not valid(parent_id) then return nil,err('invalid_argument','A parent ID is required') end
    local all,seen,token={}, {},nil
    repeat
        local args={q=quote(parent_id)..' in parents and trashed = false',fields='nextPageToken,incompleteSearch,files('..FIELDS..')',pageSize=1000,supportsAllDrives='true',includeItemsFromAllDrives='true'}
        if token then args.pageToken=token end
        local response,e=self:_request({url=API..'?'..query(args),method='GET'})
        if not response then return nil,e end
        local page; page,e=self:_decode(response.body); if not page then return nil,e end
        if not array(page.files) or page.incompleteSearch then return nil,err('invalid_response','Incomplete Drive file listing') end
        for _,file in ipairs(page.files) do
            local entry; entry,e=normalize(file,parent_id); if not entry then return nil,e end
            all[#all+1]=entry
            if #all>100000 then return nil,err('too_large','Folder contains too many entries') end
        end
        token=page.nextPageToken
        if token~=nil and (not valid(token) or seen[token]) then return nil,err('pagination','Invalid or repeated page token') end
        if token then seen[token]=true end
    until not token
    return all
end

-- The caller only sees buckets once every page succeeds, including empty ones.
function Provider:listParents(ids,scope)
    if not array(ids)or #ids<1 or #ids>20 then return nil,err('invalid_argument','Between one and twenty parents are required')end
    if scope~=nil and(type(scope)~='table'or(scope.drive_id~=nil and not valid(scope.drive_id)))then return nil,err('invalid_argument','Invalid grouped listing scope')end
    local buckets,terms={},{}
    for _,id in ipairs(ids)do
        if not valid(id)or buckets[id]then return nil,err('invalid_argument','Invalid or repeated parent ID')end
        buckets[id]={};terms[#terms+1]=quote(id)..' in parents'
    end
    local token,seen,total=nil,{},0
    repeat
        local args={q='('..table.concat(terms,' or ')..') and trashed = false',fields='nextPageToken,incompleteSearch,files('..FIELDS..')',pageSize=1000,supportsAllDrives='true',includeItemsFromAllDrives='true'}
        if scope and scope.drive_id then args.corpora='drive';args.driveId=scope.drive_id end
        if token then args.pageToken=token end
        local url=API..'?'..query(args)
        if #url>4096 then return nil,err('invalid_argument','Grouped listing URL exceeds limit')end
        local response,e=self:_request({url=url,method='GET',operation='list'});if not response then return nil,e end
        local page;page,e=self:_decode(response.body);if not page then return nil,e end
        if not array(page.files)or page.incompleteSearch then return nil,err('invalid_response','Incomplete Drive file listing')end
        for _,file in ipairs(page.files)do
            local entry;entry,e=normalize(file);if not entry then return nil,e end
            local bucket=buckets[entry.parent_id]
            if not bucket then return nil,err('invalid_response','Grouped listing supplied an unexpected parent')end
            total=total+1;if total>100000 then return nil,err('too_large','Grouped listing contains too many entries')end
            bucket[#bucket+1]=entry
        end
        token=page.nextPageToken
        if token~=nil and(not valid(token)or seen[token])then return nil,err('pagination','Invalid or repeated page token')end
        if token then seen[token]=true end
    until not token
    return buckets
end

local function changeScope(scope)
    if scope~=nil and type(scope)~='table'then return nil,err('invalid_argument','Invalid change scope')end
    if scope and scope.drive_id~=nil and not valid(scope.drive_id)then return nil,err('invalid_argument','Invalid shared drive ID')end
    return {supportsAllDrives='true',driveId=scope and scope.drive_id}
end
function Provider:getStartToken(scope)
    local args,e=changeScope(scope);if not args then return nil,e end
    args.fields='startPageToken'
    local response;response,e=self:_request({url='https://www.googleapis.com/drive/v3/changes/startPageToken?'..query(args),method='GET',operation='stat'});if not response then return nil,e end
    local page;page,e=self:_decode(response.body);if not page then return nil,e end
    if not valid(page.startPageToken)then return nil,err('invalid_response','Drive supplied no start token')end
    return page.startPageToken
end
function Provider:changes(token,scope)
    if not valid(token)then return nil,err('invalid_argument','A change token is required')end
    local args,e=changeScope(scope);if not args then return nil,e end
    args.pageToken=token;args.pageSize=1000;args.spaces='drive';args.includeRemoved='true';args.includeItemsFromAllDrives='true';args.includeCorpusRemovals='true'
    args.fields='nextPageToken,newStartPageToken,changes(fileId,removed,changeType,driveId,file('..FIELDS..'))'
    local response;response,e=self:_request({url='https://www.googleapis.com/drive/v3/changes?'..query(args),method='GET',operation='list'});if not response then return nil,e end
    local page;page,e=self:_decode(response.body);if not page then return nil,e end
    if not array(page.changes)or(not valid(page.nextPageToken)and not valid(page.newStartPageToken))or(page.newStartPageToken~=nil and not valid(page.newStartPageToken))then return nil,err('invalid_response','Invalid change page checkpoint')end
    if page.nextPageToken~=nil and(not valid(page.nextPageToken)or page.nextPageToken==token)then return nil,err('pagination','Invalid or repeated change token')end
    local out={changes={},next_page_token=page.nextPageToken,new_start_token=page.newStartPageToken}
    for _,change in ipairs(page.changes)do
        if change.changeType~='drive'then
            if not valid(change.fileId)then return nil,err('invalid_response','Change has no file identity')end
            local item={file_id=change.fileId,removed=change.removed==true}
            if not item.removed then
                item.entry,e=normalize(change.file)
                if not item.entry or item.entry.id~=item.file_id then return nil,e or err('invalid_response','Changed file identity mismatch')end
            end
            out.changes[#out.changes+1]=item
        else out.scope_changed=true end
    end
    return out
end

function Provider:stat(id)
    if not valid(id) then return nil,err('invalid_argument','A file ID is required') end
    local result,e=self:_request({url=API..'/'..escape(id)..'?'..query{fields=FIELDS,supportsAllDrives='true'},method='GET'})
    if not result then return nil,e end
    local data; data,e=self:_decode(result.body); if not data then return nil,e end
    local entry; entry,e=normalize(data,nil,result.headers); if not entry then return nil,e end
    if not entry.etag then
        -- v3 removed ETags. Obtain the metadata and its conditional token in one
        -- v2 snapshot; never attach a newer guard to the older v3 snapshot.
        result,e=self:_request({url=API_V2..'/'..escape(id)..'?'..query{fields=FIELDS_V2,supportsAllDrives='true',updateViewedDate='false'},method='GET'})
        if not result then return nil,e end
        data,e=self:_decode(result.body); if not data then return nil,e end
        local previous=entry
        entry,e=normalize(data,nil,result.headers); if not entry then return nil,e end
        entry.drive_id=entry.drive_id or previous.drive_id
        if not valid(entry.etag) then return nil,err('invalid_response','Drive supplied no conditional-write token') end
    end
    return entry
end

function Provider:read(entry,max_bytes)
    if type(entry)~='table' or not valid(entry.id) or not byte_limit(max_bytes) then return nil,err('invalid_argument','A file and a byte limit are required') end
    if entry.size and entry.size>max_bytes then return nil,err('too_large','File exceeds the size limit') end
    local result,e=self:_request({url=API..'/'..escape(entry.id)..'?alt=media&supportsAllDrives=true',method='GET'},max_bytes)
    if not result then return nil,e end
    if entry.size and result.size~=entry.size then return nil,err('size_mismatch','Downloaded size differs from metadata') end
    return result.body
end

-- Streaming MD5 uses LuaJIT's built-in bit library, with at most one file chunk
-- resident at a time. No shell invocation or external checksum executable.
local function file_md5(path)
    local bit=require('bit'); local band,bor,bxor,bnot,rol=bit.band,bit.bor,bit.bxor,bit.bnot,bit.rol
    local shifts={7,12,17,22,5,9,14,20,4,11,16,23,6,10,15,21}
    local constants={}; for i=1,64 do constants[i]=bit.tobit(math.floor(math.abs(math.sin(i))*4294967296)) end
    local a,b,c,d=0x67452301,0xefcdab89,0x98badcfe,0x10325476
    local function block(s)
        local words={}
        for i=0,15 do local x,y,z,w=s:byte(i*4+1,i*4+4); words[i]=x+y*256+z*65536+w*16777216 end
        local aa,bb,cc,dd=a,b,c,d
        for i=0,63 do
            local f,g,round
            if i<16 then f=bor(band(b,c),band(bnot(b),d)); g=i; round=0
            elseif i<32 then f=bor(band(d,b),band(bnot(d),c)); g=(5*i+1)%16; round=1
            elseif i<48 then f=bxor(b,c,d); g=(3*i+5)%16; round=2
            else f=bxor(c,bor(b,bnot(d))); g=(7*i)%16; round=3 end
            local next_b=bit.tobit(b+rol(bit.tobit(a+f+constants[i+1]+words[g]),shifts[round*4+i%4+1]))
            a,d,c,b=d,c,b,next_b
        end
        a,b,c,d=bit.tobit(a+aa),bit.tobit(b+bb),bit.tobit(c+cc),bit.tobit(d+dd)
    end
    local f=io.open(path,'rb'); if not f then return nil end
    local pending,total='',0
    while true do
        local chunk=f:read(65536); if not chunk then break end
        total=total+#chunk; pending=pending..chunk
        local upto=#pending-#pending%64
        for offset=1,upto,64 do block(pending:sub(offset,offset+63)) end
        pending=pending:sub(upto+1)
    end
    f:close()
    local function le(n) return string.char(band(n,255),band(bit.rshift(n,8),255),band(bit.rshift(n,16),255),band(bit.rshift(n,24),255)) end
    pending=pending..'\128'..string.rep('\0',(55-#pending)%64)..le((total*8)%4294967296)..le(math.floor(total/536870912))
    for offset=1,#pending,64 do block(pending:sub(offset,offset+63)) end
    return ((le(a)..le(b)..le(c)..le(d)):gsub('.',function(x) return string.format('%02x',x:byte()) end))
end

-- Strict partial media reads. Validation happens before the streaming body.
function Provider:range(entry,first,last,max_bytes)
 local size=entry and tonumber(entry.size)
 if not size or not byte_limit(first)or not byte_limit(last)or first~=math.floor(first)or last~=math.floor(last)or first>last or last>=size or (first==0 and last==size-1)or not byte_limit(max_bytes)or last-first+1>max_bytes then
  return nil,err('range','Invalid or complete-file range refused')
 end
 local r={url=API..'/'..escape(entry.id)..'?alt=media&supportsAllDrives=true',method='GET',operation='range',headers={Range='bytes='..first..'-'..last}}
 r.validate_headers=function(status,headers)
  local a,b,total=tostring(header(headers,'content-range')or ''):match('^bytes (%d+)%-(%d+)/(%d+)$')
  local valid=status==206 and tonumber(a)==first and tonumber(b)==last and tonumber(total)==size and (not header(headers,'content-encoding')or header(headers,'content-encoding')=='identity')
  r._headers_validated=valid;return valid
 end
 local result,e=self:_request(r,last-first+1)
 if not result then return nil,e end
 if result.size~=last-first+1 then return nil,err('range','Incomplete partial response')end
 return result.body
end
function Provider:download(entry,path,max_bytes,progress)
    if type(entry)~='table' or not valid(entry.id) or not valid(path) then return nil,err('invalid_argument','A file and destination are required') end
    max_bytes=max_bytes or entry.size
    if not byte_limit(max_bytes) then return nil,err('invalid_argument','A download byte limit is required') end
    if entry.size and entry.size>max_bytes then return nil,err('too_large','File exceeds the size limit') end
    local part=path..'.part'
    local f=io.open(part,'wb'); if not f then return nil,err('io','Cannot create partial download') end
    local received=0
    local function reset() received=0;f:close(); f=io.open(part,'wb'); return f~=nil end
    local result,e=self:_request({url=API..'/'..escape(entry.id)..'?alt=media&supportsAllDrives=true',method='GET'},max_bytes,
        function(chunk) received=received+#chunk;if progress then progress{received=received,total=entry.size,stage='download'}end;return f:write(chunk) end, reset)
    local closed=f and f:close()
    if result and not closed then result=nil; e=err('io','Cannot flush download') end
    if result and entry.size and result.size~=entry.size then result=nil; e=err('size_mismatch','Downloaded size differs from metadata') end
    if result and entry.checksum then
        local digest=file_md5(part)
        if not digest or digest~=entry.checksum:lower() then result=nil; e=err('checksum_mismatch','Downloaded checksum differs from metadata') end
    end
    if not result then os.remove(part); return nil,e end
    if not os.rename(part,path) then os.remove(part); return nil,err('io','Cannot publish completed download') end
    if progress then progress{received=result.size,total=entry.size,stage='complete'}end
    return {path=path,size=result.size,checksum=entry.checksum,version=entry.version}
end

function Provider:mkdir(parent,name)
    if not valid(parent) or not valid(name) then return nil,err('invalid_argument','Folder parent and name are required') end
    local ok,body=pcall(self.json.encode,{name=name,parents={parent},mimeType='application/vnd.google-apps.folder'})
    if not ok then return nil,err('invalid_argument','Cannot encode folder metadata') end
    local result,e=self:_request({url=API..'?'..query{fields=FIELDS,supportsAllDrives='true'},method='POST',body=body,
        headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}})
    if not result then return nil,e end
    local data; data,e=self:_decode(result.body); if not data then return nil,e end
    return normalize(data,parent,result.headers)
end

function Provider:upload(parent,name,path,existing_id,etag)
    if existing_id and not etag then return nil,err('conflict','Cannot overwrite a remote file without its ETag') end
    if not valid(parent) or not valid(name) or not valid(path) or (existing_id and not valid(existing_id)) or (etag and not valid(etag)) then return nil,err('invalid_argument','Invalid upload parameters') end
    local f=io.open(path,'rb'); if not f then return nil,err('io','Cannot open upload file') end
    local size=f:seek('end'); f:seek('set',0)
    local metadata=existing_id and {title=name} or {name=name,parents={parent}}
    local ok,body=pcall(self.json.encode,metadata)
    if not ok then f:close(); return nil,err('invalid_argument','Cannot encode upload metadata') end
    -- Existing native SDR uploads are small; multipart still streams the source.
    local boundary='gdriveshelf_'..tostring(os.time())..'_'..tostring(math.random(1000000000))
    local prefix='--'..boundary..'\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'..body..'\r\n--'..boundary..'\r\nContent-Type: application/octet-stream\r\n\r\n'
    local suffix='\r\n--'..boundary..'--\r\n'
    local stage=0
    local function source()
        if stage==0 then stage=1; return prefix end
        if stage==1 then local chunk=f:read(65536); if chunk then return chunk end; stage=2 end
        if stage==2 then stage=3; return suffix end
    end
    local headers={['Content-Type']='multipart/related; boundary='..boundary,['Content-Length']=tostring(#prefix+size+#suffix)}
    if etag then headers['If-Match']=etag end
    local endpoint=existing_id and UPLOAD_V2 or UPLOAD
    local result,e=self:_request({url=endpoint..(existing_id and '/'..escape(existing_id) or '')..'?'..query{uploadType='multipart',fields=existing_id and FIELDS_V2 or FIELDS,supportsAllDrives='true'},
        method=existing_id and 'PUT' or 'POST',operation='upload',source=source,headers=headers},JSON_LIMIT,nil,function() stage=0; return f:seek('set',0)~=nil end)
    f:close()
    if not result then return nil,e end
    local data; data,e=self:_decode(result.body); if not data then return nil,e end
    return normalize(data,parent,result.headers)
end
return Provider
