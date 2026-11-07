local H=require('tests/helper');local Core=require('core');local Jobs=require('jobs');local SDR=require('sdr')
local function harness(remote_data,base_data)
 local e={id='book',name='Book.cbz',parent_id='title',size=10,version='1',modified_time='book-time',is_folder=false}
 local state={sync={pending={},bases={},conflicts={}},entries={},docs={book=e},folders={},downloads={},summaries={}}
 local files={};local temp={};local process={};local seq=0;local starts=0
 local fs={root='/cache',json={encode=function()return '{}'end},readJSON=function(_,p)if p=='/cache/index.json'then return state end;return files[p]end,writeJSON=function(_,p,v)files[p]=v;return true end,remove=function(_,p)files[p]=nil;temp[p]=nil;return true end,exists=function()return false end,writeTemp=function(_,text)temp.upload=text;return 'upload'end}
 local meta={id='metadata',name='metadata.cbz.lua',parent_id='sidecar',modified_time='m1',etag='etag1',version='1',is_folder=false}
 local remote=remote_data and assert(SDR.encode(remote_data))
 if base_data then state.sync.bases.book={lua=assert(SDR.encode(base_data)),stamp=meta,book_stamp=e}end
 local provider={credentials={}}
 function provider:list(id)if id=='title'then return {e,{id='sidecar',name='Book.sdr',parent_id='title',is_folder=true}}end;return remote and {meta}or{}end
 function provider:stat(id)if id=='book'then return e end;return meta end
 function provider:read()return remote end
 function provider:upload(_,_,path)remote=temp[path];meta.etag=meta.etag..'x';return meta end
 local backend={start=function(task,path)seq=seq+1;starts=starts+1;process[seq]={task=task,path=path};return seq end,done=function(pid)return process[pid].done end,stop=function(pid)process[pid].done=true end}
 local jobs=Jobs.new{storage=fs,dir='/jobs',backend=backend,schedule=function()end,unschedule=function()end}
 local c=Core.new{storage=fs,jobs=jobs,credentials={},provider_factory=function()return provider end,settings={sync_enabled=true}}
 local function finish()local p=process[jobs.active.pid];local v,err=p.task();files[p.path]={value=v,error=err};p.done=true;jobs:poll()end
 return c,e,finish,function()return remote and assert(SDR.decode(remote)),starts end
end
H.test('snapshot saved during active sync is flushed again automatically',function()
 local c,e,finish,cloud=harness(nil,nil)
 assert(c:snapshot(e,{last_page=1}));assert(c.jobs.active)
 assert(c:snapshot(e,{last_page=2}));finish();assert(c.jobs.active,'newest pending must be scheduled');finish()
 H.eq(c.state.sync.pending.book,nil);H.eq((cloud()).last_page,2)
end)
H.test('remote-only pull does not advance base before native restore',function()
 local c,e,finish=harness({last_page=20},{last_page=10})
 assert(c:snapshot(e,{last_page=10}));finish()
 assert(c.state.sync.pending.book,'local snapshot must remain until restoration')
 H.eq(assert(SDR.decode(c.state.sync.bases.book.lua)).last_page,10)
 local staged=assert(c:deferredProgress(e,{last_page=10}))
 H.eq(assert(SDR.decode(staged.lua)).last_page,20)
 H.eq(assert(SDR.decode(staged.expected_local_lua)).last_page,10)
 assert(c:completeDeferredProgress(e,staged))
 H.eq(c.state.sync.pending.book,nil)
 H.eq(assert(SDR.decode(c.state.sync.bases.book.lua)).last_page,20)
end)
H.test('backoff also prevents already queued jobs starting network work',function()
 local c,_,finish,cloud=harness(nil,nil);local second
 c:network('fail',function()return nil,{code='network',message='offline'}end,function()end)
 c:network('later',function()error('must not run')end,function(_,err)second=err end)
 finish();local _,starts=cloud();H.eq(starts,1);H.eq(second,nil);assert(c.jobs.keys.fail and c.jobs.keys.later and #c.jobs.queue==2)
end)
print('core sync integration tests passed')
