local H=require('tests/helper')
local Cache=require('cache')
local entries={a={pool='auto',size=60,last_access=1}, b={pool='auto',size=30,last_access=2}, pin={pool='offline',size=1000,last_access=0},cover={pool='meta',size=10,last_access=0}}
H.test('offline downloads do not consume auto budget',function()
 local c=Cache.new{entries=entries,auto_limit=100,meta_limit=20,reserve=50,free_bytes=1000}
 local victims=assert(c:plan('auto',15,{})); H.eq(#victims,1); H.eq(victims[1],'a')
 H.eq(c:usage().offline,1000)
end)
H.test('protected reading file never evicted',function()
 local c=Cache.new{entries=entries,auto_limit=100,meta_limit=20,reserve=50,free_bytes=1000}
 local victims=assert(c:plan('auto',15,{a=true})); H.eq(victims[1],'b')
end)
H.test('metadata independent limit',function()
 local c=Cache.new{entries=entries,auto_limit=100,meta_limit=20,reserve=50,free_bytes=1000}
 local victims=assert(c:plan('meta',15,{})); H.eq(#victims,1); H.eq(victims[1],'cover')
end)
H.test('physical reserve never evicts pinned data',function()
 local c=Cache.new{entries=entries,auto_limit=100,meta_limit=20,reserve=50,free_bytes=20}
 local v,e=c:plan('offline',200,{}); H.eq(v,nil); assert(e:match('space'))
end)
H.test('oversize auto file fails rather than unbounded cache',function()
 local c=Cache.new{entries={},auto_limit=100,meta_limit=20,reserve=50,free_bytes=1000}
 H.eq(c:plan('auto',101,{}),nil)
end)
H.test('part bytes count and active entry protected',function()
 local c=Cache.new{entries={part={pool='auto',size=80,last_access=1}},auto_limit=100,meta_limit=20,reserve=0,free_bytes=1000}
 H.eq(c:plan('auto',30,{part=true}),nil)
end)
H.test('manual promotion preserves identity and file',function()
 local c=Cache.new{entries=entries,auto_limit=100,meta_limit=20,reserve=50,free_bytes=1000}
 c:promote('a'); H.eq(entries.a.pool,'offline'); H.eq(entries.a.size,60)
end)
print('cache tests passed')
H.test('evicting metadata on another volume cannot pretend to free book space',function()
 local entries={cover={pool='meta',size=1000,last_access=0}}
 local c=Cache.new{entries=entries,reserve=512,free_bytes=600,auto_limit=10000,volume=function(pool)return pool=='meta'and 'system'or 'books'end}
 assert(not c:plan('auto',200,{}),'Another volume must not satisfy the book reserve')
end)
