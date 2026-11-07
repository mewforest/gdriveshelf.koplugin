local H=require('tests/helper')
local load=loadfile('gdriveshelf.koplugin/overrides.lua')
assert(load,'Durable folder metadata editing is not implemented')
local Overrides=load()
local SDR=require('gdriveshelf/sdr')
local codec={encode=function(t)return assert(SDR.encode(t))end,decode=function(s)return assert(SDR.decode(s))end}
local function fixture()
 local fs={root='/metadata-test',data={},json=codec}
 function fs:read(p,limit)local s=self.data[p];if s and #s<=(limit or math.huge)then return s end end
 function fs:write(p,s)self.data[p]=s;return true end
 function fs:readJSON(p,limit)local s=self:read(p,limit);if s then return SDR.decode(s)end end
 function fs:writeJSON(p,t)return self:write(p,codec.encode(t))end
 function fs:exists(p)return self.data[p]~=nil end
 function fs:mkdir()return true end
 function fs:remove(p)self.data[p]=nil;return true end
 local provider={files={},contents={},uploads={}}
 function provider:list()local out={};for _,e in ipairs(self.files)do out[#out+1]=e end;return out end
 function provider:stat(id)for _,e in ipairs(self.files)do if e.id==id then local c={};for k,v in pairs(e)do c[k]=v end;return c end end end
 function provider:read(e)return self.contents[e.id]end
 function provider:upload(parent,name,path,id,etag)
  if id then local e=self:stat(id);assert(etag,'Unguarded overwrite');if e.etag~=etag then return nil,{code='conflict'}end end
  local e={id=id or 'remote-'..(#self.files+1),parent_id=parent,name=name,version=tostring(#self.uploads+1),etag='etag-'..(#self.uploads+1)}
  self.uploads[#self.uploads+1]={name=name,id=id,etag=etag,body=fs:read(path)}
  self.contents[e.id]=fs:read(path)
  local replaced=false;for i,v in ipairs(self.files)do if v.id==id then self.files[i]=e;replaced=true end end
  if not replaced then self.files[#self.files+1]=e end;return e
 end
 local K={};K.__index=K
 function K:titleInfo()return {title='Original title',description='Original description',author='Original author',cover_path='original-cover'}end
 function K:metadata()self.imports=(self.imports or 0)+1 end
 function K:resume()self.resumes=(self.resumes or 0)+1 end
 function K:online()return not self.settings.offline end
 function K:cachedList()return self.entries or{}end
 function K:save()return true end
 function K:emit(kind)self.last_event=kind end
 function K:network(key,work,done)
  if not self:online()then return false end
  if self.keys[key]then return false end;self.keys[key]=true
  self.queue[#self.queue+1]=function()self.keys[key]=nil;local r,e=work(provider);done(r,e)end;return true
 end
 Overrides.attach(K)
 local core=setmetatable({storage=fs,state={},settings={offline=true},queue={},keys={}},K)
 local function drain()local n=0;while #core.queue>0 do n=n+1;assert(n<20,'Metadata queue loop');table.remove(core.queue,1)()end end
 return core,provider,drain,K
end
H.test('offline edits merge immediately without changing imported metadata or tree state',function()
 local c,p=fixture();local result
 assert(c:saveFolderMetadata({id='folder'},{title='My title',description=''},nil,function(r)result=r end))
 local info=c:titleInfo('folder');H.eq(info.title,'My title');H.eq(info.description,'');H.eq(info.author,'Original author');H.eq(info.cover_path,'original-cover')
 assert(result and result.queued);H.eq(#p.uploads,0);assert(next(c.storage.data));assert(not c.state.entries)
end)
H.test('outbox restores an offline edit in a fresh core and uploads on resume',function()
 local c,p,drain,K=fixture();assert(c:saveFolderMetadata({id='folder'},{title='Saved offline',description='Text'}))
 local second=setmetatable({storage=c.storage,state={},settings={offline=false},queue=c.queue,keys=c.keys},K)
 H.eq(second:titleInfo('folder').title,'Saved offline');second:resume();drain()
 H.eq(#p.uploads,1);H.eq(p.uploads[1].name,'gdriveshelf.json');local values=codec.decode(p.uploads[1].body)
 H.eq(values.schema,1);H.eq(values.title,'Saved offline');assert(not values.tree and not values.progress and not values.author)
 assert(not second:metadataConflict('folder'))
end)
H.test('changed remote metadata preserves local edit and remote version until explicit resolution',function()
 local c,p,drain=fixture();p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='2',etag='two'}}
 p.contents.json=codec.encode{schema=1,title='Remote title',description='Remote description'}
 assert(c:saveFolderMetadata({id='folder'},{title='My offline title'}));c.settings.offline=false;c:flushMetadata();drain()
 local conflict=c:metadataConflict('folder');assert(conflict);H.eq(conflict.local_values.title,'My offline title');H.eq(conflict.remote_values.title,'Remote title');H.eq(#p.uploads,0)
 H.eq(c:titleInfo('folder').title,'My offline title')
 assert(c:resolveMetadataConflict('folder','local'));drain();H.eq(#p.uploads,1);H.eq(p.uploads[1].etag,'two');assert(not c:metadataConflict('folder'))
end)
H.test('duplicate JSON filenames never select an arbitrary overwrite target',function()
 local c,p,drain=fixture();p.files={{id='a',name='gdriveshelf.json',parent_id='folder'},{id='b',name='gdriveshelf.json',parent_id='folder'}}
 assert(c:saveFolderMetadata({id='folder'},{title='Local'}));c.settings.offline=false;c:flushMetadata();drain()
 H.eq(c:metadataConflict('folder').code,'ambiguous_metadata');H.eq(#p.uploads,0)
 local ok=c:resolveMetadataConflict('folder','local');assert(not ok)
end)
H.test('accepting the remote conflict does not write to Drive',function()
 local c,p,drain=fixture();p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='2',etag='two'}};p.contents.json=codec.encode{schema=1,title='Remote title'}
 c:saveFolderMetadata({id='folder'},{title='My version'});c.settings.offline=false;c:flushMetadata();drain()
 assert(c:resolveMetadataConflict('folder','remote'));H.eq(c:titleInfo('folder').title,'Remote title');H.eq(#p.uploads,0);assert(not c:metadataConflict('folder'))
end)
H.test('importing manual metadata ignores automatic import preference and preserves provenance',function()
 local c,p,drain=fixture();c.settings.offline=false;c.settings.load_metadata=false
 local e={id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'};p.files={e};p.contents.json=codec.encode{schema=1,title='Manual remote title',tree={leak=true},progress=100}
 c:metadata({e});drain();H.eq(c:titleInfo('folder').title,'Manual remote title');H.eq(c:titleInfo('folder').author,'Original author');assert(not c:titleInfo('folder').tree)
end)
H.test('light mode reads and sends folder overrides on explicit action only',function()
 local c,p,drain=fixture()
 c.settings.light_mode=true
 assert(c:saveFolderMetadata('draft',{title='Unsent'}))
 local entry={id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'};p.files={entry}
 p.contents.json=codec.encode{schema=1,title='Cloud folder'}
 c.settings.offline=false
 c:metadata({entry});c:resume();H.eq(#c.queue,0)
 c:metadata({entry},true);drain();H.eq(c:titleInfo('folder').title,'Cloud folder')
 p.files={};c:resume(true);drain();H.eq(#p.uploads,1)
end)
H.test('saving a prepared draft does not decode the image again on the UI thread',function()
 local c=fixture();local T=require('gdriveshelf/thumbnails');local render=T.render;local sha=package.loaded['ffi/sha2']
 local png='\137PNG\r\n\26\n\0\0\0\13IHDR\0\0\1\64\0\0\1\184'
 c.storage:write('/prepared.png',png);c.prepared_cover_paths={['/prepared.png']=true}
 package.loaded['ffi/sha2']={sha256=function()return string.rep('b',64)end}
 T.render=function()error('Already prepared PNG was decoded again')end
 assert(c:saveFolderMetadata('folder',{title='Title'},'/prepared.png'))
 local cover=c:titleInfo('folder').custom_cover_path
 assert(cover~='/prepared.png');H.eq(c.storage:read(cover),png)
 T.render=render;package.loaded['ffi/sha2']=sha
end)
H.test('an in-flight older save cannot acknowledge a newer offline edit',function()
 local c,p,drain=fixture();c.settings.offline=false;c:saveFolderMetadata({id='folder'},{title='First'})
 c.settings.offline=true;c:saveFolderMetadata({id='folder'},{title='Second'});drain();H.eq(c:titleInfo('folder').title,'Second')
 c.settings.offline=false;c:flushMetadata();drain();H.eq(c:titleInfo('folder').title,'Second')
 local last=codec.decode(p.uploads[#p.uploads].body);H.eq(last.title,'Second')
end)
H.test('new cover uploads before its JSON pointer and older cover bytes are immutable',function()
 local c,p,drain=fixture();local T=require('gdriveshelf/thumbnails');local render=T.render;local sha=package.loaded['ffi/sha2']
 local function be(n)return string.char(math.floor(n/16777216)%256,math.floor(n/65536)%256,math.floor(n/256)%256,n%256)end
 local function png(marker)return '\137PNG\r\n\26\n'..be(13)..'IHDR'..be(320)..be(440)..marker end
 package.loaded['ffi/sha2']={sha256=function(data)return string.rep(string.format('%02x',data:byte(-1)),32)end}
 T.render=function(data,path)c.storage:write(path,data);return {path=path}end
 c.storage:write('/chosen',png('a'));assert(c:saveFolderMetadata({id='folder'},{title='First'},'/chosen'))
 local first=c:titleInfo('folder').cover_path;local bytes=c.storage:read(first);assert(first:match('/gdriveshelf%-cover%-[a-f0-9]+%.png$'))
 c.settings.offline=false;c:flushMetadata();drain();H.eq(#p.uploads,2);assert(p.uploads[1].name:match('%.png$'));H.eq(p.uploads[2].name,'gdriveshelf.json')
 c.storage:write('/chosen',png('b'));assert(c:saveFolderMetadata({id='folder'},{title='Second'},'/chosen'));drain()
 assert(c:titleInfo('folder').cover_path~=first);H.eq(c.storage:read(first),bytes);H.eq(p.uploads[4].etag,'etag-2')
 T.render=render;package.loaded['ffi/sha2']=sha
end)
H.test('conditional-write conflict keeps both values and never retries as an unguarded upload',function()
 local c,p,drain=fixture();local e={id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'};p.files={e};p.contents.json=codec.encode{schema=1,title='Before'}
 c.settings.offline=false;c:metadata({e});drain();assert(c:saveFolderMetadata({id='folder'},{title='My edit'}))
 local upload=p.upload
 p.upload=function(self,parent,name,path,id,etag)
  H.eq(id,'json');H.eq(etag,'one');self.files[1]={id='json',name='gdriveshelf.json',parent_id='folder',version='2',etag='two'};self.contents.json=codec.encode{schema=1,title='Concurrent edit'}
  return nil,{code='conflict',status=412}
 end
 drain();local conflict=c:metadataConflict('folder');assert(conflict);H.eq(conflict.local_values.title,'My edit');H.eq(conflict.remote_values.title,'Concurrent edit');H.eq(#p.uploads,0)
 p.upload=upload
end)
H.test('unreadable durable edits are preserved rather than reset',function()
 local c=fixture();c.storage:write('/metadata-test/metadata-outbox.json','broken')
 local ok,err=c:saveFolderMetadata({id='folder'},{title='New'});assert(not ok and err);H.eq(c.storage:read('/metadata-test/metadata-outbox.json'),'broken')
end)
H.test('metadata filenames in different folders do not create a false duplicate conflict',function()
 local c,p,drain=fixture();c.settings.offline=false
 local first={id='a',name='gdriveshelf.json',parent_id='first',version='1',etag='a'}
 local second={id='b',name='gdriveshelf.json',parent_id='second',version='1',etag='b'}
 p.files={first,second};p.contents.a=codec.encode{schema=1,title='First folder'};p.contents.b=codec.encode{schema=1,title='Second folder'}
 c:metadata({first,second});drain();H.eq(c:titleInfo('first').title,'First folder');H.eq(c:titleInfo('second').title,'Second folder')
end)
H.test('failed outbox write does not replace the previously durable visible edit',function()
 local c=fixture();assert(c:saveFolderMetadata({id='folder'},{title='Durable'}))
 local writeJSON=c.storage.writeJSON
 c.storage.writeJSON=function(self,path,value)if path:match('metadata%-outbox%.json$')then return nil,'Disk full'end;return writeJSON(self,path,value)end
 local ok,err=c:saveFolderMetadata({id='folder'},{title='Not saved'});assert(not ok and err);H.eq(c:titleInfo('folder').title,'Durable')
end)
H.test('oversized encoded text finishes the editor callback without saving a partial edit',function()
 local c=fixture();local why
 local ok,err=c:saveFolderMetadata({id='folder'},{title='Title',description=string.rep('\n',40000)},nil,function(_,failure)why=failure end)
 assert(not ok and err and why);H.eq(c:titleInfo('folder').title,'Original title');assert(not next(c.storage.data))
end)
H.test('a newer online edit automatically follows its in-flight predecessor',function()
 local c,p,drain=fixture();c.settings.offline=false
 assert(c:saveFolderMetadata('folder',{title='First'}));assert(c:saveFolderMetadata('folder',{title='Second'}));drain()
 H.eq(codec.decode(p.contents[p.files[1].id]).title,'Second');assert(not c.folder_metadata.pending.folder)
end)
H.test('refresh clears a resolved duplicate conflict even when the original is unchanged',function()
 local c,p,drain=fixture();c.settings.offline=false
 local original={id='json',parent_id='folder',name='gdriveshelf.json',version='1',etag='one'}
 p.files={original};p.contents.json=codec.encode{schema=1,title='Original'}
 c:metadata({original});drain()
 p.files[2]={id='duplicate',parent_id='folder',name='gdriveshelf.json',version='2',etag='two'}
 p.contents.duplicate=codec.encode{schema=1,title='Duplicate'}
 assert(c:saveFolderMetadata('folder',{title='My edit'}));drain();H.eq(c:metadataConflict('folder').code,'ambiguous_metadata')
 p.files={original};c:metadata({original});drain()
 assert(not c:metadataConflict('folder'));assert(not c.folder_metadata.pending.folder);H.eq(codec.decode(p.contents.json).title,'My edit')
end)
H.test('temporary metadata reads preserve structured errors instead of creating conflicts',function()
 for _,failure in ipairs{{code='network',message='Temporary transport failure'},{code='api',status=503,message='Temporary server failure'},{code='auth',message='Authorization required'},{code='io',message='Local disk failure'}}do
  local c,p,drain=fixture();c.settings.offline=false
  local original={id='json',parent_id='folder',name='gdriveshelf.json',version='1',etag='one'}
  p.files={original};p.contents.json=codec.encode{schema=1,title='Original'};c:metadata({original});drain()
  local read=p.read;p.read=function()return nil,failure end
  assert(c:saveFolderMetadata('folder',{title='My edit'}));drain()
  assert(not c:metadataConflict('folder'),'temporary read was converted into an unrecoverable conflict')
  assert(c.folder_metadata.pending.folder);p.read=read;c:flushMetadata();drain()
  assert(not c.folder_metadata.pending.folder);H.eq(codec.decode(p.contents.json).title,'My edit')
 end
end)
H.test('explicit local choice recreates a confirmed deleted metadata pointer safely',function()
 local c,p,drain=fixture();c.settings.offline=false
 local original={id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}
 p.files={original};p.contents.json=codec.encode{schema=1,title='Original'};c:metadata({original});drain()
 c.settings.offline=true;assert(c:saveFolderMetadata('folder',{title='My edit'}));p.files={};c.settings.offline=false;c:flushMetadata();drain()
 local issue=c:metadataConflict('folder');assert(issue and issue.confirmed_absent,'Missing pointer was not acknowledged as absent')
 assert(c:resolveMetadataConflict('folder','local'));drain();H.eq(#p.uploads,1);assert(not p.uploads[1].id);H.eq(codec.decode(p.uploads[1].body).title,'My edit');assert(not c:metadataConflict('folder'))
end)
H.test('a pointer reappearing after deletion recovery is preserved as a fresh conflict',function()
 local c,p,drain=fixture();c.settings.offline=false
 local original={id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}
 p.files={original};p.contents.json=codec.encode{schema=1,title='Original'};c:metadata({original});drain()
 c.settings.offline=true;c:saveFolderMetadata('folder',{title='Mine'});p.files={};c.settings.offline=false;c:flushMetadata();drain();assert(c:resolveMetadataConflict('folder','local'))
 p.files={{id='replacement',name='gdriveshelf.json',parent_id='folder',version='2',etag='two'}};p.contents.replacement=codec.encode{schema=1,title='Reappeared'}
 drain();H.eq(#p.uploads,0);local issue=assert(c:metadataConflict('folder'));H.eq(issue.remote_entry.id,'replacement');H.eq(issue.remote_values.title,'Reappeared')
end)
H.test('explicit malformed JSON recovery preserves private raw bytes before a guarded overwrite',function()
 local c,p,drain=fixture();c.settings.offline=false;p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}}
 local raw='{"schema":1,"broken":';p.contents.json=raw;assert(c:saveFolderMetadata('folder',{title='Recovered'}));drain()
 local issue=assert(c:metadataConflict('folder'));assert(issue.unreadable_json and issue.remote_backup_path,'Malformed JSON has no recoverable snapshot');H.eq(c.storage:read(issue.remote_backup_path),raw);H.eq(#p.uploads,0)
 assert(c:resolveMetadataConflict('folder','local'));drain();H.eq(#p.uploads,1);H.eq(p.uploads[1].etag,'one');H.eq(codec.decode(p.contents.json).title,'Recovered');H.eq(c.storage:read(issue.remote_backup_path),raw);assert(not c:metadataConflict('folder'))
 H.eq(c.folder_metadata.records.folder.preserved_remote_backup_path,issue.remote_backup_path)
end)
H.test('malformed JSON recovery never bypasses a newer ETag and preserves both raw versions',function()
 local c,p,drain=fixture();c.settings.offline=false;p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}}
 local first='broken first';p.contents.json=first;c:saveFolderMetadata('folder',{title='Mine'});drain();local old=assert(c:metadataConflict('folder'));assert(c:resolveMetadataConflict('folder','local'))
 p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='2',etag='two'}};local second='broken second';p.contents.json=second
 drain();H.eq(#p.uploads,0);local current=assert(c:metadataConflict('folder'));H.eq(current.remote_entry.etag,'two');H.eq(c.storage:read(old.remote_backup_path),first);H.eq(c.storage:read(current.remote_backup_path),second)
end)
H.test('failed raw backup writes never authorize malformed metadata replacement',function()
 local c,p,drain=fixture();c.settings.offline=false;p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}};p.contents.json='broken'
 local write=c.storage.write;c.storage.write=function(self,path,data)if path:find('/conflicts/',1,true)then return nil,'Disk full'end;return write(self,path,data)end
 assert(c:saveFolderMetadata('folder',{title='Mine'}));drain();H.eq(#p.uploads,0);assert(c.folder_metadata.pending.folder)
 local accepted=c:resolveMetadataConflict('folder','local');assert(not accepted);H.eq(p.contents.json,'broken');H.eq(c:titleInfo('folder').title,'Mine')
end)
H.test('a missing malformed metadata backup blocks explicit local resolution',function()
 local c,p,drain=fixture();c.settings.offline=false;p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}};p.contents.json='broken'
 c:saveFolderMetadata('folder',{title='Mine'});drain();local issue=assert(c:metadataConflict('folder'));assert(issue.remote_backup_path);c.storage:remove(issue.remote_backup_path)
 local accepted=c:resolveMetadataConflict('folder','local');assert(not accepted);assert(c:metadataConflict('folder'));H.eq(#p.uploads,0)
end)
H.test('future metadata schemas stay unsupported and are not overwritten by local recovery',function()
 local c,p,drain=fixture();c.settings.offline=false;p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}};local wire=codec.encode{schema=2,title='Future format'};p.contents.json=wire
 c:saveFolderMetadata('folder',{title='Mine'});drain();local accepted=c:resolveMetadataConflict('folder','local');assert(not accepted);drain();H.eq(p.contents.json,wire);H.eq(#p.uploads,0)
end)
H.test('a freshly moved or renamed pointer cannot authorize edits to another remote path',function()
 for _,change in ipairs{{name='renamed.json',parent_id='folder'},{name='gdriveshelf.json',parent_id='another-folder'}}do
  local c,p,drain=fixture();c.settings.offline=false
  p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}};p.contents.json=codec.encode{schema=1,title='Remote'}
  p.stat=function()return {id='json',name=change.name,parent_id=change.parent_id,version='2',etag='two'}end
  c:saveFolderMetadata('folder',{title='Mine'});drain()
  assert(not c:metadataConflict('folder'),'Moved or renamed file was offered as an overwrite target')
  assert(c.folder_metadata.pending.folder.last_error);H.eq(#p.uploads,0);H.eq(codec.decode(p.contents.json).title,'Remote')
 end
end)
H.test('hide and reset are distinct across reload and cloud round trip',function()
 local c,p,drain,K=fixture()
 assert(c:saveFolderMetadata('folder',{title='Mine'},true))
 local i=c:titleInfo('folder');assert(i.cover_hidden);H.eq(i.cover_path,nil);H.eq(i.automatic_cover_path,'original-cover')
 local fresh=setmetatable({storage=c.storage,state={},settings={offline=false},queue=c.queue,keys=c.keys},K)
 H.eq(fresh:titleInfo('folder').cover_source,'hidden');fresh:flushMetadata();drain()
 local remote=codec.decode(p.contents[p.files[1].id]);assert(remote.cover_hidden and not remote.cover)
 assert(fresh:saveFolderMetadata('folder',{title='Keep hide'},nil));drain()
 H.eq(fresh:titleInfo('folder').cover_path,nil)
 assert(fresh:saveFolderMetadata('folder',{title='Reset'},false));drain()
 i=fresh:titleInfo('folder');assert(not i.cover_hidden);H.eq(i.cover_path,'original-cover')
 remote=codec.decode(p.contents[p.files[1].id]);assert(not remote.cover_hidden and not remote.cover)
end)
H.test('cover-only conflict exposes separate effective previews without changing the remote pointer',function()
 local c,p,drain=fixture()
 p.files={{id='json',name='gdriveshelf.json',parent_id='folder',version='1',etag='one'}}
 p.contents.json=codec.encode{schema=1,title='Same title'}
 assert(c:saveFolderMetadata('folder',{title='Same title'},true))
 c.settings.offline=false;c:flushMetadata();drain()
 local issue=assert(c:metadataConflict('folder'))
 H.eq(issue.local_values.title,issue.remote_values.title);assert(issue.local_values.cover_hidden)
 H.eq(issue.local_preview_path,nil);H.eq(issue.remote_preview_path,'original-cover');H.eq(issue.remote_cover_path,nil)
 assert(c:resolveMetadataConflict('folder','remote'));H.eq(c:titleInfo('folder').cover_path,'original-cover');H.eq(#p.uploads,0)
end)
