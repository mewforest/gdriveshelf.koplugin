local H=require('tests/helper');local M=require('gdriveshelf/relocation')
H.test('relocation plan excludes unmanaged files and keeps old paths until commit',function()
 local core={state={entries={a={id='a',name='1.cbz',path='/old/Books/T/1.cbz',pool='auto',ready=true,parent_id='p'},m={id='m',path='/state/meta/m',pool='meta'}},docs={},folders={p={name='Title'}}},storage={books_dir='/old/Books',root='/state',account='account'}}
 local allocated={filePath=function(_,entry)H.eq(entry.parent_name,'Title');return '/new/Books/Title/'..entry.name end}
 local plan=M.plan(core,allocated);H.eq(#plan,1);H.eq(plan[1].source,'/old/Books/T/1.cbz');H.eq(core.state.entries.a.path,'/old/Books/T/1.cbz')
 M.commit(core,plan);H.eq(core.state.entries.a.path,'/new/Books/Title/1.cbz');H.eq(core.state.entries.m.path,'/state/meta/m')
end)
H.test('relocation updates durable document identity without erasing pending progress',function()
 local core={state={entries={},docs={a={id='a',path='/old/book.epub'}},sync={pending={a={lua='return {}'}}}}}
 M.commit(core,{{id='a',source='/old/book.epub',target='/new/book.epub'}})
 H.eq(core.state.docs.a.path,'/new/book.epub');assert(core.state.sync.pending.a)
end)
