-- Add a self-authored embedded-cover EPUB only inside the existing disposable
-- test subtree. Supply covered.epub in GDRIVESHELF_OUTPUT; never overwrite books.
require('setupkoenv');G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(assert(os.getenv('GDRIVESHELF_OUTPUT'))..'/host.reader.lua')
local source=assert(os.getenv('GDRIVESHELF_ROOT'))
dofile(source..'/gdriveshelf.koplugin/bootstrap.lua')(source..'/gdriveshelf.koplugin')
local store=require('gdriveshelf/storage').new{root=assert(os.getenv('GDRIVESHELF_OUTPUT'))}
local credentials=assert(os.getenv('GDRIVESHELF_CREDS'));local parent=assert(os.getenv('GDRIVESHELF_TEST_PARENT'))
local p=require('gdriveshelf/providers/gdrive').new{credentials=assert(store:readJSON(credentials))}
local function check(value,e)assert(value,e and e.code);return value end
local plan=assert(store:readJSON(store.root..'/plan.json'));assert(plan.source_parent==parent)
assert(check(p:stat(plan.root_id)).parent_id==parent);assert(check(p:stat(plan.novels_id)).parent_id==plan.root_id)
plan.documents[1]=check(p:upload(plan.novels_id,'Example covered.epub',store.root..'/covered.epub'))
assert(store:writeJSON(store.root..'/plan.json',plan));assert(store:writeJSON(credentials,p.credentials))
print('PASS embedded-cover self-authored EPUB added only inside disposable test subtree')
