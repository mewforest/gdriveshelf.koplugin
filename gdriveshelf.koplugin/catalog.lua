-- Local catalog decisions; no network or document decoding happens here.
local Library=require('gdriveshelf/library')
local Metadata=require('gdriveshelf/metadata')
local C={}
function C.kind(entry,state)
 local override=(state.folder_types or {})[entry.parent_id]
 if override=='comics'or override=='books'then return override end
 local ext=(entry.name or ''):lower():match('%.([^%.]+)$')
 return (ext=='cbz'or ext=='cbr'or ext=='cb7')and 'comics'or 'books'
end
function C.recordOpen(state,entry,time)
 state.history=state.history or {};state.last_opened=state.last_opened or {}
 local copy={};for k,v in pairs(entry)do copy[k]=v end
 copy.local_path=(state.docs[entry.id]or {}).local_path or copy.local_path
 state.docs[entry.id]=copy;state.history[entry.id]={entry=copy,time=time or os.time()}
 state.last_opened[entry.parent_id]=time or os.time();state.last_document=entry.id
end
function C.history(state)
 local groups,rows={},{}
 for _,record in pairs(state.history or {})do
  if C.kind(record.entry,state)=='comics'then
   local id=record.entry.parent_id
   if not groups[id]or record.time>groups[id].time then groups[id]={entry=record.entry,time=record.time,folder_id=id}end
  else rows[#rows+1]=record end
 end
 for _,record in pairs(groups)do rows[#rows+1]=record end
 table.sort(rows,function(a,b)if a.time~=b.time then return a.time>b.time end;return a.entry.id<b.entry.id end)
 return rows
end
function C.due(listing,now,settings)
 if not listing or not listing.complete then return true end
 local hours=settings.index_hours;if hours==nil then hours=24 end
 return hours>0 and now-(listing.checked_at or 0)>=hours*3600
end
function C.downloadStats(core)
 local state=core.state
 local totals={}
 for _,entry in pairs(state.entries)do
  if entry.ready and (entry.pool=='auto' or entry.pool=='offline') and core.storage:exists(entry.path)then
   local id=entry.parent_id
   local seen={}
   while id and not seen[id]do
    seen[id]=true
    local sum=totals[id] or {bytes=0,downloaded=0,direct_bytes=0,direct_downloaded=0}
    totals[id]=sum
    sum.bytes=sum.bytes+(entry.size or 0)
    sum.downloaded=sum.downloaded+1
    if id==entry.parent_id and Library.supported(entry)then
     sum.direct_bytes=sum.direct_bytes+(entry.size or 0)
     sum.direct_downloaded=sum.direct_downloaded+1
    end
    local folder=(state.folders or {})[id]
    id=folder and folder.parent_id
   end
  end
 end
 return totals
end
function C.stats(core,parent,downloads)
 local state=core.state;local count,folders,empty,visible_count,total_bytes
 if (state.listings or {})[parent]and state.listings[parent].complete then
  count,folders,visible_count,total_bytes=0,0,0,0
  for _,e in ipairs(core:cachedList(parent))do
   if not Metadata.isService(e)then
    visible_count=visible_count+1
    if e.is_folder then
     folders=folders+1
    elseif Library.supported(e)then
     count=count+1
     local size=tonumber(e.size)
     if total_bytes then total_bytes=size and size>=0 and total_bytes+size or nil end
    end
   end
  end
  empty=visible_count==0
 end
 local sum=(downloads or C.downloadStats(core))[parent]or {}
 return {count=count,folders=folders,visible_count=visible_count,empty=empty,total_bytes=total_bytes,
  bytes=sum.bytes or 0,downloaded=sum.downloaded or 0,
  direct_bytes=sum.direct_bytes or 0,direct_downloaded=sum.direct_downloaded or 0}
end
function C.order(entries,mode,reverse,known_first,compare)
 if mode=='drive_name'then
  local originals,sortable={},{}
  for _,entry in ipairs(entries)do
   originals[entry.id]=entry
   sortable[#sortable+1]={id=entry.id,name=entry.drive_name or entry.name,pinned=entry.pinned,known=entry.known,is_folder=true}
  end
  local ordered=C.order(sortable,'natural',reverse,known_first,compare)
  for i,entry in ipairs(ordered)do ordered[i]=originals[entry.id]end
  return ordered
 end
 local ordered=Library.ordered(entries,mode,reverse,compare);local groups={{},{},{}}
 for _,e in ipairs(ordered)do
  local rank=e.pinned and 1 or (known_first~=false and e.known and 2 or 3)
  groups[rank][#groups[rank]+1]=e
 end
 local out={};for _,group in ipairs(groups)do for _,e in ipairs(group)do out[#out+1]=e end end;return out
end
return C
