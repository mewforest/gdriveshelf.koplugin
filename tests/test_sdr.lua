package.path = './gdriveshelf.koplugin/?.lua;' .. package.path
local sdr = require('sdr')
local n = 0
local function test(name, fn) fn(); n=n+1; print('ok '..name) end
local function rejects(text, opts) local data,err=sdr.decode(text,opts); assert(data==nil and err, text) end
test('native fixture roundtrip and summary', function()
 local f=assert(io.open('tests/fixtures/metadata.cbz.lua')); local text=f:read('*a'); f:close()
 local d=assert(sdr.decode(text)); assert(d.last_page==1 and d.stats.pages==38)
 local encoded=assert(sdr.encode(d)); local copy=assert(sdr.decode(encoded)); assert(sdr.decide(nil,d,copy)=='same')
 local summary=sdr.summary(d); assert(summary.page==1 and summary.status=='reading' and summary.percent==d.percent_finished)
 assert(sdr.sidecarName('a.b.cbz')=='a.b.sdr'); assert(sdr.metadataName('a.b.CBZ')=='metadata.CBZ.lua')
end)
test('literal keys escapes comments and long strings', function()
 local d=assert(sdr.decode([==[-- comment
return { [1] = "a\000\255\n\"", [false] = true, foo = -1.25e+2, [2] = [=[long
text]=], nested = { "v", 7; }, --[[comment]]
}]==]))
 assert(d[1]=='a\0\255\n"' and d[false] and d.foo==-125 and d[2]=='long\ntext' and d.nested[2]==7)
 assert(sdr.decode(assert(sdr.encode(d)))[false]==true)
end)
test('no executable Lua or ambiguous data accepted', function()
 for _,v in ipairs({'return {}; os.execute("false")','return (function() return {} end)()', 'return {x=os.time()}', 'return {x=function() end}', 'return {x=1+2}', 'return { [1]=1,[1]=2 }', 'return {} return {}', 'return {x=1/0}', 'return {x="\\999"}', 'return {x=0x1p9999}'}) do rejects(v) end
 assert(_G.sdr_injected==nil); rejects('return {}; sdr_injected=true')
end)
test('bounded input nodes nesting and encoder cycles', function()
 rejects('return {}',{max_bytes=5}); rejects('return {{{{}}}}',{max_depth=2}); rejects('return {1,2,3}',{max_nodes=2})
 local x={}; x.x=x; assert(sdr.encode(x)==nil); assert(sdr.encode({x=math.huge})==nil)
end)
test('three way policy never prefers higher page', function()
 local base={last_page=10}; local l={last_page=11}; local r={last_page=2}
 assert(sdr.decide(base,l,r)=='conflict'); assert(sdr.decide(nil,l,r)=='conflict')
 assert(sdr.decide(base,base,r)=='pull'); assert(sdr.decide(base,l,base)=='push')
 assert(sdr.decide(nil,l,nil)=='push'); assert(sdr.decide(nil,nil,r)=='pull')
end)
test('doc path is device-local and summary tolerates malformed scalar types', function()
 local base={last_page=1,doc_path='/cloud/book.cbz'}; local local_data={last_page=2,doc_path='/local/book.cbz'}
 assert(sdr.decide(base,local_data,{last_page=1,doc_path='/other/book.cbz'})=='push')
 assert(sdr.summary({last_page='2',doc_pages='10'}).percent==0.2)
 assert(sdr.summary({last_page='junk',percent_finished='junk'}).page==nil)
end)
test('book identity trusts content checksums over metadata drift', function()
 assert(sdr.sameBook({id='b',checksum='AaFF',version='1',modified_time='old'},{id='b',checksum='aaff',version='2',modified_time='new'}))
 assert(not sdr.sameBook({id='a',checksum='ff'},{id='b',checksum='ff'}))
 assert(not sdr.sameBook({checksum='aa'},{checksum='bb'}))
 assert(sdr.sameBook({version='1',size=10},{version='1',size=10}))
 assert(not sdr.sameBook({version='1',size=10},{version='2',size=10}))
 assert(not sdr.sameBook({modified_time='same',size=10},{modified_time='same',size=11}))
 assert(not sdr.sameBook({id='b'},{id='b'}))
 assert(not sdr.sameBook({size=10},{size=10}))
 assert(not sdr.sameBook(nil,{checksum='aa'}))
end)
print('SDR: '..n..' tests passed')
