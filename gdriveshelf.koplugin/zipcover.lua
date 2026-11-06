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
local function extract(file,fetch,options)
 options=options or {};local size=assert(tonumber(file.size));assert(size>=23,'Invalid ZIP size')
 local ranges,transferred={},0
 local function read(first,last)
  assert(first>=0 and last>=first and last<size,'Invalid ZIP offset')
  local count=last-first+1;assert(transferred+count<=8*MiB,'Preview transfer budget');assert(options.local_file or transferred+count<size,'Complete-file transfer budget refused')
  local nextRanges={};for _,r in ipairs(ranges)do nextRanges[#nextRanges+1]=r end;nextRanges[#nextRanges+1]={first,last}
  table.sort(nextRanges,function(a,b)return a[1]<b[1]end)
  local covered,lo,hi=0,nil,nil
  for _,r in ipairs(nextRanges)do
   if not lo then lo,hi=r[1],r[2]elseif r[1]<=hi+1 then hi=math.max(hi,r[2])else covered=covered+hi-lo+1;lo,hi=r[1],r[2]end
  end
  covered=covered+hi-lo+1;assert(options.local_file or covered<size,'Complete remote ZIP refused')
  local data=assert(fetch(first,last));assert(#data==count,'Incomplete ZIP range')
  ranges=nextRanges;transferred=transferred+count;return data
 end
 local tail=read(size-math.min(65557,size-1),size-1);local eocd
 for p=#tail-21,1,-1 do if tail:sub(p,p+3)=='PK\5\6'and p+21+n(tail,p+20,2)==#tail then eocd=p;break end end
 assert(eocd,'Missing ZIP directory')
 assert(n(tail,eocd+4,2)==0 and n(tail,eocd+6,2)==0,'Multi-disk ZIP')
 local count=n(tail,eocd+10,2);local directorySize=n(tail,eocd+12,4);local directoryOffset=n(tail,eocd+16,4)
 assert(count<65535 and directorySize<4294967295 and directoryOffset<4294967295,'ZIP64 unsupported')
 assert(directorySize>0 and directorySize<=MiB and directoryOffset+directorySize<=size-22,'ZIP directory budget')
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
 local image=require('gdriveshelf/library').ordered(images,'natural')[1]
 assert(require('bit').band(image.flags,1)==0 and(image.method==0 or image.method==8),'Unsupported encrypted/compressed image')
 assert(image.expanded>0 and image.expanded<=16*MiB and image.compressed>0 and image.compressed<=8*MiB,'Image byte budget')
 local header=read(image.offset,image.offset+29);assert(header:sub(1,4)=='PK\3\4','Invalid local ZIP header')
 assert(n(header,7,2)==image.flags and n(header,9,2)==image.method,'ZIP headers disagree')
 local offset=image.offset+30+n(header,27,2)+n(header,29,2)
 assert(offset+image.compressed<=directoryOffset,'Image overlaps ZIP directory')
 local data=read(offset,offset+image.compressed-1)
 if image.method==8 then data=inflate(data,image.expanded)else assert(#data==image.expanded)end
 assert(Z.crc32(data)==image.crc,'ZIP checksum mismatch')
 return data,image,{bytes=transferred}
end
function Z.extract(file,fetch,options)
 local ok,data,image,stats=pcall(extract,file,fetch,options)
 if ok then return data,image,stats end
 return nil,{code='preview',message='Archive preview unavailable: unsupported, changed, damaged or over budget'}
end
return Z
