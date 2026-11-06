-- Host-side opt-in fixture setup for an isolated Android Drive regression.
-- Creates/copies only inside a fresh child of the explicitly authorized parent.
require('setupkoenv')
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(assert(os.getenv('GDRIVESHELF_OUTPUT'))..'/host.reader.lua')
local root=assert(os.getenv('GDRIVESHELF_ROOT'))
dofile(root..'/gdriveshelf.koplugin/bootstrap.lua')(root..'/gdriveshelf.koplugin')
local Storage=require('gdriveshelf/storage');local Provider=require('gdriveshelf/providers/gdrive')
local store=Storage.new{root=assert(os.getenv('GDRIVESHELF_OUTPUT'))}
local credpath=assert(os.getenv('GDRIVESHELF_CREDS'))
local parent=assert(os.getenv('GDRIVESHELF_TEST_PARENT'))
local provider=Provider.new{credentials=assert(store:readJSON(credpath)),ca_file=root..'/gdriveshelf.koplugin/cacert.pem'}
local function check(value,e)assert(value,e and e.code..': '..e.message);return value end
local planpath=store.root..'/plan.json'
if os.getenv('GDRIVESHELF_EXTEND')=='1'then
 local plan=assert(store:readJSON(planpath));assert(plan.source_parent==parent)
 assert(check(provider:stat(plan.root_id)).parent_id==parent)
 local nested=check(provider:mkdir(plan.root_id,'Nested title'))
 local source=check(provider:stat(plan.books[3].id));assert(source.parent_id==plan.root_id)
 local body=store.json.encode({name=source.name,parents={nested.id}})
 local r=check(provider:_request{url='https://www.googleapis.com/drive/v3/files/'..source.id..'/copy',method='POST',body=body,headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}})
 plan.nested_id=nested.id;plan.nested_book=check(provider:stat(check(provider:_decode(r.body)).id))
 assert(store:writeJSON(planpath,plan));assert(store:writeJSON(credpath,provider.credentials));print('PASS nested fixture added inside the isolated test subtree');return
end
if os.getenv('GDRIVESHELF_CLEANUP')=='1'then
 local plan=assert(store:readJSON(planpath));assert(plan.source_parent==parent)
 local entry=check(provider:stat(plan.root_id));assert(entry.parent_id==parent)
 local body=store.json.encode({trashed=true})
 check(provider:_request{url='https://www.googleapis.com/drive/v3/files/'..entry.id,method='PATCH',body=body,headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}})
 assert(store:writeJSON(credpath,provider.credentials));print('PASS isolated Android test subtree moved to trash');return
end
local folder=check(provider:stat(parent));assert(folder.is_folder)
local entries=check(provider:list(parent));local books,metadata={},{}
for _,e in ipairs(entries)do
 if not e.is_folder and e.name:lower():match('%.cbz$')then books[#books+1]=e
 elseif not e.is_folder and (e.name=='cover.jpg'or e.name=='index.json')then metadata[#metadata+1]=e end
end
books=require('gdriveshelf/library').ordered(books,'natural');assert(#books>=3)
local child=check(provider:mkdir(parent,'.gdriveshelf-avd-'..os.time()));assert(child.parent_id==parent)
local plan={root_id=child.id,source_parent=parent,books={},metadata={}}
assert(store:writeJSON(planpath,plan)) -- Retain a cleanup handle before any copies.
local function copy(entry)
 assert(entry.parent_id==parent and not entry.is_folder)
 local body=store.json.encode({name=entry.name,parents={child.id}})
 local response=check(provider:_request{url='https://www.googleapis.com/drive/v3/files/'..entry.id..'/copy',method='POST',body=body,headers={['Content-Type']='application/json',['Content-Length']=tostring(#body)}})
 local copied=check(provider:_decode(response.body));copied=check(provider:stat(copied.id));assert(copied.parent_id==child.id)
 return copied
end
for i=1,3 do plan.books[i]=copy(books[i]);assert(store:writeJSON(planpath,plan))end
for _,e in ipairs(metadata)do plan.metadata[#plan.metadata+1]=copy(e);assert(store:writeJSON(planpath,plan))end
assert(store:writeJSON(credpath,provider.credentials))
print('PASS prepared isolated Android test subtree with three chapters and metadata; original progress untouched')
