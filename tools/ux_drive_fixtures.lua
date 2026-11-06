-- Upload self-authored book/archive fixtures ONLY into the existing disposable test subtree.
require('setupkoenv');G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(assert(os.getenv('GDRIVESHELF_OUTPUT'))..'/host.reader.lua')
local root=assert(os.getenv('GDRIVESHELF_ROOT'));dofile(root..'/gdriveshelf.koplugin/bootstrap.lua')(root..'/gdriveshelf.koplugin')
local store=require('gdriveshelf/storage').new{root=os.getenv('GDRIVESHELF_OUTPUT')}
local credentials=assert(os.getenv('GDRIVESHELF_CREDS'));local parent=assert(os.getenv('GDRIVESHELF_TEST_PARENT'))
local provider=require('gdriveshelf/providers/gdrive').new{credentials=assert(store:readJSON(credentials))}
local function check(value,e)assert(value,e and e.message);return value end
local plan=assert(store:readJSON(store.root..'/plan.json'));assert(plan.source_parent==parent)
assert(check(provider:stat(plan.root_id)).parent_id==parent)
if os.getenv('GDRIVESHELF_RENAME')=='1'then
 for _,entry in ipairs(plan.documents)do
  assert(check(provider:stat(entry.id)).parent_id==plan.novels_id)
  local name=entry.name:match('%.epub$')and 'Example novel.epub'or 'Example guide.pdf'
  local body=store.json.encode({name=name})
  check(provider:_request{url='https://www.googleapis.com/drive/v3/files/'..entry.id,method='PATCH',body=body,headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}})
  local fresh=check(provider:stat(entry.id));for k,v in pairs(fresh)do entry[k]=v end
 end
 assert(store:writeJSON(store.root..'/plan.json',plan));assert(store:writeJSON(credentials,provider.credentials));print('PASS book fixture names are unambiguous');return
end
plan.novels_id=check(provider:mkdir(plan.root_id,'Example books')).id
plan.previews_id=check(provider:mkdir(plan.root_id,'Archive previews')).id
assert(store:writeJSON(store.root..'/plan.json',plan))
plan.documents={};plan.preview_files={}
for _,name in ipairs{'Example.epub','Example.pdf'}do plan.documents[#plan.documents+1]=check(provider:upload(plan.novels_id,name:match('%.epub$')and 'Example novel.epub'or 'Example guide.pdf',root..'/build/ux/fixtures/'..name));assert(store:writeJSON(store.root..'/plan.json',plan))end
for _,name in ipairs{'Store.cbz','Deflate.cbz'}do plan.preview_files[#plan.preview_files+1]=check(provider:upload(plan.previews_id,name,root..'/build/ux/fixtures/'..name));assert(store:writeJSON(store.root..'/plan.json',plan))end
assert(store:writeJSON(credentials,provider.credentials))
print('PASS self-authored EPUB/PDF and Store/Deflate archives uploaded only inside isolated test subtree')
