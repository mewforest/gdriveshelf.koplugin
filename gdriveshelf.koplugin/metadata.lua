local M={}
local function text(v)
 if type(v)=='string'and v:find('%S')then return v:sub(1,65536)end
end
local function names(v)
 if type(v)=='string' then return text(v) end
 local out={};if type(v)=='table' then for _,x in ipairs(v) do local s=type(x)=='table' and text(x.title or x.name) or text(x);if s then out[#out+1]=s end end end
 return table.concat(out,', ')
end
local function basename(s)
 return type(s)=='string' and s~='' and not s:find('[/\\%c]') and s~='.' and s~='..'
end
local cover_names={'cover.jpg','cover.jpeg','cover.png','cover.webp'}
local standard_cover={}
for _,name in ipairs(cover_names) do standard_cover[name]=true end
local image_extensions={jpg=true,jpeg=true,png=true,webp=true}
function M.isImageName(name)
 if not basename(name) then return false end
 return image_extensions[name:lower():match('%.([^%.]+)$')]==true
end
function M.isCoverName(name)
 return type(name)=='string' and standard_cover[name:lower()]==true
end
function M.coverCandidates(entries,preferred)
 local matches, exact = {}, nil
 local preferred_lower=M.isImageName(preferred) and preferred:lower()
 for _,entry in ipairs(entries or {}) do
  if not entry.is_folder and M.isImageName(entry.name) then
   local lower=entry.name:lower()
   if standard_cover[lower] or lower==preferred_lower then
    if matches[lower]==nil then matches[lower]=entry else matches[lower]=false end
   end
   if entry.name==preferred then
    if exact==nil then exact=entry else exact=false end
   end
  end
 end
 local ordered={}
 local chosen=exact or (exact==nil and preferred_lower and matches[preferred_lower])
 if chosen then ordered[#ordered+1]=chosen end
 for _,name in ipairs(cover_names) do
  if matches[name] and matches[name]~=chosen then ordered[#ordered+1]=matches[name] end
 end
 return ordered
end
function M.normalize(data,kind)
 data=type(data)=='table' and data or {}
 local d=type(data.metadata)=='table' and data.metadata or data
 local m={title=text(d.title)or text(d.name),author=names(d.authors or d.author),description=text(d.description_text)or text(d.description)or text(d.summary),tags=names(d.tags or d.genre),status=text(d.state)or text(d.status),publisher=text(d.publisher),year=tonumber(d.year),chapters={},cover='cover.jpg'}
 if M.isImageName(d.cover_entry) then m.cover=d.cover_entry
 elseif M.isImageName(data.cover_entry) then m.cover=data.cover_entry end
 local chapters=d.chapters or data.chapters
 if type(chapters)=='table' then
  for _,ch in pairs(chapters) do
   if type(ch)=='table' and basename(ch.file) then
    local name=text(ch.name)
    name=name and name:match('^%s*(.-)%s*$')
    if name and name~='' then m.chapters[ch.file]=name end
   end
  end
 end
 return m
end
function M.isService(e)
 local n=(e.name or ''):lower()
 return (not e.is_folder and M.isCoverName(n)) or n=='index.json' or n=='series.json' or n=='gdriveshelf.json' or n:match('^gdriveshelf%-cover%-.+%.png$')~=nil or (e.is_folder==true and n:match('%.sdr$')~=nil)
end
function M.visible(entries,show,preferred_cover)
 local r={}
 local chosen=not show and preferred_cover and M.coverCandidates(entries,preferred_cover)[1]
 for _,e in ipairs(entries or {}) do
  if show or (e~=chosen and not M.isService(e)) then r[#r+1]=e end
 end
 return r
end
function M.fingerprint(e)return '2:'..tostring(e.version or '')..':'..tostring(e.modified_time or '')..':'..tostring(e.checksum or '')end
return M
