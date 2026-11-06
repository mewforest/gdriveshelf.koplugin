-- Local catalog decisions; no network or document decoding happens here.
local Library=require('gdriveshelf/library')
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
function C.stats(core,parent)
 local state=core.state;local count
 if (state.listings or {})[parent]and state.listings[parent].complete then
  count=0;for _,e in ipairs(core:cachedList(parent))do if Library.supported(e)then count=count+1 end end
 end
 local function belongs(id)
  local seen={};while id and not seen[id]do
   if id==parent then return true end;seen[id]=true;id=(state.folders or {})[id]and state.folders[id].parent_id
  end
 end
 local bytes,downloaded=0,0
 for _,e in pairs(state.entries)do
  if e.ready and (e.pool=='auto'or e.pool=='offline')and belongs(e.parent_id)and core.storage:exists(e.path)then
   bytes=bytes+(e.size or 0);downloaded=downloaded+1
  end
 end
 return {count=count,bytes=bytes,downloaded=downloaded}
end
function C.order(entries,mode,reverse,known_first,compare)
 local ordered=Library.ordered(entries,mode,reverse,compare);local groups={{},{},{}}
 for _,e in ipairs(ordered)do
  local rank=e.pinned and 1 or (known_first~=false and e.known and 2 or 3)
  groups[rank][#groups[rank]+1]=e
 end
 local out={};for _,group in ipairs(groups)do for _,e in ipairs(group)do out[#out+1]=e end end;return out
end
return C
