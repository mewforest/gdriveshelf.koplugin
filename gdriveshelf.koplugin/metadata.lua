local M={}
local function text(v) if type(v)=='string' then return v:sub(1,65536) end end
local function names(v)
 if type(v)=='string' then return text(v) end
 local out={};if type(v)=='table' then for _,x in ipairs(v) do local s=type(x)=='table' and text(x.title or x.name) or text(x);if s then out[#out+1]=s end end end
 return table.concat(out,', ')
end
local function basename(s) return type(s)=='string' and s~='' and not s:find('[/\\]') and s~='.' and s~='..' end
function M.normalize(data,kind)
 data=type(data)=='table' and data or {}
 local d=type(data.metadata)=='table' and data.metadata or data
 local m={title=text(d.title or d.name),author=names(d.authors or d.author),description=text(d.description_text or d.description or d.summary),tags=names(d.tags or d.genre),status=text(d.state or d.status),publisher=text(d.publisher),year=tonumber(d.year),chapters={},cover='cover.jpg'}
 if basename(d.cover_entry) then m.cover=d.cover_entry end
 if type(d.chapters)=='table' then for _,ch in pairs(d.chapters) do if type(ch)=='table' and basename(ch.file) then m.chapters[ch.file]=text(ch.name) end end end
 return m
end
function M.isService(e)
 local n=(e.name or ''):lower()
 return n=='cover.jpg' or n=='index.json' or n=='series.json' or (e.is_folder==true and n:match('%.sdr$')~=nil)
end
function M.visible(entries,show)
 local r={};for _,e in ipairs(entries or {}) do if show or not M.isService(e) then r[#r+1]=e end end;return r
end
return M
