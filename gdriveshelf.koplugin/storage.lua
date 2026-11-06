local S={};S.__index=S
function S.safeName(name)
 local n=tostring(name or 'file'):gsub('[%z\1-\31/\\]','_'):gsub('^%.+$','_')
 return n~='' and n:sub(1,180) or 'file'
end
function S.key(value) return (tostring(value):gsub('.',function(c)return string.format('%02x',c:byte())end)) end
function S.new(o)
 local self=setmetatable({root=o.root,json=o.json or require('json'),lfs=o.lfs or require('libs/libkoreader-lfs')},S)
 self:mkdir(self.root);self:mkdir(self.root..'/jobs');self:mkdir(self.root..'/files');self:mkdir(self.root..'/meta');self:mkdir(self.root..'/snapshots')
 return self
end
function S:mkdir(path)
 if self.lfs.attributes(path,'mode')=='directory' then return true end
 local parent=path:match('^(.*)/[^/]+$');if parent and parent~='' and parent~=path then self:mkdir(parent) end
 local ok,e=self.lfs.mkdir(path);if not ok and self.lfs.attributes(path,'mode')~='directory' then return nil,e end;return true
end
function S:read(path,limit)
 local f,e=io.open(path,'rb');if not f then return nil,e end
 local s=f:read((limit or 8*1048576)+1);f:close();if not s then return '' end
 if #s>(limit or 8*1048576) then return nil,'File exceeds read limit' end;return s
end
function S:write(path,text)
 local ok,e=self:mkdir(path:match('^(.*)/'));if not ok then return nil,e end
 local tmp=path..'.new'
 -- IPC results may contain refreshed tokens: create every temporary state file
 -- private from the first byte, even under a permissive process umask.
 local ffi=require('ffi');pcall(ffi.cdef,'unsigned int umask(unsigned int mask);')
 os.remove(tmp);local previous=ffi.C.umask(63)
 local f,err=io.open(tmp,'wb');ffi.C.umask(previous)
 if not f then return nil,err end
 local good,writeerr=f:write(text)
 if good then f:flush();local uok,u=pcall(require,'ffi/util');if uok and u.fsyncOpenedFile then pcall(u.fsyncOpenedFile,f,true) end end
 local closed,closeerr=f:close()
 if not good or not closed then os.remove(tmp);return nil,writeerr or closeerr end
 -- Rename publishes only a complete file; the previous state survives failed writes.
 local moved,merr=os.rename(tmp,path);if not moved then os.remove(tmp);return nil,merr end;return true
end
function S:readJSON(path,limit)
 local text,err=self:read(path,limit);if not text then return nil,err end
 local ok,data=pcall(self.json.decode,text);if ok and type(data)=='table' then return data end
 return nil,'Invalid JSON file'
end
function S:writeJSON(path,data)
 local ok,text=pcall(self.json.encode,data);if not ok then return nil,'Cannot encode state' end
 return self:write(path,text)
end
function S:remove(path) return os.remove(path) end
function S:size(path) return self.lfs.attributes(path,'size') or 0 end
function S:exists(path) return self.lfs.attributes(path,'mode')=='file' end
function S:treeSize(path)
 local a=self.lfs.attributes(path);if not a then return 0 end
 if a.mode~='directory' then return a.size or 0 end
 local n=0;for f in self.lfs.dir(path) do if f~='.' and f~='..' then local p=path..'/'..f;local s=self.lfs.symlinkattributes(p);if s and s.mode~='link' then n=n+self:treeSize(p) end end end;return n
end
-- Old-session incoming files are never ready archives. Unlinking an orphan's
-- open partial file is safe: it cannot publish into the new session's namespace.
function S:cleanupDownloads(entries)
 local ready={};for _,e in pairs(entries or {})do if e.path then ready[e.path]=true end end
 local removed=0
 local function walk(path,jobs)
  if self.lfs.attributes(path,'mode')~='directory'then return end
  for name in self.lfs.dir(path)do if name~='.'and name~='..'then
   local p=path..'/'..name;local a=self.lfs.symlinkattributes(p)
   if a and a.mode=='directory'then walk(p,jobs)
   elseif a and a.mode=='file' and not ready[p]then
    local temp=name:match('%.incoming%-%d+%-%d+%-%w+%.part$') or name:match('%.incoming%-%d+%-%d+%-%w+$')
    if temp or (jobs and (name:match('^result%-')or name:match('^sync%-')))then if os.remove(p)then removed=removed+1 end end
   end
  end end
 end
 walk(self.root..'/files');walk(self.root..'/meta');walk(self.root..'/jobs',true)
 return removed
end
function S:freeBytes()
 local ok,u=pcall(require,'ffi/util')
 if ok and u.getFreeDiskSpace then local good,n=pcall(u.getFreeDiskSpace,self.root);if good and type(n)=='number' then return n end end
 -- df is present on Android (toybox) and macOS. Only a quoted local path reaches the shell.
 local quote="'"..self.root:gsub("'","'\\''").."'"
 local f=io.popen('df -Pk '..quote..' 2>/dev/null','r');if not f then return nil end
 local out=f:read('*a');f:close();local available
 for line in out:gmatch('[^\n]+') do local n=line:match('^%S+%s+%d+%s+%d+%s+(%d+)%s+%d+%%');if n then available=tonumber(n)*1024 end end
 return available
end
function S:filePath(entry,pool)
 local dir=self.root..(pool=='meta' and '/meta/' or '/files/')..S.key(entry.id)
 assert(self:mkdir(dir));return dir..'/'..S.safeName(entry.name)
end
function S:writeTemp(text)
 self._seq=(self._seq or 0)+1
 local path=self.root..'/jobs/sync-'..tostring(os.time())..'-'..self._seq..'.tmp'
 local ok,e=self:write(path,text);if not ok then return nil,e end;return path
end
return S
