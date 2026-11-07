local H=require('tests/helper')
local Core=require('gdriveshelf/core')
local SDR=require('gdriveshelf/sdr')
local id='chapter'
local book={id=id,name='Chapter.cbz',parent_id='title',checksum='booksum'}
local function encode(page,annotations)
 return assert(SDR.encode({last_page=page,doc_pages=10,summary={status='reading'},annotations=annotations}))
end
local function clone(v)
 if type(v)~='table'then return v end
 local result={};for key,value in pairs(v)do result[key]=clone(value)end;return result
end
local function fixture(localPage,cloudPage,policy)
 local fs={root='/fake',files={},writes=0}
 function fs:writeJSON(path,value)if self.fail==path then return nil,'write failed'end;self.files[path]=clone(value);return true end
 function fs:readJSON(path)return clone(self.files[path])end
 function fs:exists(path)return self.files[path]~=nil end
 function fs:writeTemp(lua)self.files['temp']=lua;return 'temp'end
 function fs:remove(path)self.files[path]=nil;return true end
 local folder={id='sdr',name='Chapter.sdr',parent_id='title',is_folder=true}
 local provider={uploads=0,book=book,metadata={id='meta',name='metadata.cbz.lua',parent_id='sdr',etag='e1',
  version='1',modified_time='2026-11-06T12:00:00Z'},lua=encode(cloudPage)}
 function provider:list(parent)
  if parent=='title'then return {self.book,folder}end
  if parent=='sdr'then return {self.metadata}end
  error('unexpected parent')
 end
 function provider:stat(key)
  if key==id then return clone(self.book)end
  if key=='meta'then return clone(self.metadata)end
  error('unexpected key')
 end
 function provider:read()return self.lua end
 function provider:upload(parent,name,path,key,etag)
  assert(parent=='sdr' and name=='metadata.cbz.lua' and key=='meta' and etag==self.metadata.etag)
  self.uploads=self.uploads+1
  self.metadata.etag='e2'
  self.metadata.version='2'
  if self.race then self.lua=encode(7);return nil,{status=412,code='api'}end
  self.lua=fs.files[path]
  return clone(self.metadata)
 end
 fs:writeJSON('/fake/index.json',{sync={bases={[id]={lua=encode(1),book_stamp=book}}}})
 local function create()
  local jobs,events={},{}
  local c=Core.new{settings={sync_enabled=true,sync_conflict_policy=policy},storage=fs,jobs={setOffline=function()end},
   provider_factory=function()return provider end,onchange=function(kind,entry,detail)
    events[#events+1]={kind=kind,entry=entry,detail=detail}
   end}
  function c:network(key,work,done,front,before)
   for _,j in ipairs(jobs)do if j.key==key then return false end end
   jobs[#jobs+1]={key=key,work=work,done=done,before=before}
   return true
  end
  local function step()
   local job=assert(table.remove(jobs,1),'nothing queued')
   if job.before then local ok,e=job.before();if not ok then job.done(nil,e);return end end
   local result,e=job.work(provider);job.done(result,e)
  end
  return c,step,jobs,events
 end
 local c,step,jobs,events=create()
 assert(c:snapshot(book,assert(SDR.decode(encode(localPage)))))
 return c,step,jobs,events,provider,fs,create
end
H.test('farthest choice archives both versions before an update and resumes after restart',function()
 local c,step,jobs,events,p,fs,restart=fixture(8,5)
 step()
 assert(#jobs==1 and p.uploads==0)
 local intent=assert(c.state.sync.resolutions[id])
 local archive=assert(fs:readJSON('/fake/snapshots/'..intent.id..'.json'))
 assert(archive.choice=='local' and archive.local_lua==encode(8) and archive.remote_lua==encode(5))
 local persisted=assert(fs:readJSON('/fake/index.json'))
 assert(persisted.sync.resolutions[id].id==intent.id)
 local recovered,nextStep=restart()
 recovered:flushPending();nextStep()
 assert(p.uploads==1 and p.lua==encode(8))
 assert(not recovered.state.sync.resolutions[id] and not recovered.state.sync.pending[id])
end)
H.test('HTTP 412 preserves archived alternatives and shows the changed cloud snapshot',function()
 local c,step,jobs,events,p,fs=fixture(8,5)
 step();p.race=true
 local archived=c.state.sync.resolutions[id].id
 step()
 local conflict=assert(c.state.sync.conflicts[id])
 assert(conflict.reason=='changed_during_resolution' and conflict.remote_lua==encode(7))
 assert(fs:readJSON('/fake/snapshots/'..archived..'.json').remote_lua==encode(5))
 assert(#jobs==0 and events[#events].kind=='conflict')
end)
H.test('an interrupted upload is acknowledged when the already-written bytes match',function()
 local c,step,_,_,p,_,restart=fixture(8,5)
 step()
 p.lua=encode(8);p.metadata.etag='e2'
 local recovered,nextStep=restart()
 recovered:flushPending();nextStep()
 assert(p.uploads==0 and not recovered.state.sync.resolutions[id])
 assert(recovered.state.sync.bases[id].lua==encode(8))
end)
H.test('a new local revision interrupts in-flight selection without losing either version',function()
 local c,step,jobs,events,p,fs=fixture(8,5)
 step()
 local intent=c.state.sync.resolutions[id]
 local stat=p.stat
 local hits=0
 function p:stat(key)
  if key==id then hits=hits+1;if hits==2 then assert(c:snapshot(book,assert(SDR.decode(encode(9)))))end end
  return stat(self,key)
 end
 step()
 assert(p.uploads==0 and #jobs==0 and events[#events].kind=='conflict')
 assert(c.state.sync.conflicts[id].local_lua==encode(9))
 assert(fs:readJSON('/fake/snapshots/'..intent.id..'.json').local_lua==encode(8))
end)
H.test('cloud choice defers native application until the matching book is safely reopened',function()
 local c,step,_,_,p,_,restart=fixture(4,7)
 step();step()
 assert(p.uploads==0 and c.state.sync.pending[id].lua==encode(4))
 local recovered=restart()
 local old=assert(SDR.decode(encode(4)))
 recovered.active_id=id
 assert(not recovered:deferredProgress(book,old))
 recovered.active_id=nil
 assert(not recovered:deferredProgress({id=id,checksum='replaced'},old))
 local staged=assert(recovered:deferredProgress(book,old))
 assert(staged.lua==encode(7))
 -- Native flush can succeed before a crash; acknowledging equal bytes is safe.
 assert(recovered:deferredProgress(book,assert(SDR.decode(encode(7))))==staged)
 assert(recovered:completeDeferredProgress(book,staged))
 assert(not recovered.state.sync.deferred[id] and not recovered.state.sync.pending[id] and recovered.state.sync.bases[id].lua==encode(7))
end)
H.test('opening older local metadata without a verified common baseline creates an explicit comparison',function()
 local c,step,_,_,p=fixture(4,7,'manual')
 step()
 local conflict=c.state.sync.conflicts[id]
 assert(conflict and p.uploads==0)
 assert(c:snapshot(book,assert(SDR.decode(encode(5)))))
 assert(not c:resolveProgressConflict(book,'local',conflict))
 local selected=assert(c:resolveProgressConflict(book,'remote',c.state.sync.conflicts[id]))
 step()
 assert(c.state.sync.deferred[id].id==selected.id)
 assert(not c:deferredProgress(book,assert(SDR.decode(encode(6)))))
 assert(c.state.sync.conflicts[id].local_lua==encode(6))
end)
H.test('a failed journal write leaves both versions and prevents any mutation',function()
 local c,step,jobs,_,p,fs=fixture(8,5,'manual')
 step()
 local conflict=c.state.sync.conflicts[id]
 fs.fail='/fake/index.json'
 assert(not c:resolveProgressConflict(book,'local',conflict))
 assert(not c.state.sync.resolutions[id] and c.state.sync.conflicts[id].remote_lua==encode(5))
 assert(#jobs==0 and p.uploads==0)
end)
H.test('cloud progress applies without a sidecar but a divergent native file stays intact',function()
 local c,_,_,_,_,fs,restart=fixture(4,7)
 fs:writeJSON('/fake/index.json',{sync={}})
 c=restart()
 local remote={lua=encode(7),book_stamp=book,stamp={id='meta',version='1',etag='e1'}}
 local staged=assert(c:stageRemoteProgress(book,remote,nil))
 assert(c:completeDeferredProgress(book,staged))
 -- Re-downloading a file with no native sidecar can restore the same cloud base.
 assert(c:stageRemoteProgress(book,remote,nil))
 fs:writeJSON('/fake/index.json',{sync={}})
 c=restart()
 local result,e=c:stageRemoteProgress(book,remote,assert(SDR.decode(encode(4,{{text='local bookmark'}}))))
 assert(not result and e.code=='conflict')
 assert(SDR.decode(c.state.sync.conflicts[id].local_lua).annotations[1].text=='local bookmark')
end)
H.test('a newly observed remote revision supersedes a cloud decision awaiting reopen',function()
 local c,step=fixture(4,7)
 step();step()
 local older=assert(c.state.sync.deferred[id])
 local newer={lua=encode(9),book_stamp=book,stamp={id='meta',version='2',etag='e2'}}
 assert(not c:deferredProgress(book,assert(SDR.decode(encode(4))),newer))
 assert(not c.state.sync.deferred[id])
 assert(c.state.sync.conflicts[id].remote_lua==encode(9))
 assert(not c:completeDeferredProgress(book,older))
end)
H.test('a durable push invalidates stale remote metadata and rejects it on reopen',function()
 local c,step,_,_,p,fs=fixture(8,1)
 local stale={lua=encode(1),stamp=clone(p.metadata),book_stamp=book}
 local key='sdr:'..id
 local path='/fake/remote-sdr.json'
 fs:writeJSON(path,stale)
 c.state.entries[key]={id=key,pool='meta',path=path,ready=true}
 c.state.progress_cache={[id]={summary={page=1}}}
 assert(c:save())
 step()
 assert(p.uploads==1 and c.state.sync.bases[id].lua==encode(8))
 assert(not c.state.entries[key] and not fs:exists(path) and not c.state.progress_cache[id])
 assert(not fs:readJSON('/fake/index.json').entries[key])
 local current=assert(SDR.decode(encode(8)))
 assert(not c:stageRemoteProgress(book,stale,current))
 local newer={lua=encode(9),stamp={id='meta',version='3',etag='e3'},book_stamp=book}
 assert(c:stageRemoteProgress(book,newer,current))
end)
H.test('a missing sidecar can recover the known base instead of restoring an older cache',function()
 local c,step,_,_,p=fixture(8,1)
 local stale={lua=encode(1),stamp=clone(p.metadata),book_stamp=book}
 step()
 local restored=assert(c:stageRemoteProgress(book,stale,nil))
 assert(restored.lua==encode(8) and restored.stamp.version=='2')
end)
