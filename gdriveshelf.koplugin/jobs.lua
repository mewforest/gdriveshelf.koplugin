local Jobs={};Jobs.__index=Jobs
function Jobs.new(o)
 local self=setmetatable({queue={},keys={},storage=o.storage,dir=o.dir,schedule=o.schedule,unschedule=o.unschedule,backend=o.backend,offline=false,seq=0},Jobs)
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
function Jobs:enqueue(key,task,callback,front,before)
 if self.keys[key] then
  if front then for i,j in ipairs(self.queue)do if j.key==key then table.remove(self.queue,i);table.insert(self.queue,1,j);break end end end
  return false
 end
 local job={key=key,task=task,callback=callback,before=before};self.keys[key]=true
 if front then table.insert(self.queue,1,job) else self.queue[#self.queue+1]=job end
 self:pump();return true
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
function Jobs:pump()
 if self.offline or self.active or #self.queue==0 then return end
 local j=table.remove(self.queue,1);self.seq=self.seq+1;j.result_path=self.dir..'/result-'..self.nonce..'-'..self.seq..'.json'
 self.storage:remove(j.result_path)
 if j.before then
  local ran,good,why=pcall(j.before)
  if not ran then good=false;why={code='prepare',message='Background preparation failed'}end
  if not good then self.keys[j.key]=nil;self:notify(j,nil,why);return self:pump()end
 end
 local ok,pid=pcall(self.backend.start,j.task,j.result_path)
 if not ok or not pid then self.keys[j.key]=nil;self:notify(j,nil,{code='spawn',message='Cannot start background process'});return self:pump() end
 j.pid=pid;self.active=j;self.schedule(self.tick,0.25)
end
function Jobs:poll()
 local j=self.active;if not j then return end
 if not self.backend.done(j.pid) then self.schedule(self.tick,0.25);return end
 self.active=nil;self.keys[j.key]=nil
 local r=self.storage:readJSON(j.result_path,64*1048576);self.storage:remove(j.result_path)
 self:notify(j,r and r.value,r and r.error or (not r and {code='worker',message='Background process exited without a result'}))
 self:pump()
end
function Jobs:cancel(key)
 if self.active and self.active.key==key then
  local j=self.active;self.backend.stop(j.pid);self.active=nil;self.keys[key]=nil
  if self.unschedule then self.unschedule(self.tick) end
  -- terminateSubProcess sends SIGKILL; waitpid must still collect the child.
  local function reap() if not self.backend.done(j.pid) then self.schedule(reap,1) else self.storage:remove(j.result_path) end end
  reap()
  self:notify(j,nil,{code='cancelled',message='Cancelled'})
 else for i=#self.queue,1,-1 do if self.queue[i].key==key then local j=table.remove(self.queue,i);self.keys[key]=nil;self:notify(j,nil,{code='cancelled',message='Cancelled'})end end end
 self:pump()
end
function Jobs:setOffline(value)
 self.offline=value
 if value and self.active then self:cancel(self.active.key) end
 if not value then self:pump() end
end
function Jobs:clear()
 self.offline=true
 local keys={};for k in pairs(self.keys) do keys[#keys+1]=k end;for _,k in ipairs(keys)do self:cancel(k)end
end
return Jobs
