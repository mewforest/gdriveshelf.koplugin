-- Read-only live protocol check. Uses memory-only Core storage and never opens
-- native documents, downloads books/covers, writes SDR, or persists credentials.
-- Run from an official KOReader runtime; supply ROOT, CREDS, SMOKE_PARENTS (CSV)
-- and optionally SMOKE_REPORT. Use a disposable KO_HOME.
local function run()
 require('setupkoenv')
 G_defaults=require('luadefaults'):open()
 G_reader_settings=require('luasettings'):open(assert(os.getenv('KO_HOME'))..'/smoke-reader.lua')
 local source=assert(os.getenv('GDRIVESHELF_ROOT'))
 dofile(source..'/gdriveshelf.koplugin/bootstrap.lua')(source..'/gdriveshelf.koplugin')
 local JSON=require('json');local Provider=require('gdriveshelf/providers/gdrive');local Core=require('gdriveshelf/core')
 local SDR=require('gdriveshelf/sdr');local Library=require('gdriveshelf/library');local Metadata=require('gdriveshelf/metadata')
 local function read(path)local f=assert(io.open(path,'rb'));local s=f:read(1048577);f:close();assert(s and #s<=1048576);return s end
 local p=Provider.new{credentials=JSON.decode(read(assert(os.getenv('GDRIVESHELF_CREDS')))),ca_file=source..'/gdriveshelf.koplugin/cacert.pem'}
 local totals={requests=0,bytes=0,reads=0,lists=0,stats=0,auth=0}
 p.trace=function(_,event)
  totals.requests=totals.requests+1;assert(totals.requests<=100,'Read-only smoke request budget exceeded')
  totals.bytes=totals.bytes+(event.bytes or 0)
  if event.operation=='read'then totals.reads=totals.reads+1 elseif event.operation=='list'then totals.lists=totals.lists+1 elseif event.operation=='stat'then totals.stats=totals.stats+1 elseif event.operation=='auth'then totals.auth=totals.auth+1 end
 end
 local send=p._send
 p._send=function(self,r,...)
  assert(r.method=='GET'or(r.method=='POST'and r.url=='https://oauth2.googleapis.com/token'),'Read-only smoke refused a cloud write')
  return send(self,r,...)
 end
 local allowed,sdrs,stage={},{},'catalog'
 local listParents=p.listParents
 p.listParents=function(self,ids,scope)
  for _,id in ipairs(ids)do assert(allowed[id]and(stage~='catalog'or not sdrs[id]),'Folder outside read-only traversal')end
  local buckets,e=listParents(self,ids,scope);if not buckets then return nil,e end
  for _,entries in pairs(buckets)do for _,entry in ipairs(entries)do if entry.is_folder then allowed[entry.id]=true;if Metadata.isService(entry)and entry.name:lower():match('%.sdr$')then sdrs[entry.id]=true end end end end
  return buckets
 end
 local readMedia=p.read
 p.read=function(self,entry,...)
  assert(stage=='progress'and sdrs[entry.parent_id]and entry.name:match('^metadata%.[%w]+%.lua$'),'Read-only smoke refused non-SDR media')
  return readMedia(self,entry,...)
 end
 p.range=function()error('Read-only smoke refused archive ranges')end
 p.download=function()error('Read-only smoke refused document download')end
 p.upload=function()error('Read-only smoke refused upload')end;p.mkdir=p.upload
 local function copy(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
 local function delta(before)local d={};for k,v in pairs(totals)do d[k]=v-(before[k]or 0)end;return d end
 local report={schema=1,read_only=true,libraries={}}
 local targets={};for id in assert(os.getenv('GDRIVESHELF_SMOKE_PARENTS')):gmatch('[^,]+')do targets[#targets+1]=id end;assert(#targets==2,'Supply exactly two authorized libraries')
 for number,parent in ipairs(targets)do
  local files,queue={},{};allowed={[parent]=true};sdrs={};stage='catalog'
  local fs={root='/memory-smoke',account='smoke',json=JSON,readJSON=function(_,path)local s=files[path];return s and JSON.decode(s)end,writeJSON=function(_,path,v)files[path]=JSON.encode(v);return true end,
   write=function(_,path,text)files[path]=text;return true end,exists=function(_,path)return files[path]~=nil end,remove=function(_,path)files[path]=nil;return true end,
   freeBytes=function()return 1e12 end,filePath=function(_,entry)return '/memory-smoke/meta/'..entry.id end}
  local c=Core.new{storage=fs,jobs={setOffline=function()end,cancel=function()end},settings={home=parent,index_enabled=true,index_recursive_confirmed=true,sync_enabled=true,load_covers=false,load_metadata=false},provider_factory=function()return p end}
  c.catalog_visible=true
  -- Optional folder enrichment is deliberately outside this protocol smoke.
  c.metadata=function()end
  c.network=function(_,key,work,done)queue[#queue+1]={key=key,run=work,done=done};return true end
  local function drain()
   local steps=0;while #queue>0 do steps=steps+1;assert(steps<=150,'Read-only smoke step budget exceeded')
    local job=table.remove(queue,1);local value,e=job.run(p);assert(value,e and e.code or 'Read-only worker failed');job.done(value,e)
   end
  end
  local before=copy(totals);c:reindexHome();drain();assert(c.state.catalog.phase=='ready'and c.state.catalog.token,'Catalog did not catch up')
  local bootstrap=delta(before);local folders,documents,by_parent=0,0,{}
  for id in pairs(c.state.catalog.members)do
   local folder=c.state.folders[id]
   if folder then if not sdrs[id]then folders=folders+1 else assert(not c.state.listings[id],'Catalog traversed SDR content')end
   else local entry=c.state.docs[id];if entry and Library.supported(entry)then documents=documents+1;by_parent[entry.parent_id]=by_parent[entry.parent_id]or{};table.insert(by_parent[entry.parent_id],entry)end end
  end
  before=copy(totals);c:catalogRefresh(true);drain();local incremental=delta(before);assert(incremental.reads==0,'Catalog read document content')
  local visible={};local best=-1
  for folder,entries in pairs(by_parent)do
   local sidecars={};for _,entry in ipairs(c:cachedList(folder))do if entry.is_folder then sidecars[entry.name]=true end end
   local score=0;for _,entry in ipairs(entries)do if sidecars[SDR.sidecarName(entry.name)]then score=score+1 end end
   if score>best then best=score;visible=Library.ordered(entries,'natural')end
  end
  while #visible>7 do table.remove(visible)end;assert(#visible>0,'No readable documents in authorized library')
  stage='progress';c.progress_fresh={};before=copy(totals);c:lazyProgress(visible);drain();local first=delta(before)
  local valid=0;for _,entry in ipairs(visible)do local payload=c:remote(entry);if payload then assert(SDR.decode(payload.lua));assert(not payload.stamp.etag,'Read-only snapshot acquired write guard');valid=valid+1 end end
  before=copy(totals);c:lazyProgress(visible);drain();local warm=delta(before);assert(warm.reads==0,'Unchanged native Lua was downloaded again')
  c.progress_fresh={};before=copy(totals);c:lazyProgress(visible);drain();local rechecked=delta(before);assert(rechecked.reads==0,'Unchanged metadata caused another media GET')
  report.libraries[number]={folders=folders,documents=documents,visible=#visible,native_snapshots=valid,bootstrap=bootstrap,incremental=incremental,first_progress=first,warm_progress=warm,rechecked_progress=rechecked}
  print(string.format('PASS read-only library %d: %d folders, %d documents, %d native summaries; bootstrap=%d requests, incremental=%d, progress=%d, unchanged media=0',number,folders,documents,valid,bootstrap.requests,incremental.requests,first.requests))
 end
 report.totals=totals
 local output=os.getenv('GDRIVESHELF_SMOKE_REPORT')
 if output then local f=assert(io.open(output,'wb'));f:write(JSON.encode(report));f:close()end
 print('PASS live catalog/progress smoke: no Drive writes, no archive reads, no credential persistence')
end
local ok,why=pcall(run)
if not ok then
 local code=tostring(why):match('([%w_]+)$')or 'failed'
 io.stderr:write('FAIL read-only catalog/progress smoke ('..(code:match('^[%w_]+$')and code or 'failed')..')\n');os.exit(1)
end
