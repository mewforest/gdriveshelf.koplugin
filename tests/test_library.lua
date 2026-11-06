local H=require('tests/helper'); local L=require('library')
local e={{id='a',name='Tom 1.cbz',parent_id='x'},{id='z',name='Tom 2.cbz',parent_id='y'},{id='c',name='Tom 11.cbz',parent_id='x'},{id='b',name='Tom 2.cbz',parent_id='x'},{id='s',name='cover.jpg',parent_id='x'}}
H.test('next follows natural order within parent only',function()local n=L.next(e,'a',3); H.eq(#n,2); H.eq(n[1].id,'b'); H.eq(n[2].id,'c') end)
H.test('end of title never crosses into another title',function() H.eq(#L.next(e,'c',2),0) end)
H.test('duplicate names deterministic by identity',function()local r=L.ordered({{id='z',name='1.cbz'},{id='a',name='1.cbz'}}); H.eq(r[1].id,'a') end)
H.test('offline groups retain distinct parent folders',function()local g=L.offlineGroups({a={id='a',parent_id='x',pool='auto',ready=true},b={id='b',parent_id='y',pool='offline',ready=true},c={id='c',parent_id='x',pool='meta',ready=true}});H.eq(#g.x,1);H.eq(#g.y,1) end)
print('library tests passed')
H.test('native sorting supports both KOReader 2026.07 and newer preparation hooks',function()
 local old={init_sort_func=function()return function(a,b)return a.text<b.text end end}
 assert(L.nativeComparator(old)({text='a'},{text='b'}))
 local modern={item_func=function(item)item.prepared=item.text end,init_sort_func=function()return function(a,b)return a.prepared<b.prepared end end}
 assert(L.nativeComparator(modern)({text='a'},{text='b'}))
end)
H.test('title recency and addition order are newest first with stable unread fallback',function()
 local titles={{id='a',name='Alpha',last_read=100,created_time='2025-01-01'},{id='b',name='Beta',last_read=200,created_time='2024-01-01'},{id='c',name='Unread'}}
 H.eq(L.ordered(titles,'read')[1].id,'b');H.eq(L.ordered(titles,'read')[3].id,'c')
 H.eq(L.ordered(titles,'added')[1].id,'a');H.eq(L.ordered(titles,'read',true)[1].id,'c')
 H.eq(L.next(e,'a',1)[1].id,'b')
end)
H.test('folder progress is absent without CBZ books',function()
 H.eq(L.folderProgress(),nil)
 H.eq(L.folderProgress({{id='pdf',name='Book.pdf'},{id='folder',name='Book.cbz',is_folder=true},{id='sdr',name='Book.sdr',is_folder=true}}),nil)
end)
H.test('folder progress counts exact native sidecars and case insensitive CBZ extensions',function()
 local progress=L.folderProgress({
  {id='a',name='Chapter 1.CBZ'},{id='b',name='Chapter 2.cbz'},{id='c',name='Chapter 3.cbz'},
  {id='s1',name='Chapter 1.sdr',is_folder=true},{id='s1-copy',name='Chapter 1.sdr',is_folder=true},
  {id='s2',name='chapter 2.sdr',is_folder=true},{id='s3',name='Chapter 3.sdr'},
  {id='other',name='Unrelated.sdr',is_folder=true},{id='pdf',name='Another.pdf'},
 })
 H.eq(progress.total,3);H.eq(progress.started,1);H.eq(progress.ratio,1/3)
end)
H.test('folder progress unions native sidecars with known local summaries and pending snapshots',function()
 local progress=L.folderProgress({
  {id='a',name='1.cbz'},{id='b',name='2.cbz'},{id='c',name='3.cbz'},{id='d',name='4.cbz'},
  {id='s1',name='1.sdr',is_folder=true},
 },{a={percent=0.9},b={percent=0},unrelated={percent=1}},{a={lua='snapshot'},c={lua='snapshot'},unrelated={lua='snapshot'}})
 H.eq(progress.total,4);H.eq(progress.started,3);H.eq(progress.ratio,0.75)
end)
H.test('folder progress does not assign ambiguous native sidecars to individual books',function()
 local entries={
  {id='a',name='Same.cbz'},{id='b',name='Same.CBZ'},{id='side',name='Same.sdr',is_folder=true},
  {id='c',name='Other.cbz'},{id='pdf',name='Other.pdf'},{id='other-side',name='Other.sdr',is_folder=true},
 }
 local progress=L.folderProgress(entries)
 H.eq(progress.total,3);H.eq(progress.started,0);H.eq(progress.ratio,0)
 progress=L.folderProgress(entries,{a={page=1}},{c={lua='snapshot'}})
 H.eq(progress.total,3);H.eq(progress.started,2);H.eq(progress.ratio,2/3)
end)
H.test('title info derives folder progress from cached children without network or SDR reads',function()
 local Core=require('core')
 local core=setmetatable({
  state={entries={},docs={
   a={id='a',name='1.cbz',parent_id='title'},b={id='b',name='2.cbz',parent_id='title'},
   c={id='c',name='3.cbz',parent_id='title'},other={id='other',name='Elsewhere.cbz',parent_id='elsewhere'},
  },folders={title={id='title',name='Title'},side={id='side',name='1.sdr',is_folder=true,parent_id='title'}},
  summaries={b={percent=0.25}},sync={pending={c={lua='snapshot'}}}},settings={},
  storage={readJSON=function()error('unexpected content read')end},
  provider_factory=function()error('unexpected network request')end,
 },Core)
 local info=core:titleInfo('title')
 H.eq(info.title,'Title');assert(info.progress,'folder progress missing from title info')
 H.eq(info.progress.total,3);H.eq(info.progress.started,3);H.eq(info.progress.ratio,1)
 H.eq(core:titleInfo('empty').progress,nil)
end)
