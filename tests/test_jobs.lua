local H=require('tests/helper');local Jobs=require('jobs')
local function setup()
 local results={};local active={};local n=0;local timer
 local backend={start=function(task,path)n=n+1;active[n]={task=task,path=path};return n end,done=function(pid)return active[pid].done end,stop=function(pid)active[pid].done=true end}
 local store={readJSON=function(_,p)return results[p] end,remove=function(_,p)results[p]=nil end}
 local j=Jobs.new{backend=backend,storage=store,dir='/jobs',schedule=function(fn)timer=fn end,unschedule=function()end}
 local function finish()local a=active[j.active.pid];local v,e=a.task();results[a.path]={value=v,error=e};a.done=true;timer() end
 return j,finish
end
H.test('offline enqueue never starts a process',function()local j=setup();j:setOffline(true);j:enqueue('a',function()return 1 end,function()end);H.eq(j.active,nil);H.eq(#j.queue,1) end)
H.test('deduplicates active job and FIFO callbacks',function()local j,finish=setup();local out={};j:enqueue('a',function()return 1 end,function(v)out[#out+1]=v end);j:enqueue('a',function()return 2 end,function()end);j:enqueue('b',function()return 3 end,function(v)out[#out+1]=v end);H.eq(#j.queue,1);finish();H.eq(out[1],1);finish();H.eq(out[2],3) end)
H.test('cancellation never reports successful partial work',function()local j=setup();local value;j:enqueue('a',function()return true end,function(v,e)value=e end);j:cancel('a');H.eq(value.code,'cancelled');H.eq(j.active,nil) end)
H.test('returning online pumps previously queued work',function()local j=setup();j:setOffline(true);j:enqueue('a',function()return 1 end,function()end);j:setOffline(false);assert(j.active);H.eq(j.active.key,'a') end)
print('jobs tests passed')
H.test('IPC limit supports large bounded folder results',function()
 local seen
 local j=Jobs.new{dir='/jobs',storage={remove=function()end,readJSON=function(_,_,limit)seen=limit;return {value=1}end},backend={start=function()return 1 end,done=function()return true end,stop=function()end},schedule=function()end,unschedule=function()end}
 j:enqueue('large',function()return 1 end,function()end);j:poll();assert(seen and seen>=64*1048576)
end)
H.test('a throwing cancellation callback cannot interrupt clearing the queue',function()
 local j=setup();j:enqueue('a',function()end,function()error('cancel callback failed')end)
 j:enqueue('b',function()end,function()end)
 local ok=pcall(j.clear,j);assert(ok);assert(not next(j.keys)and #j.queue==0 and not j.active)
end)
H.test('a preparation exception fails one job without escaping or blocking future work',function()
 local j=setup();local why
 local ok=pcall(j.enqueue,j,'bad',function()end,function(_,e)why=e end,false,function()error('prepare failed')end)
 assert(ok and why and why.code=='prepare');assert(not j.keys.bad)
 j:enqueue('next',function()end,function()end);assert(j.active and j.active.key=='next')
end)
H.test('foreground priority promotes an already queued prefetch target',function()
 local j=setup();j:enqueue('B',function()return 1 end,function()end)
 j:enqueue('C',function()return 2 end,function()end);j:enqueue('D',function()return 3 end,function()end)
 j:enqueue('D',function()error('existing task must be retained')end,function()end,true)
 H.eq(j.queue[1].key,'D');H.eq(j.queue[2].key,'C')
end)
H.test('worker progress is bounded data and reaches the parent without waiting for completion',function()
 local records={};local task
 local j=Jobs.new{dir='/jobs',storage={remove=function()end,writeJSON=function(_,p,v)records[p]=v;return true end,readJSON=function(_,p)return records[p]end},backend={start=function(fn)task=fn;return 1 end,done=function()return false end},schedule=function()end}
 local seen;j:enqueue('a',function(report)report{received=17,total=30,stage='download'}end,function()end,false,nil,function(v)seen=v end)
 task();j:poll();assert(seen and seen.received==17 and seen.total==30)
end)
H.test('local relocation jobs run offline while network jobs stay queued',function()
 local j,finish=setup();j:setOffline(true);local done=false
 j:enqueue('network',function()return 1 end,function()end)
 j:enqueue('relocate',function()return true end,function()done=true end,true,nil,nil,true)
 assert(j.active and j.active.key=='relocate');finish();assert(done and not j.active and j.keys.network)
end)
H.test('temporary pause preserves priority and runs only local work',function()
 local j,finish=setup();j:setPaused(true)
 j:enqueue('remote',function()return 1 end,function()end)
 local local_done=false;j:enqueue('local',function()return true end,function()local_done=true end,false,nil,nil,true)
 assert(j.active and j.active.key=='local');finish();assert(local_done and j.keys.remote and not j.active)
 j:setPaused(false);assert(j.active and j.active.key=='remote');finish();assert(not next(j.keys))
end)
H.test('a deferred preparation retains the job and its completion',function()
 local j,finish=setup();local ready=false;local calls=0
 j:enqueue('later',function()return 3 end,function(v)calls=calls+1;H.eq(v,3)end,false,function()if not ready then return nil,{code='paused',defer=true}end;return true end)
 assert(j.keys.later and #j.queue==1 and not j.active and calls==0)
 ready=true;j:setPaused(false);assert(j.active);finish();H.eq(calls,1)
end)
H.test('local worker timeout releases its key and continues the queue once',function()
 local time=os.time;local now=1000;os.time=function()return now end
 local ok,why=pcall(function()
  local j,finish=setup();local calls=0
  j:enqueue('hung',function()return true end,function(_,e)calls=calls+1;H.eq(e.code,'timeout')end,false,nil,nil,true,{timeout=15})
  j:enqueue('next',function()return 2 end,function()end)
  now=1016;j:poll();assert(calls==1 and not j.keys.hung and j.active.key=='next');finish();H.eq(calls,1)
 end)
 os.time=time;assert(ok,why)
end)
H.test('offline stops active remote worker without completing its intention',function()
 local j,finish=setup();local calls=0
 j:enqueue('remote',function()return 7 end,function(value,err)calls=calls+1;H.eq(value,7);assert(not err)end)
 j:setOffline(true);assert(calls==0 and j.keys.remote and #j.queue==1 and not j.active)
 local local_done=false;j:enqueue('local',function()return true end,function()local_done=true end,false,nil,nil,true);finish();assert(local_done and calls==0)
 j:setOffline(false);finish();H.eq(calls,1)
end)
H.test('wake waits for the stopped worker to be reaped before restarting it',function()
 local done=false;local starts=0;local scheduled;local calls=0
 local j=Jobs.new{dir='/jobs',storage={remove=function()end},backend={start=function()starts=starts+1;return starts end,stop=function()end,done=function()return done end},schedule=function(fn)scheduled=fn end,unschedule=function()end}
 j:enqueue('remote',function()return true end,function()calls=calls+1 end)
 j:setOffline(true);j:setOffline(false);assert(starts==1 and calls==0 and j.keys.remote and not j.active)
 done=true;scheduled();assert(starts==2 and calls==0 and j.active and j.active.key=='remote')
end)
H.test('a retained retry does not overtake a newer foreground intention',function()
 local j,finish=setup();local retried=false
 j:enqueue('old',function()return nil,{code='network'}end,function()end,true,nil,nil,false,{retry=function()if not retried then retried=true;j:setPaused(true);return true end end})
 j:enqueue('selected',function()return true end,function()end,true)
 finish();assert(j.keys.old and j.keys.selected);j:setPaused(false);H.eq(j.active.key,'selected')
end)
