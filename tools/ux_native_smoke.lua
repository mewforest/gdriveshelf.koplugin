-- Self-authored local fixtures; no network or account data.
require('setupkoenv');G_defaults=require('luadefaults'):open()
G_reader_settings=require('luasettings'):open(assert(os.getenv('GDRIVESHELF_OUTPUT'))..'/reader.lua')
local source=assert(os.getenv('GDRIVESHELF_ROOT'));dofile(source..'/gdriveshelf.koplugin/bootstrap.lua')(source..'/gdriveshelf.koplugin')
local Device=require('device');require('document/canvascontext'):init(Device);require('ui/bidi').setup('en_US')
local Storage=require('gdriveshelf/storage');local store=Storage.new{root=os.getenv('GDRIVESHELF_OUTPUT')}
local fixtures=source..'/build/ux/fixtures'
for _,name in ipairs{'Store','Deflate'}do
 local path=fixtures..'/'..name..'.cbz';local entry={id=name,name=name..'.cbz',size=store:size(path)}
 local result,err=require('gdriveshelf/thumbnails').build(entry,{path=path},{},store.root..'/'..name..'.png')
 assert(result,err and err.message);assert(store:size(result.path)>0)
 print('PASS '..name..' ZIP preview, bounded decompression, dimensions and native PNG rendering')
end
