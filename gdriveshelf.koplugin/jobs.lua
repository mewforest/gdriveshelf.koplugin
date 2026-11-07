local Jobs={};Jobs.__index=Jobs
function Jobs.new(o)
 local self=setmetatable({queue={},keys={},storage=o.storage,dir=o.dir,schedule=o.schedule,unschedule=o.unschedule,backend=o.backend,logger=o.logger,offline=false,paused=false,seq=0,task_seq=0},Jobs)
 if not self.backend then
  local ffiutil=require('ffi/util');local UI=require('ui/uimanager')
  self.schedule=function(fn,delay)UI:scheduleIn(delay,fn)end;self.unschedule=function(fn)UI:unschedule(fn)end
  self.backend={start=function(task,path)
   return ffiutil.runInSubProcess(function()
    local ok,v,e=pcall(task)
    self.storage:writeJSON(path,ok and {value=v,error=e} or {error={code='worker',message='Background task failed'}})
   end,false)
  end,done=function(pid)return ffiutil.isSubProcessDone(pid)end,stop=function(pid)ffiutil.terminateSubProcess(pid)end}
 end
 local ffi=require('ffi');pcall(ffi.cdef,'int getpid(void);');self.nonce=tostring(os.time())..'-'..tonumber(ffi.C.getpid())..'-'..tostring(self):gsub('[^%w]','')
 self.tick=function() self:poll() end
 return self
end
function Jobs:trace(job,transition,err)
 if self.logger then pcall(self.logger.event,self.logger,'job',{taskref=job.ref,transition=transition,error=err and err.code})end
end
function Jobs:enqueue(key,task,callback,front,before,progress,local_task,options)
 if self.keys[key] then
  if front then
   if self.active and self.active.key==key then self.active.front=true end
   for i,j in ipairs(self.queue)do if j.key==key then j.front=true;table.remove(self.queue,i);table.insert(self.queue,1,j);break end end
  end
  if options and options.automatic==false then
   if self.active and self.active.key==key then self.active.automatic=false end
   for _,job in ipairs(self.queue)do if job.key==key then job.automatic=false;break end end
  end
  return false
 end
 self.task_seq=self.task_seq+1
 local timeout=options and tonumber(options.timeout)
 local job={key=key,task=task,callback=callback,before=before,progress=progress,local_task=local_task,ref=self.task_seq,front=front==true,retry=options and options.retry,automatic=options and options.automatic,timeout=timeout and timeout>0 and timeout<86400 and timeout or nil};self.keys[key]=true
 if front then table.insert(self.queue,1,job) else self.queue[#self.queue+1]=job end
 self:trace(job,'queued');self:pump();return true
end
function Jobs:notify(job,value,err)
 if job.callback then
  local ok=pcall(job.callback,value,err)
  if not ok then
   -- Callback payloads may include private network data; do not log the error.
   local good,logger=pcall(require,'logger');if good then logger.warn('GDriveShelf background callback failed')end
  end
 end
end
function Jobs:retain(job)
 local index=job.front and 1 or #self.queue+1
 if job.front then while self.queue[index]and self.queue[index].front do index=index+1 end end
 table.insert(self.queue,index,job)
end
function Jobs:pump()
 if self.active or self.stopping or self.hold or #self.queue==0 then return end
 local index=1
 if self.offline or self.paused then
  index=nil;for i,job in ipairs(self.queue)do if job.local_task then index=i;break end end
  if not index then return end
 end
 local j=table.remove(self.queue,index);self.seq=self.seq+1;j.result_path=self.dir..'/result-'..self.nonce..'-'..self.seq..'.json'
 self.storage:remove(j.result_path)
 if j.before then
  local ran,good,why=pcall(j.before)
  if not ran then good=false;why={code='prepare',message='Background preparation failed'}end
  if not good then
   if type(why)=='table'and why.code=='paused'and why.defer then
    table.insert(self.queue,index,j);self.paused=true;self:trace(j,'deferred');return self:pump()
   end
   self.keys[j.key]=nil;self:trace(j,'failed',why);self:notify(j,nil,why);return self:pump()
  end
 end
 local last_report
 local function report(value)
  if not j.progress or not self.storage.writeJSON then return end
  local now=os.time();if last_report==now and value.stage~='complete'then return end;last_report=now
  self.storage:writeJSON(j.result_path..'.progress',{received=tonumber(value.received)or 0,total=tonumber(value.total),stage=value.stage=='complete'and 'complete'or 'download',time=now})
 end
 local ok,pid=pcall(self.backend.start,function()return j.task(report)end,j.result_path)
 if not ok or not pid then self.keys[j.key]=nil;self:trace(j,'failed',{code='spawn'});self:notify(j,nil,{code='spawn',message='Cannot start background process'});return self:pump() end
 j.pid=pid;j.started=os.time();j.last_progress=nil;self.active=j;self:trace(j,'started');self.schedule(self.tick,0.25)
end
function Jobs:poll()
 local j=self.active;if not j then return end
 if j.progress then
  local value=self.storage:readJSON(j.result_path..'.progress',32768)
  if value and (not j.last_progress or value.time~=j.last_progress.time or value.received~=j.last_progress.received)then j.last_progress=value;pcall(j.progress,value)end
 end
 if not self.backend.done(j.pid) then
  if j.timeout and os.time()-j.started>=j.timeout then self:cancel(j.key,{code='timeout',message='Background task timed out'});return end
  self.schedule(self.tick,0.25);return
 end
 self.active=nil
 local r=self.storage:readJSON(j.result_path,64*1048576);self.storage:remove(j.result_path);self.storage:remove(j.result_path..'.progress')
 local err=r and r.error or (not r and {code='worker',message='Background process exited without a result'})
 if j.retry then
  local ok,again=pcall(j.retry,r and r.value,err)
  if ok and again==true then
   self:retain(j)
   self:trace(j,'deferred',err);self:pump();return
  end
 end
 self.keys[j.key]=nil
 self:trace(j,err and 'failed'or 'completed',err);self:notify(j,r and r.value,err)
 self:pump()
end
function Jobs:cancel(key,reason)
 reason=reason or {code='cancelled',message='Cancelled'}
 if self.active and self.active.key==key then
  local j=self.active;self.backend.stop(j.pid);self.active=nil;self.keys[key]=nil
  if self.unschedule then self.unschedule(self.tick) end
  -- terminateSubProcess sends SIGKILL; waitpid must still collect the child.
  local function reap() if not self.backend.done(j.pid) then self.schedule(reap,1) else self.storage:remove(j.result_path) end end
  reap();self.storage:remove(j.result_path..'.progress')
  self:trace(j,reason.code=='timeout'and 'failed'or 'cancelled',reason);self:notify(j,nil,reason)
 else for i=#self.queue,1,-1 do if self.queue[i].key==key then local j=table.remove(self.queue,i);self.keys[key]=nil;self:trace(j,'cancelled',reason);self:notify(j,nil,reason)end end end
 self:pump()
end
function Jobs:setPaused(value)
 self.paused=value==true;self:pump()
end
function Jobs:setOffline(value)
 self.offline=value
 if value and self.active and not self.active.local_task then
  local j=self.active;self.backend.stop(j.pid);self.active=nil;self.stopping=true
  if self.unschedule then self.unschedule(self.tick)end
  -- A temporary stop retains both identity and intention. Restart preparation
  -- runs only after the old worker is reaped, so partial outputs cannot race.
  self:retain(j);self:trace(j,'deferred')
  local path=j.result_path
  local function reap()
   if not self.backend.done(j.pid)then self.schedule(reap,1);return end
   self.storage:remove(path);self.storage:remove(path..'.progress');self.stopping=nil;self:pump()
  end
  reap()
 end
 self:pump()
end
function Jobs:clear(reason)
 self.offline=true
 local keys={};for k in pairs(self.keys) do keys[#keys+1]=k end;for _,k in ipairs(keys)do self:cancel(k,reason)end
end
return Jobs
