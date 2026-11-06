package.path = './gdriveshelf.koplugin/?.lua;' .. package.path
local Sync = require('sync')
local sdr = require('sdr')
local n=0
local function test(name,fn) fn(); n=n+1; print('ok '..name) end
local book={id='book',name='Book.cbz',parent_id='title',checksum='booksum'}
local function fixture()
 local p={children={title={book}},texts={},calls=0,uploads=0}
 function p:list(parent) self.calls=self.calls+1; return self.children[parent] or {} end
 function p:read(e) self.calls=self.calls+1; return self.texts[e.id] end
 function p:stat(id) for _,entries in pairs(self.children) do for _,e in ipairs(entries) do if e.id==id then return e end end end end
 function p:mkdir(parent,name) self.calls=self.calls+1; local e={id=parent=='title' and 'folder' or parent..'-folder',name=name,parent_id=parent,is_folder=true}; table.insert(self.children[parent],e); self.children[e.id]={}; return e end
 function p:upload(parent,name,path,id,etag) self.uploads=self.uploads+1; local f=assert(io.open(path)); local text=f:read('*a'); f:close(); if id then assert(etag, 'must guard existing writes') end; local e={id=id or (parent=='folder' and 'meta' or parent..'-meta'),name=name,parent_id=parent,etag='new-etag',modified_time='new-time',checksum='new-sum'}; self.children[parent]={e}; self.texts[e.id]=text; return e end
 local storage={}
 function storage:writeTemp(text) local path=os.tmpname(); local f=assert(io.open(path,'w')); f:write(text); f:close(); return path end
 function storage:remove(path) return os.remove(path) end
 return p,storage
end
local function remote(p,page)
 p.children.title={book,{id='folder',name='Book.sdr',parent_id='title',is_folder=true}}
 p.children.folder={{id='meta',name='metadata.cbz.lua',parent_id='folder',modified_time='t1',etag='e1',checksum='m1'}}
 p.texts.meta=assert(sdr.encode({last_page=page}))
end
test('offline snapshots coalesce and survive JSON-friendly restart', function()
 local p,storage=fixture(); local state={}; local sync=Sync.new{provider=p,storage=storage,state=state,offline=true}
 assert(sync:snapshot(book,{[false]='key',last_page=1})); assert(sync:snapshot(book,{[false]='key',last_page=4})); assert(p.calls==0)
 local second={id='b2',name='Second.cbz',parent_id='other'}; sync:snapshot(second,{last_page=2})
 local restarted=Sync.new{provider=p,storage=storage,state=state}; local pending=restarted:pendingList(); assert(#pending==2 and pending[1].entry.id=='book' and pending[2].entry.id=='b2')
 assert(type(pending[1].lua)=='string' and sdr.decode(pending[1].lua)[false]=='key')
 assert(sync:pull(book)==nil and p.calls==0)
end)
test('native exact folder/file names and result-only pushes', function()
 local p,storage=fixture(); local state={}; local sync=Sync.new{provider=p,storage=storage,state=state}; local pending=assert(sync:snapshot(book,{last_page=3}))
 local r=assert(sync:push(book,pending)); assert(r.action=='pushed' and r.stamp.id=='meta'); assert(state.pending.book==pending)
 assert(p.children.title[2].name=='Book.sdr' and p.children.folder[1].name=='metadata.cbz.lua')
end)
test('child timestamp invalidates despite unchanged folder', function()
 local p,storage=fixture(); remote(p,2); local sync=Sync.new{provider=p,storage=storage,state={}}
 local first=assert(sync:pull(book)); p.children.folder[1].modified_time='t2'; p.texts.meta=assert(sdr.encode({last_page=3})); local next=assert(sync:pull(book))
 assert(next.data.last_page==3 and next.stamp.modified_time~=first.stamp.modified_time)
end)
test('base plus concurrent changes conflict with both snapshots', function()
 local p,storage=fixture(); remote(p,2); local state={bases={book={lua=assert(sdr.encode({last_page=1})),stamp={id='meta',etag='e0'}}}}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local pending=sync:snapshot(book,{last_page=9}); local result=assert(sync:push(book,pending)); assert(result.action=='conflict' and result.conflict.local_lua==pending.lua and sdr.decode(result.conflict.remote_lua).last_page==2 and p.uploads==0)
 local unknown=Sync.new{provider=p,storage=storage,state={}}; local no_base=unknown:snapshot(book,{last_page=9}); assert(unknown:push(book,no_base).action=='conflict')
end)
test('existing writes require provider etag', function()
 local p,storage=fixture(); remote(p,1); local state={bases={book={lua=p.texts.meta,stamp={id='meta',etag='e1'}}}}; local sync=Sync.new{provider=p,storage=storage,state=state}; local pending=sync:snapshot(book,{last_page=2})
 assert(sync:push(book,pending).action=='pushed'); assert(p.uploads==1)
 remote(p,1); p.children.folder[1].etag=nil; local result,err=sync:push(book,pending); assert(result==nil and err.code=='unguarded_write' and p.uploads==1)
end)
test('duplicates and identical stems block upload', function()
 local p,storage=fixture(); remote(p,1); table.insert(p.children.title,{id='folder2',name='Book.sdr',parent_id='title',is_folder=true}); local sync=Sync.new{provider=p,storage=storage,state={}}
 local r,e=sync:pull(book); assert(not r and e.code=='ambiguous_sidecar')
 p.children.title={book,{id='otherbook',name='Book.epub',parent_id='title'}}; local pending=sync:snapshot(book,{last_page=2}); r,e=sync:push(book,pending); assert(not r and e.code=='ambiguous_stem' and p.uploads==0)
 remote(p,1); table.insert(p.children.folder,{id='meta2',name='metadata.cbz.lua',parent_id='folder'}); r,e=sync:pull(book); assert(not r and e.code=='ambiguous_metadata')
end)
test('invalid cloud Lua and changed book never apply silently', function()
 local p,storage=fixture(); remote(p,1); p.texts.meta='return {}; error("bad")'; local sync=Sync.new{provider=p,storage=storage,state={}}; assert(sync:pull(book)==nil)
 local state={bases={book={lua=assert(sdr.encode({last_page=1})),book_stamp={checksum='old'}}}}; remote(p,1); sync=Sync.new{provider=p,storage=storage,state=state}; local r=assert(sync:push(book,sync:snapshot(book,{last_page=2}))); assert(r.action=='conflict' and r.conflict.reason=='book_changed')
end)
test('manual resolution persists both alternatives then rechecks remote', function()
 local p,storage=fixture(); remote(p,2)
 local state={bases={book={lua=assert(sdr.encode({last_page=1}))}}}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local pending=sync:snapshot(book,{last_page=3}); local r=assert(sync:push(book,pending)); sync:commit(book,pending,r)
 assert(state.conflicts.book.local_lua and state.conflicts.book.remote_lua and state.pending.book)
 local retry=assert(sync:resolve('book','local')); local pushed=assert(sync:push(book,retry)); assert(pushed.action=='pushed'); sync:commit(book,retry,pushed)
 remote(p,2); pending=sync:snapshot(book,{last_page=4}); r=assert(sync:push(book,pending)); sync:commit(book,pending,r)
 local chosen=assert(sync:resolve('book','remote')); assert(chosen.data.last_page==2 and not state.pending.book and not state.conflicts.book)
end)
test('parent commit preserves and rebases newer snapshot', function()
 local p,storage=fixture(); local state={}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local old=sync:snapshot(book,{last_page=1}); local result=assert(sync:push(book,old)); local latest=sync:snapshot(book,{last_page=2})
 sync:commit(book,old,result); assert(state.pending.book==latest and latest.base_lua==old.lua)
 local r=assert(sync:push(book,latest)); assert(r.action=='pushed'); sync:commit(book,latest,r); assert(state.pending.book==nil and sdr.decode(state.bases.book.lua).last_page==2)
end)
test('all titles flush in stable order after restart', function()
 local p,storage=fixture(); local second={id='b2',name='Second.cbz',parent_id='other'}; p.children.other={second}
 local state={}; local offline=Sync.new{provider=p,storage=storage,state=state,offline=true}
 offline:snapshot(book,{last_page=1}); offline:snapshot(second,{last_page=8}); offline:snapshot(book,{last_page=4})
 local online=Sync.new{provider=p,storage=storage,state=state}; local ids={}
 for _,pending in ipairs(online:pendingList()) do ids[#ids+1]=pending.entry.id; local r=assert(online:push(pending.entry,pending)); online:commit(pending.entry,pending,r) end
 assert(ids[1]=='book' and ids[2]=='b2' and next(state.pending)==nil and p.uploads==2)
 local selected={}; online:lazy({book,second,{id='dir',name='Folder',is_folder=true}},function(e) selected[#selected+1]=e.id end); assert(#selected==2)
end)
test('conditional-write conflict preserves pending and temp cleaned', function()
 local p,storage=fixture(); remote(p,1); local state={bases={book={lua=p.texts.meta}}}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local pending=sync:snapshot(book,{last_page=2}); local removed=false; local remove=storage.remove
 storage.remove=function(self,path) removed=true; return remove(self,path) end
 p.upload=function() return nil,{code='precondition_failed',status=412,message='concurrent write'} end
 local result,e=sync:push(book,pending); assert(result==nil and e.status==412 and removed and state.pending.book==pending)
end)
test('remote-only result cannot rebase concurrent new local edit', function()
 local p,storage=fixture(); remote(p,2); local state={bases={book={lua=assert(sdr.encode({last_page=1}))}}}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local old=sync:snapshot(book,{last_page=1}); local pulled=assert(sync:push(book,old)); assert(pulled.action=='pull')
 local latest=sync:snapshot(book,{last_page=3}); sync:commit(book,old,pulled)
 assert(sync:push(book,latest).action=='conflict')
end)
test('saved conflicts track newest local snapshot including in-flight replacement', function()
 local p,storage=fixture(); remote(p,2); local state={bases={book={lua=assert(sdr.encode({last_page=1}))}}}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local old=sync:snapshot(book,{last_page=3}); local conflict=assert(sync:push(book,old)); sync:snapshot(book,{last_page=4}); sync:commit(book,old,conflict)
 assert(sdr.decode(state.conflicts.book.local_lua).last_page==4)
 sync:snapshot(book,{last_page=5}); assert(sdr.decode(state.conflicts.book.local_lua).last_page==5)
end)
test('explicit local choice acknowledges changed source version', function()
 local p,storage=fixture(); remote(p,1); local state={bases={book={lua=p.texts.meta,book_stamp={checksum='old'}}}}; local sync=Sync.new{provider=p,storage=storage,state=state}
 local oldentry={id=book.id,name=book.name,parent_id=book.parent_id,checksum='old'}
 local pending=sync:snapshot(oldentry,{last_page=2}); local result=assert(sync:push(book,pending)); assert(result.conflict.reason=='book_changed'); sync:commit(book,pending,result)
 local retry=assert(sync:resolve('book','local')); assert(sync:push(book,retry).action=='pushed')
end)
test('equal book checksum tolerates asynchronous source version drift', function()
 local p,storage=fixture(); remote(p,1)
 local source={id=book.id,name=book.name,parent_id=book.parent_id,checksum='BOOKSUM',version='1',modified_time='old',size=10}
 p.children.title[1]={id=book.id,name=book.name,parent_id=book.parent_id,checksum='booksum',version='2',modified_time='new',size=10}
 local state={bases={book={lua=p.texts.meta,book_stamp={id=book.id,checksum='booksum',version='1',modified_time='old'}}}}
 local sync=Sync.new{provider=p,storage=storage,state=state}; local pending=sync:snapshot(source,{last_page=2})
 local result=assert(sync:push(source,pending)); assert(result.action=='pushed')
end)
test('source drift without checksum remains blocked', function()
 local p,storage=fixture(); remote(p,1)
 local source={id=book.id,name=book.name,parent_id=book.parent_id,version='1',size=10}
 p.children.title[1]={id=book.id,name=book.name,parent_id=book.parent_id,version='2',size=10}
 local sync=Sync.new{provider=p,storage=storage,state={}}; local pending=sync:snapshot(source,{last_page=2})
 local result=assert(sync:push(source,pending)); assert(result.action=='conflict' and result.conflict.reason=='book_changed' and p.uploads==0)
end)
print('Sync: '..n..' tests passed')
