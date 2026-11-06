-- Native, offline-only setup/import regression. Use a dedicated KO_HOME.
require('setupkoenv')
local source=assert(os.getenv('GDRIVESHELF_ROOT'))
local lang=os.getenv('GDRIVESHELF_LANGUAGE')or 'ru'
G_defaults=require('luadefaults'):open()
local Settings=require('luasettings');local DS=require('datastorage')
G_reader_settings=Settings:open(DS:getDataDir()..'/settings.reader.lua')
G_reader_settings:saveSetting('language',lang)
require('gettext').changeLang(lang)
local Device=require('device');require('document/canvascontext'):init(Device);require('ui/bidi').setup(lang)
local UI=require('ui/uimanager');require('ui/widget/menu').is_enable_shortcut=false
local Storage=dofile(source..'/gdriveshelf.koplugin/storage.lua')
local fs=Storage.new{root=DS:getDataDir()..'/setup-fixtures'}
assert(fs:mkdir(DS:getSettingsDir()))
assert(fs:mkdir(fs.root..'/Download'))
local path=fs.root..'/Download/gdriveshelf-credentials.json'
assert(fs:writeJSON(path,{client_id='demo-client',refresh_token='demo-refresh',access_token='demo-access',scope='https://www.googleapis.com/auth/drive'}))
assert(fs:writeJSON(fs.root..'/Download/client.json',{installed={client_id='demo-client'}}))
G_reader_settings:saveSetting('home_dir',fs.root)
local settings=Settings:open(DS:getSettingsDir()..'/gdriveshelf.lua')
settings:delSetting('import_dir')
settings:saveSetting('offline',true);settings:saveSetting('cache_dir',DS:getDataDir()..'/cache');settings:flush()
local Plugin=dofile(source..'/gdriveshelf.koplugin/main.lua')
local p=Plugin:new{ui={menu={registerToMainMenu=function()end},folder_shortcuts={hasFolderShortcut=function()return false end,getShortcutFullName=function()end}}}
-- Repeated invocations must test the unconnected state without deleting credentials.
p.core.credentials={}
p:showLibrary();assert(p.connection_menu,'Initial setup not shown')
local chooser=p:pickCredentials();assert(chooser.path==fs.root,'Picker did not use KOReader home')
chooser:changeToPath(fs.root..'/Download')
local selected
for _,item in ipairs(chooser.item_table)do if item.text=='gdriveshelf-credentials.json'then selected=item end end
assert(selected,'Native chooser hid JSON')
local ok,e=p:importCredentials(fs.root..'/Download/client.json');assert(ok==false and e,'Wrong JSON must be rejected')
-- The real selection callback imports atomically and enters the library.
chooser:onFileSelect(selected)
assert(p:hasCredentials(),'Selected JSON was not imported')
assert(not p.connection_menu,'Setup was not dismissed')
assert(p.folder_menu,'Library did not open after import')
assert(require('ffi/util').realpath(p.settings.import_dir)==require('ffi/util').realpath(fs.root..'/Download'),'Import directory was not saved')
assert(#p.core.jobs.queue==0 and not p.core.jobs.active,'Offline setup made a network request')
assert(fs.lfs.attributes(DS:getSettingsDir()..'/gdriveshelf-credentials.json','permissions')=='rw-------','Imported credentials are not private')
print('PASS native setup, JSON chooser navigation/selection, wrong-client rejection, private import and library transition; no network')
UI:quit()
