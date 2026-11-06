local M={};local Metadata=require('gdriveshelf/metadata');local SDR=require('gdriveshelf/sdr')
local extensions={cbz=true,cbr=true,cb7=true,pdf=true,epub=true,djvu=true,fb2=true,mobi=true,azw=true,azw3=true,txt=true,html=true,htm=true,rtf=true,doc=true,docx=true,zip=true}
function M.supported(e) return not e.is_folder and not Metadata.isService(e) and extensions[(e.name or ''):lower():match('%.([^%.]+)$')] or false end
function M.nativeComparator(collate)
 local compare=collate.init_sort_func()
 return function(a,b)
  if collate.item_func then collate.item_func(a);collate.item_func(b)end
  return compare(a,b)
 end
end
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
  elseif mode=='date' then av,bv=a.modified_time or '',b.modified_time or ''
  elseif mode=='read' then av,bv=tonumber(a.last_read)or 0,tonumber(b.last_read)or 0
  elseif mode=='added' then av,bv=a.created_time or '',b.created_time or '' end
  local less,more
  if av and av~=bv then
   if mode=='read'or mode=='added'then less,more=av>bv,av<bv else less,more=av<bv,av>bv end
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
-- A matching native sidecar only says a book was opened, not how far it was read.
function M.folderProgress(entries,summaries,pending)
 local books,stems,sidecars={},{},{}
 for _,e in ipairs(entries or {})do
  local name=e.name or ''
  if e.is_folder then sidecars[name]=true
  else
   local side=SDR.sidecarName(name);stems[side]=(stems[side]or 0)+1
   if name:lower():match('%.cbz$')then books[#books+1]=e end
  end
 end
 if #books==0 then return nil end
 local started=0
 for _,book in ipairs(books)do
  local side=SDR.sidecarName(book.name)
  if (summaries and summaries[book.id])or(pending and pending[book.id])or(sidecars[side]and stems[side]==1)then started=started+1 end
 end
 return {started=started,total=#books,ratio=started/#books}
end
return M
