local H=require('tests/helper')
local load=loadfile('gdriveshelf.koplugin/localcovers.lua')
assert(load,'Local cover extraction is not implemented')
local Covers=load()
local Metadata=require('gdriveshelf/metadata')
local function png(w,h)
 local function be(n)return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)end
 return '\137PNG\r\n\26\n'..be(13)..'IHDR'..be(w)..be(h)..string.rep('\0',16)
end
local function write(path,data)local f=assert(io.open(path,'wb'));assert(f:write(data));f:close()end
local function withJobsDirectory(c)
 local ffi=require('ffi');pcall(ffi.cdef,'int mkdir(const char *, unsigned int);')
 H.eq(ffi.C.mkdir(c.storage.root,448),0);H.eq(ffi.C.mkdir(c.storage.root..'/jobs',448),0)
 return function()assert(os.remove(c.storage.root..'/jobs'));assert(os.remove(c.storage.root))end
end
local function fixture()
 local base=os.tmpname();os.remove(base)
 local path=base..'.cbz';write(path,'verified complete archive')
 local e={id='book',name='01.cbz',parent_id='folder',size=25,version='1',checksum='abcd'}
 local c={};for k,v in pairs(e)do c[k]=v end;c.path=path;c.ready=true;c.pool='auto'
 local K={};K.__index=K
 function K:cached(id)local x=self.state.entries[id];if x and self.storage:exists(x.path)then return x end end
 function K:protected()return self.active_id and {[self.active_id]=true}or{}end
 function K:cache()return {plan=function(_,_,_,protected)assert(protected.book,'Source lost eviction protection');return {}end}end
 function K:evict()end;function K:save()return true end;function K:emit()end
 function K:cachedList()return self.entries end
 function K:titleInfo()return {}end
 function K:online()return not self.settings.offline end
 local fs={root=base,lfs={attributes=function(p,key)local f=io.open(p,'rb');if not f then return nil end;local n=f:seek('end');f:close();local a={size=n,modification=100};return key and a[key]or a end}}
 function fs:exists(p)return self.lfs.attributes(p)~=nil end
 function fs:size(p)return self.lfs.attributes(p,'size')or 0 end
 function fs:filePath()return base..'.png'end
 function fs:remove(p)return os.remove(p)end
 function fs:mkdir()return true end
 local jobs={queue={},keys={},nonce='test'}
 function jobs:enqueue(key,task,done,front,before,progress,local_task,options)
  if self.keys[key]then return false end;self.keys[key]=true;self.queue[#self.queue+1]={key=key,task=task,done=done,before=before,local_task=local_task,options=options};return true
 end
 function jobs:cancel(key)
  self.keys[key]=nil
  for i,j in ipairs(self.queue)do if j.key==key then table.remove(self.queue,i);j.done(nil,{code='cancelled'});return end end
 end
 local core=setmetatable({storage=fs,jobs=jobs,settings={offline=true},state={entries={book=c},docs={book=e}},entries={e}},K)
 Covers.attach(K)
 local function clean()for _,suffix in ipairs{'.cbz','.png','.png.incoming-test'}do os.remove(base..suffix)end end
 return core,e,clean
end
H.test('offline verified books queue bounded local work with source eviction protection',function()
 local c,e,clean=fixture();H.eq(c:ensureLocalCovers({e}),1)
 H.eq(#c.jobs.queue,1);local j=c.jobs.queue[1];assert(j.local_task);H.eq(j.options.timeout,15);assert(c:protected().book)
 assert(j.before());j.done(nil,{code='preview',message='Unsupported archive'})
 assert(not c:protected().book);H.eq(c:ensureLocalCovers({e}),0);clean()
end)
H.test('partial changed and active books never create a cover job',function()
 local c,e,clean=fixture();c.active_id=e.id;H.eq(c:ensureLocalCovers({e}),0)
 c.active_id=nil;c.state.entries.book.ready=false;H.eq(c:ensureLocalCovers({e}),0)
 c.state.entries.book.ready=true;c.state.entries.book.checksum='other';H.eq(c:ensureLocalCovers({e}),0)
 c.state.entries.book.checksum='abcd';e.size=999;H.eq(c:ensureLocalCovers({e}),0);clean()
end)
H.test('completed local cover is bounded and visible without a beta flag',function()
 local c,e,clean=fixture();local T=require('gdriveshelf/thumbnails');local old=T.build
 T.build=function(entry,cached,provider,path)assert(cached and not provider);write(path,png(320,440));return {path=path}end
 assert(c:ensureLocalCovers({e})==1);local j=c.jobs.queue[1];assert(j.before());local result,err=j.task();assert(result,err and err.message);j.done(result)
 local cover=c:localCover(e);assert(cover and cover.path and cover.source_stamp==Metadata.fingerprint(e));H.eq(c:thumbnail(e),cover)
 T.build=old;clean()
end)
H.test('changed source cannot publish an older worker cover',function()
 local c,e,clean=fixture();c:ensureLocalCovers({e});local j=c.jobs.queue[1];assert(j.before())
 local path=c.storage:filePath()..'.incoming-test';write(path,png(320,440));write(c.state.entries.book.path,'replaced')
 j.done({path=path});assert(not c:localCover(e));assert(not c.storage:exists(path));clean()
end)
H.test('folder fallback uses a later available chapter cover',function()
 local c,e,clean=fixture();c.entries={{id='missing',name='00.cbz'},e}
 local path=c.storage:filePath();write(path,png(300,400));c.state.entries['thumb:book']={id='thumb:book',path=path,ready=true,source_stamp=Metadata.fingerprint(e)}
 H.eq(c:titleInfo('folder').cover_path,path);clean()
end)
H.test('native cover adapter never checks SDR and never reuses inherited documents',function()
 local base=os.tmpname();local output=base..'.png';local touched=0;local closed=0;local passed
 local registry={registry={}}
 local provider={provider='mupdf'}
 function provider:convertKoptToReflowableFontSize(n)assert(n==1,'Metadata-dependent font lookup');return 22 end
 function provider:extend(t)return setmetatable(t,{__index=self})end
 function registry:getProviders()return {{provider=provider}}end
 function registry:getProvider()error('Preferred-provider lookup reads SDR')end
 function registry:openDocument(path,p)assert(p~=provider);H.eq(p:convertKoptToReflowableFontSize(),22);return {file=path,close=function()closed=closed+1 end}end
 local bb={getWidth=function()return 800 end,getHeight=function()return 1200 end,free=function()end,writePNG=function(_,p)write(p,png(293,440))end}
 local old={registry=package.loaded['document/documentregistry'],helper=package.loaded['apps/filemanager/filemanagerbookinfo'],image=package.loaded['ui/renderimage']}
 package.loaded['document/documentregistry']=registry
 package.loaded['apps/filemanager/filemanagerbookinfo']={getCoverImage=function(_,doc,file,force)assert(doc and file==nil and force==true);return bb end}
 package.loaded['ui/renderimage']={scaleBlitBuffer=function(_,image,w,h)H.eq(w,293);H.eq(h,440);return image end}
 local result,err=Covers.build({name='sample.pdf'},{path=base},output);assert(result,err and err.message);H.eq(closed,1)
 registry.registry[base]={doc={}};local second,why=Covers.build({name='sample.pdf'},{path=base},output);assert(not second);H.eq(why.code,'active');H.eq(closed,1)
 package.loaded['document/documentregistry']=old.registry;package.loaded['apps/filemanager/filemanagerbookinfo']=old.helper;package.loaded['ui/renderimage']=old.image
 os.remove(base);os.remove(output)
end)
H.test('manual first-chapter extraction can use ranges with automatic beta previews disabled',function()
 local c,e,clean=fixture();c.settings.offline=false;c.settings.beta_thumbnails=false
 c.entries={{id='first',name='00.cbz',parent_id='folder',size=100,version='1'},e}
 local key;c.network=function(_,value)key=value;return true end
 local accepted,jobkey=c:extractFolderCover({id='folder'},function()end)
 assert(accepted);H.eq(key,'local-cover:first');H.eq(jobkey,key);clean()
end)
H.test('manual first-chapter extraction explains offline missing first chapter rather than choosing another',function()
 local c,e,clean=fixture();c.entries={{id='first',name='00.cbz',parent_id='folder',size=100,version='1'},e}
 local why;local accepted=c:extractFolderCover({id='folder'},function(_,err)why=err end)
 assert(not accepted and why and why.code=='preview');H.eq(#c.jobs.queue,0);clean()
end)
H.test('a local CBZ disappearing before the worker starts is a safe preview skip',function()
 local ok,result,err=pcall(Covers.build,{name='missing.cbz',size=1024},{path='/no-such-gdriveshelf-cover-fixture'},os.tmpname())
 assert(ok,'Missing local archive escaped as an exception');assert(not result and err and err.code=='preview')
end)
H.test('manual extraction of the active chapter finishes with an explanation',function()
 local c,e,clean=fixture();c.active_id=e.id;local why
 local accepted,err=c:extractFolderCover({id='folder'},function(_,failure)why=failure end)
 assert(not accepted and err and why and why.code=='active');H.eq(#c.jobs.queue,0);clean()
end)
H.test('completed background downloads schedule stable local cover work',function()
 local Core=require('gdriveshelf/core');local events={};local scheduled
 local core=setmetatable({onchange=function(kind)events[#events+1]=kind end},{__index=Core})
 core.ensureLocalCovers=function(_,entries)scheduled=entries[1]end
 local book={id='finished',name='example.cbz'}
 core:emit('downloaded',book)
 assert(scheduled==book,'download completion did not schedule a local preview')
 H.eq(events[1],'downloaded')
end)
H.test('a successful local cover can be regenerated after metadata LRU eviction',function()
 local c,e,clean=fixture();local T=require('gdriveshelf/thumbnails');local original=T.build
 T.build=function(_,_,_,path)write(path,png(320,440));return{path=path}end
 assert(c:ensureLocalCovers({e})==1);local j=c.jobs.queue[1];assert(j.before());j.done(assert(j.task()));c.jobs.keys[j.key]=nil
 local cover=assert(c:localCover(e));os.remove(cover.path);c.state.entries['thumb:book']=nil
 H.eq(c:ensureLocalCovers({e}),1)
 T.build=original;clean()
end)
H.test('light mode drops automatic cover tasks but keeps manual subscribers',function()
 local c,e,clean=fixture();assert(c:ensureLocalCovers({e})==1)
 c.settings.light_mode=true;c:cancelAutomaticCovers();H.eq(#c.jobs.queue,0);H.eq(c:ensureLocalCovers({e}),0)
 c.settings.light_mode=false;assert(c:ensureLocalCovers({e})==1)
 assert(c:extractFolderCover({id=e.parent_id},function()end))
 c.settings.light_mode=true;c:cancelAutomaticCovers();H.eq(#c.jobs.queue,1)
 c.jobs:cancel(c.jobs.queue[1].key);clean()
end)
H.test('page gallery keeps only one visible batch and releases archive pin before saving',function()
 local c,e,clean=fixture()
 local clean_dir=withJobsDirectory(c)
 local original=Covers.galleryPages
 Covers.galleryPages=function(entry,cached,first,count,paths,w,h)
  H.eq(entry,e);assert(cached.path);local pages={}
  for slot=1,count do write(paths[slot],png(w,h));pages[slot]={number=first+slot-1,path=paths[slot]}end
  return {total=10,first=first,pages=pages}
 end
 local function run()
  local job=table.remove(c.jobs.queue,1);assert(job.before());assert(job.local_task);H.eq(job.options.timeout,25)
  local data=job.task();c.jobs.keys[job.key]=nil;job.done(data)
 end
 local gallery=assert(c:coverGallery(e));assert(c:protected().book)
 local thumb;gallery:load(1,function(result)H.eq(#result.pages,6);thumb=result.pages[1].path end);run();assert(c.storage:exists(thumb))
 local selected;gallery:select(2,function(path)selected=assert(path)end);run();assert(c.storage:exists(selected))
 gallery:release();assert(not c:protected().book and not c.storage:exists(thumb)and c.storage:exists(selected))
 local cancelled=assert(c:coverGallery(e));cancelled:load(1,function()error('Cancelled gallery callback fired')end)
 cancelled:close();H.eq(#c.jobs.queue,0);assert(not c:protected().book)
 assert(c.storage:exists(selected),'Another gallery removed the already selected cover')
 gallery:close();assert(not c.storage:exists(selected))
 Covers.galleryPages=original
 clean_dir();clean()
end)
H.test('choosing a local image defers decoding and retains only a bounded draft file',function()
 local c,e,clean=fixture()
 local clean_dir=withJobsDirectory(c)
 local Thumbnails=require('gdriveshelf/thumbnails');local original=Thumbnails.render
 local reads=0
 function c.storage:read(path,limit)H.eq(path,'/picked.jpg');H.eq(limit,8*1048576);reads=reads+1;return 'raw input'end
 Thumbnails.render=function(data,path)H.eq(data,'raw input');write(path,png(320,440));return {path=path}end
 local prepared,discard
 local key=c:prepareFolderCover('/picked.jpg',function(path,err,cleanup)prepared=assert(path,err and err.message);discard=cleanup end)
 H.eq(reads,0);assert(key and not prepared)
 local job=table.remove(c.jobs.queue,1);H.eq(job.key,key);assert(job.local_task);job.done(assert(job.task()))
 H.eq(reads,1);assert(c.prepared_cover_paths[prepared] and c.storage:exists(prepared))
 discard();assert(not c.prepared_cover_paths[prepared] and not c.storage:exists(prepared))
 Thumbnails.render=original;clean_dir();clean()
end)
