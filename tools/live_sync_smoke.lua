-- Explicit opt-in integration test. Writes ONLY a newly created child of
-- GDRIVESHELF_TEST_PARENT, then moves that entire test child to Drive trash.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/gdriveshelf-live-sync-settings.lua')
local source=assert(os.getenv('GDRIVESHELF_ROOT'))
dofile(source..'/gdriveshelf.koplugin/bootstrap.lua')(source..'/gdriveshelf.koplugin')
local JSON=require('json');local function read(path)local f=assert(io.open(path,'rb'));local t=f:read('*a');f:close();return t end
local Provider=require('gdriveshelf/providers/gdrive');local SDR=require('gdriveshelf/sdr');local Sync=require('gdriveshelf/sync');local Storage=require('gdriveshelf/storage')
local parent=assert(os.getenv('GDRIVESHELF_TEST_PARENT'),'Explicit test parent is required')
local dir=assert(os.getenv('GDRIVESHELF_OUTPUT'))
local p=Provider.new{credentials=JSON.decode(read(assert(os.getenv('GDRIVESHELF_CREDS')))),ca_file=source..'/gdriveshelf.koplugin/cacert.pem'}
local function check(v,e)assert(v,e and (e.code..': '..e.message));return v end
local testroot
local ok,why=xpcall(function()
 testroot=check(p:mkdir(parent,'.gdriveshelf-smoke-'..os.time()))
 assert(testroot.parent_id==parent)
 local store=Storage.new{root=dir..'/sync-state'}
 assert(store:writeJSON(dir..'/test-artifact.json',{id=testroot.id,parent_id=parent,name=testroot.name}))
 local book=check(p:upload(testroot.id,'Smoke.cbz',dir..'/Smoke.cbz'))
 book=check(p:stat(book.id));assert(book.parent_id==testroot.id)
 local state={};local sync=Sync.new{provider=p,storage=store,state=state,sdr=SDR}
 local first={last_page=1,doc_pages=1,percent_finished=1,summary={status='complete'}}
 local pending=assert(sync:snapshot(book,first));local pushed=check(sync:push(book,pending));assert(pushed.action=='pushed')
 sync:commit(book,pending,pushed)
 local remote=check(sync:pull(book));assert(remote.data.last_page==1);print('ETag on native metadata GET:',remote.stamp.etag and 'present' or 'absent')
 local oldtag=remote.stamp.etag
 pending=assert(sync:snapshot(book,{last_page=0,doc_pages=1,percent_finished=0}))
 pushed=check(sync:push(book,pending));assert(pushed.action=='pushed');sync:commit(book,pending,pushed)
 remote=check(sync:pull(book));assert(remote.data.last_page==0)
 print('PASS real Drive native SDR create, pull, ETag-guarded update and roundtrip')
 local path=assert(store:writeTemp(assert(SDR.encode({last_page=99}))))
 local stale,err=p:upload(remote.folder.id,'metadata.cbz.lua',path,remote.metadata.id,oldtag)
 assert(not stale and err.code=='conflict','Stale ETag must reject overwrite')
 assert(check(sync:pull(book)).data.last_page==0)
 local external=assert(store:writeTemp(assert(SDR.encode({last_page=2}))))
 check(p:upload(remote.folder.id,'metadata.cbz.lua',external,remote.metadata.id,remote.stamp.etag))
 pending=assert(sync:snapshot(book,{last_page=3,doc_pages=1,percent_finished=0.5}))
 local conflict=check(sync:push(book,pending));assert(conflict.action=='conflict');sync:commit(book,pending,conflict)
 assert(state.pending[book.id] and state.conflicts[book.id]);assert(check(sync:pull(book)).data.last_page==2)
 print('PASS real stale-write rejection and both-side progress conflict without data loss')
end,debug.traceback)
if testroot then
 -- The only deletion is our own freshly created test subtree, recoverable in trash.
 local body=JSON.encode({trashed=true})
 local result,e=p:_request{url='https://www.googleapis.com/drive/v3/files/'..testroot.id..'?supportsAllDrives=true',method='PATCH',body=body,headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}}
 check(result,e);print('PASS isolated test subtree moved to trash; source manga files untouched')
end
local f=assert(io.open(assert(os.getenv('GDRIVESHELF_CREDS')),'wb'));f:write(JSON.encode(p.credentials));f:close()
assert(ok,why)
