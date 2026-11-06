local H=require('tests/helper'); local L=require('library')
local e={{id='a',name='Tom 1.cbz',parent_id='x'},{id='z',name='Tom 2.cbz',parent_id='y'},{id='c',name='Tom 11.cbz',parent_id='x'},{id='b',name='Tom 2.cbz',parent_id='x'},{id='s',name='cover.jpg',parent_id='x'}}
H.test('next follows natural order within parent only',function()local n=L.next(e,'a',3); H.eq(#n,2); H.eq(n[1].id,'b'); H.eq(n[2].id,'c') end)
H.test('end of title never crosses into another title',function() H.eq(#L.next(e,'c',2),0) end)
H.test('duplicate names deterministic by identity',function()local r=L.ordered({{id='z',name='1.cbz'},{id='a',name='1.cbz'}}); H.eq(r[1].id,'a') end)
H.test('offline groups retain distinct parent folders',function()local g=L.offlineGroups({a={id='a',parent_id='x',pool='auto',ready=true},b={id='b',parent_id='y',pool='offline',ready=true},c={id='c',parent_id='x',pool='meta',ready=true}});H.eq(#g.x,1);H.eq(#g.y,1) end)
print('library tests passed')
