local M={};local Metadata=require('gdriveshelf/metadata')
local extensions={cbz=true,cbr=true,cb7=true,pdf=true,epub=true,djvu=true,fb2=true,mobi=true,azw=true,azw3=true,txt=true,html=true,htm=true,rtf=true,doc=true,docx=true,zip=true}
function M.supported(e) return not e.is_folder and not Metadata.isService(e) and extensions[(e.name or ''):lower():match('%.([^%.]+)$')] or false end
-- KOReader comparator is injected by the UI; this fallback also works in standalone tests.
local function natural(a,b)
 local x,y=a:lower(),b:lower();local i,j=1,1
 while i<=#x and j<=#y do
  local nx=x:sub(i):match('^%d+');local ny=y:sub(j):match('^%d+')
  if nx and ny then
   local vx,vy=nx:gsub('^0+',''),ny:gsub('^0+','')
   if #vx~=#vy then return #vx<#vy end
   if vx~=vy then return vx<vy end
   i=i+#nx;j=j+#ny
  else
   local cx,cy=x:sub(i,i),y:sub(j,j);if cx~=cy then return cx<cy end;i=i+1;j=j+1
  end
 end
 return #x<#y
end
function M.ordered(entries,mode,reverse,cmp)
 local r={};for _,e in ipairs(entries or {}) do r[#r+1]=e end
 table.sort(r,function(a,b)
  if not not a.is_folder~=not not b.is_folder then return not not a.is_folder end
  local av,bv
  if mode=='size' then av,bv=tonumber(a.size) or 0,tonumber(b.size) or 0
  elseif mode=='date' then av,bv=a.modified_time or '',b.modified_time or '' end
  local less,more
  if av and av~=bv then less,more=av<bv,av>bv
  elseif a.name~=b.name then
   if mode=='name' then less,more=a.name<b.name,a.name>b.name
   elseif cmp then less,more=cmp({text=a.name},{text=b.name}),cmp({text=b.name},{text=a.name})
   else less,more=natural(a.name,b.name),natural(b.name,a.name) end
  end
  if not less and not more then return tostring(a.id)<tostring(b.id) end
  if reverse then return more end;return less
 end);return r
end
function M.next(entries,id,count,mode,reverse,cmp)
 local current;for _,e in ipairs(entries) do if e.id==id then current=e;break end end
 if not current then return {} end
 local list={};for _,e in ipairs(entries) do if e.parent_id==current.parent_id and M.supported(e) then list[#list+1]=e end end
 list=M.ordered(list,mode,reverse,cmp);local result={};local found=false
 for _,e in ipairs(list) do if found and #result<(count or 1) then result[#result+1]=e end;if e.id==id then found=true end end
 return result
end
function M.offlineGroups(entries)
 local r={};for _,e in pairs(entries) do if e.ready and (e.pool=='auto' or e.pool=='offline') then local p=e.parent_id;r[p]=r[p] or {};r[p][#r[p]+1]=e end end;return r
end
return M
