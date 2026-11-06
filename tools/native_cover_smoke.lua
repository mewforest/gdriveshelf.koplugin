-- Offline, self-authored fixtures in an isolated KO_HOME. Every extraction runs
-- in a fresh child; no user books, Google credentials, or Drive API are used.
require('setupkoenv')
local source=assert(os.getenv('GDRIVESHELF_ROOT'))
local output=assert(os.getenv('GDRIVESHELF_OUTPUT'))
G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(output..'/reader.lua')
local Device=require('device');require('document/canvascontext'):init(Device);require('ui/bidi').setup('en_US')
dofile(source..'/gdriveshelf.koplugin/bootstrap.lua')(source..'/gdriveshelf.koplugin')
local Covers=dofile(source..'/gdriveshelf.koplugin/localcovers.lua')
local Storage=require('gdriveshelf/storage');local fs=Storage.new{root=output}
local sha=require('ffi/sha2');local NativeSDR=require('docsettings')
local Registry=require('document/documentregistry')
local utility=require('ffi/util');local socket=require('socket')
local png=assert(fs:read(source..'/build/ux/fixtures/first.png',8*1048576))
local epub=output..'/covered.epub'
local writer=require('ffi/archiver').Writer:new();assert(writer:open(epub,'zip'))
for _,entry in ipairs{
 {'mimetype','application/epub+zip'},
 {'META-INF/container.xml','<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'},
 {'content.opf','<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Local cover fixture</dc:title><dc:identifier id="id">gdriveshelf-local-cover-fixture</dc:identifier><dc:language>en</dc:language><meta name="cover" content="cover"/></metadata><manifest><item id="cover" href="cover.png" media-type="image/png"/><item id="text" href="text.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="text"/></spine><guide><reference type="cover" title="Cover" href="text.xhtml"/></guide></package>'},
 {'text.xhtml','<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>Cover fixture</title></head><body><img src="cover.png" alt="Cover"/><p>Self-authored local cover smoke fixture.</p></body></html>'},
 {'cover.png',png},
}do assert(writer:addFileFromMemory(entry[1],entry[2]))end
writer:close();assert(fs:exists(epub))
local rows={};local sequence=0
local function snapshot(dir)
 local result={}
 local function walk(path)
  for name in fs.lfs.dir(path)do if name~='.'and name~='..'then
   local p=path..'/'..name;local a=fs.lfs.attributes(p)
   if a.mode=='directory'then walk(p)else result[p]={hash=sha.sha256(assert(fs:read(p))),size=a.size,mtime=a.modification}end
  end end
 end
 walk(dir);return require('gdriveshelf/sdr').encode(result)
end
local function worker(entry,cached,destination)
 sequence=sequence+1;local result_path=output..'/worker-'..sequence..'.json'
 local pid=assert(utility.runInSubProcess(function()
  local attempts=0
  for _,key in ipairs{'open','hasSidecarFile','findCustomCoverFile','getSidecarDir','flush','updateLocation'}do
   NativeSDR[key]=function()attempts=attempts+1;error('Cover extraction accessed native SDR')end
  end
  local result,err=Covers.build(entry,cached,destination)
  assert(fs:writeJSON(result_path,{result=result,error=err,sidecar_accesses=attempts}))
 end,false))
 local deadline=socket.gettime()+20
 while not utility.isSubProcessDone(pid)do
  if socket.gettime()>deadline then utility.terminateSubProcess(pid);error('Native cover worker exceeded deadline')end
  socket.sleep(.02)
 end
 local result=assert(fs:readJSON(result_path));assert(result.sidecar_accesses==0,'Native sidecar API was called')
 return result
end
for _,format in ipairs{'epub','pdf','cbz'}do
 for _,state in ipairs{'missing','empty','corrupt','valid'}do
  local dir=output..'/'..format..'-'..state;fs:mkdir(dir)
  local path=dir..'/document.'..format
  local original=format=='epub'and epub or source..'/build/ux/fixtures/'..(format=='pdf'and 'Example.pdf'or 'Store.cbz')
  assert(fs:write(path,assert(fs:read(original,32*1048576))))
  local sidecar=dir..'/document.sdr';fs:mkdir(sidecar)
  if state~='missing'then
   local text=state=='empty'and ''or state=='corrupt'and 'return {unfinished='or 'return {last_page=7,percent_finished=0.42,provider="mupdf"}'
   assert(fs:write(sidecar..'/metadata.'..format..'.lua',text))
  end
  assert(fs:write(sidecar..'/metadata.'..format..'.lua.old','return {last_page=5}'))
  assert(fs:write(sidecar..'/metadata.'..format..'.lua.new','backup sentinel'))
  local before=snapshot(sidecar);local source_hash=sha.sha256(assert(fs:read(path)))
  local result=worker({name='document.'..format,size=fs:size(path)},{path=path},dir..'/cover.png')
  assert(result.result,result.error and result.error.message)
  assert(snapshot(sidecar)==before,'Cover extraction changed SDR bytes, timestamps or backups')
  assert(sha.sha256(assert(fs:read(path)))==source_hash,'Source document was modified')
  assert(not Registry.registry[path],'Child cover leaked a document into parent registry')
  local w,h=require('gdriveshelf/thumbnails').dimensions(assert(fs:read(dir..'/cover.png')))
  assert(w and w<=320 and h<=440);rows[#rows+1]={format=format,sidecar=state,width=w,height=h,result='pass'}
  print('PASS fresh '..format..' worker, '..state..' SDR untouched, cover '..w..'x'..h)
 end
end
local active_path=output..'/pdf-valid/document.pdf'
local provider=assert(Registry:getProviders(active_path))[1].provider
local original_conversion=provider.convertKoptToReflowableFontSize
local scoped=provider:extend{convertKoptToReflowableFontSize=function(self,size)return original_conversion(self,size or 1)end}
local document=assert(Registry:openDocument(active_path,scoped))
local references=Registry:getReferenceCount(active_path)
local skipped=worker({name='document.pdf'},{path=active_path},output..'/active-cover.png')
assert(not skipped.result and skipped.error.code=='active')
assert(document.is_open and Registry:getReferenceCount(active_path)==references,'Inherited active document was reused or closed')
assert(provider.convertKoptToReflowableFontSize==original_conversion,'Native provider class was globally patched')
document:close();assert(not Registry.registry[active_path])
local cb7=worker({name='unsupported.cb7'},{path=active_path},output..'/cb7-cover.png')
assert(not cb7.result and cb7.error.code=='preview')
-- Native image import, real JSON, durable outbox and cache eviction roundtrip.
local metadatafs=Storage.new{root=output..'/metadata-roundtrip'}
local Core=require('gdriveshelf/core')
local function offlineCore()
 return Core.new{storage=metadatafs,jobs={setOffline=function()end},settings={offline=true},credentials={},provider_factory=function()error('Offline metadata created a network provider')end}
end
local core=offlineCore();core.state.folders.folder={id='folder',name='Original title',is_folder=true}
core.state.history.keep={id='book',last_opened=123};core.state.sync.pending.keep={text='return {last_page=7}',parent_id='folder'};assert(core:save())
local progress_before=require('gdriveshelf/sdr').encode{history=core.state.history,pending=core.state.sync.pending}
local sidecars_before=snapshot(output..'/pdf-valid/document.sdr')
local saved
assert(core:saveFolderMetadata({id='folder'},{title='Offline title',description='Description'},source..'/build/ux/fixtures/first.png',function(result)assert(result and result.queued);saved=true end))
assert(saved);local info=core:titleInfo('folder');assert(info.title=='Offline title'and info.description=='Description'and metadatafs:exists(info.cover_path))
local cover=assert(metadatafs:read(info.cover_path));assert(info.cover_path:match('/gdriveshelf%-cover%-'..sha.sha256(cover)..'%.png$'))
assert(metadatafs.lfs.attributes(info.cover_path,'permissions')=='rw-------','Override image permissions are not private')
assert(metadatafs:write(metadatafs.root..'/evictable','temporary metadata'))
core.state.entries.evictable={id='evictable',path=metadatafs.root..'/evictable',ready=true,pool='meta',size=18}
core:clearPool('meta');assert(metadatafs:exists(info.cover_path),'Metadata eviction removed the user cover')
local restored=offlineCore();assert(restored:titleInfo('folder').title=='Offline title')
assert(require('gdriveshelf/sdr').encode{history=restored.state.history,pending=restored.state.sync.pending}==progress_before,'Manual metadata changed reading history or pending progress')
local pending=assert(metadatafs:readJSON(metadatafs.root..'/metadata-outbox.json'));assert(pending.folders.folder.record.values.title=='Offline title')
assert(snapshot(output..'/pdf-valid/document.sdr')==sidecars_before,'Editing manual metadata changed native SDR')
assert(fs:writeJSON(output..'/results.json',{tests=rows,active_document='preserved',provider_class='unchanged',cb7='skipped',offline_metadata='restored',immutable_cover='private and survives metadata eviction',native_sidecar_accesses=0,network_requests=0}))
print('PASS inherited active document preserved, original provider class unchanged, CB7 skipped; zero SDR access and zero network')
print('PASS real JSON and native image import, private immutable cover, durable offline edit/outbox across cache eviction and restart')
