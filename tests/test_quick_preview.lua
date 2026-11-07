local H=require('tests/helper')
local Preview=require('gdriveshelf/preview')
local Zip=require('gdriveshelf/zipcover')
local function fixture()
 local function u(n,k)local out='';for _=1,k do out=out..string.char(n%256);n=math.floor(n/256)end;return out end
 local parts,items={'padding'},{ };local offset=#parts[1]
 for _,i in ipairs{2,1}do
  local name=i..'.png';local data='image'..i
  local fields=u(0,2)..u(0,2)..u(0,4)..u(Zip.crc32(data),4)..u(#data,4)..u(#data,4)..u(#name,2)..u(0,2)
  parts[#parts+1]='PK\3\4'..u(20,2)..fields..name..data
  items[#items+1]='PK\1\2'..u(20,2)..u(20,2)..fields..u(0,2)..u(0,2)..u(0,2)..u(0,4)..u(offset,4)..name
  offset=offset+#parts[#parts]
 end
 local cd=table.concat(items);parts[#parts+1]=cd..'PK\5\6'..u(0,4)..u(2,2)..u(2,2)..u(#cd,4)..u(offset,4)..u(0,2)
 local bytes=table.concat(parts)..'';local entry={id='cbz',name='Comic.cbz',parent_id='title',size=#bytes,version='3'}
 local provider={ranges=0,stats=0}
 function provider:stat()
  self.stats=self.stats+1
  return {id=entry.id,name=entry.name,parent_id=entry.parent_id,size=entry.size,version=self.stats==self.change_at and '4'or entry.version}
 end
 function provider:range(_,a,b)
  self.ranges=self.ranges+1
  return bytes:sub(a+1,b+1)
 end
 return entry,provider
end
local function render(data,path)return {path=path,value=data}end
H.test('preview reads one requested page and reuses the verified ZIP directory',function()
 local entry,provider=fixture()
 local first=Preview.readPage(entry,provider,nil,nil,1,entry.size-1,'unused',nil,nil,render)
 H.eq(first.value.value,'image1');H.eq(provider.ranges,4);H.eq(provider.stats,2)
 local second=Preview.readPage(entry,provider,nil,first.index,2,entry.size-1-first.bytes,'unused',nil,nil,render)
 H.eq(second.value.value,'image2');H.eq(provider.ranges,6);H.eq(provider.stats,4)
 assert(first.bytes+second.bytes<entry.size)
end)
H.test('preview refuses a changed source before requests and drops bytes changed after requests',function()
 local entry,provider=fixture()
 provider.change_at=1
 local result=Preview.readPage(entry,provider,nil,nil,1,entry.size-1,'unused',nil,nil,render)
 H.eq(result.error.code,'changed');H.eq(provider.ranges,0);H.eq(result.bytes,0)
 provider.change_at=3
 result=Preview.readPage(entry,provider,nil,nil,1,entry.size-1,'unused',nil,nil,function()error('changed bytes must not render')end)
 H.eq(result.error.code,'changed');assert(result.bytes>0)
end)
H.test('preview charges unsuccessful reads without queuing a whole-file fallback',function()
 local entry,provider=fixture()
 function provider:range()return nil,{code='range',message='bad range'}end
 local result=Preview.readPage(entry,provider,nil,nil,1,22,'unused',nil,nil,render)
 H.eq(result.error.code,'range');H.eq(result.bytes,22)
end)
H.test('preview reports the pixel limit before invoking the native decoder',function()
 local renderImage=package.loaded['ui/renderimage']
 package.loaded['ui/renderimage']={renderImageData=function()error('oversized image reached native decoder')end}
 local png='\137PNG\r\n\26\n'..string.rep('\0',4)..'IHDR'..'\0\0\16\0'..'\0\0\16\0'
 local output,err=require('gdriveshelf/thumbnails').render(png,'unused',1000,1000)
 package.loaded['ui/renderimage']=renderImage
 H.eq(output,nil);H.eq(err.code,'preview_limit')
end)
H.test('interrupted preview work retains its byte reservation before a worker restarts',function()
 local entry={id='cbz',name='Comic.cbz',parent_id='title',size=48*1048576,version='3'}
 local before,finish
 local core={jobs={nonce='preview-budget-test',dir='/tmp'},storage={},state={docs={cbz=entry}}}
 function core:cached()return nil end
 function core:online()return true end
 function core:network(_,_,callback,_,prepare)finish=callback;before=prepare;return true end
 local session=assert(Preview.new(core,entry,600,800))
 local error_seen
 session:page(1,function(result,err)H.eq(result,nil);error_seen=err end)
 local initial=session.remaining
 assert(before())
 local first_reservation=initial-session.remaining
 assert(first_reservation>0)
 assert(before())
 H.eq(session.remaining,initial-2*first_reservation)
 finish({bytes=22,error={code='range'}})
 H.eq(error_seen.code,'range');H.eq(session.remaining,initial-first_reservation-22)
 core.retired=true
 session:page(1,function(result,err)H.eq(result,nil);error_seen=err end)
 H.eq(error_seen.code,'cancelled')
 session:close()
 H.eq(core.quick_preview_session,nil)
end)
