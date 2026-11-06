-- Relocation is copy-first and journalled: cancellation leaves the original usable.
local M={}
function M.plan(core,destination)
 local rows,seen={},{}
 local function add(id,entry,source)
  if seen[id]or not source then return end;seen[id]=true
  local e={};for k,v in pairs(entry)do e[k]=v end;e.parent_name=(core.state.folders[e.parent_id]or{}).name or e.parent_name
  rows[#rows+1]={id=id,source=source,target=destination:filePath(e,'auto')}
 end
 for id,e in pairs(core.state.entries)do if e.pool=='auto'or e.pool=='offline'then add(id,e,e.path)end end
 for id,e in pairs(core.state.docs)do add(id,e,e.local_path)end
 table.sort(rows,function(a,b)return a.id<b.id end);return rows
end
function M.commit(core,rows)
 for _,row in ipairs(rows)do
  local e=core.state.entries[row.id];if e then e.path=row.target end
  local d=core.state.docs[row.id];if d then d.path=row.target;d.local_path=row.target end
  local h=(core.state.history or {})[row.id];if h then h.entry.path=row.target;h.entry.local_path=row.target end
 end
end
local function digest(path)
 local f=io.open(path,'rb');if not f then return nil end
 local hash=require('ffi/sha2').sha256()
 while true do local chunk=f:read(65536);if not chunk then break end;hash(chunk)end
 f:close();return hash()
end
local function owned(hash,expected)
 if type(expected)=='table'then return hash and(hash==expected[1]or hash==expected[2])end
 return hash and hash==expected
end
local function copy(storage,source,target,resuming)
 local attr=storage.lfs.symlinkattributes(source)
 if not attr then
  if resuming and storage:exists(target)then if owned(digest(target),resuming)then storage:remove(target)else return nil,'Destination changed during interrupted move'end end
  return true
 end
 if attr.mode=='link'then return nil,'Symbolic links are not moved'end
 if attr.mode=='directory'then
  assert(storage:mkdir(target))
  for name in storage.lfs.dir(source)do if name~='.'and name~='..'then local ok,err=copy(storage,source..'/'..name,target..'/'..name);if not ok then return nil,err end end end
  return true
 end
 if attr.mode~='file'then return nil,'Unsupported local file type'end
 if storage.lfs.symlinkattributes(target)then
  if not resuming or storage.lfs.attributes(target,'mode')~='file'then return nil,'Destination already contains a file'end
  local targetHash=digest(target);local sourceHash=digest(source)
  if targetHash==sourceHash then return true end
  if not owned(targetHash,resuming)then return nil,'Destination changed during interrupted move'end
  -- An unchanged copy owned by this journal can be atomically replaced by the
  -- newer source. Any user-modified destination fails closed above.
 end
 local available=storage:diskStats(target:match('^(.*)/')).free
 if not available or available-(attr.size or 0)<512*1048576 then return nil,'Not enough free disk space (safety reserve)'end
 local input=io.open(source,'rb');if not input then return nil,'Cannot read local document'end
 local previous=require('ffi').C.umask(63);local output=io.open(target..'.moving','wb');require('ffi').C.umask(previous)
 if not output then input:close();return nil,'Cannot write destination'end
 local good=true
 while true do local chunk=input:read(65536);if not chunk then break end;if not output:write(chunk)then good=false;break end end
 input:close();local flushed=output:flush();local closed=output:close()
 if not good or not flushed or not closed then os.remove(target..'.moving');return nil,'Cannot copy local document'end
 return os.rename(target..'.moving',target)
end
function M.finalize(core,journal,current_path)
 local history=require('readhistory');local pending={}
 core.state.relocation_aliases=core.state.relocation_aliases or {}
 for _,row in ipairs(journal.rows)do
  history:updateItem(row.source,row.target)
  if G_reader_settings and G_reader_settings:readSetting('lastfile')==row.source then G_reader_settings:saveSetting('lastfile',row.target)end
  if current_path==row.source then core.state.relocation_aliases[row.source]=row.id;pending[#pending+1]=row end
 end
 if G_reader_settings then G_reader_settings:flush()end
 journal.phase='finalizing';assert(core.storage:writeJSON(core.storage.root..'/relocation.json',journal))
 assert(core:save())
 for _,row in ipairs(journal.rows)do if current_path~=row.source then
  -- Never delete an externally changed original after publishing its copy.
  local attr=core.storage.lfs.attributes(row.source)
  if attr and row.source_size==attr.size and row.source_mtime==attr.modification then core.storage:remove(row.source)end
 end end
 if #pending==0 then core.storage:remove(core.storage.root..'/relocation.json')else journal.rows=pending;assert(core.storage:writeJSON(core.storage.root..'/relocation.json',journal))end
end
function M.recover(core,current_path)
 local journal=core.storage:readJSON(core.storage.root..'/relocation.json')
 if journal and core.state.books_dir==journal.to then M.finalize(core,journal,current_path)end
end
function M.install(Core)
 function Core:finishRelocationForPath(path)
  local id=(self.state.relocation_aliases or {})[path];if not id then return end
  local entry=self.state.entries[id]or self.state.docs[id];local target=entry and(entry.path or entry.local_path)
  if not target then return end
  require('docsettings').updateLocation(path,target,true)
  self.state.relocation_aliases[path]=nil;self:save()
  M.recover(self,nil)
 end
 function Core:relocateBooks(path,callback)
  if type(path)~='string'or path:sub(1,1)~='/'or path:find('[%z\r\n]')then return false,'Enter an absolute path'end
  if self.active_id or self.opening_id then return false,'Close the book first'end
  if path==self.storage.books_dir then callback(true);return true end
  if self.relocating then return false,'A move is already in progress'end
  local source=self.storage;local old=source.books_dir
  if path:sub(1,#old+1)==old..'/'or old:sub(1,#path+1)==path..'/'then return false,'Choose a separate document folder'end
  if self.jobs.active then return false,'Wait for active downloads to finish'end
  local realpath=require('ffi/util').realpath
  local Storage=require('gdriveshelf/storage');assert(source:mkdir(path))
  local resolvedOld,resolvedNew=realpath(old),realpath(path)
  if not resolvedOld or not resolvedNew then return false,'Cannot resolve document folder'end
  if resolvedOld==resolvedNew then callback(true);return true end
  if resolvedNew:sub(1,#resolvedOld+1)==resolvedOld..'/'or resolvedOld:sub(1,#resolvedNew+1)==resolvedNew..'/'then return false,'Choose a separate document folder'end
  path=resolvedNew
  local destination=Storage.new{root=source.root,account=source.account,books_dir=path,json=source.json,lfs=source.lfs}
  local journal_path=source.root..'/relocation.json';local journal=source:readJSON(journal_path)
  if not journal or journal.from~=old or journal.to~=path then journal={from=old,to=path,done={}}end
  journal.rows=M.plan(self,destination);journal.expected=journal.expected or {};journal.copying=journal.copying or {}
  assert(source:writeJSON(journal_path,journal))
  self.relocating=true
  self.jobs:enqueue('relocate',function(report)
   for index,row in ipairs(journal.rows)do
    local resuming=journal.expected[row.id]or journal.copying[row.id]
    if journal.expected[row.id]and journal.copying[row.id]then resuming={journal.expected[row.id],journal.copying[row.id]}end
    journal.copying[row.id]=digest(row.source);assert(source:writeJSON(journal_path,journal))
    local ok,err=copy(source,row.source,row.target,resuming);if not ok then return nil,{code='disk',message=err}end
    if source:exists(row.source)and digest(row.source)~=digest(row.target)then return nil,{code='disk',message='Document changed during copy'}end
    local attr=source.lfs.attributes(row.source);row.source_size=attr and attr.size;row.source_mtime=attr and attr.modification
    -- KOReader handles doc/dir/hash locations and rewrites doc_path itself.
    local settings=require('docsettings');settings.updateLocation(row.source,row.target,true)
    local from=row.source:gsub('%.[^./]+$','')..'.sdr';local to=row.target:gsub('%.[^./]+$','')..'.sdr'
    -- updateLocation copies standard metadata; preserve extra user SDR files too.
    if source.lfs.attributes(from,'mode')=='directory'then
     assert(source:mkdir(to))
     for name in source.lfs.dir(from)do if name~='.'and name~='..'and not source.lfs.attributes(to..'/'..name)then local good,why=copy(source,from..'/'..name,to..'/'..name);if not good then return nil,{code='disk',message=why}end end end
    end
    journal.done[row.id]=true;journal.expected[row.id]=journal.copying[row.id];journal.copying[row.id]=nil;assert(source:writeJSON(journal_path,journal));report{received=index,total=#journal.rows,stage='download'}
   end
   return {rows=journal.rows}
  end,function(result,err)
   self.relocating=nil
   if not result then callback(false,err);return end
   if self.active_id or self.opening_id then callback(false,{code='busy',message='Close the book first'});return end
   local savedEntries,savedDocs,savedHistory=self.state.entries,self.state.docs,self.state.history
   -- Save the new index before removing any original archive.
   local function clone(value)if type(value)~='table'then return value end;local out={};for k,v in pairs(value)do out[k]=clone(v)end;return out end
   self.state.entries=clone(savedEntries);self.state.docs=clone(savedDocs);self.state.history=clone(savedHistory)
   journal=source:readJSON(journal_path)or journal;journal.rows=result.rows
   journal.phase='committing';assert(source:writeJSON(journal_path,journal))
   local oldBooks=self.state.books_dir;M.commit(self,result.rows);self.state.books_dir=path
   local ok,why=self:save()
   if not ok then self.state.entries,self.state.docs,self.state.history=savedEntries,savedDocs,savedHistory;self.state.books_dir=oldBooks;callback(false,{code='disk',message=why});return end
   source.books_dir=path;self.settings.books_dir=path
   M.finalize(self,journal,nil);callback(true)
  end,true,nil,function(value)self:emit('relocating',nil,value)end,true)
  return true
 end
end
return M
