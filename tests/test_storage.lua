local H=require('tests/helper');local S=require('storage')
H.test('provider identifiers cannot collide after path encoding',function() assert(S.key('a/b')~=S.key('a_2fb')) end)
H.test('unsafe display name remains a basename',function() assert(not S.safeName('../a/b.cbz'):find('/'));H.eq(S.safeName('..'),'_') end)
print('storage tests passed')
