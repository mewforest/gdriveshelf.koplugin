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
H.test('foreground priority promotes an already queued prefetch target',function()
 local j=setup();j:enqueue('B',function()return 1 end,function()end)
 j:enqueue('C',function()return 2 end,function()end);j:enqueue('D',function()return 3 end,function()end)
 j:enqueue('D',function()error('existing task must be retained')end,function()end,true)
 H.eq(j.queue[1].key,'D');H.eq(j.queue[2].key,'C')
end)
