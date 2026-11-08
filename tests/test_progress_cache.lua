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
H.test('a metadata file removed after discovery does not interrupt the other summaries',function()
 local c,_,drain,_,_,p,_,entries=fixture()
 local read=p.read
 p.read=function(self,entry)
  if entry.id=='m3' then return nil,{code='api',status=404} end
  return read(self,entry)
 end
 c:lazyProgress(entries);drain()
 assert(c.state.progress_cache.b3.missing and not c.state.summaries.b3)
 H.eq(c.state.summaries.b4.page,4)
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
H.test('Continue reads only the last matched chapter and reuses its verified position',function()
 local c,_,drain,_,_,_,calls,entries,parents,_,texts=fixture()
 texts.m7=assert(SDR.encode({last_page=31,doc_pages=35,summary={status='reading'}}))
 c:rememberList('title',parents)
 local resolved
 local initial=c:resumeChapter('title',parents,function(result)resolved=result end)
 assert(initial.waiting);H.eq(initial.entry.id,'b7')
 drain()
 H.eq(calls.reads,1);H.eq(resolved.entry.id,'b7');H.eq(resolved.summary.page,31)
 assert(resolved.resume and not resolved.waiting)
 local again=c:resumeChapter('title',parents)
 assert(not again.waiting);H.eq(again.summary.page,31);H.eq(calls.reads,1)
end)
H.test('Continue favors recent reading, advances only past complete into an unopened chapter',function()
 local c,_,_,_,_,_,calls,entries,parents=fixture()
 c.state.history={b2={time=10,entry=entries[2]},b6={time=5,entry=entries[6]}}
 c.state.summaries.b2={page=7,percent=1,status='reading'}
 c.settings.offline=true
 local partial=c:resumeChapter('title',parents)
 H.eq(partial.entry.id,'b2');assert(partial.resume and not partial.completed)
 c.state.summaries.b2.status='complete'
 for i,entry in ipairs(parents)do if entry.id=='s3' then table.remove(parents,i);break end end
 local nextChapter=c:resumeChapter('title',parents)
 H.eq(nextChapter.entry.id,'b3');assert(not nextChapter.resume and not nextChapter.completed)
 assert(calls.reads==0)
end)
H.test('light mode skips visible reads but manual progress visits bounded batches',function()
 local c,step,drain,_,_,_,calls,entries,parents=fixture()
 c.settings.light_mode=true
 c:rememberList('title',parents)
 assert(not c:lazyProgress(entries));H.eq(calls.reads,0)
 assert(c:loadFolderProgress('title',parents));H.eq(c.progress_job.mode,'all')
 step();H.eq(calls.reads,4);H.eq(c.progress_job.done,4)
 assert(not c:lazyProgress({entries[2]}))
 drain();H.eq(calls.reads,7);assert(not c.progress_job)
end)
H.test('cancelled Continue never reports a late chapter',function()
 local c,_,_,jobs,_,p,_,_,parents=fixture();c:rememberList('title',parents)
 local called=false
 c:resumeChapter('title',parents,function()called=true end)
 local old=table.remove(jobs,1);c:cancelProgress()
 old.done(old.run(p))
 assert(not called and not c.state.summaries.b7)
end)
H.test('offline mark preserves local position, survives reopening, and applies only to this version',function()
 local c,_,_,_,_,_,_,entries=fixture();c.settings.offline=true
 local book=entries[1];c.state.summaries[book.id]={page=4,percent=.5}
 assert(c:setChapterRead(book,true));assert(c.state.sync.pending[book.id].status_only)
 H.eq(c:chapterSummary(book).status,'complete');H.eq(c:chapterSummary(book).page,4)
 local data={last_page=4,annotations={{text='bookmark'}}};assert(c:applyChapterMark(book,data))
 H.eq(data.summary.status,'complete');H.eq(data.last_page,4);H.eq(data.annotations[1].text,'bookmark')
 assert(not c:applyChapterMark({id=book.id,name=book.name,parent_id=book.parent_id,version='replaced'},{}))
 local pending=c.state.sync.pending[book.id]
 assert(c:chapterMarkApplied(book));assert(c:chapterMark(book)==nil)
 assert(c.state.sync.pending[book.id]==pending and pending.status_only)
 assert(c:setChapterRead(book,false));assert(c:applyChapterMark(book,data));H.eq(data.summary.status,'reading')
end)
H.test('choosing cloud conflict replaces the displayed mark and invalidates the old summary version',function()
 local c,_,_,_,_,_,_,entries=fixture();c.settings.offline=true
 local book=entries[1];assert(c:setChapterRead(book,true))
 local data={last_page=12,summary={status='reading'}}
 c.state.sync.conflicts[book.id]={remote_lua=assert(SDR.encode(data)),stamp={id='m1',version='2'},book_stamp=book}
 c.state.progress_cache={[book.id]={signature='old'}}
 local resolved=assert(c:sync():resolve(book.id,'remote'))
 c:chapterCloudResolved(book,resolved)
 assert(not c.state.progress_cache[book.id] and c:chapterMark(book)==nil and not c.state.sync.pending[book.id])
 H.eq(c:chapterSummary(book).status,'reading');H.eq(c:chapterSummary(book).page,12)
 H.eq(c:remote(book).stamp.version,'2')
end)
H.test('Continue uses chapter numbers from the cached index with an offline subset',function()
 local c,_,_,_,_,_,calls,entries,parents=fixture()
 local first,second,last=entries[3],entries[1],entries[2]
 parents[#parents+1]={id='index',name='index.json',parent_id='title'}
 c:rememberList('title',parents)
 c.settings.offline=true
 local cached=c.cached
 c.cached=function(self,id)
  if id=='index' then
   return {parsed={chapter_numbers={[first.name]=0,[second.name]=1,[last.name]=2}}}
  end
  return cached(self,id)
 end
 local offline={second,last,first}
 H.eq(c:resumeChapter('title',offline).entry.id,first.id)
 c.state.history[first.id]={time=10,entry=first}
 c.state.summaries[first.id]={page=7,percent=1,status='complete'}
 H.eq(c:resumeChapter('title',offline).entry.id,second.id)
 H.eq(calls.reads,0)
end)
