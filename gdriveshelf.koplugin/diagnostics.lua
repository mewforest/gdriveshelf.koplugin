-- Opt-in, bounded telemetry. Never serialize arbitrary strings or error payloads.
local Logger={};Logger.__index=Logger
local LIMIT=1048576
local events={request=true,job=true,network=true,ui_error=true}
local function enum(words)local out={};for word in words:gmatch('%S+')do out[word]=true end;return out end
local enums={
 operation=enum('list stat read range download mkdir upload auth index scan thumbnail sync progress'),
 transition=enum('queued deferred started completed failed cancelled'),
 state=enum('online offline sleep retry auth'),
 error=enum('network api auth unauthorized io disk preview range not_found invalid_argument invalid_response invalid_remote_metadata invalid_local_metadata invalid_pending invalid_base invalid_name changed size_mismatch checksum_mismatch too_large pagination conflict redirect cancelled paused space limit prepare spawn worker timeout ambiguous_stem ambiguous_sidecar ambiguous_metadata metadata_moved unguarded_write concurrent_creation upload_failed'),
 module=enum('main core jobs ux controls diagnostics storage requests scanning thumbnails zipcover catalog metadata indexer progress localcovers overrides indexing library sync sdr relocation browser providers/gdrive'),
}
local order={'operation','taskref','duration','bytes','status','error','transition','state','module','line'}
local function number(value,max,integer)
 return type(value)=='number'and value==value and value>=0 and value<=(max or 9007199254740991)and(not integer or value==math.floor(value))
end
local function file(path,mode,fn)
 local f=io.open(path,mode);if not f then error('io',0)end
 local ok,value=pcall(fn,f);local closed,result=pcall(f.close,f)
 if not ok or not closed or not result then error('io',0)end
 return value
end
local function guarded(fn)
 local ok,result=pcall(fn);if ok then return result end;return nil,'io'
end
local function validPath(path)return type(path)=='string'and path:sub(1,1)=='/'and not path:find('[%z\r\n]')end
function Logger.new(o)
 o=o or {};local dir=o.dir
 if not validPath(dir)or dir:find('.koplugin',1,true)then dir=nil end
 local version=type(o.version)=='string'and #o.version<=48 and(o.version:match('^%d+%.%d+%.%d+$')or o.version:match('^%d+%.%d+%.%d+%-dev$'))or nil
 local runtime
 if type(o.runtime)=='string'then
  local system,arch=o.runtime:match('^(%w+) (%w+)$')
  if enum('Linux OSX Windows BSD POSIX Android')[system]and enum('x86 x64 arm arm64 mips ppc ppc64')[arch]then runtime=o.runtime end
 end
 return setmetatable({dir=dir,enabled=o.enabled,version=version,runtime=runtime},Logger)
end
function Logger:event(name,fields)
 return guarded(function()
  if not self.dir or type(self.enabled)~='function'or self.enabled()~=true or not events[name]then return false end
  local values={'event='..name};fields=type(fields)=='table'and fields or {}
  if self.version then values[#values+1]='version='..self.version end
  if self.runtime then values[#values+1]='runtime='..self.runtime end
  for _,key in ipairs(order)do
   local value=rawget(fields,key);local allowed=enums[key]
   if allowed then
    if type(value)=='string'and allowed[value]then values[#values+1]=key..'='..value end
   elseif number(value,key=='status'and 599 or nil,key~='duration')and(key~='status'or value>=100)then values[#values+1]=key..'='..tostring(value)end
  end
  local line=table.concat(values,'\t')..'\n';local path=self.dir..'/diagnostics.log'
  local written=file(path,'ab',function(f)
   local size=assert(f:seek('end'))
   if size+#line>LIMIT then return false end
   assert(f:write(line));return true
  end)
  if not written then
   local size=file(path,'rb',function(f)return assert(f:seek('end'))end)
   if size>LIMIT then assert(os.remove(path))else assert(os.rename(path,self.dir..'/diagnostics.previous.log'))end
   file(path,'wb',function(f)assert(f:write(line));return true end)
  end
  return true
 end)
end
function Logger:export(path)
 return guarded(function()
  if not self.dir or not validPath(path)or path==self.dir..'/diagnostics.log'or path==self.dir..'/diagnostics.previous.log'then return false end
  local chunks={}
  for _,name in ipairs{'diagnostics.previous.log','diagnostics.log'}do
   local input,_,errno=io.open(self.dir..'/'..name,'rb')
   if input then
    local ok,data=pcall(input.read,input,LIMIT);local closed,result=pcall(input.close,input)
    if not ok or not closed or not result or not data then error('io',0)end
    chunks[#chunks+1]=data
   elseif errno~=2 then error('io',0)end
  end
  if #chunks==0 then return false end
  file(path,'wb',function(f)for _,chunk in ipairs(chunks)do assert(f:write(chunk))end;return true end)
  return true
 end)
end
function Logger:clear()
 return guarded(function()
  if not self.dir then return false end
  for _,name in ipairs{'diagnostics.log','diagnostics.previous.log'}do
   local removed,_,errno=os.remove(self.dir..'/'..name)
   if not removed and errno~=2 then error('io',0)end
  end
  return true
 end)
end
return Logger
