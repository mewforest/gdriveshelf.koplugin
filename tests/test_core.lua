local H=require('tests/helper');local Core=require('core')
local function setup()
 local state={entries={a={id='a',name='1.cbz',parent_id='x',pool='offline',path='/cache/a',ready=true,size=20}},docs={},folders={},sync={pending={},bases={},conflicts={}},downloads={}}
 local fs={root='/cache',json={encode=function()return '{}'end},readJSON=function()return state end,writeJSON=function()return true end,exists=function(_,p)return p=='/cache/a' end,remove=function()return true end,mkdir=function()return true end,freeBytes=function()return 10000000000 end}
 local n=0;local jobs={keys={},queue={},setOffline=function(self,x)self.offline=x end,enqueue=function(self,key)self.queue[#self.queue+1]=key;self.keys[key]=true end}
 local c=Core.new{storage=fs,jobs=jobs,credentials={},settings={offline=true},provider_factory=function()n=n+1;return {}end}
 return c,function()return n end
end
H.test('cached offline opening returns path without any network',function()local c,calls=setup();local path;c:open({id='a',name='1.cbz',parent_id='x'},function(p)path=p end);H.eq(path,'/cache/a');H.eq(calls(),0);H.eq(#c.jobs.queue,0) end)
H.test('offline uncached tap gives error without a queued request',function()local c,calls=setup();local err;c:open({id='b',name='2.cbz',parent_id='x'},function(_,e)err=e end);H.eq(err.code,'offline');H.eq(calls(),0);H.eq(#c.jobs.queue,0) end)
H.test('offline fallback list derives only correct title',function()local c=setup();c.state.docs={a={id='a',name='1.cbz',parent_id='x'},b={id='b',name='2.cbz',parent_id='y'}};local list=c:cachedList('x');H.eq(#list,1);H.eq(list[1].id,'a') end)
H.test('manual offline download persists independent pool intent',function()local c=setup();c:download({id='b',name='2.cbz',parent_id='y',size=10},'offline');H.eq(c.state.downloads.b.pool,'offline');H.eq(c.state.downloads.b.entry.parent_id,'y') end)
H.test('unreadable durable queue never resets to empty state',function()
 local writes=0
 local fs={root='/cache',readJSON=function()return nil,'Index too large'end,exists=function()return true end,writeJSON=function()writes=writes+1 end}
 local ok,err=pcall(Core.new,{storage=fs,jobs={setOffline=function()end},settings={}})
 H.eq(ok,false);assert(tostring(err):match('durable index'));H.eq(writes,0)
end)
print('core tests passed')
H.test('foreground uncached open cancels unrelated automatic prefetch',function()
 local c=setup();c.settings.offline=false
 c.storage.filePath=function()return '/cache/b'end
 c.jobs.active={key='download:prefetch'};c.jobs.offline=false;c.jobs.pump=function()end
 local cancelled;c.jobs.cancel=function(_,key)cancelled=key;c.jobs.active=nil end
 c.state.downloads.prefetch={entry={id='prefetch'},pool='auto'}
 c:open({id='b',name='2.cbz',parent_id='y',size=10},function()end)
 H.eq(cancelled,'download:prefetch');H.eq(c.jobs.queue[1],'download:b')
end)
H.test('reopened folder receives its already in-flight listing',function()
 local c=setup();c.settings.offline=false;local completion
 c.jobs.enqueue=function(self,key,task,done)if self.keys[key]then return false end;self.keys[key]=true;completion=done;return true end
 c.rememberList=function()end
 local first,second
 c:folder('new-title','Title',function(entries)first=entries end)
 c:folder('new-title','Title',function(entries)second=entries end)
 completion({result={{id='chapter',name='1.cbz',parent_id='new-title',is_folder=false}}})
 assert(first and second and first[1].id=='chapter' and second[1].id=='chapter')
end)
H.test('opening a cached book first cancels an unfinished relocation',function()
 local c=setup();c.relocating=true;local cancelled
 c.jobs.cancel=function(_,key)cancelled=key;c.relocating=nil end
 local path;c:open({id='a',name='1.cbz',parent_id='x'},function(p)path=p end)
 H.eq(cancelled,'relocate');H.eq(path,'/cache/a');assert(not c.relocating)
end)
H.test('next chapter and prefetch use chapter numbers from an older cached index offline',function()
 local c,calls=setup()
 local first={id='first',name='Z opening.cbz',parent_id='x'}
 local second={id='second',name='A sequel.cbz',parent_id='x'}
 local last={id='last',name='B finale.cbz',parent_id='x'}
 local index={id='metadata',name='index.json',parent_id='x'}
 c.state.docs={first=first,second=second,last=last,metadata=index}
 c.state.entries.metadata={id='metadata',ready=true,path='/cache/index',parsed={chapters={}}}
 local reads=0
 c.storage.exists=function(_,path)return path=='/cache/index'end
 c.storage.readJSON=function(_,path)
  H.eq(path,'/cache/index');reads=reads+1
  return {chapters={
   {file=first.name,number=0},{file=second.name,number=2.5},{file=last.name,number=10},
  }}
 end
 local next_entry=c:next(first)
 H.eq(next_entry and next_entry.id,'second')
 H.eq(c:next(second).id,'last')
 H.eq(reads,1);H.eq(calls(),0)
 c.settings.offline=false;c.settings.prefetch=1
 local prefetched
 c.download=function(_,entry)prefetched=entry.id end
 c:prefetch(first)
 H.eq(prefetched,'second');H.eq(reads,1)
end)
