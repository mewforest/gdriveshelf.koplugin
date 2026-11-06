-- Opening is a UI intention, separate from the lifetime of its download.
local R={};R.__index=R
function R.new(core)return setmetatable({core=core},R)end
function R:cancel(stop)
 local request=self.current;self.current=nil
 if request and self.core.opening_id==request.entry.id then self.core.opening_id=nil end
 if request and stop and self.core.cancelDownload then self.core:cancelDownload(request.entry.id)end
end
function R:start(entry,complete)
 self:cancel(true)
 local request={entry=entry};self.current=request
 self.core:open(entry,function(path,err)
  if self.current~=request then return end
  self.current=nil;complete(path,err)
 end)
 return request
end
return R
