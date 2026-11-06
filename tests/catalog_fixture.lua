local Core=require('core')
local F={}
function F.new(settings,provider,state)
 state=state or {};local jobs={};local events={};local saved;local files,encoded={},{}
 local function copy(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
 local fs={root='/catalog',account='account',json={encode=function(value)local key=tostring(#encoded+1);encoded[#encoded+1]=copy(value);return key end},readJSON=function(_,path)if path=='/catalog/index.json'then return state end;return copy(files[path])end,exists=function(_,path)return files[path]~=nil end,writeJSON=function(_,_,v)saved=copy(v);return true end,write=function(_,path,text)files[path]=copy(encoded[tonumber(text)]);return true end,remove=function(_,path)files[path]=nil;return true end,freeBytes=function()return 1e12 end,filePath=function(_,e)return '/meta/'..e.id end}
 local c=Core.new{storage=fs,jobs={setOffline=function()end,cancel=function()end},settings=settings or{home='home',index_enabled=true,index_recursive_confirmed=true},provider_factory=function()return provider end,onchange=function(kind,entry,e)events[#events+1]={kind=kind,entry=entry,error=e}end}
 c.network=function(_,key,work,done)jobs[#jobs+1]={key=key,run=work,done=done};return true end
 local function step()
  local job=table.remove(jobs,1);assert(job,'No scheduled work');local value,e=job.run(provider);job.done(value,e);return job
 end
 local function drain()local n=0;while #jobs>0 do n=n+1;assert(n<200,'Unbounded work');step()end end
 return c,step,drain,jobs,events
end
return F
