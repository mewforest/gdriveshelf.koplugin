local H=require('tests/helper')
local Manage=require('gdriveshelf/manage')
local function fixture()
 local entries={
  a={id='a',path='/Books/A/1.cbz',pool='auto',parent_id='alpha',ready=true,size=99},
  b={id='b',path='/Books/A/2.cbz',pool='offline',parent_id='alpha',ready=true,size=99},
  c={id='c',path='/Books/B/3.cbz',pool='offline',parent_id='beta',ready=true,size=99},
  meta={id='meta',path='/meta/value',pool='meta',ready=true},
 }
 local sizes={a=200,b=400,c=20,meta=1}
 local protected={}
 local core={state={entries=entries,folders={alpha={id='alpha',name='Alpha',parent_id='home'},beta={id='beta',name='Beta'}},downloads={a={pool='offline'}}},storage={
  bookRegistry=function()return {}end,
  managedPath=function(_,entry)return true,{mode='file',size=sizes[entry.id]}end},
  protected=function()return protected end,evict=function(self,ids)
   for _,id in ipairs(ids)do self.state.entries[id]=nil end
  end,save=function()return true end,emit=function()end}
 return core,protected
end
H.test('download inventory groups both archive pools by folder and actual on-disk bytes',function()
 local core=fixture()
 local inventory=Manage.inventory(core)
 H.eq(#inventory,2);H.eq(inventory[1].id,'alpha');H.eq(inventory[1].size,600)
 H.eq(inventory[1].entries[1].id,'b')
 assert(Manage.inBranch(core.state.folders,'alpha','home'))
 assert(not Manage.inBranch(core.state.folders,'beta','home'))
end)
H.test('selective deletion rechecks protection and identity and preserves queued work',function()
 local core,protected=fixture()
 local targets=Manage.inventory(core)[1].entries
 local pending={};local result
 assert(Manage.remove(core,targets,function(fn)pending[#pending+1]=fn end,function(stats)result=stats end))
 protected.a=true
 core.state.entries.b.path='/Books/A/new.cbz'
 pending[1]()
 H.eq(result.removed,0);H.eq(result.skipped,2);assert(core.state.downloads.a)
 protected.a=nil
 assert(Manage.remove(core,{{id='a',path='/Books/A/1.cbz',pool='auto',size=200}},function(fn)fn()end,function(stats)result=stats end))
 H.eq(result.removed,1);assert(core.state.downloads.a);assert(core.state.entries.meta)
end)
H.test('account switching restores distinct home/index preferences and adopts legacy settings',function()
 local s={home='legacy',books_dir='/legacy-books',index_enabled=true,index_recursive_confirmed=true}
 Manage.accountHome(s,'one');H.eq(s.home,'legacy')
 Manage.accountHome(s,'two');H.eq(s.home,'root');H.eq(s.index_enabled,nil);H.eq(s.books_dir,nil)
 s.home='two-home';s.books_dir='/second-books'
 Manage.accountHome(s,'one');H.eq(s.home,'legacy');H.eq(s.books_dir,'/legacy-books');assert(s.index_recursive_confirmed)
 Manage.accountHome(s,'two');H.eq(s.home,'two-home');H.eq(s.books_dir,'/second-books')
end)
H.test('memory stats render on the existing menu after asynchronous storage work',function()
 local prototype={}
 local format=function(n)return tostring(n or '?')end
 Manage.install(prototype,{root='/plugin',bytes=format,binaryBytes=format,message=function()end,problem=function()end})
 local pending={}
 local core=fixture()
 core.storage.books_dir='/Books'
 core.jobs={enqueue=function(_,key,_,done,_,_,_,local_task)
  assert(local_task)
  H.eq(key,'storage-stats');pending[#pending+1]=done
  return true
 end}
 local headers,menus,updates=0,0,0
 local function menu(_,_,rows,options)
  menus=menus+1
  return {item_table=rows,close=options.close}
 end
 local p=setmetatable({core=core,settings={},menu=menu,
  whenVisible=function()return true end,replaceMenu=function(self,widget,rows)
   assert(widget==self.memory_menu);widget.item_table=rows;updates=updates+1
  end},{__index=prototype})
 package.loaded.device={screen={getWidth=function()return 600 end}}
 package.loaded['gdriveshelf/browser']={header=function(options)
  headers=headers+1;H.eq(#options.bars,4)
  return {setBars=function(_,bars)H.eq(#bars,4)end,setSubTitle=function(_,value)H.eq(value,'Free space: 80')end}
 end}
 local memory=p:showMemory()
 assert(p:showMemory()==memory)
 H.eq(menus,1);H.eq(headers,1);H.eq(updates,0)
 local data={disk={free=80,total=100},usage={auto=1,offline=2,meta=3},progress=4,index=5}
 pending[1](data)
 H.eq(updates,1);H.eq(memory.item_table[3].text,'Choose downloads to remove');H.eq(memory.item_table[6].mandatory,'2')
 memory.refreshMemory();pending[2](data)
 H.eq(updates,2);H.eq(menus,1);H.eq(headers,1)
end)
