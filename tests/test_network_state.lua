local H=require('tests/helper');local Core=require('core');local Jobs=require('jobs')
local real_time=os.time;local now=1000;os.time=function()return now end
local function setup()
 local records,processes,timers={},{},{};local started=0
 local storage={root='/cache',readJSON=function(_,p)return records[p]end,writeJSON=function(_,p,v)records[p]=v;return true end,exists=function()return false end,remove=function(_,p)records[p]=nil;return true end,filePath=function(_,e)return '/cache/'..e.id end,freeBytes=function()return 1e12 end}
 local jobs=Jobs.new{storage=storage,dir='/jobs',schedule=function(fn,delay)timers[#timers+1]={fn=fn,at=now+delay}end,unschedule=function(fn)for i=#timers,1,-1 do if timers[i].fn==fn then table.remove(timers,i)end end end,
  backend={start=function(fn,path)started=started+1;processes[started]={fn=fn,path=path};return started end,done=function(id)return processes[id].done end,stop=function(id)processes[id].done=true end}}
 local core=Core.new{storage=storage,jobs=jobs,settings={},credentials={},provider_factory=function()return {credentials={}}end}
 local function finish()local p=processes[jobs.active.pid];local v,e=p.fn();records[p.path]={value=v,error=e};p.done=true;jobs:poll()end
 local function advance(seconds)now=now+seconds;local pending=timers;timers={};for _,t in ipairs(pending)do if t.at<=now then t.fn()else timers[#timers+1]=t end end end
 return core,jobs,finish,advance,function()return started end
end
local failures=0
local function test(name,fn)local ok,e=pcall(fn);if ok then print('ok - '..name)else failures=failures+1;print('FAIL '..name..': '..tostring(e))end end
test('local, missing-file and metadata errors never pause unrelated browsing',function()
 for _,err in ipairs{{code='io'},{code='preview'},{code='not_found',status=404},{code='invalid_remote_metadata'},{code='invalid_pending'},{code='changed'}}do
  now=1000;local c,j,finish=setup();local listed=false
  c:network('bad',function()return nil,err end);c:network('list:next',function()return {}end,function(v)listed=v~=nil end);finish()
  assert(not c.retry_after and j.active and j.active.key=='list:next');finish();assert(listed)
 end
end)
test('cooldown retains queued keys and accepts foreground work until retry deadline',function()
 now=1000;local c,j,finish,advance,count=setup();local result
 c:network('fails',function()return nil,{code='network'}end)
 c:network('list:queued',function()return {}end,function(v)result=v end);finish()
 assert(c:networkState()=='retry' and c:online());assert(j.keys.fails and j.keys['list:queued'] and #j.queue==2 and not j.active and not result)
 j:cancel('fails')
 c:network('list:front',function()return {}end,nil,true);assert(#j.queue==2 and count()==1)
 advance(1);assert(j.active and j.active.key=='list:front');finish();finish();assert(result and not next(j.keys))
end)
test('transient API errors use exponential bounded backoff and honor Retry-After',function()
 now=1000;local c,j,finish,advance=setup();local expected={1,2,4,8,16,30,30}
 for i,delay in ipairs(expected)do local key='fails:'..i;c:network(key,function()return nil,{code='api',status=503}end);finish();H.eq(c.retry_after-now,delay);j:cancel(key);advance(delay)end
 c:network('limited',function()return nil,{code='api',status=429,retry_after=45}end);finish();H.eq(c.retry_after-now,45)
end)
test('wake clears cooldown before queued browsing is unpaused',function()
 now=1000;local c,j,finish=setup();local done=false
 c:network('failure',function()return nil,{code='network'}end);c:network('list:wake',function()return {}end,function(v)done=v~=nil end);finish()
 c:suspend();c:wake();assert(j.active and j.active.key=='list:wake' and not c.retry_after);finish();assert(done)
end)
test('local worker can finish while manual offline or during network cooldown',function()
 for _,offline in ipairs{false,true}do
  now=1000;local c,j,finish=setup();if offline then c:setOffline(true)else c:network('failure',function()return nil,{code='network'}end);finish()end
  local done=false;c:network('thumb:local',function()return {}end,function(v)done=v~=nil end,false,nil,nil,true)
  assert(j.active and j.active.local_task);finish();assert(done);if not offline then assert(c.retry_after)end
 end
end)
test('auth requires explicit recovery and does not masquerade as offline',function()
 now=1000;local c,j,finish,advance=setup();c:network('auth',function()return nil,{code='auth'}end);finish()
 assert(c:networkState()=='auth' and not c:online());local err;c:open({id='book',name='book.cbz'},function(_,e)err=e end);H.eq(err.code,'auth')
 c:wake();c:setOffline(false);advance(100);assert(c:networkState()=='auth' and not j.active)
 c:resetNetwork(true);assert(c:networkState()=='online')
end)
test('cancelling work during cooldown clears key and invokes callback once',function()
 now=1000;local c,j,finish,advance=setup();local calls=0
 c:network('failure',function()return nil,{code='network'}end);c:network('queued',function()return {}end,function(_,e)calls=calls+1;H.eq(e.code,'cancelled')end);finish()
 j:cancel('queued');j:cancel('failure');advance(10);assert(calls==1 and not j.keys.queued and not j.active)
end)
test('opening an uncached book during retry waits with its download intent',function()
 now=1000;local c,j,finish=setup();local called=false
 c:network('failure',function()return nil,{code='network'}end);finish()
 c:open({id='book',name='book.cbz',parent_id='folder',size=10},function()called=true end)
 assert(not called and c.state.downloads.book and c.waiters.book and j.keys['download:book'])
end)
test('duplicate owner wake calls do not cancel or duplicate queued browsing',function()
 now=1000;local c,j,finish,_,count=setup();local calls=0
 c:network('failure',function()return nil,{code='network'}end);c:network('list:wake',function()return {}end,function()calls=calls+1 end);finish()
 c:suspend();c:suspend();c:wake();c:wake();H.eq(count(),2);finish();H.eq(calls,1)
end)
test('provider diagnostics are bounded and written after worker completion in the parent',function()
 now=1000;local c,_,finish=setup();local requests=0
 c.logger={event=function(_,name)if name=='request'then requests=requests+1 end end}
 c:network('trace',function(provider)
  for _=1,200 do provider.trace('request',{operation='list',status=200})end
  H.eq(requests,0);return {}
 end)
 finish();H.eq(requests,128)
end)
test('active listing preserves its completion across transient failure',function()
 now=1000;local c,j,finish,advance=setup();local attempts,calls=0,0
 c:network('list:active',function()attempts=attempts+1;if attempts==1 then return nil,{code='network'}end;return {{id='book'}}end,function(value,err)calls=calls+1;assert(value and not err)end)
 finish();assert(calls==0 and j.keys['list:active'] and #j.queue==1)
 advance(1);finish();H.eq(attempts,2);H.eq(calls,1)
end)
test('active listing survives sleep and manual offline with its callback attached',function()
 for _,manual in ipairs{false,true}do
  now=1000;local c,j,finish,_,count=setup();local calls=0
  c:network('list:active',function()return {{id='book'}}end,function(value,err)calls=calls+1;assert(value and not err)end)
  if manual then c:setOffline(true)else c:suspend()end
  assert(calls==0 and j.keys['list:active'] and #j.queue==1 and not j.active)
  if manual then c:setOffline(false)else c:wake()end
  assert(j.active and count()==2);finish();H.eq(calls,1)
 end
end)
test('transient retries stop after three attempts and preserve other queued work',function()
 now=1000;local c,j,finish,advance,count=setup();local calls,other=0,0
 c:network('list:active',function()return nil,{code='network'}end,function(value,err)calls=calls+1;assert(not value and err.code=='network')end,true)
 c:network('list:other',function()return {}end,function()other=other+1 end)
 finish();assert(calls==0);advance(1);finish();assert(calls==0);advance(2);finish();H.eq(calls,1)
 advance(4);assert(j.active and j.active.key=='list:other');finish();advance(100);H.eq(count(),4);H.eq(other,1)
end)
test('explicit cancellation of a retry or suspended active request prevents later success',function()
 for _,sleep in ipairs{false,true}do
  now=1000;local c,j,finish,advance,count=setup();local calls=0
  c:network('list:active',function()return nil,{code='network'}end,function(value,err)calls=calls+1;assert(not value and err.code=='cancelled')end)
  if sleep then c:suspend()else finish()end
  j:cancel('list:active');c:wake();advance(100);assert(calls==1 and count()==1 and not j.active and not j.keys['list:active'])
 end
end)
test('foreground download retains open intent through retry and sleep and cleans stale partials',function()
 for _,sleep in ipairs{false,true}do
  now=1000;local c,j,finish,advance=setup();local attempts,calls,cleaned=0,0,0
  local old_remove=c.storage.remove;c.storage.remove=function(self,path)if path=='/cache/book.incoming-'..j.nonce..'x1.part'then cleaned=cleaned+1 end;return old_remove(self,path)end
  local entry={id='book',name='Book.cbz',parent_id='folder',size=10,version='1'}
  c.provider_factory=function()return {credentials={},download=function()attempts=attempts+1;if attempts==1 and not sleep then return nil,{code='network'}end;return {size=10}end,stat=function()return entry end}end
  c:open(entry,function(path,err)calls=calls+1;assert(path=='/cache/book'and not err)end)
  if sleep then c:suspend()else finish()end
  assert(calls==0 and c.opening_id=='book'and c.waiters.book and j.keys['download:book'])
  local rename=os.rename;os.rename=function()return true end
  local good,why=pcall(function()if sleep then c:wake()else advance(1)end;finish()end);os.rename=rename;assert(good,why)
  assert(calls==1 and not c.waiters.book and not c.state.downloads.book and cleaned>=2)
 end
end)
test('cancelling a suspended foreground download cannot open it after wake',function()
 now=1000;local c,j,_,advance,count=setup();local calls=0
 c:open({id='book',name='Book.cbz',parent_id='folder',size=10},function(path,err)calls=calls+1;assert(not path and err.code=='cancelled')end)
 c:suspend();c:cancelDownload('book');c:wake();advance(100)
 assert(calls==1 and count()==1 and not j.active and not c.state.downloads.book and not c.waiters.book and not c.opening_id)
end)
test('network state transitions notify the UI once rather than leaving stale online feedback',function()
 now=1000;local c=setup();local states={}
 c.onchange=function(kind)if kind=='network_state'then states[#states+1]=c:networkState()end end
 c:syncNetworkJobs();c:syncNetworkJobs();c:suspend();c:wake()
 H.eq(table.concat(states,','),'online,sleep,online')
end)
test('light mode pauses automatic downloads while keeping a foreground download and explicit retry',function()
 now=1000
 local c,j=setup()
 local manual={id='manual',name='Manual.cbz',parent_id='p',size=10}
 local auto={id='auto',name='Auto.cbz',parent_id='p',size=10}
 c:open(manual,function()end)
 c:download(auto,'auto',nil,true)
 assert(j.active.key=='download:manual' and j.keys['download:auto'])
 c:setLightMode(true)
 assert(j.active.key=='download:manual'and c.waiters.manual and not j.keys['download:auto'])
 assert(c.state.downloads.auto and c.state.downloads.auto.automatic and not c.state.downloads.auto.error)
 c:resume()
 assert(not j.keys['download:auto'])
 c:resetNetwork(nil,true)
 assert(j.keys['download:auto']and c.state.downloads.auto.automatic==false)
end)
os.time=real_time
assert(failures==0,tostring(failures)..' network state tests failed')
