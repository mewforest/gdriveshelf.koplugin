-- Cache policy is pure: the caller applies the returned eviction plan on disk.
local Cache={};Cache.__index=Cache
function Cache.new(o)
 return setmetatable({entries=o.entries or {},auto_limit=o.auto_limit or 3072*1048576,meta_limit=o.meta_limit or 256*1048576,reserve=o.reserve or 512*1048576,free_bytes=o.free_bytes,volume=o.volume},Cache)
end
function Cache:usage()
 local u={auto=0,offline=0,meta=0}
 for _,e in pairs(self.entries) do if u[e.pool] then u[e.pool]=u[e.pool]+(tonumber(e.size) or 0) end end
 return u
end
function Cache:promote(id) if self.entries[id] then self.entries[id].pool='offline' end end
function Cache:plan(pool,bytes,protected,replace_id)
 bytes=tonumber(bytes);protected=protected or {}
 if not bytes or bytes<0 or bytes~=bytes then return nil,'Unknown or invalid file size' end
 local limit=pool=='auto' and self.auto_limit or pool=='meta' and self.meta_limit
 if pool~='auto' and pool~='meta' and pool~='offline' then return nil,'Unknown cache pool' end
 if limit and bytes>limit then return nil,'File exceeds cache limit' end
 local used=self:usage()[pool];local old=self.entries[replace_id]
 if old and old.pool==pool then used=used-(old.size or 0) end
 local available=type(self.free_bytes)=='function' and self.free_bytes(pool) or self.free_bytes
 if not available then return nil,'Cannot determine free disk space' end
 local candidates={}
 for id,e in pairs(self.entries) do
  if e.pool~='offline' and not protected[id] and id~=replace_id then candidates[#candidates+1]={id=id,e=e} end
 end
 table.sort(candidates,function(a,b)
  local ap,bp=a.e.pool==pool,b.e.pool==pool
  if ap~=bp then return ap end
  if (a.e.last_access or 0)==(b.e.last_access or 0) then return a.id<b.id end
  return (a.e.last_access or 0)<(b.e.last_access or 0)
 end)
 local victims={}
 for _,c in ipairs(candidates) do
  local budget=limit and used+bytes>limit
  local physical=available-bytes<self.reserve
  if not budget and not physical then break end
  local same_volume=not self.volume or self.volume(c.e.pool)==self.volume(pool)
  if (physical and same_volume)or(budget and c.e.pool==pool)then
   victims[#victims+1]=c.id;if same_volume then available=available+(c.e.size or 0)end
   if c.e.pool==pool then used=used-(c.e.size or 0) end
  end
 end
 if limit and used+bytes>limit then return nil,'Cache is full; active files are protected' end
 if available-bytes<self.reserve then return nil,'Not enough free disk space (safety reserve)' end
 return victims
end
return Cache
