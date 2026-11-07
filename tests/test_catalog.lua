local H=require('tests/helper');local C=require('gdriveshelf/catalog')
H.test('a container of folders is not an empty reading folder',function()
 local children={{id='child',name='Volumes',is_folder=true},{id='sdr',name='book.sdr',is_folder=true}}
 local core={state={listings={p={complete=true}},entries={}},cachedList=function()return children end,storage={exists=function()return true end}}
 local info=C.stats(core,'p');H.eq(info.count,0);H.eq(info.folders,1);H.eq(info.empty,false)
 children={};info=C.stats(core,'p');H.eq(info.empty,true)
 core.state.listings.p=nil;info=C.stats(core,'p');H.eq(info.empty,nil);H.eq(info.count,nil)
end)
H.test('mixed history groups only comic files and survives archive eviction',function()
 local state={docs={},folders={p={id='p',name='Title',is_folder=true}},history={},folder_types={}}
 C.recordOpen(state,{id='c1',name='1.cbz',parent_id='p'},10)
 C.recordOpen(state,{id='b',name='Novel.epub',parent_id='p'},20)
 C.recordOpen(state,{id='c2',name='2.cbz',parent_id='p'},30)
 local history=C.history(state);H.eq(#history,2);H.eq(history[1].entry.id,'c2');H.eq(history[1].folder_id,'p');H.eq(history[2].entry.id,'b');assert(not history[2].folder_id)
end)
H.test('folder override treats PDF as comic without classifying unrelated books',function()
 local s={folder_types={comic='comics'}}
 H.eq(C.kind({name='1.pdf',parent_id='comic'},s),'comics')
 H.eq(C.kind({name='Novel.epub',parent_id='other'},s),'books')
 H.eq(C.kind({name='1.CBZ',parent_id='other'},s),'comics')
end)
H.test('unknown is distinct from a confirmed empty folder and statistics exclude metadata',function()
 local core={state={listings={},entries={a={id='a',parent_id='p',ready=true,pool='auto',size=20,path='a'},cover={parent_id='p',ready=true,pool='meta',size=100,path='c'}}},storage={exists=function()return true end},cachedList=function()return {}end}
 local info=C.stats(core,'p');H.eq(info.count,nil);H.eq(info.bytes,20)
 core.state.listings.p={complete=true};info=C.stats(core,'p');H.eq(info.count,0)
end)
H.test('pinned and enriched folders precede ordinary folders even in reverse order',function()
 local list={{id='a',name='A',is_folder=true},{id='z',name='Z',is_folder=true,pinned=true},{id='b',name='B',is_folder=true,known=true}}
 local rows=C.order(list,'name',true,true);H.eq(rows[1].id,'z');H.eq(rows[2].id,'b');H.eq(rows[3].id,'a')
 rows=C.order(list,'name',true,false);H.eq(rows[1].id,'z');H.eq(rows[2].id,'b')
end)
H.test('index interval disabled still discovers unseen folders',function()
 assert(C.due(nil,100,{index_hours=0}));assert(not C.due({complete=true,checked_at=1},100000,{index_hours=0}))
 assert(not C.due({complete=true,checked_at=1},100,{index_hours=24}));assert(C.due({complete=true,checked_at=1},90000,{index_hours=24}))
end)
H.test('opening a stale cached listing cannot replace a relocated local identity',function()
 local state={docs={a={id='a',local_path='/new/Books/book.cbz'}},history={},last_opened={}}
 C.recordOpen(state,{id='a',name='book.cbz',parent_id='p',local_path='/old/Books/book.cbz'},10)
 H.eq(state.docs.a.local_path,'/new/Books/book.cbz')
end)
H.test('original Drive name sorting respects grouping but ignores the displayed title',function()
 local entries={{id='z',name='A display title',drive_name='Series 10'},
  {id='b',name='Z display title',drive_name='Series 2'},
  {id='p',name='Pinned title',drive_name='Series 100',pinned=true}}
 local ordered=C.order(entries,'drive_name',false,false)
 H.eq(ordered[1].id,'p');H.eq(ordered[2].id,'b');H.eq(ordered[3].id,'z')
end)
