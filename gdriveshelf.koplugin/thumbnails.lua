local T={};local bit=require('bit')
local function number(s,p,k,big)
 local v=0;for i=0,k-1 do local b=s:byte(big and p+i or p+k-1-i);if not b then return nil end;v=v*256+b end;return v
end
function T.dimensions(s)
 local w,h
 if s:sub(1,8)=='\137PNG\r\n\26\n'and s:sub(13,16)=='IHDR'then w,h=number(s,17,4,true),number(s,21,4,true)
 elseif s:sub(1,2)=='\255\216'then
  local pos=3
  while pos+8<=#s do
   if s:byte(pos)~=255 then return nil end
   local marker=s:byte(pos+1);if marker==255 then pos=pos+1
   elseif marker==217 or marker==218 then return nil
   else
    local length=number(s,pos+2,2,true);if not length or length<2 then return nil end
    if (marker>=192 and marker<=195)or(marker>=197 and marker<=199)or(marker>=201 and marker<=203)or(marker>=205 and marker<=207)then h,w=number(s,pos+5,2,true),number(s,pos+7,2,true);break end
    pos=pos+2+length
   end
  end
 elseif s:sub(1,4)=='RIFF'and s:sub(9,12)=='WEBP'then
  local tag=s:sub(13,16)
  if tag=='VP8X'then w,h=number(s,25,3),number(s,28,3);if w and h then w,h=w+1,h+1 end
  elseif tag=='VP8 'and s:sub(24,26)=='\157\1\42'then local a,b=number(s,27,2),number(s,29,2);if a and b then w,h=bit.band(a,16383),bit.band(b,16383)end
  elseif tag=='VP8L'and s:byte(21)==47 then local x=number(s,22,4);if x then w=bit.band(x,16383)+1;h=bit.band(bit.rshift(x,14),16383)+1 end end
 end
 if not w or not h or w<1 or h<1 then return nil,nil,'preview_format' end
 if w*h>16000000 then return nil,nil,'preview_limit' end
 return w,h
end
function T.build(entry,cached,provider,path)
 local Z=require('gdriveshelf/zipcover');local file;local fetched=0
 if cached then
  file=io.open(cached.path,'rb')
  if not file then return nil,{code='preview',message='Cannot read local archive'}end
 end
 local function read(a,b)
  if file then file:seek('set',a);return file:read(b-a+1)end
  local data,err=provider:range(entry,a,b,8*1048576);if data then fetched=fetched+#data end;return data,err
 end
 local data,why=Z.extract(entry,read,{local_file=file~=nil});if file then file:close()end
 if not data then return nil,why end
 local result,err=T.render(data,path);if result then result.range_bytes=fetched end;return result,err
end
function T.render(data,path,max_w,max_h)
 local w,h,code=T.dimensions(data)
 if not w then return nil,{code=code,message=code=='preview_limit'and 'Image exceeds the preview pixel limit' or 'Unsupported or damaged preview image'}end
 local scale=math.min((max_w or 320)/w,(max_h or 440)/h,1)
 local ok,bb=pcall(function()return require('ui/renderimage'):renderImageData(data,#data,false,math.max(1,math.floor(w*scale)),math.max(1,math.floor(h*scale)))end)
 if not ok or not bb then return nil,{code='preview',message='Cannot render cover image'}end
 local saved=pcall(bb.writePNG,bb,path);bb:free()
 local f=saved and io.open(path,'rb');local valid=f and f:read(8)=='\137PNG\r\n\26\n';if f then f:close()end
 if not valid then os.remove(path);return nil,{code='preview',message='Cannot save cover image'}end
 return {path=path}
end
return T
