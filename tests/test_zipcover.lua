local H=require('tests/helper');local Z=require('gdriveshelf/zipcover')
local function u(n,k)local out='';for _=1,k do out=out..string.char(n%256);n=math.floor(n/256)end;return out end
local function archive(name,data,method,padding)
 method=method or 0;local crc=Z.crc32(data)
 local localheader='PK\3\4'..u(20,2)..u(0,2)..u(method,2)..u(0,4)..u(crc,4)..u(#data,4)..u(#data,4)..u(#name,2)..u(0,2)..name
 local prefix=string.rep('padding',padding or 12000);local offset=#prefix
 local cd='PK\1\2'..u(20,2)..u(20,2)..u(0,2)..u(method,2)..u(0,4)..u(crc,4)..u(#data,4)..u(#data,4)..u(#name,2)..u(0,2)..u(0,2)..u(0,2)..u(0,2)..u(0,4)..u(offset,4)..name
 return prefix..localheader..data..cd..'PK\5\6'..u(0,4)..u(1,2)..u(1,2)..u(#cd,4)..u(offset+#localheader+#data,4)..u(0,2)
end
H.test('extracts first image with bounded ranges without fetching the complete archive',function()
 local bytes=archive('001.jpg','a small image');local got={};local total=0
 local data,entry=Z.extract({size=#bytes},function(a,b)got[#got+1]={a,b};total=total+b-a+1;return bytes:sub(a+1,b+1)end)
 H.eq(data,'a small image');H.eq(entry.name,'001.jpg');assert(total<#bytes)
end)
H.test('corrupt ZIP and unsupported compression never produce an image',function()
 local bad=archive('001.jpg','image',99)
 assert(not Z.extract({size=#bad},function(a,b)return bad:sub(a+1,b+1)end))
 assert(not Z.extract({size=100},function()return string.rep('x',99)end))
end)
H.test('refuses requests whose combined ranges would cover an entire small CBZ',function()
 local bytes=archive('001.jpg','image',0,0)
 local received=0
 local data=Z.extract({size=#bytes},function(a,b)received=received+b-a+1;return bytes:sub(a+1,b+1)end)
 assert(not data and received<#bytes)
end)
H.test('range failures preserve structured transport errors for retry',function()
 local network={code='network',status=503,retry_after=9,message='private detail'}
 local data,why=Z.extract({size=100},function()return nil,network end)
 assert(not data);H.eq(why,network)
end)
H.test('local gallery extracts only the selected natural-order batch',function()
 local files,directory={},{};local offset=0
 for _,num in ipairs{10,2,1,8,9,3,4,5,6,7}do
  local name=num..'.png';local data='image-'..num;local crc=Z.crc32(data)
  local fields=u(0,2)..u(0,2)..u(0,4)..u(crc,4)..u(#data,4)..u(#data,4)..u(#name,2)..u(0,2)
  files[#files+1]='PK\3\4'..u(20,2)..fields..name..data
  directory[#directory+1]='PK\1\2'..u(20,2)..u(20,2)..fields..u(0,2)..u(0,2)..u(0,2)..u(0,4)..u(offset,4)..name
  offset=offset+#files[#files]
 end
 local cd=table.concat(directory);local bytes=table.concat(files)..cd..'PK\5\6'..u(0,4)..u(10,2)..u(10,2)..u(#cd,4)..u(offset,4)..u(0,2)
 local seen={};local result=assert(Z.pages({size=#bytes},function(a,b)return bytes:sub(a+1,b+1)end,7,6,function(page,data)seen[page]=data end))
 H.eq(result.total,10);H.eq(result.first,7);H.eq(seen[7],'image-7');H.eq(seen[10],'image-10');assert(not seen[6])
end)
