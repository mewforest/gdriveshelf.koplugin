-- Authentic upstream AppStore + native KOReader UI/Archiver. The sole replaced
-- dependency is socket.http.request, serving synthetic GitHub responses/ZIPs.
-- Run install and restart phases with a new, isolated KO_HOME on external SSD.
require('setupkoenv')
local config=rawget(_G,'GDriveShelfAppStoreFixture')or{}
local source=assert(config.source or os.getenv('GDRIVESHELF_ROOT'))
local artifacts=assert(config.artifacts or os.getenv('GDRIVESHELF_APPSTORE_FIXTURES'))
local mode=config.mode or os.getenv('GDRIVESHELF_APPSTORE_MODE')or 'fresh'
local phase=config.phase or os.getenv('GDRIVESHELF_APPSTORE_PHASE')or 'install'
local route=config.route or os.getenv('GDRIVESHELF_APPSTORE_ROUTE')or 'release'
assert(mode=='fresh'or mode=='legacy');assert(phase=='install'or phase=='restart');assert(route=='release'or route=='source')
G_defaults=require('luadefaults'):open()
local DS=require('datastorage');local Settings=require('luasettings')
G_reader_settings=Settings:open(DS:getDataDir()..'/settings.reader.lua')
G_reader_settings:saveSetting('language','en_US');require('gettext').changeLang('en_US')
local Device=require('device')
if not config.embedded then require('document/canvascontext'):init(Device);require('ui/bidi').setup('en_US')end
local UI=require('ui/uimanager');local json=require('json');local sha=require('ffi/sha2')
local Storage=dofile(source..'/gdriveshelf.koplugin/storage.lua')
local fs=Storage.new{root=DS:getDataDir()}
local profile=fs.root;local plugins=profile..'/custom-plugins';fs:mkdir(plugins)
local installed=plugins..'/gdriveshelf.koplugin'
local cache=profile..'/gdriveshelf';local account=Storage.key('fixture-account')
local account_root=cache..'/drive-'..account;local books=profile..'/custom books'
local book=books..'/Saved title/01.pdf'
local settings_path=DS:getSettingsDir()..'/gdriveshelf.lua'
local credentials_path=DS:getSettingsDir()..'/gdriveshelf-credentials.json'
local index_path=account_root..'/index.json'
local manifest_path=profile..'/fixture-manifest.json'
local Archiver=require('ffi/archiver')
local repo={owner='fixture-owner',name='googledriveunofficial.koplugin',full_name='fixture-owner/googledriveunofficial.koplugin',id=987654,kind='plugin',default_branch='master',data={default_branch='master',owner={login='fixture-owner'}}}
local current='0.1.700';local final='0.1.701';local requests={}
local function archivePath(version)return artifacts..'/assets/gdriveshelf.koplugin-'..version..'.zip'end
local function rawMeta(version)
 local reader=Archiver.Reader:new();assert(reader:open(archivePath(version)))
 for entry in reader:iterate()do if entry.path=='gdriveshelf.koplugin/_meta.lua'then break end end
 local text=assert(reader:extractToMemory('gdriveshelf.koplugin/_meta.lua'));reader:close();return text
end
local function release(version)
 local name='gdriveshelf.koplugin-'..version..'.zip'
 return {tag_name='v'..version,name='Fixture '..version,draft=false,prerelease=false,published_at='2030-01-01T00:00:00Z',body='Synthetic native installer fixture',assets={{name=name,browser_download_url='https://github.com/fixture-owner/googledriveunofficial.koplugin/releases/download/v'..version..'/'..name}}}
end
-- Keep upstream Net, timeout restoration, sinks, GitHub client, archive detector,
-- collision guards, extraction, install records and version comparison intact.
require('socket.http').request=function(request)
 assert(type(request)=='table'and type(request.url)=='string','Unexpected HTTP transport call')
 local url=request.url;requests[#requests+1]=url
 local f=assert(io.open(profile..'/github-transport.log','ab'));f:write(url,'\n');f:close()
 local body,status
 if url:match('^https://api%.github%.com/repos/fixture%-owner/googledriveunofficial%.koplugin/releases/latest')then body=json.encode(release(current))
 elseif url:match('^https://api%.github%.com/repos/fixture%-owner/googledriveunofficial%.koplugin/releases[%?]?')then body=json.encode{release(current)}
 elseif url=='https://api.github.com/repos/fixture-owner/googledriveunofficial.koplugin/zipball'then body=assert(fs:read(artifacts..'/assets/source-0.1.701.zip',8*1048576))
 elseif url:match('^https://api%.github%.com/repos/fixture%-owner/googledriveunofficial%.koplugin[%?]?')then body=json.encode{id=repo.id,name=repo.name,full_name=repo.full_name,owner={login=repo.owner},default_branch='master',pushed_at='2030-01-01T00:00:00Z'}
 elseif url:match('^https://raw%.githubusercontent%.com/fixture%-owner/googledriveunofficial%.koplugin/[^/]+/gdriveshelf%.koplugin/_meta%.lua$')then body=rawMeta(current)
 elseif url:match('^https://github%.com/fixture%-owner/googledriveunofficial%.koplugin/releases/download/')then
  local version=url:match('/v([%d%.]+)/');assert(version=='0.1.700'or version=='0.1.701');body=assert(fs:read(archivePath(version),8*1048576))
 else error('Non-fixture network request refused: '..url)end
 status=200
 for offset=1,#body,16384 do assert(request.sink(body:sub(offset,offset+16383)))end
 assert(request.sink(nil))
 return 1,status,{['content-length']=tostring(#body)},'HTTP/1.1 200 OK'
end
package.path=artifacts..'/upstream/appstore.koplugin/?.lua;'..package.path
G_reader_settings:saveSetting('extra_plugin_paths',{plugins})
G_reader_settings:saveSetting('document_metadata_folder','doc')
G_reader_settings:saveSetting('start_with','filemanager')
G_reader_settings:saveSetting('home_dir',books)
local protected={}
local function protect(path)assert(fs:exists(path),path);protected[#protected+1]=path end
local function snapshot(paths)
 local out={}
 for _,path in ipairs(paths)do
  local attr=assert(fs.lfs.attributes(path));out[path]={sha256=sha.sha256(assert(fs:read(path,16*1048576))),size=attr.size,mtime=attr.modification,permissions=attr.permissions}
 end
 return out
end
local function verify(before)
 local after=snapshot(protected)
 for path,value in pairs(before)do
  local actual=assert(after[path]);assert(actual.sha256==value.sha256,'State bytes changed: '..path)
  assert(actual.mtime==value.mtime,'State timestamp changed: '..path);assert(actual.permissions==value.permissions,'State permissions changed: '..path)
 end
end
if phase=='install'then
 assert(not fs:exists(manifest_path),'Install phase requires a new disposable KO_HOME')
 assert(fs:write(book,assert(fs:read(source..'/build/ux/fixtures/Example.pdf',8*1048576))))
 local settings=Settings:open(settings_path)
 for key,value in pairs{offline=true,home='folder',cache_dir=cache,books_dir=books,prefetch=3,sort='added',file_sort='natural',sync_enabled=true,local_covers=true,folder_view='grid',threshold=84}do settings:saveSetting(key,value)end
 settings:flush()
 assert(fs:writeJSON(credentials_path,{account_id='fixture-account',client_id='synthetic-client',refresh_token='synthetic-refresh',access_token='synthetic-access',expires_at=2147483647}))
 local pending='return {last_page=7,percent_finished=0.42}\n'
 local document={id='book',name='01.pdf',parent_id='folder',version='1',size=fs:size(book),local_path=book}
 local cached={};for k,v in pairs(document)do cached[k]=v end;cached.path=book;cached.ready=true;cached.pool='offline'
 local state={archive_layout=2,books_dir=books,entries={book=cached},docs={book=document},folders={folder={id='folder',name='Saved title',parent_id='root',is_folder=true}},listings={folder={complete=true,ids={'book'},checked_at=123}},sync={pending={book={text=pending,parent_id='folder',stamp={id='book',version='1'}}},bases={},conflicts={}},downloads={queued={entry={id='queued',name='02.pdf',parent_id='folder',size=123,version='1'},pool='offline'}},history={book={id='book',last_opened=456}},folder_types={folder='comics'},folder_pins={folder=true},summaries={book={percent_finished=.42}}}
 assert(fs:writeJSON(index_path,state))
 local sidecar=require('docsettings'):open(book);sidecar:saveSetting('last_page',3);sidecar:saveSetting('percent_finished',.25)
  local sidecar_dir=assert(sidecar:flush());local sidecar_path=sidecar_dir..'/metadata.pdf.lua';assert(fs:write(sidecar_path..'.old','return {last_page=2}\n'))
 assert(fs:write(profile..'/history.lua','return {{time=123456,file='..string.format('%q',book)..'}}\n'))
 local cover=assert(fs:read(source..'/build/ux/fixtures/first.png',8*1048576));local cover_name='gdriveshelf-cover-'..sha.sha256(cover)..'.png'
 local cover_path=account_root..'/folder-metadata/'..Storage.key('folder')..'/'..cover_name;assert(fs:write(cover_path,cover))
 local record={revision=1,values={schema=1,title='Manual offline title',description='Keep my description',cover=cover_name},cover_path=cover_path}
 assert(fs:writeJSON(account_root..'/folder-overrides.json',{schema=1,folders={folder=record}}))
 assert(fs:writeJSON(account_root..'/metadata-outbox.json',{schema=1,folders={folder={record=record}}}))
 for _,path in ipairs{settings_path,credentials_path,index_path,book,sidecar_path,sidecar_path..'.old',profile..'/history.lua',cover_path,account_root..'/folder-overrides.json',account_root..'/metadata-outbox.json'}do protect(path)end
 G_reader_settings:flush()
end
-- A real FileManager supplies the real menu/UI object; no UI or installer mock.
local FileManager=require('apps/filemanager/filemanager')
if not config.embedded then FileManager:showFiles(books)end
local owner=config.ui or assert(FileManager.instance)
local base_windows=#UI._window_stack
local app=dofile(artifacts..'/upstream/appstore.koplugin/main.lua'):new{ui=owner}
local app_settings=require('appstore_settings')
app_settings:saveSetting('hidden_plugin_paths',{'plugins'});app_settings:flush()
local InstallStore=require('appstore_installs')
local function closePopups()
 while #UI._window_stack>base_windows do UI:close(UI._window_stack[#UI._window_stack].widget)end
end
local function choose(text)
 local dialog=assert(UI._window_stack[#UI._window_stack]).widget
 for _,row in ipairs(dialog.other_buttons or dialog.buttons or{})do for _,button in ipairs(row)do if button.text==text then assert(button.callback)();return end end end
 error('Expected real AppStore asset button was not found: '..text)
end
local function tracked()
 for _,item in ipairs(app:collectUpdateSummary().data)do if item.plugin.dirname=='gdriveshelf.koplugin'and item.plugin.root==plugins then return item end end
 error('Installed plugin not visible in its existing custom directory')
end
local function screenshot(name)
 local path=profile..'/'..name..'.png'
 UI:forceRePaint();Device.screen:shot(path);assert(fs:exists(path),'Native AppStore screenshot was not saved')
end
local function checkLatest()
 app:checkAllUpdates();assert(app:collectUpdateSummary().tracked==1,'AppStore fixture did not isolate its custom plugin path')
 local item=tracked();assert(item.remote and not item.remote.error,item.remote and item.remote.error)
 assert(item.remote.release_tag_name=='v'..current,'Stable latest release was not checked');return item
end
local failure,completed
do
  local ok,err=xpcall(function()
   if phase=='install'then
    if mode=='legacy'then
     local reader=Archiver.Reader:new();assert(reader:open(artifacts..'/assets/legacy-0.1.6.zip'))
     for entry in reader:iterate()do if entry.mode=='file'then local path=plugins..'/'..entry.path;fs:mkdir(assert(path:match('^(.*)/')));assert(reader:extractToPath(entry.path,path))end end;reader:close()
     local old=dofile(installed..'/_meta.lua');assert(not old.name and not old.version,'Legacy fixture no longer represents the old metadata')
     local plugin
     for _,candidate in ipairs(app:getUnmatchedPlugins())do if candidate.dirname=='gdriveshelf.koplugin'and candidate.root==plugins then plugin=candidate end end
     assert(plugin);app:matchPluginWithRepo(plugin,repo)
    else
     app:promptPluginInstallOptions(repo);choose(release(current).assets[1].name)
     assert(dofile(installed..'/_meta.lua').version==current,'Fresh release ZIP installation failed')
    end
    fs:mkdir(installed);assert(fs:write(installed..'/user-local.txt','User-authored plugin-local file must survive\n'));protect(installed..'/user-local.txt')
    local before=snapshot(protected);closePopups();current=final
    app:ensureUpdatesState();app.updates_state.filter_only_linked=true
    local available=checkLatest();assert(available.has_update,'New stable release was not identified as an update')
    closePopups();app:showUpdatesDialog();screenshot('appstore-update-available');closePopups()
    app:updatePluginFromRecord(assert(InstallStore.get('gdriveshelf.koplugin')))
    choose(route=='source'and 'Direct download from repo'or release(current).assets[1].name)
    local meta=dofile(installed..'/_meta.lua');assert(meta.name=='gdriveshelf'and meta.version==final,'Updated literal metadata version/identity is wrong')
    assert(assert(fs:read(installed..'/PACKAGE_VERSION')):match('^'..final:gsub('%.','%%.')..'\n$'),'Diagnostic package version differs')
    verify(before)
    local record=assert(InstallStore.get('gdriveshelf.koplugin'));assert(record.owner==repo.owner and record.repo==repo.name and record.installed_version==final)
    assert(record.meta_path=='gdriveshelf.koplugin/_meta.lua','Nested metadata path was not retained')
    if route=='release'then assert(record.installed_tag=='v'..final)end
    closePopups();local latest=checkLatest();assert(not latest.has_update,'Freshly updated plugin still appears outdated')
    closePopups();app:showUpdatesDialog();screenshot('appstore-up-to-date')
    assert(fs:writeJSON(manifest_path,{schema=1,mode=mode,route=route,protected_paths=protected,before=before,version=final,plugin_root=plugins,book=book,index=index_path,upstream_ref=assert(fs:readJSON(artifacts..'/upstream-manifest.json')).ref}))
    assert(fs:writeJSON(profile..'/install-results.json',{mode=mode,route=route,installed_version=meta.version,nested_folder=record.meta_path,tracked=true,state_bytes_mtime_permissions='unchanged',latest_check='up to date',github_transport_requests=#requests,real_network_requests=0}))
    print('PASS real AppStore '..mode..' '..route..' install/update; native ZIP, tracking, latest check, synthetic settings/tokens/books/SDR/queues/manual metadata preserved')
   else
    current=final;local manifest=assert(fs:readJSON(manifest_path));assert(dofile(installed..'/_meta.lua').version==final)
    local item=checkLatest();assert(not item.has_update);assert(item.plugin.version==final)
    local Shelf=dofile(installed..'/main.lua')
    local shelf=config.embedded and setmetatable({ui=owner},{__index=Shelf})or Shelf:new{ui=owner}
    local core=shelf:getCore();assert(shelf:hasCredentials(),'Restart asked for credential reimport')
    assert(core.settings.home=='folder'and core.settings.books_dir==books and core.settings.prefetch==3)
    assert(core.state.entries.book.path==book and core.state.sync.pending.book.text=='return {last_page=7,percent_finished=0.42}\n')
    assert(core.state.downloads.queued.pool=='offline'and core.state.folder_pins.folder and core.state.folder_types.folder=='comics')
    assert(core.state.history.book.last_opened==456 and core:titleInfo('folder').title=='Manual offline title')
    assert(fs.lfs.attributes(credentials_path,'permissions')=='rw-------')
    local sidecar=require('docsettings'):open(book);assert(sidecar:readSetting('last_page')==3 and sidecar:readSetting('percent_finished')==.25)
    closePopups();app:ensureUpdatesState();app.updates_state.filter_only_linked=true;app:showUpdatesDialog();screenshot('appstore-restarted-up-to-date')
    assert(fs:writeJSON(profile..'/restart-results.json',{mode=mode,route=route,version=final,credential_reimport=false,settings='preserved',native_progress='preserved',pending_progress='preserved',download_queue='preserved',history='preserved',manual_metadata_outbox='preserved',latest_check='up to date',real_network_requests=0}))
    print('PASS separate-process restart: installed version '..final..', no credential reimport, native/pending progress and queues/history/manual metadata preserved; latest is up to date')
   end
  end,debug.traceback)
  if not ok then failure=err else completed=true end
  if config.embedded then closePopups()else UI:quit()end
end
assert(not failure,failure)
assert(completed,'Native AppStore scenario did not finish')
