local H=require('tests/helper');local Storage=require('storage')
local function storage(account,shared)
 shared=shared or {};local disk={}
 local s=setmetatable({root='/state/'..account,account=account,books_dir='/library/Books',lfs={attributes=function(path)return disk[path]and {mode='file'}end}},Storage)
 s.mkdir=function()return true end
 s.readJSON=function(_,p)return shared[p]end
 s.writeJSON=function(_,p,v)shared[p]=v;return true end
 return s,shared,disk
end
H.test('chapters share a readable parent and pinning does not change path',function()
 local s=storage('a');local e={id='one',name='01.cbz',parent_id='title',parent_name='My manga'}
 H.eq(s:filePath(e,'auto'),'/library/Books/My manga/01.cbz')
 e.id='two';e.name='02.cbz';H.eq(s:filePath(e,'offline'),'/library/Books/My manga/02.cbz')
 e.id='one';e.name='01.cbz';H.eq(s:filePath(e,'offline'),'/library/Books/My manga/01.cbz')
end)
H.test('same names across folders accounts and case do not overwrite',function()
 local a,shared=storage('a');local b=storage('b',shared)
 local first=a:filePath({id='one',name='book.cbz',parent_id='p',parent_name='Title'},'auto')
 local other=a:filePath({id='two',name='BOOK.cbz',parent_id='p',parent_name='Title'},'auto')
 local folder=a:filePath({id='three',name='book.cbz',parent_id='q',parent_name='title'},'auto')
 local account=b:filePath({id='one',name='book.cbz',parent_id='p',parent_name='Title'},'auto')
 assert(first:lower()~=other:lower()and first:lower()~=folder:lower()and first:lower()~=account:lower())
 assert(other:match('BOOK.*%.cbz$')and folder:find('title',1,true))
end)
H.test('registered paths survive remote rename and never overwrite an unrelated file',function()
 local s,_,disk=storage('a');disk['/library/Books/Title/book.cbz']=true
 local e={id='one',name='book.cbz',parent_id='p',parent_name='Title'}
 local path=s:filePath(e,'auto');assert(path~='/library/Books/Title/book.cbz')
 e.name='renamed.cbz';e.parent_name='Renamed title';H.eq(s:filePath(e,'offline'),path)
end)
H.test('metadata remains outside the readable book tree',function()
 local s=storage('a');local p=s:filePath({id='cover',name='cover.jpg',parent_id='p'},'meta')
 assert(p:match('^/state/a/meta/'))
end)
