-- Visual/integration harness; uses only local copies of the provided manga.
-- Run from an official macOS KOReader directory. KO_HOME should point at a
-- dedicated disposable test directory, never an ordinary reader profile.
require('setupkoenv')
local source=assert(os.getenv('GDRIVESHELF_ROOT'))
local samples=assert(os.getenv('GDRIVESHELF_SAMPLES'))
local output=source..'/docs/screenshots/'
local language=os.getenv('GDRIVESHELF_LANGUAGE')or 'ru'
local suffix=language:match('^en')and '-en'or ''
local LuaSettings=require('luasettings');local DataStorage=require('datastorage')
G_defaults=require('luadefaults'):open()
G_reader_settings=LuaSettings:open(DataStorage:getDataDir()..'/settings.reader.lua')
G_reader_settings:saveSetting('language',language);G_reader_settings:saveSetting('color_rendering',false)
G_reader_settings:saveSetting('document_metadata_folder','doc')
G_reader_settings:saveSetting('home_dir',samples)
require('gettext').changeLang(language)
local Device=require('device');require('document/canvascontext'):init(Device);require('ui/bidi').setup(language)
local UI=require('ui/uimanager');local json=require('json')
require('ui/widget/menu').is_enable_shortcut=false
local function read(path)local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
local lfs=require('libs/libkoreader-lfs');lfs.mkdir(DataStorage:getSettingsDir())
local settings=LuaSettings:open(DataStorage:getSettingsDir()..'/gdriveshelf.lua')
settings.data={offline=true,sync_enabled=false,prefetch=1,threshold=75,auto_mib=3072,meta_mib=256,home='demo-title',cache_dir=DataStorage:getDataDir()..'/cache-shelf'};settings:flush()
local Plugin=dofile(source..'/gdriveshelf.koplugin/main.lua')
local shelf=Plugin:new{ui={menu={registerToMainMenu=function()end}}}
local nativeMenu=shelf.menu
shelf.menu=function(self,...)local menu=nativeMenu(self,...);self.preview_menu=menu;return menu end
local c=shelf.core;local entries=json.decode(read(samples..'/folder.json'))
-- Replace provider identities with local demo IDs: no account or Drive IDs in screenshots/state.
for i,e in ipairs(entries)do e.id='demo-'..i;e.parent_id='demo-title' end
c.state.folders['demo-title']={id='demo-title',parent_id='demo-library',name='Лунная линия',is_folder=true}
c.state.folders['demo-library']={id='demo-library',name=language=='ru'and 'Библиотека'or 'Library',is_folder=true}
c:rememberList('demo-title',entries)
local function copy(from,to)
 local a=assert(io.open(from,'rb'));local b=assert(io.open(to,'wb'))
 while true do local chunk=a:read(65536);if not chunk then break end;assert(b:write(chunk))end;a:close();b:close()
end
local first
for _,e in ipairs(entries)do
 if e.name=='cover.jpg'or e.name=='index.json'or e.name:match('^0_.*%.cbz$')then
  local pool=e.name:match('%.cbz$')and 'offline'or'meta';local path=c.storage:filePath(e,pool)
  copy(samples..'/'..e.name,path)
  local cached={};for k,v in pairs(e)do cached[k]=v end
  cached.path=path;cached.pool=pool;cached.ready=true;cached.last_access=os.time()
  c.state.entries[e.id]=cached
  if pool=='offline'then first=e;c.state.summaries[e.id]={percent=1/38,page=1,status='reading'}end
 end
end
assert(first);c.state.last_document=first.id;c:save()
local titleFolders={c.state.folders['demo-title']}
for i=2,9 do
 local id='demo-folder-'..i;local folder={id=id,parent_id='demo-library',name=(language=='ru'and 'Пример папки 'or 'Example folder ')..i,is_folder=true}
 c.state.folders[id]=folder;titleFolders[#titleFolders+1]=folder
 if i==2 then c:rememberList(id,{})end
end
c:rememberList('demo-library',titleFolders)
local function closeAll()
 while #UI._window_stack>0 do UI:close(UI._window_stack[#UI._window_stack].widget)end
end
local function shot(name)
 UI:forceRePaint();assert(Device.screen:shot(output..name..suffix..'.png'));print('SCREENSHOT '..name..suffix)
end
shelf:showLibrary();shot('connect');closeAll()
-- Synthetic credentials only; the preview remains strictly offline.
c.credentials={client_id='demo-client',refresh_token='demo-refresh',access_token='demo-access'}
shelf:showFolder('demo-library');shot('titles');closeAll()
shelf.settings.folder_view='grid';shelf:showFolder('demo-library');shot('titles-grid');closeAll();shelf.settings.folder_view='list'
shelf:showLibrary();shot('library');closeAll()
shelf:showFolderActions('demo-title',true);shot('library-actions');closeAll()
shelf:showFileSort();shot('file-sorting');closeAll()
shelf:showTitleSort();shelf.preview_menu.item_table[3].callback();shot('title-sorting')
assert(LuaSettings:open(DataStorage:getSettingsDir()..'/gdriveshelf.lua'):readSetting('title_sort')=='read','Title sorting did not persist')
closeAll()
shelf:showMemory();shot('storage');closeAll()
shelf:showSettings();shot('settings');closeAll()
shelf:showSettingsCategory('catalog');shot('settings-catalog');closeAll()
shelf:showSettingsCategory('reading');shot('settings-reading');closeAll()
shelf:showSettingsCategory('experimental');shot('settings-experimental');closeAll()
shelf:showSettings();
local settingsMenu=shelf.preview_menu
if settingsMenu.page_num>1 then settingsMenu:onGotoPage(2);shot('settings-more')end
closeAll()
shelf:showAbout();shot('about');closeAll()
shelf:showOffline();shot('offline');closeAll()
shelf:showInfo('demo-title');shot('manga-info');closeAll()
local cover=c:titleInfo('demo-title').cover_path
assert(cover);UI:show(require('ui/widget/imageviewer'):new{file=cover,title_text='Лунная линия',with_title_bar=true});shot('cover');closeAll()
print('PASS all principal GDriveShelf widgets rendered from real local manga fixtures')
-- Open through the same tap handler used in the plugin, then turn a native page.
shelf:openLastDocument()
UI:scheduleIn(7,function()
 local Reader=require('apps/reader/readerui');local reader=Reader.instance
 assert(reader and reader.document,'Native reader did not open')
 assert(reader.document:getPageCount()==38,'Unexpected CBZ page count')
 reader:handleEvent(require('ui/event'):new('GotoPage',2))
 UI:forceRePaint();assert(Device.screen:shot(output..'reading'..suffix..'.png'))
 print('PASS last document resumed through GDriveShelf; 38 pages, page navigation, rendering and persistent title sorting')
 reader:onClose();UI:quit()
end)
UI:run()
