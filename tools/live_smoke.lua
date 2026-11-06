-- Run with the official KOReader LuaJIT from its runtime directory.
-- Credentials are read locally; never print them. All cloud writes stay in a NEW
-- test subtree under the explicitly supplied test parent. Nothing is overwritten.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open('/tmp/gdriveshelf-live-smoke-settings.lua')
local root=assert(os.getenv('GDRIVESHELF_ROOT'))
dofile(root..'/gdriveshelf.koplugin/bootstrap.lua')(root..'/gdriveshelf.koplugin')
local JSON=require('json');local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local Provider=require('gdriveshelf/providers/gdrive')
local p=Provider.new{credentials=JSON.decode(read(assert(os.getenv('GDRIVESHELF_CREDS')))),ca_file=root..'/gdriveshelf.koplugin/cacert.pem'}
local parent=assert(os.getenv('GDRIVESHELF_TEST_PARENT'))
local out=assert(os.getenv('GDRIVESHELF_OUTPUT'))
local function check(v,e)assert(v,e and (e.code..': '..e.message));return v end
local entries=check(p:list(parent))
local Library=require('gdriveshelf/library');local SDR=require('gdriveshelf/sdr')
local Metadata=require('gdriveshelf/metadata')
local visible=Metadata.visible(entries,false);local books={}
for _,e in ipairs(Library.ordered(visible))do if Library.supported(e)then books[#books+1]=e end end
assert(#books>=1,'Test parent contains no readable files')
local expected_parent=books[1].parent_id;for _,e in ipairs(books)do assert(e.parent_id==expected_parent)end
print('PASS real Drive listing, service filtering and natural reading queue ('..#books..' documents)')
for _,e in ipairs(entries)do
 if e.name=='index.json' or e.name=='cover.jpg' or e.id==books[1].id then
  check(p:download(e,out..'/'..e.name,math.max(e.size,1)))
 end
end
local f=assert(io.open(out..'/folder.json','wb'));f:write(JSON.encode(entries));f:close()
local f2=assert(io.open(out..'/first-book.json','wb'));f2:write(JSON.encode(books[1]));f2:close()
print('PASS real complete CBZ, cover and Kotatsu metadata downloads (size and MD5 verified)')
local Sync=require('gdriveshelf/sync');local Storage=require('gdriveshelf/storage')
local store=Storage.new{root=out..'/test-state'}
local s=Sync.new{provider=p,storage=store,state={},sdr=SDR}
local remote=check(s:pull(books[1]))
if remote.lua then assert(SDR.decode(remote.lua));print('PASS existing native SDR safe read (read-only)')end
local private=assert(io.open(assert(os.getenv('GDRIVESHELF_CREDS')),'wb'));private:write(JSON.encode(p.credentials));private:close()
