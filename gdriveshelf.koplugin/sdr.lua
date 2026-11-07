-- A data parser, deliberately independent of Lua's compiler and evaluator.
local M = {}
local defaults = { max_bytes = 2 * 1024 * 1024, max_depth = 64, max_nodes = 100000 }
local function limits(opts)
    local result = {}
    for k, v in pairs(defaults) do result[k] = opts and opts[k] or v end
    return result
end
local function finite(n) return n and n == n and n ~= math.huge and n ~= -math.huge end
function M.decode(text, opts)
    local lim = limits(opts)
    if type(text) ~= 'string' then return nil, 'SDR must be a string' end
    if #text > lim.max_bytes then return nil, 'SDR byte limit exceeded' end
    local p, nodes = 1, 0
    local function fail(message) error(message .. ' at byte ' .. p, 0) end
    local function longString()
        local eq = text:match('^%[(=*)%[', p)
        if not eq then return nil end
        p = p + #eq + 2
        local close = ']' .. eq .. ']'
        local last = text:find(close, p, true)
        if not last then fail('Unterminated long string') end
        local value = text:sub(p, last - 1):gsub('\r\n', '\n'):gsub('\r', '\n')
        value = value:gsub('^\n', '')
        p = last + #close
        return value
    end
    local function skip()
        while true do
            local _, last = text:find('^%s+', p)
            if last then p = last + 1 end
            if text:sub(p,p+1) ~= '--' then return end
            p = p + 2
            if text:match('^%[=*%[', p) then longString()
            else p = (text:find('[\r\n]', p) or (#text + 1)) end
        end
    end
    local function take(token)
        skip()
        if text:sub(p,p+#token-1) ~= token then fail('Expected ' .. token) end
        p = p + #token
    end
    local escapes = { a='\a', b='\b', f='\f', n='\n', r='\r', t='\t', v='\v', ['\\']='\\', ['"']='"', ["'"]="'" }
    local function quoted()
        local quote = text:sub(p,p); p=p+1
        local parts = {}
        while p <= #text do
            local c = text:sub(p,p); p=p+1
            if c == quote then return table.concat(parts) end
            if c == '\r' or c == '\n' then fail('Unescaped newline in string') end
            if c == '\\' then
                c = text:sub(p,p); p=p+1
                if c:match('%d') then
                    local digits = c .. (text:match('^%d?%d?', p) or '')
                    p=p+#digits-1
                    local byte = tonumber(digits)
                    if byte > 255 then fail('Invalid decimal escape') end
                    c = string.char(byte)
                elseif c == '\n' then c='\n'
                elseif c == '\r' then if text:sub(p,p)=='\n' then p=p+1 end; c='\n'
                elseif escapes[c] then c=escapes[c]
                else fail('Invalid string escape') end
            end
            parts[#parts+1]=c
        end
        fail('Unterminated string')
    end
    local value
    value = function(depth)
        skip(); nodes=nodes+1
        if nodes > lim.max_nodes then fail('SDR node limit exceeded') end
        if depth > lim.max_depth then fail('SDR depth limit exceeded') end
        local c = text:sub(p,p)
        if c=='"' or c=="'" then return quoted() end
        if c=='[' and text:match('^%[=*%[', p) then return longString() end
        if c=='{' then
            p=p+1; local result, seen, index = {}, {}, 1
            skip()
            while text:sub(p,p) ~= '}' do
                if p > #text then fail('Unterminated table') end
                local key, val
                if text:sub(p,p)=='[' and not text:match('^%[=*%[', p) then
                    p=p+1; key=value(depth+1); take(']'); take('='); val=value(depth+1)
                else
                    local name = text:match('^([%a_][%w_]*)%s*=', p)
                    if name then p=p+#name; take('='); key=name; nodes=nodes+1; val=value(depth+1)
                    else key=index; index=index+1; val=value(depth+1) end
                end
                if key == nil or type(key)=='table' then fail('Invalid table key') end
                if seen[key] then fail('Duplicate table key') end
                seen[key]=true; result[key]=val
                skip(); c=text:sub(p,p)
                if c==',' or c==';' then p=p+1; skip()
                elseif c~='}' then fail('Expected table separator') end
            end
            p=p+1; return result
        end
        local word = text:match('^[%a_][%w_]*', p)
        if word then
            p=p+#word
            if word=='true' then return true elseif word=='false' then return false elseif word=='nil' then return nil end
            fail('Only literals are allowed')
        end
        local number = text:match('^[+-]?0[xX][%da-fA-F]+%.?[%da-fA-F]*[pP][+-]?%d+', p)
            or text:match('^[+-]?0[xX][%da-fA-F]+', p)
            or text:match('^[+-]?%d+%.?%d*[eE][+-]?%d+', p)
            or text:match('^[+-]?%.%d+[eE][+-]?%d+', p)
            or text:match('^[+-]?%d+%.?%d*', p) or text:match('^[+-]?%.%d+', p)
        if number then
            local n=tonumber(number); if not finite(n) then fail('Nonfinite number') end
            p=p+#number; return n
        end
        fail('Expected literal')
    end
    local ok, result = pcall(function()
        skip()
        if text:sub(p,p+5)~='return' or text:sub(p+6,p+6):match('[%w_]') then fail('Expected return') end
        p=p+6; local data=value(1); skip()
        if p <= #text then fail('Trailing executable or invalid text') end
        if type(data)~='table' then fail('SDR root must be a table') end
        return data
    end)
    if not ok then return nil,result end
    return result
end
function M.encode(data, opts)
    local lim, active, nodes = limits(opts), {}, 0
    local function quote(s)
        return '"' .. s:gsub('[%z\1-\31\127-\255\\"]', function(c)
            if c=='"' or c=='\\' then return '\\'..c end
            return string.format('\\%03d',c:byte())
        end) .. '"'
    end
    local out, bytes = {}, 0
    local function emit(s) bytes=bytes+#s; if bytes>lim.max_bytes then error('SDR byte limit exceeded',0) end; out[#out+1]=s end
    local encode
    encode=function(v,depth)
        nodes=nodes+1
        if nodes>lim.max_nodes or depth>lim.max_depth then error('SDR complexity limit exceeded',0) end
        local kind=type(v)
        if kind=='string' then emit(quote(v))
        elseif kind=='number' then if not finite(v) then error('Nonfinite number',0) end; emit(string.format('%.17g',v))
        elseif kind=='boolean' then emit(tostring(v))
        elseif kind=='table' then
            if active[v] then error('Cyclic metadata table',0) end
            if getmetatable(v) then error('Metadata metatables are unsupported',0) end
            active[v]=true; local keys={}
            for k in pairs(v) do
                local t=type(k)
                if t~='string' and t~='number' and t~='boolean' then error('Unsupported table key',0) end
                keys[#keys+1]=k
                if #keys>lim.max_nodes then error('SDR node limit exceeded',0) end
            end
            table.sort(keys,function(a,b) local x,y=type(a),type(b); if x~=y then return x<y end; if x=='boolean' then return not a and b end; return a<b end)
            emit('{')
            for _,k in ipairs(keys) do emit('['); encode(k,depth+1); emit(']='); encode(v[k],depth+1); emit(',') end
            emit('}'); active[v]=nil
        else error('Unsupported metadata value: '..kind,0) end
    end
    local ok,err=pcall(function() if type(data)~='table' then error('SDR root must be a table',0) end; emit('return '); encode(data,1); emit('\n') end)
    if not ok then return nil,err end
    return table.concat(out)
end
-- Checksums identify content; provider revisions may change for metadata alone.
-- Without hashes, every comparable stamp must agree and a revision/time must
-- confirm identity. Equal sizes alone do not identify a book's contents.
function M.sameBook(a,b)
    if type(a)~='table' or type(b)~='table' then return false end
    if a.id~=nil and b.id~=nil and a.id~=b.id then return false end
    if type(a.checksum)=='string' and a.checksum~='' and type(b.checksum)=='string' and b.checksum~='' then
        return a.checksum:lower()==b.checksum:lower()
    end
    local confirmed=false
    for _,key in ipairs({'version','modified_time','size'}) do
        if a[key]~=nil and b[key]~=nil then
            if tostring(a[key])~=tostring(b[key]) then return false end
            if key~='size' then confirmed=true end
        end
    end
    return confirmed
end
function M.sidecarName(name) return (name:gsub('%.[^%.]+$','')) .. '.sdr' end
function M.metadataName(name) return 'metadata.' .. (name:match('%.([^%.]+)$') or '') .. '.lua' end
function M.summary(data)
    data=data or {}
    local percent=tonumber(data.percent_finished)
    local page=tonumber(data.last_page)
    if not finite(page) then page=nil end
    local pages=tonumber(data.doc_pages)
    if not finite(percent) and page and finite(pages) and pages>0 then percent=page/pages end
    if not finite(percent) then percent=nil else percent=math.max(0,math.min(1,percent)) end
    return {percent=percent,page=page,status=type(data.summary)=='table' and data.summary.status or nil}
end
function M.setReadingStatus(data,status,date)
    if type(data.summary)~='table' then data.summary={} end
    data.summary.status=status
    data.summary.modified=date
    return data
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
M.equal=equal
local function sameMetadata(a,b)
    if type(a)~='table' or type(b)~='table' then return equal(a,b) end
    for k,v in pairs(a) do if k~='doc_path' and not equal(v,b[k]) then return false end end
    for k in pairs(b) do if k~='doc_path' and a[k]==nil then return false end end
    return true
end
M.sameMetadata=sameMetadata

-- This is deliberately narrower than the progress display. Clamped percentages
-- and opaque reflowable locations must never decide which snapshot to replace.
local fixed_page={cbz=true,cbr=true,cb7=true,pdf=true,djvu=true}
local function pagePosition(data)
    local page=data and data.last_page
    local pages=data and data.doc_pages
    if not finite(page) or page<1 or page%1~=0 or page>10000000 then return nil end
    if pages~=nil and (not finite(pages) or pages<page or pages%1~=0) then return nil end
    local percent=data.percent_finished
    if percent~=nil and (not finite(percent) or percent<0 or percent>1
        or (pages and math.abs(percent-page/pages)>.01)) then return nil end
    if data.last_xpointer~=nil then return nil end
    return page,percent
end
local function projected(data)
    local result={}
    for key,value in pairs(data or {}) do
        if key=='summary' and type(value)=='table' then
            local summary={}
            for name,field in pairs(value) do if name~='modified' then summary[name]=field end end
            if next(summary) then result.summary=summary end
        elseif key~='doc_path' and key~='last_page' and key~='percent_finished' then result[key]=value end
    end
    return result
end
local monthDays={31,28,31,30,31,30,31,31,30,31,30,31}
local function leap(year)return year%4==0 and (year%100~=0 or year%400==0)end
local function daysBeforeYear(year)
    local last=year-1
    return 365*last+math.floor(last/4)-math.floor(last/100)+math.floor(last/400)
end
local function utcTime(text)
    if type(text)~='string' then return nil end
    local y,m,d,h,n,s,tail=text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.-)Z$')
    if not y or (tail~='' and not tail:match('^%.%d+$')) then return nil end
    y,m,d,h,n,s=tonumber(y),tonumber(m),tonumber(d),tonumber(h),tonumber(n),tonumber(s)
    if y<1970 or m<1 or m>12 or d<1 or d>monthDays[m]+(m==2 and leap(y) and 1 or 0)
        or h>23 or n>59 or s>59 then return nil end
    local days=daysBeforeYear(y)-daysBeforeYear(1970)+d-1
    for month=1,m-1 do days=days+monthDays[month] end
    if m>2 and leap(y) then days=days+1 end
    return days*86400+h*3600+n*60+s+(tonumber(tail) or 0)
end
M.utcTime=utcTime
function M.automaticChoice(entry,local_data,remote_data,policy,local_time,remote_time,now)
    if not fixed_page[(entry.name or ''):lower():match('%.([^%.]+)$')]
        or (policy~='farthest' and policy~='freshest') then return nil end
    local local_page,local_percent=pagePosition(local_data)
    local remote_page,remote_percent=pagePosition(remote_data)
    if not local_page or not remote_page or local_page==remote_page
        or not equal(projected(local_data),projected(remote_data)) then return nil end
    if local_percent and remote_percent and ((local_page>remote_page and local_percent<remote_percent)
        or (local_page<remote_page and local_percent>remote_percent)) then return nil end
    if policy=='farthest' then return local_page>remote_page and 'local' or 'remote' end
    local_time=tonumber(local_time)
    remote_time=utcTime(remote_time)
    now=now or os.time()
    if not finite(local_time) or not remote_time or local_time<=0 or local_time>now+300
        or remote_time>now+300 or math.abs(local_time-remote_time)<5 then return nil end
    return local_time>remote_time and 'local' or 'remote'
end
local function described(data,date)
    if not data then return nil end
    local summary=M.summary(data)
    if type(date)=='number' and finite(date) and date>0 then
        local ok,formatted=pcall(os.date,'!%Y-%m-%dT%H:%M:%SZ',date)
        if ok then summary.date=formatted end
    elseif utcTime(date) then summary.date=date end
    if not summary.date and type(data.summary)=='table' and type(data.summary.modified)=='string'
        and data.summary.modified:match('^%d%d%d%d%-%d%d%-%d%d$') then summary.date=data.summary.modified end
    if summary.status~='reading' and summary.status~='complete' and summary.status~='abandoned'
        and summary.status~='new' then summary.status=nil end
    return summary
end
function M.describeConflict(saved)
    local l=saved.local_lua and M.decode(saved.local_lua)
    local r=saved.remote_lua and M.decode(saved.remote_lua)
    local differences={}
    if l and r then
        local a,b=projected(l),projected(r)
        for _,key in ipairs{'annotations','bookmarks','highlights'} do
            if not equal(a[key],b[key]) then
                if not differences[1] then differences[1]='annotations' end
                a[key],b[key]=nil,nil
            end
        end
        if M.summary(l).status~=M.summary(r).status then
            differences[#differences+1]='status'
            if type(a.summary)=='table' then a.summary.status=nil;if not next(a.summary) then a.summary=nil end end
            if type(b.summary)=='table' then b.summary.status=nil;if not next(b.summary) then b.summary=nil end end
        end
        if not equal(a,b) then differences[#differences+1]='settings' end
        if l.last_page~=r.last_page or l.percent_finished~=r.percent_finished or l.last_xpointer~=r.last_xpointer then
            differences[#differences+1]='position'
        end
    end
    return {local_version=described(l,saved.local_time),remote_version=described(r,saved.stamp and saved.stamp.modified_time),
        differences=differences}
end
function M.decide(base,local_data,remote)
    if sameMetadata(local_data,remote) then return 'same' end
    if type(local_data)=='table' and type(remote)=='table' and local_data.last_page==remote.last_page
        and local_data.percent_finished==remote.percent_finished and equal(projected(local_data),projected(remote)) then
        return 'same'
    end
    if sameMetadata(base,remote) then return 'push' end
    if sameMetadata(base,local_data) then return 'pull' end
    return 'conflict'
end
return M
