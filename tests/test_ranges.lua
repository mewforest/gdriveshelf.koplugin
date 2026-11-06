local H=require('tests/helper');local Provider=require('providers/gdrive')
local function provider(fn)return Provider.new{credentials={access_token='fixture'},json={},transport=fn}end
H.test('range validation rejects whole-file requests before contacting Drive',function()
 local calls=0;local p=provider(function()calls=calls+1 end)
 local value,err=p:range({id='a',size=100},0,99,100);assert(not value and err);H.eq(calls,0)
end)
H.test('ignored Range is rejected before its response body is consumed',function()
 local consumed=false
 local p=provider(function(r)
  local accepted=r.validate_headers(200,{['content-length']='100000000'})
  if accepted then consumed=true;r.sink(string.rep('x',20))end
  return 200,{['content-length']='100000000'}
 end)
 local value,err=p:range({id='a',size=100000000},10,19,10)
 assert(not value and err and not consumed)
end)
H.test('only the exact bounded Content-Range is accepted',function()
 local p=provider(function(r)
  H.eq(r.headers.Range,'bytes=10-19');local headers={['content-range']='bytes 10-19/100'}
  assert(r.validate_headers(206,headers));assert(r.sink('0123456789'));return 206,headers
 end)
 H.eq(assert(p:range({id='a',size=100},10,19,10)),'0123456789')
 local bad=provider(function()return 206,{['content-range']='bytes 0-9/100'},'0123456789'end)
 assert(not bad:range({id='a',size=100},10,19,10))
end)
