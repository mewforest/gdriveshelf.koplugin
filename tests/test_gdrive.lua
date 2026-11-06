package.path = './gdriveshelf.koplugin/?.lua;' .. package.path
local ok, Provider = pcall(require, 'providers/gdrive')
assert(ok, 'Drive provider is not implemented: ' .. tostring(Provider))
local count = 0
local function test(name, fn) fn(); count = count + 1; print('ok ' .. name) end
local decoded = {
    page1 = {files={{id='a',name='one.cbz',parents={'p'},size='3',mimeType='application/zip',md5Checksum='abc',version='8'}},nextPageToken='middle'},
    page2 = {files={},nextPageToken='last'}, page3 = {files={{id='b',name='one.cbz',parents={'p'},size='4'}}},
    stat = {id='a',name='one.cbz',parents={'p'},size='3',version='8'},
    token = {access_token='new',expires_in=3600}, empty = {files={}},
    created = {id='new',name='folder',mimeType='application/vnd.google-apps.folder'},
}
local json = {decode=function(s) assert(decoded[s], 'unexpected JSON'); return decoded[s] end,
    encode=function(t) return t.mimeType and 'folder_metadata' or 'file_metadata' end}
local function provider(fn, credentials)
    return Provider.new{credentials=credentials or {access_token='old'}, transport=fn, json=json, ca_file='gdriveshelf.koplugin/cacert.pem'}
end
local function unquote(s) return (s:gsub('%%(%x%x)',function(x) return string.char(tonumber(x,16)) end)) end
local path = os.tmpname()
test('pagination preserves duplicates across empty pages and escapes parent queries', function()
    local n=0
    local p=provider(function(r)
        n=n+1; assert(r.redirect == false); assert(r.headers.Authorization=='Bearer old')
        assert(unquote(r.url):find("'a\\'b\\\\c' in parents",1,true));
        return 200,{},({'page1','page2','page3'})[n]
    end)
    local entries=assert(p:list("a'b\\c")); assert(#entries==2 and entries[2].id=='b' and entries[1].size==3 and entries[1].parent_id=='p'); assert(n==3)
end)
test('401 refresh uses new bearer and persists refreshed credentials',function()
    local n=0
    local p=provider(function(r)
        n=n+1
        if n==1 then return 401,{},'unauthorized' end
        if n==2 then assert(r.url=='https://oauth2.googleapis.com/token'); assert(r.body:find('refresh_token=refresh',1,true)); return 200,{},'token' end
        assert(r.headers.Authorization=='Bearer new'); return 200,{etag='"fixture"'},'stat'
    end,{access_token='old',refresh_token='refresh',client_id='client',client_secret='secret'})
    assert(p:stat('a').id=='a'); assert(p.credentials.access_token=='new' and p.credentials.refresh_token=='refresh')
end)
test('redirect cannot leak authorization',function()
    local n=0; local p=provider(function(r) n=n+1; return 302,{location='https://evil.test/'},'' end)
    local v,e=p:list('p'); assert(not v and e.code=='redirect' and n==1)
end)
test('read rejects oversized streamed body',function()
    local p=provider(function(r) assert(r.sink('ab')); local ok=r.sink('cdef'); assert(not ok); return nil,'sink failed' end)
    local v,e=p:read({id='a'},3); assert(not v and e.code=='too_large')
end)
test('download streams to disk and verifies size before publication',function()
    local p=provider(function(r) assert(r.sink('a')); assert(r.sink('bc')); return 200,{},nil end)
    local v=assert(p:download({id='a',size=3},path,3)); assert(v.size==3 and v.path==path)
    local f=assert(io.open(path,'rb')); assert(f:read('*a')=='abc'); f:close(); os.remove(path)
end)
test('short download removes partial and preserves existing file',function()
    local f=assert(io.open(path,'wb')); f:write('original'); f:close()
    local p=provider(function(r) r.sink('ab'); return 200,{},nil end)
    local v,e=p:download({id='a',size=3},path,9); assert(not v and e.code=='size_mismatch')
    f=assert(io.open(path,'rb')); assert(f:read('*a')=='original'); f:close(); os.remove(path)
    assert(not io.open(path..'.part','rb'))
end)
test('API errors stay structured without reflecting credential-bearing body',function()
    local p=provider(function() return 403,{},'access_token=private' end)
    local v,e=p:list('p'); assert(not v and e.status==403 and not e.message:find('private',1,true))
end)
test('malformed JSON and repeated page tokens fail safely',function()
    local p=provider(function() return 200,{},'bad' end); local v,e=p:list('p'); assert(not v and e.code=='invalid_response')
    p=provider(function() return 200,{},'page1' end); v,e=p:list('p'); assert(not v and e.code=='pagination')
end)
test('upload streams its file and sends conditional precondition',function()
    local f=assert(io.open(path,'wb')); f:write('abc'); f:close()
    local p=provider(function(r)
        assert(r.method=='PUT' and r.url:find('/upload/drive/v2/files/a?',1,true) and r.headers['If-Match']=='"old-etag"'); local chunks={}
        while true do local chunk=r.source(); if not chunk then break end; chunks[#chunks+1]=chunk end
        assert(table.concat(chunks):find('abc',1,true)); return 412,{},'do not expose'
    end)
    local v,e=p:upload('p','one.cbz',path,'a','"old-etag"'); assert(not v and e.code=='conflict' and e.status==412); os.remove(path)
end)
test('mkdir normalizes folder entries',function()
    local p=provider(function(r) assert(r.method=='POST' and r.body=='folder_metadata'); return 200,{},'created' end)
    local e=assert(p:mkdir('p','folder')); assert(e.id=='new' and e.is_folder and e.parent_id=='p')
end)
test('MD5 checksum rejects corruption and accepts the whole streamed file',function()
    local p=provider(function(r) r.sink('a'); r.sink('bc'); return 200,{},nil end)
    local v,e=p:download({id='a',size=3,checksum='ffffffffffffffffffffffffffffffff'},path,3)
    assert(not v and e.code=='checksum_mismatch' and not io.open(path..'.part','rb'))
    assert(p:download({id='a',size=3,checksum='900150983cd24fb0d6963f7d28e17f72'},path,3)); os.remove(path)
end)
test('existing cloud uploads fail closed without an ETag',function()
    local p=provider(function() error('must not issue an unguarded write') end)
    local v,e=p:upload('p','one.cbz','does-not-exist','a'); assert(not v and e.code=='conflict')
end)
test('unauthorized tiny media refreshes before interpreting its error body',function()
    local n=0
    local p=provider(function(r)
        n=n+1
        if n==1 then return 401,{},'a long unauthorized error' end
        if n==2 then return 200,{},'token' end
        return 200,{},'abc'
    end,{access_token='old',refresh_token='refresh',client_id='client'})
    local v,e=p:read({id='a',size=3},3); assert(v=='abc', e and e.code)
end)
test('default TLS transport rejects hostname mismatch before sending bearer headers',function()
    local names={'socket.http','ssl.https','socketutil','ltn12'}
    local saved={}; for _,name in ipairs(names) do saved[name]=package.loaded[name]; package.loaded[name]=nil end
    local dns='attacker.test'; local sent=0; local reads=0; local response=200
    local socketutil={block_timeout=60,total_timeout=-1,set_timeout=function(self,b,t) self.block_timeout=b; self.total_timeout=t end}
    package.loaded.socketutil=socketutil
    package.loaded['ltn12']={source={string=function(body) local done=false; return function() if not done then done=true; return body end end end}}
    package.loaded['ssl.https']={tcp=function(options)
        assert(options.verify=='peer' and options.cafile=='gdriveshelf.koplugin/cacert.pem')
        return function() return {connect=function() return 1 end,close=function() end,
            getpeercertificate=function() return {extensions=function() return {['2.5.29.17']={dNSName={dns}}} end} end} end
    end}
    package.loaded['socket.http']={open=function(host,port,create)
        local c=create(); assert(c:connect(host,port))
        return {sendrequestline=function() sent=sent+1 end,sendheaders=function(_,h) assert(h.authorization=='Bearer old') end,
            receivestatusline=function() return response end,receiveheaders=function() return {etag='"fixture"'} end,
            receivebody=function(_,_,sink) reads=reads+1; sink('stat') end,close=function() end}
    end}
    local p=Provider.new{credentials={access_token='old'},json=json,ca_file='gdriveshelf.koplugin/cacert.pem'}
    local v,e=p:stat('a'); assert(not v and e.code=='network' and sent==0)
    dns='*.googleapis.com'; assert(p:stat('a').id=='a' and sent==1)
    response=302; v,e=p:stat('a'); assert(not v and e.code=='redirect' and reads==1)
    assert(socketutil.block_timeout==60 and socketutil.total_timeout==-1)
    for _,name in ipairs(names) do package.loaded[name]=saved[name] end
end)
test('nonfinite media limits cannot disable response bounds',function()
    local p=provider(function() error('must reject limit before network') end)
    for _,limit in ipairs({math.huge,0/0,-1}) do
        local v,e=p:read({id='a'},limit); assert(not v and e.code=='invalid_argument')
        v,e=p:download({id='a'},path,limit); assert(not v and e.code=='invalid_argument')
    end
end)
test('MD5 crosses stream chunk and padding boundaries',function()
    local p=provider(function(r)
        for i=1,122 do assert(r.sink(string.rep('a',8192))) end
        assert(r.sink(string.rep('a',576))); return 200,{},nil
    end)
    assert(p:download({id='a',size=1000000,checksum='7707d6ae4e027c70eea2a935c2296f21'},path,1000000)); os.remove(path)
end)
test('stat obtains a real conditional token when Drive v3 omits ETag',function()
    decoded.v2stat={id='a',title='one.cbz',parents={{id='p'}},fileSize='3',modifiedDate='2026-11-06T00:00:00Z',md5Checksum='900150983cd24fb0d6963f7d28e17f72',version='9',etag='"v2-real-token"',mimeType='application/zip'}
    local n=0
    local p=provider(function(r)
        n=n+1
        if n==1 then assert(r.url:find('/drive/v3/files/a?',1,true));return 200,{},'stat' end
        assert(r.url:find('/drive/v2/files/a?',1,true) and unquote(r.url):find('etag',1,true) and r.url:find('updateViewedDate=false',1,true));return 200,{},'v2stat'
    end)
    local entry=assert(p:stat('a'))
    assert(n==2 and entry.etag=='"v2-real-token"' and entry.name=='one.cbz' and entry.parent_id=='p' and entry.size==3 and entry.version=='9' and entry.modified_time=='2026-11-06T00:00:00Z')
end)
test('existing conditional upload uses v2 metadata schema and preserves returned token',function()
    local f=assert(io.open(path,'wb'));f:write('abc');f:close()
    local metadata
    local codec={decode=json.decode,encode=function(value)metadata=value;return 'encoded_metadata' end}
    local p=Provider.new{credentials={access_token='old'},json=codec,transport=function(r)
        assert(r.method=='PUT' and r.url:find('/upload/drive/v2/files/a?',1,true))
        assert(r.headers['If-Match']=='"old-tag"')
        assert(metadata.title=='one.cbz' and metadata.name==nil and metadata.parents==nil)
        local data={};while true do local chunk=r.source();if not chunk then break end;data[#data+1]=chunk end
        assert(table.concat(data):find('abc',1,true));return 200,{},'v2stat'
    end}
    local entry=assert(p:upload('p','one.cbz',path,'a','"old-tag"'));os.remove(path)
    assert(entry.etag=='"v2-real-token"' and entry.parent_id=='p' and entry.size==3)
end)
test('missing conditional token on both API versions fails closed',function()
    local p=provider(function(r)return 200,{},'stat' end)
    local value,e=p:stat('a');assert(not value and e.code=='invalid_response')
end)
print(count .. ' provider tests passed')
