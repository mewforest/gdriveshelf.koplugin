local S={};S.__index=S
local function basename(name)
 return type(name)=='string' and name~='' and name~='.' and name~='..' and not name:find('[%z%c/\\]')
end
local function bookRelative(path)
 if type(path)~='string'then return nil end
 local folder,file=path:match('^([^/]+)/([^/]+)$')
 if basename(folder)and basename(file)then return folder,file end
end
function S.safeName(name)
 local n=tostring(name or 'file'):gsub('[%z\1-\31/\\]','_'):gsub('^%.+$','_')
 return n~='' and n:sub(1,180) or 'file'
end
function S.key(value) return (tostring(value):gsub('.',function(c)return string.format('%02x',c:byte())end)) end
function S.new(o)
 local self=setmetatable({root=o.root,account=o.account or o.root,books_dir=o.books_dir or o.root..'/Books',json=o.json or require('json'),lfs=o.lfs or require('libs/libkoreader-lfs')},S)
 self:mkdir(self.root);self:mkdir(self.root..'/jobs');self:mkdir(self.books_dir);self:mkdir(self.root..'/meta');self:mkdir(self.root..'/snapshots')
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
 local a=self.lfs.symlinkattributes(path);if not a or a.mode=='link'then return 0 end
 if a.mode~='directory' then return a.size or 0 end
 local n=0;for f in self.lfs.dir(path) do if f~='.' and f~='..' then local p=path..'/'..f;local s=self.lfs.symlinkattributes(p);if s and s.mode~='link' then n=n+self:treeSize(p) end end end;return n
end
function S:bookRegistry()
 local data=self:readJSON(self.books_dir..'/.gdriveshelf-paths.json',16*1048576)
 return data and type(data.files)=='table'and data.files or {}
end
function S:managedPath(entry,registry)
 if type(entry.id)~='string'or type(entry.path)~='string'then return false end
 local root,relative,folder
 if entry.pool=='auto'or entry.pool=='offline'then
  root=self.books_dir
  relative=(registry or self:bookRegistry())[S.key(self.account)..':'..S.key(entry.id)]
  folder=bookRelative(relative)
  if not folder or entry.path~=root..'/'..relative or entry.preview_path then return false end
 elseif entry.pool=='meta'then
  root=self.root..'/meta'
  if self.lfs.symlinkattributes(root,'mode')=='link'then return false end
  folder=S.key(entry.id)
  local prefix=root..'/'..folder..'/'
  if entry.path:sub(1,#prefix)~=prefix or not basename(entry.path:sub(#prefix+1))then return false end
  if entry.preview_path and entry.preview_path~=prefix..'cover-preview.png'then return false end
 else return false end
 local mode=self.lfs.symlinkattributes(root..'/'..folder,'mode')
 if mode and mode~='directory'then return false end
 local attr=self.lfs.symlinkattributes(entry.path)
 if attr and attr.mode~='file'then return false end
 return true,attr
end
-- Old-session incoming files are never ready archives. Unlinking an orphan's
-- open partial file is safe: it cannot publish into the new session's namespace.
function S:cleanupDownloads(entries)
 local ready={};for _,e in pairs(entries or {})do if e.path then ready[e.path]=true end;if e.preview_path then ready[e.preview_path]=true end end
 local removed=0
 local function walk(path,jobs)
  if self.lfs.attributes(path,'mode')~='directory'then return end
  for name in self.lfs.dir(path)do if name~='.'and name~='..'then
   local p=path..'/'..name;local a=self.lfs.symlinkattributes(p)
   if a and a.mode=='directory'then walk(p,jobs)
   elseif a and a.mode=='file' and not ready[p]then
    local temp=name:match('%.incoming%-%d+%-%d+%-%w+%.part$') or name:match('%.incoming%-%d+%-%d+%-%w+$')or name:match('%.incoming%-%d+%-%d+%-%w+%.png$')
    if temp or (jobs and (name:match('^result%-')or name:match('^sync%-')))then if os.remove(p)then removed=removed+1 end end
   end
  end end
 end
 walk(self.root..'/files');walk(self.root..'/meta');walk(self.root..'/jobs',true)
 -- Books may contain user files and other accounts. Inspect only registered
 -- basenames owned by this account, never recursively clean a chosen folder.
 local registry=self.books_dir and self:readJSON(self.books_dir..'/.gdriveshelf-paths.json',16*1048576)
 local owner=S.key(self.account or self.root)..':'
 for key,relative in pairs(registry and type(registry.files)=='table'and registry.files or {})do if key:sub(1,#owner)==owner then
  local folder,base=bookRelative(relative);local dir=folder and self.books_dir..'/'..folder
  if dir and self.lfs.symlinkattributes(dir,'mode')=='directory'then
   for name in self.lfs.dir(dir)do
    if name:sub(1,#base+10)==base..'.incoming-'and not ready[dir..'/'..name]then
     local suffix=name:sub(#base+11)
     if suffix:match('^%d+%-%d+%-%w+%.part$')or suffix:match('^%d+%-%d+%-%w+$')then if os.remove(dir..'/'..name)then removed=removed+1 end end
    end
   end
  end
 end end
 return removed
end
function S:freeBytes(path)
 local target=path or self.books_dir or self.root
 local ok,u=pcall(require,'ffi/util')
 if ok and u.getFreeDiskSpace then local good,n=pcall(u.getFreeDiskSpace,target);if good and type(n)=='number' then return n end end
 -- df is present on Android (toybox) and macOS. Only a quoted local path reaches the shell.
 local quote="'"..target:gsub("'","'\\''").."'"
 local f=io.popen('df -Pk '..quote..' 2>/dev/null','r');if not f then return nil end
 local out=f:read('*a');f:close();local available
 for line in out:gmatch('[^\n]+') do local n=line:match('^%S+%s+%d+%s+%d+%s+(%d+)%s+%d+%%');if n then available=tonumber(n)*1024 end end
 return available
end
-- A shared ownership registry keeps names readable without allowing two accounts
-- or duplicate Drive names to overwrite one another. Paths never change on pin.
function S:filePath(entry,pool)
 if pool=='meta'then
  local dir=self.root..'/meta/'..S.key(entry.id);assert(self:mkdir(dir))
  return dir..'/'..S.safeName(entry.name)
 end
 local registry=self.books_dir..'/.gdriveshelf-paths.json'
 local map,why=self:readJSON(registry,16*1048576)
 if not map and self.lfs.attributes(registry)then error(why or 'Cannot read book paths')end
 map=map or {folders={},files={}};map.folders=map.folders or {};map.files=map.files or {}
 local owner=S.key(self.account or self.root)..':'
 local filekey=owner..S.key(entry.id)
 if map.files[filekey]then
  local folder=assert(bookRelative(map.files[filekey]),'Invalid stored document path')
  assert(self.lfs.symlinkattributes(self.books_dir..'/'..folder,'mode')~='link','Invalid stored document directory')
  return self.books_dir..'/'..map.files[filekey]
 end
 local function allocate(base,key,values,parent,is_file)
  base=S.safeName(base);local stem,ext=base:match('^(.*)(%.[^%.]+)$')
  if not is_file or not stem then stem,ext=base,''end
  local candidate=base;local attempt=0
  while true do
   local relative=(parent and parent..'/'or '')..candidate;local occupied=false
   for _,used in pairs(values)do if used:lower()==relative:lower()then occupied=true;break end end
   if not occupied and not self.lfs.attributes(self.books_dir..'/'..relative)then return relative end
   attempt=attempt+1
   candidate=stem..' ['..S.key(key):sub(1,12)..(attempt>1 and '-'..attempt or '')..']'..ext
  end
 end
 local folderkey=owner..S.key(entry.parent_id or 'root')
 local folder=map.folders[folderkey]
 if not folder then
  folder=allocate(entry.parent_name or entry.parent_id or 'Library',folderkey,map.folders,nil,false)
  map.folders[folderkey]=folder
 end
 assert(basename(folder)and self.lfs.symlinkattributes(self.books_dir..'/'..folder,'mode')~='link','Invalid stored document directory')
 assert(self:mkdir(self.books_dir..'/'..folder))
 local relative=allocate(entry.name,entry.id,map.files,folder,true)
 map.files[filekey]=relative
 local ok,err=self:writeJSON(registry,map);assert(ok,err)
 return self.books_dir..'/'..relative
end
function S:volume(path)return self.lfs.attributes(path or self.books_dir or self.root,'dev')end
function S:diskStats(path)
 path=path or self.books_dir or self.root
 local quote="'"..path:gsub("'","'\\''").."'"
 local f=io.popen('df -Pk '..quote..' 2>/dev/null','r');if not f then return {}end
 local out=f:read('*a');f:close()
 for line in out:gmatch('[^\n]+')do
  local total,used,available=line:match('^%S+%s+(%d+)%s+(%d+)%s+(%d+)%s+%d+%%')
  if total then return {total=tonumber(total)*1024,used=tonumber(used)*1024,free=tonumber(available)*1024}end
 end
 return {}
end
function S:writeTemp(text)
 self._seq=(self._seq or 0)+1
 local path=self.root..'/jobs/sync-'..tostring(os.time())..'-'..self._seq..'.tmp'
 local ok,e=self:write(path,text);if not ok then return nil,e end;return path
end
return S
