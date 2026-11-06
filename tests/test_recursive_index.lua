local H=require('tests/helper');local F=require('catalog_fixture');local Core=require('core')
local ok,install=pcall(require,'indexer');assert(ok,'Recursive catalog module is missing');install(Core)
local function folder(id,parent,name)return{id=id,parent_id=parent,name=name or id,is_folder=true}end
local function book(id,parent)return{id=id,parent_id=parent,name=id..'.cbz',version='1'}end
local function provider(tree,pages)
 local calls={};local p={}
 function p:stat(id)calls[#calls+1]='stat';return folder(id,nil)end
 function p:getStartToken(scope)calls[#calls+1]='token';return 'before'end
 function p:listParents(ids)calls[#calls+1]={ids=ids};local out={};for _,id in ipairs(ids)do out[id]=tree[id]or{}end;return out end
 function p:changes(token)calls[#calls+1]='changes:'..token;return table.remove(pages or{},1)or{changes={},new_start_token='after'}end
 return p,calls
end
H.test('recursive catalog token precedes BFS and excludes native SDR contents',function()
 local p,calls=provider({home={folder('a','home'),folder('sdr','home','Book.sdr')},a={folder('nested','a'),book('a1','a')},nested={book('deep','nested')}})
 local c,_,drain=F.new(nil,p);c:indexHome();drain()
 H.eq(calls[1],'stat');H.eq(calls[2],'token');H.eq(calls[3].ids[1],'home');H.eq(calls[4].ids[1],'a');H.eq(calls[5].ids[1],'nested');H.eq(calls[6],'changes:before')
 H.eq(c.state.catalog.token,'after');assert(c.state.catalog.members.deep);assert(not c.state.listings.sdr);H.eq(c.state.catalog.phase,'ready')
end)
H.test('unconfirmed migration and Drive root never start recursive discovery',function()
 local p,calls=provider({});local c=F.new({home='home',index_enabled=true},p);c:indexHome(true);H.eq(#calls,0)
 c.settings.index_recursive_confirmed=true;c.settings.home='root';c:indexHome();H.eq(#calls,0)
end)
H.test('cancel preserves BFS queue and a late callback cannot advance it',function()
 local p=provider({home={folder('a','home')},a={book('b','a')}});local c,step,drain,jobs=F.new(nil,p)
 c:indexHome();step();local old=table.remove(jobs,1);c:cancelIndex();local rows=old.run(p);old.done(rows)
 H.eq(c.state.catalog.queue[1],'home');assert(c.state.catalog.paused);c:catalogRefresh(true);drain();assert(c.state.catalog.members.b)
end)
H.test('changes mutate membership without deleting local documents or pending SDR',function()
 local p=provider({home={folder('a','home'),folder('b','home')},a={book('one','a')},b={}})
 local c,_,drain=F.new(nil,p);c:indexHome();drain();c.state.sync.pending.one={lua='local'};c.state.docs.one.local_path='/Books/one.cbz'
 p.changes=function()return{changes={{file_id='one',entry={id='one',name='renamed.cbz',parent_id='b',version='2'}},{file_id='noise',entry={id='noise',name='private unrelated name',parent_id='outside'}}},new_start_token='moved'}end
 c:catalogRefresh(true);drain();H.eq(#c:cachedList('a'),0);H.eq(c:cachedList('b')[1].name,'renamed.cbz');assert(not c.state.docs.noise)
 p.changes=function()return{changes={{file_id='b',removed=true}},new_start_token='gone'}end
 c:catalogRefresh(true);drain();assert(not c.state.catalog.members.one);H.eq(c.state.docs.one.local_path,'/Books/one.cbz');assert(c.state.sync.pending.one);H.eq(#c:cachedList('home'),1)
end)
H.test('new subtree in change feed is discovered before ready checkpoint',function()
 local p=provider({home={}});local c,_,drain=F.new(nil,p);c:indexHome();drain()
 local n=0;p.changes=function()n=n+1;if n==1 then return{changes={{file_id='new',entry=folder('new','home')}},new_start_token='new-token'}end;return{changes={},new_start_token='caught-up'}end
 p.listParents=function(_,ids)local out={};for _,id in ipairs(ids)do out[id]=id=='new'and{book('inside','new')}or{}end;return out end
 c:catalogRefresh(true);drain();assert(c.state.catalog.members.inside);H.eq(c.state.catalog.token,'caught-up')
end)
H.test('restart resumes persisted queue and feed without another bootstrap token',function()
 local p,calls=provider({home={folder('a','home')},a={book('b','a')}});local c,step=F.new(nil,p);c:indexHome();step();step()
 local resumed,_,drain=F.new(c.settings,p,c.state);resumed:catalogRefresh(true);drain();assert(resumed.state.catalog.members.b)
 local tokens=0;for _,call in ipairs(calls)do if call=='token'then tokens=tokens+1 end end;H.eq(tokens,1)
end)
H.test('ready refresh polls changes and is throttled instead of rescanning folders',function()
 local p,calls=provider({home={}});local c,_,drain=F.new(nil,p);c:indexHome();drain();local before=#calls
 c:catalogRefresh();drain();H.eq(#calls,before);c:catalogRefresh(true);drain();H.eq(#calls,before+1);assert(type(calls[#calls])=='string')
end)
H.test('failed grouped listing retains queue and cannot mark partial work complete',function()
 local p=provider({});p.listParents=function()return nil,{code='network'}end
 local c,_,drain=F.new(nil,p);c:indexHome();drain();H.eq(c.state.catalog.queue[1],'home');assert(not c.state.listings.home);H.eq(c.state.catalog.token,'before')
end)
H.test('a save between grouped buckets retains every parent until the group finishes',function()
 local p=provider({home={folder('a','home'),folder('b','home')},a={book('aa','a')},b={book('bb','b')}})
 local c,_,drain=F.new(nil,p);local observed=false;local save=c.save
 c.save=function(self)
  if self.state.listings.a and not self.state.listings.b then observed=true;H.eq(self.state.catalog.queue[1],'a');H.eq(self.state.catalog.queue[2],'b')end
  return save(self)
 end
 c:indexHome();drain();assert(observed);assert(c.state.catalog.members.bb)
end)
H.test('change feed invalidates native SDR summaries without cataloguing SDR contents',function()
 local p=provider({home={folder('s','home','Book.sdr')}});local c,_,drain=F.new(nil,p);c:indexHome();drain()
 c.state.progress_cache={book={sidecar_id='s'}}
 p.changes=function()return{changes={{file_id='metadata',entry={id='metadata',name='metadata.cbz.lua',parent_id='s',version='2'}}},new_start_token='updated'}end
 c:catalogRefresh(true);drain();assert(not c.state.docs.metadata);assert(c.state.progress_cache.book.dirty);assert(not c.state.listings.s)
end)
H.test('shared drive home captures and replays its own drive-scoped feed',function()
 local p=provider({home={}});p.stat=function()local e=folder('home');e.drive_id='shared-drive';return e end
 p.getStartToken=function(_,scope)H.eq(scope.drive_id,'shared-drive');return 'shared-before'end
 p.changes=function(_,token,scope)H.eq(token,'shared-before');H.eq(scope.drive_id,'shared-drive');return{changes={},new_start_token='shared-after'}end
 local c,_,drain=F.new(nil,p);c:indexHome();drain();H.eq(c.state.catalog.scope.drive_id,'shared-drive')
end)
H.test('parent-only permission changes refresh known descendant folders',function()
 local p=provider({home={folder('a','home')},a={folder('b','a')},b={book('gone','b')}});local c,_,drain=F.new(nil,p);c:indexHome();drain()
 local n=0;p.changes=function()n=n+1;return{changes=n==1 and{{file_id='a',entry=folder('a','home')}}or{},new_start_token='permission-'..n}end
 local visited={};p.listParents=function(_,ids)local buckets={};for _,id in ipairs(ids)do visited[id]=true;buckets[id]=id=='a'and{folder('b','a')}or{}end;return buckets end
 c:catalogRefresh(true);drain();assert(visited.a and visited.b and not visited.home);assert(not c.state.catalog.members.gone);H.eq(#c:cachedList('b'),0)
end)
H.test('changing home while a request runs ignores its obsolete result',function()
 local p=provider({home={book('old','home')}});local c,_,_,jobs=F.new(nil,p);c:indexHome();local old=table.remove(jobs,1)
 c.settings.home='other';local result,e=old.run(p);old.done(result,e);assert(not c.state.docs.old);assert(not c.state.catalog.token)
 c:catalogRefresh(true);H.eq(c.state.catalog.home,'other')
end)
H.test('replaying a removal after interrupted persistence also repairs parent membership',function()
 local p=provider({home={folder('a','home')},a={folder('nested','a')},nested={book('book','nested')}});local c,_,drain=F.new(nil,p);c:indexHome();drain()
 p.changes=function()return{changes={{file_id='a',removed=true}},new_start_token='removed'}end
 local snapshot;local function copy(v)if type(v)~='table'then return v end;local t={};for k,x in pairs(v)do t[k]=copy(x)end;return t end
 c.save=function(self)
  if not self.state.catalog.members.a then snapshot=copy(self.state);error('simulated process exit')end;return true
 end
 c:catalogRefresh(true);assert(not pcall(drain));assert(snapshot)
 local resumed,_,finish=F.new(c.settings,p,snapshot);resumed:catalogRefresh(true);finish();H.eq(#resumed:cachedList('home'),0);assert(not resumed.state.catalog.members.book)
end)
H.test('unrelated account file names are discarded before worker IPC',function()
 local p=provider({home={}});local c,_,drain,jobs=F.new(nil,p);c:indexHome();drain()
 p.changes=function()return{changes={{file_id='unrelated',entry={id='unrelated',name='unrelated-private-name.pdf',parent_id='outside'}}},new_start_token='filtered'}end
 c:catalogRefresh(true);local job=table.remove(jobs,1);local result=assert(job.run(p));H.eq(#result.changes,0);job.done(result);assert(not c.state.docs.unrelated)
end)
H.test('a home moved to another drive captures a new scoped checkpoint before relisting',function()
 local p=provider({home={}});local c,_,drain=F.new(nil,p);c:indexHome();drain()
 local changed=false;local n=0
 p.changes=function(_,_,scope)
  n=n+1
  if not changed then changed=true;local home=folder('home');home.drive_id='new-drive';return{changes={{file_id='home',entry=home}},new_start_token='old-feed-end'}end
  H.eq(scope.drive_id,'new-drive');return{changes={},new_start_token='new-feed-end'}
 end
 p.stat=function()local home=folder('home');home.drive_id='new-drive';return home end
 p.getStartToken=function(_,scope)H.eq(scope.drive_id,'new-drive');return 'new-feed-start'end
 c:catalogRefresh(true);drain();H.eq(c.state.catalog.scope.drive_id,'new-drive');H.eq(c.state.catalog.token,'new-feed-end')
end)
H.test('a rejected change checkpoint rebuilds once instead of retrying it forever',function()
 local p=provider({home={}});local c,_,drain=F.new(nil,p);c:indexHome();drain();local attempts=0
 p.changes=function()attempts=attempts+1;if attempts==1 then return nil,{code='api',status=410}end;return{changes={},new_start_token='recovered'}end
 c:catalogRefresh(true);drain();H.eq(c.state.catalog.token,'recovered');H.eq(attempts,2)
end)
H.test('optional folder metadata is scheduled only after the recursive catalog catches up',function()
 local p=provider({home={folder('title','home')},title={{id='cover',name='cover.jpg',parent_id='title'}}})
 local c,_,drain=F.new(nil,p);local folders={}
 c.metadata=function(self,entries)assert(not self.index_job and self.state.catalog.phase=='ready');for _,e in ipairs(entries)do folders[e.parent_id]=true end end
 c:indexHome();drain();assert(folders.home and folders.title)
end)
H.test('closed catalog does not start automatic refresh but explicit reindex remains possible',function()
 local p=provider({home={}});local c,_,drain,jobs=F.new(nil,p);c.catalog_visible=false
 c:catalogRefresh();H.eq(#jobs,0);c:reindexHome();drain();H.eq(c.state.catalog.phase,'ready')
end)
