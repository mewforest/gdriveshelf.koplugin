-- Experimental ZIP32 random access. Every remote read has a hard byte budget.
local Z={};local MiB=1048576
local function n(s,p,k)local v=0;for i=k-1,0,-1 do local b=s:byte(p+i);if not b then error('Truncated ZIP')end;v=v*256+b end;return v end
local lib
local function zlib()
 if lib then return lib end
 local ffi=require('ffi')
 ffi.cdef[[
 typedef struct { const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
 unsigned char *next_out; unsigned int avail_out; unsigned long total_out; const char *msg;
 void *state; void *zalloc; void *zfree; void *opaque; int data_type; unsigned long adler; unsigned long reserved; } gds_z_stream;
 const char *zlibVersion(void); int inflateInit2_(gds_z_stream *, int, const char *, int);
 int inflate(gds_z_stream *, int); int inflateEnd(gds_z_stream *);
 unsigned long crc32(unsigned long, const unsigned char *, unsigned int);
 ]]
 -- Android's KOReader monolithic library exports crc32/compress but may omit
 -- raw inflate. Its public system libz supplies the full stable zlib ABI.
 local loaders={function()return ffi.loadlib and ffi.loadlib('z',1)or ffi.load('z')end,
  function()return ffi.load(jit.os=='OSX'and '/usr/lib/libz.dylib'or 'libz.so.1')end,
  function()return ffi.load('libz.so')end}
 for _,load in ipairs(loaders)do
  local ok,candidate=pcall(load)
  if ok and pcall(function()return candidate.inflateInit2_ end)then lib=candidate;return lib end
 end
 error('Raw deflate codec unavailable')
end
function Z.crc32(data)return tonumber(zlib().crc32(0,data,#data))end
local function inflate(data,size)
 local ffi=require('ffi');local z=zlib();local stream=ffi.new('gds_z_stream[1]');local buffer=ffi.new('unsigned char[?]',math.max(size,1))
 assert(z.inflateInit2_(stream,-15,z.zlibVersion(),ffi.sizeof(stream[0]))==0)
 stream[0].next_in=data;stream[0].avail_in=#data;stream[0].next_out=buffer;stream[0].avail_out=size
 local result=z.inflate(stream,4);local length=tonumber(stream[0].total_out);local remaining=tonumber(stream[0].avail_in);z.inflateEnd(stream)
 assert(result==1 and length==size and remaining==0,'Invalid bounded deflate')
 return ffi.string(buffer,length)
end
local function problem(code,message)error({code=code,message=message},0)end
local function previewError()
 return {code='preview',message='The CBZ archive is damaged or unreadable'}
end
function Z.partialReader(file,fetch,local_file,limit)
 local size=tonumber(file.size)
 local transferred=0
 local function read(first,last)
  assert(size and first>=0 and last>=first and last<size,'Invalid ZIP offset')
  local count=last-first+1
  if transferred+count>limit or (not local_file and transferred+count>=size)then
   problem('preview_limit','Archive preview byte limit reached')
  end
  -- A failed response may already have transferred part of the range.
  transferred=transferred+count
  local data,why=fetch(first,last)
  if not data and type(why)=='table'and type(why.code)=='string'then error(why,0)end
  assert(data and #data==count,'Incomplete ZIP range')
  return data
 end
 return read,function()return transferred end
end
local function parseIndex(file,read,fast)
 local size=assert(tonumber(file.size));assert(size>=23,'Invalid ZIP size')
 local tail,eocd
 if fast then
  tail=read(size-22,size-1)
  if tail:sub(1,4)=='PK\5\6'and n(tail,21,2)==0 then eocd=1 end
 end
 if not eocd then
  tail=read(size-math.min(65557,size-1),size-1)
  for p=#tail-21,1,-1 do
   if tail:sub(p,p+3)=='PK\5\6'and p+21+n(tail,p+20,2)==#tail then eocd=p;break end
  end
 end
 assert(eocd,'Missing ZIP directory')
 if n(tail,eocd+4,2)~=0 or n(tail,eocd+6,2)~=0 then
  problem('preview_format','This CBZ archive format is unsupported')
 end
 local count=n(tail,eocd+10,2);local directorySize=n(tail,eocd+12,4);local directoryOffset=n(tail,eocd+16,4)
 if count==65535 or directorySize==4294967295 or directoryOffset==4294967295 then
  problem('preview_format','This CBZ archive format is unsupported')
 end
 if directorySize>MiB then problem('preview_limit','Archive preview byte limit reached')end
 assert(directorySize>0 and directoryOffset+directorySize<=size-22,'Invalid ZIP directory')
 local directory=read(directoryOffset,directoryOffset+directorySize-1);local images={};local pos=1
 for index=1,count do
  assert(directory:sub(pos,pos+3)=='PK\1\2','Invalid ZIP entry')
  local flags,method=n(directory,pos+8,2),n(directory,pos+10,2)
  local compressed,expanded=n(directory,pos+20,4),n(directory,pos+24,4)
  local nameLength,extraLength,commentLength=n(directory,pos+28,2),n(directory,pos+30,2),n(directory,pos+32,2)
  local name=directory:sub(pos+46,pos+45+nameLength);assert(#name==nameLength)
  local ext=name:lower():match('%.([^%.]+)$')
  if (ext=='jpg'or ext=='jpeg'or ext=='png'or ext=='webp')and not name:match('^__MACOSX/')and not name:match('^%.')and not name:find('/%.')then
   images[#images+1]={id=tostring(index),name=name,flags=flags,method=method,compressed=compressed,expanded=expanded,offset=n(directory,pos+42,4),crc=n(directory,pos+16,4)}
  end
  pos=pos+46+nameLength+extraLength+commentLength;assert(pos<=#directory+1)
 end
 assert(#images>0,'No image in ZIP')
 return {images=require('gdriveshelf/library').ordered(images,'natural'),offset=directoryOffset}
end
local function imageData(image,directoryOffset,read)
 if require('bit').band(image.flags,1)~=0 or (image.method~=0 and image.method~=8)then
  problem('preview_format','This CBZ archive format is unsupported')
 end
 if image.expanded>16*MiB or image.compressed>8*MiB then
  problem('preview_limit','Archive preview byte limit reached')
 end
 assert(image.expanded>0 and image.compressed>0,'Invalid image size')
 local header=read(image.offset,image.offset+29);assert(header:sub(1,4)=='PK\3\4','Invalid local ZIP header')
 assert(n(header,7,2)==image.flags and n(header,9,2)==image.method,'ZIP headers disagree')
 local offset=image.offset+30+n(header,27,2)+n(header,29,2)
 assert(offset+image.compressed<=directoryOffset,'Image overlaps ZIP directory')
 local data=read(offset,offset+image.compressed-1)
 if image.method==8 then data=inflate(data,image.expanded)else assert(#data==image.expanded)end
 assert(Z.crc32(data)==image.crc,'ZIP checksum mismatch')
 return data
end
local function checked(fn,...)
 local ok,value,other,stats=pcall(fn,...)
 if ok then return value,other,stats end
 if type(value)=='table'and type(value.code)=='string'then return nil,value end
 return nil,previewError()
end
function Z.previewIndex(file,read)
 local index,err=checked(parseIndex,file,read,true)
 if index then
  -- Filenames are useful only to order pages. The preview keeps numeric
  -- offsets and sizes, which also makes its worker result encoding compact.
  for _,image in ipairs(index.images)do image.id=nil;image.name=nil end
 end
 return index,err
end
function Z.previewPage(index,number,read)
 local image=index.images[number]
 if not image then return nil,previewError()end
 return checked(imageData,image,index.offset,read)
end
function Z.extract(file,fetch,options)
 return checked(function()
  local read,transferred=Z.partialReader(file,fetch,options and options.local_file,8*MiB)
  local index=parseIndex(file,read)
  local image=index.images[1]
  return imageData(image,index.offset,read),image,{bytes=transferred()}
 end)
end
function Z.pageWindow(total,first,count)
 if type(first)~='number'or first<1 or first%1~=0 or type(count)~='number'or count<1 or count>6 or count%1~=0 then return nil end
 if first>total then return nil end
 return math.min(first+count-1,total)
end
-- Local only. Decode one member at a time and cap the number of members even
-- if the caller asks for a larger batch.
function Z.pages(file,fetch,first,count,visitor)
 local ok,result=pcall(function()
  local read=Z.partialReader(file,fetch,true,50*MiB)
  local index=parseIndex(file,read)
  local last=assert(Z.pageWindow(#index.images,first,count))
  for number=first,last do
   local data,err=Z.previewPage(index,number,read)
   visitor(number,data,err)
  end
  return {total=#index.images,first=first}
 end)
 if ok then return result end
 return nil,previewError()
end
return Z
