local H=require('tests/helper');local F=require('catalog_fixture');local Core=require('core');local SDR=require('sdr')
local ok,install=pcall(require,'progress');assert(ok,'Visible progress cache module is missing');install(Core)
local function fixture()
 local entries,parents,sidecars,texts={},{},{},{};local counters={lists=0,reads=0,stats=0}
 for i=1,7 do
  entries[i]={id='b'..i,name=i..'.cbz',parent_id='title',version='book-v1',size=10}
  parents[#parents+1]=entries[i];parents[#parents+1]={id='s'..i,name=i..'.sdr',parent_id='title',is_folder=true}
  sidecars['s'..i]={{id='m'..i,name='metadata.cbz.lua',parent_id='s'..i,version='1',size=10}}
  texts['m'..i]=assert(SDR.encode({last_page=i}))
 end
 local p={}
 function p:listParents(ids)counters.lists=counters.lists+1;local out={};for _,id in ipairs(ids)do out[id]=id=='title'and parents or sidecars[id]or{}end;return out end
 function p:read(e) counters.reads=counters.reads+1;return texts[e.id]end
 function p:stat()counters.stats=counters.stats+1;error('Visible summaries must not acquire a write guard')end
 local c,step,drain,jobs,events=F.new({home='home',sync_enabled=true},p)
 return c,step,drain,jobs,events,p,counters,entries,parents,sidecars,texts
end
H.test('seven visible summaries share parent discovery and grouped native SDR listings',function()
 local c,_,drain,_,_,_,calls,entries=fixture();c:lazyProgress(entries);drain()
 H.eq(calls.lists,2);H.eq(calls.reads,7);H.eq(calls.stats,0);H.eq(c.state.summaries.b7.page,7);assert(c:remote(entries[1]).lua);assert(not c:remote(entries[1]).stamp.etag)
end)
H.test('fresh parent listing is reused and unchanged Lua causes no media request',function()
 local c,_,drain,_,_,_,calls,entries,parents=fixture();c:rememberList('title',parents);c:lazyProgress(entries);drain();H.eq(calls.lists,1)
 local before=calls.reads;c:lazyProgress(entries);drain();H.eq(calls.reads,before);H.eq(c.state.summaries.b1.page,1)
end)
H.test('only changed metadata downloads and pending local progress stays newest',function()
 local c,_,drain,_,_,_,calls,entries,_,sidecars,texts=fixture();c:lazyProgress(entries);drain()
 sidecars.s2[1].version='2';texts.m2=assert(SDR.encode({last_page=20}));c.state.progress_cache.b2.dirty=true
 c.state.sync.pending.b2={lua='newest-local'};c.state.summaries.b2={page=99}
 c:lazyProgress(entries);drain();H.eq(calls.reads,8);H.eq(c.state.summaries.b2.page,99);assert(not(c.remote_ready and c.remote_ready.b2==texts.m2))
end)
H.test('invalid remote Lua is isolated from healthy books and does not retry same version',function()
 local c,_,drain,_,events,_,calls,entries,_,sidecars,texts=fixture();texts.m3='return {}; error("unsafe")'
 c:lazyProgress(entries);drain();assert(not c.state.summaries.b3);H.eq(c.state.summaries.b4.page,4);assert(not c.retry_after)
 c:lazyProgress(entries);drain();H.eq(calls.reads,7)
 sidecars.s3[1].version='2';texts.m3=assert(SDR.encode({last_page=30}));c.state.progress_cache.b3.dirty=true;c:lazyProgress(entries);drain();H.eq(c.state.summaries.b3.page,30)
end)
H.test('late result from another visible page cannot overwrite current summaries',function()
 local c,_,_,jobs,_,p,_,entries=fixture();c:lazyProgress({entries[1]});local old=table.remove(jobs,1)
 c:lazyProgress({entries[2]});local result,e=old.run(p);old.done(result,e);assert(not c.state.summaries.b1)
end)
H.test('ambiguous stem or sidecar never applies a remote snapshot',function()
 local c,_,drain,_,_,_,calls,entries,parents=fixture();parents[#parents+1]={id='duplicate',name='1.epub',parent_id='title'}
 c:lazyProgress({entries[1]});drain();H.eq(calls.reads,0);assert(not c:remote(entries[1]));assert(not c.state.summaries.b1)
end)
H.test('book identity change while visible worker runs prevents restoration cache',function()
 local c,_,_,jobs,_,p,_,entries=fixture();c.state.docs.b1=entries[1];c:lazyProgress({entries[1]});local job=table.remove(jobs,1)
 local result,e=job.run(p);c.state.docs.b1={id='b1',name='1.cbz',parent_id='other',version='new',size=10};job.done(result,e)
 assert(not c:remote(entries[1]));assert(not c.state.summaries.b1)
end)
H.test('visible discovery keeps parent and sidecar queries in their shared drive',function()
 local c,_,drain,_,_,p,_,entries=fixture();entries[1].drive_id='shared';local list=p.listParents;local queries=0
 p.listParents=function(self,ids,scope)queries=queries+1;H.eq(scope and scope.drive_id,'shared');return list(self,ids)end
 c:lazyProgress({entries[1]});drain();H.eq(queries,2);H.eq(c.state.summaries.b1.page,1)
end)
