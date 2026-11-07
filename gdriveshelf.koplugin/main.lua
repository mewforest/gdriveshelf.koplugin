local pluginRoot=debug.getinfo(1,'S').source:sub(2):match('^(.*)/main%.lua$') or 'plugins/gdriveshelf.koplugin'
dofile(pluginRoot..'/bootstrap.lua')(pluginRoot)
local WidgetContainer=require('ui/widget/container/widgetcontainer')
local Catalog=require('gdriveshelf/catalog')
local Requests=require('gdriveshelf/requests')
local Core=require('gdriveshelf/core')
local Storage=require('gdriveshelf/storage')
local Jobs=require('gdriveshelf/jobs')
local Library=require('gdriveshelf/library')
local Metadata=require('gdriveshelf/metadata')
local SDR=require('gdriveshelf/sdr')
local I18N=require('gdriveshelf/i18n')
local Manage=require('gdriveshelf/manage')
local tr=I18N.gettext
local F=I18N.format
local shared=package.loaded['gdriveshelf/runtime'] or {owners=setmetatable({},{__mode='k'})}
package.loaded['gdriveshelf/runtime']=shared
local Shelf=WidgetContainer:extend{name='gdriveshelf',title='GDriveShelf',is_doc_only=false}
local MiB=1048576
local function ui()return require('ui/uimanager')end
local function formatBytes(n,base,units)
 if not n then return tr("unknown")end
 local i=1
 while n>=base and i<#units do n=n/base;i=i+1 end
 local value=string.format('%.1f',n):gsub('%.0$','')
 return value..' '..tr(units[i])
end
local function bytes(n)return formatBytes(n,1000,{'B','kB','MB','GB','TB'})end
local function binaryBytes(n)return formatBytes(n,1024,{'B','KiB','MiB','GiB','TiB'})end
local function message(text)ui():show(require('ui/widget/infomessage'):new{text=tostring(text),timeout=5})end
local function problem(e)message(tr(type(e)=='table' and (e.message or e.code) or e or "Could not complete the action"))end
local function stamp(e)return {id=e.id,version=e.version,checksum=e.checksum,modified_time=e.modified_time}end
local function sameBook(a,b)return SDR.sameBook(a,b)end
function Shelf:runAction(callback,...)
 local args={...}
 local ok,a,b=xpcall(function()return callback(unpack(args))end,function(err)
  -- Record code locations, never the error payload: a JSON parser or third-party
  -- module could include credentials or private filenames in its error text.
  local logger=self.core and self.core.logger
  for level=2,24 do
   local info=debug.getinfo(level,'nSl');if not info then break end
   local name=(info.source or ''):match('gdriveshelf%.koplugin/(.+)%.lua$')
   if name and logger then logger:event('ui_error',{module=name,line=info.currentline})end
  end
  return tr("Google Drive Shelf could not complete this action. KOReader is still running. Diagnostics are available in Connection and startup.")
 end)
 if not ok then pcall(problem,a);return false,a end
 return a,b
end
function Shelf:trackAccountWidget(widget)
 self._account_widgets=self._account_widgets or setmetatable({},{__mode='k'})
 if self.core then self._account_widgets[widget]=self.core end
 return widget
end
function Shelf:confirmation(options)
 local core,widget=self.core
 for _,key in ipairs{'ok_callback','cancel_callback'}do
  local callback=options[key]
  if callback then options[key]=function(...)
   if core and (self.core~=core or core.retired)then return end
   widget._shelf_running=true
   local ok,err=self:runAction(callback,...)
   widget._shelf_running=nil
   return ok,err
  end end
 end
 widget=require('ui/widget/confirmbox'):new(options)
 return self:trackAccountWidget(widget)
end
local function privateJSON(path,data)
 local ffi=require('ffi');require('ffi/posix_h')
 -- KOReader 2026.07's POSIX declarations do not include fchmod yet.
 ffi.cdef[[int fchmod(int, mode_t);]]
 local json=require('json');local text=json.encode(data)
 -- Start private even while the atomic replacement is being written.
 local bit=require('bit')
 local tmp=path..'.new';os.remove(tmp)
 -- Exclusive create prevents a pre-existing symlink from being followed.
 local fd=ffi.C.open(tmp,bit.bor(ffi.C.O_CREAT,ffi.C.O_WRONLY,ffi.C.O_TRUNC,jit.os=='OSX' and 2048 or 128),ffi.cast('mode_t',384))
 if fd<0 then return nil end
 local secured=ffi.C.fchmod(fd,384)==0
 local written=secured and tonumber(ffi.C.write(fd,text,#text))==#text
 local synced=written and ffi.C.fsync(fd)==0
 ffi.C.close(fd)
 if not synced then os.remove(tmp);return nil end
 local ok=os.rename(tmp,path);if not ok then os.remove(tmp)end;return ok
end
function Shelf:loadSettings()
 if not shared.settings_store then
  local DataStorage=require('datastorage')
  shared.settings_dir=DataStorage:getSettingsDir()
  shared.settings_store=require('luasettings'):open(shared.settings_dir..'/gdriveshelf.lua')
  local s=shared.settings_store.data
  if s.auto_mib==nil then s.auto_mib=3072 end;if s.meta_mib==nil then s.meta_mib=256 end
  if s.prefetch==nil then s.prefetch=1 end;if s.threshold==nil then s.threshold=75 end
  if s.sync_enabled==nil then s.sync_enabled=true end
  s.home=s.home or 'root';s.cache_dir=s.cache_dir or DataStorage:getDataDir()..'/gdriveshelf'
 end
 self.settings=shared.settings_store.data
 return self.settings
end
function Shelf:saveSettings()if shared.settings_store then shared.settings_store:flush()end end
function Shelf:getCore()
 if self.core then return self.core end
 self:loadSettings()
 if not shared.core then
  local json=require('json');local credentials={}
  local f=io.open(shared.settings_dir..'/gdriveshelf-credentials.json','rb')
  if f then local text=f:read(1048577);f:close();if text and #text<=1048576 then local ok,c=pcall(json.decode,text);if ok and type(c)=='table'then credentials=c end end end
  local account=credentials.account_id and Storage.key(credentials.account_id)
   or require('ffi/sha2').sha256(credentials.refresh_token or 'unconfigured')
  if credentials.account_id==nil and type(credentials.local_cache_account)=='string'
    and #credentials.local_cache_account==64 and credentials.local_cache_account:match('^%x+$')then
   account=credentials.local_cache_account
  end
  if credentials.refresh_token and Manage.accountHome(self.settings,account)then self:saveSettings()end
  local storage=Storage.new{root=self.settings.cache_dir..'/drive-'..account,books_dir=self.settings.books_dir or self.settings.cache_dir..'/Books',account=account,json=json}
  local jobs=Jobs.new{storage=storage,dir=storage.root..'/jobs'}
  local provider=require('gdriveshelf/providers/gdrive')
  local core
  core=Core.new{storage=storage,jobs=jobs,current_path=self.ui.document and self.ui.document.file,credentials=credentials,settings=self.settings,
   provider_factory=function(c)return provider.new{credentials=c,ca_file=pluginRoot..'/cacert.pem'}end,
   onchange=function(kind,entry,e)
    if not core or core.retired or shared.core~=core then return end
    for owner in pairs(shared.owners)do owner:onCoreChange(kind,entry,e)end
   end}
  shared.core=core
  local logdir=require('datastorage'):getDataDir()..'/gdriveshelf/logs'
  if self.settings.diagnostics then storage:mkdir(logdir)end
  local version='0.0.0-dev';local vf=io.open(pluginRoot..'/PACKAGE_VERSION','rb')
  if vf then version=(vf:read(64)or version):gsub('%s+$','');vf:close()end
  shared.core.logger=require('gdriveshelf/diagnostics').new{dir=logdir,enabled=function()return self.settings.diagnostics==true end,version=version,runtime=jit.os..' '..jit.arch}
  jobs.logger=shared.core.logger
  if not credentials.refresh_token then core.auth_error=true end
  core.oncredentials=function(c)
   if shared.core~=core or core.retired then return end
   if not c.account_id then c.local_cache_account=account end
   if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',c)then message(tr("Could not save refreshed credentials"))end
  end
  local BookList=require('ui/widget/booklist')
  shared.core.natural=Library.nativeComparator(BookList.collates.natural)
 end
 for owner in pairs(shared.owners)do owner.core=shared.core end
 self.core=shared.core;return self.core
end
function Shelf:init()
 self:loadSettings();shared.owners[self]=true
 self.ui.menu:registerToMainMenu(self)
 self:onDispatcherRegisterActions()
 local core=self:getCore();local current=self:activeEntry()
 if current then core.active_id=current.id;core.opening_id=nil;self:installEndHook()end
 ui():nextTick(function()self:runAction(function()if not self.ui.tearing_down then core:resume();if current then
  if self.settings.light_mode then
   local doc=self.ui.doc_settings
   local fraction=doc and doc.readSetting and tonumber(doc:readSetting('percent_finished'))
   local page=doc and doc.readSetting and tonumber(doc:readSetting('last_page'))
   if not fraction and page and self.ui.document and self.ui.document.getPageCount then
    local pages=self.ui.document:getPageCount()
    if pages and pages>0 then fraction=page/pages end
   end
   core:prefetch(current,fraction)
  elseif self.settings.immediate then core:prefetch(current)end
 end end end)end)
end
function Shelf:menu(title,rows,options)
 options=options or {};local Menu=require('ui/widget/menu');local Device=require('device');local menu
 local MenuClass=Menu
 if options.grid then MenuClass=require('gdriveshelf/browser').gridClass(Menu)
 elseif options.icons then
  for _,row in ipairs(rows)do if row.checked~=nil then row.text=row.text:gsub('^☑ ',''):gsub('^☐ ','')end end
  MenuClass=Menu:extend{is_enable_shortcut=true,getItemShortCutIcon=function(m,dimen,key,style)
   local slot;for i,k in ipairs(m.item_shortcuts)do if k==key then slot=i;break end end
   local index=slot and (m.items_max_lines and m.page_items[m.page][slot] or ((m.page or 1)-1)*m.perpage+slot)
   local row=index and m.item_table[index]
   if row and row.checked~=nil then
    local text=require('ui/widget/textwidget'):new{text=row.checked and '☑'or '☐',face=require('ui/font'):getFace('cfont',math.floor(dimen.h*.48))}
    return require('ui/widget/container/centercontainer'):new{dimen=dimen,text}
   end
   if not row or not (row.icon or row.icon_file)then return require('ui/widget/horizontalspan'):new{width=dimen.w}end
   local size=math.floor(math.min(dimen.w,dimen.h)*0.75)
   local picture=require('ui/widget/iconwidget'):new{file=row.icon_file,icon=row.icon,width=size,height=size,alpha=true,is_icon=not row.cover,scale_factor=row.cover and 0 or nil}
   if row.folder_progress~=nil then
    picture=require('ui/widget/verticalgroup'):new{align='center',picture,
     require('ui/widget/verticalspan'):new{width=math.max(1,math.floor(dimen.h*0.02))},
     require('ui/widget/progresswidget'):new{width=size,height=math.max(3,math.floor(dimen.h*0.07)),percentage=row.folder_progress,radius=0,margin_h=0,margin_v=0}}
   end
   return require('ui/widget/container/centercontainer'):new{dimen=dimen,picture}
  end}
 end
 if options.decorated and not options.grid then
  local update=MenuClass.updateItems
  MenuClass=MenuClass:extend{updateItems=function(m,...)
   update(m,...)
   require('gdriveshelf/browser').decorateList(m)
  end}
 end
 if options.parent_enabled~=nil then
  local update=MenuClass.updatePageInfo
  MenuClass=MenuClass:extend{updatePageInfo=function(m,...)
   if update then update(m,...)end
   if m.page_return_arrow then m.page_return_arrow:showHide(options.parent_enabled);m.page_return_arrow:enableDisable(options.parent_enabled)end
  end}
 end
 local origin=self.core
 local top=ui().getTopmostVisibleWidget and ui():getTopmostVisibleWidget()
 local nested=not options.header and (options.back or (top and top._shelf_menu))
 local function closed()
  if menu._closed then return end
  menu._closed=true
  if self._shelf_menus then self._shelf_menus[menu]=nil end
  if self.folder_menu==menu then
   self.folder_menu=nil
   if not self.replacing_folder and self.core and self.core.cancelProgress then self.core:cancelProgress()end
  end
  if options.close then options.close()end
 end
 menu=MenuClass:new{title=title,item_table=rows,width=Device.screen:getWidth(),height=Device.screen:getHeight(),
  custom_title_bar=options.header,grid_columns=options.columns,is_enable_shortcut=options.icons==true and not options.grid,is_borderless=true,is_popout=false,items_per_page=options.perpage,multilines_forced=options.multiline,
  title_bar_left_icon=nested and 'chevron.left' or nil,close_callback=closed}
 if options.header and options.header.bindMenu then options.header:bindMenu(menu)end
 menu._shelf_menu=true
 self._shelf_menus=self._shelf_menus or setmetatable({},{__mode='k'})
 self._shelf_menus[menu]=true
 local onCloseWidget=menu.onCloseWidget
 menu.onCloseWidget=function(m,...)
  if onCloseWidget then onCloseWidget(m,...)end
  closed()
 end
 if nested then menu.onLeftButtonTap=function(m)m:onCloseAllMenus();return true end end
 menu.onMenuSelect=function(_,item)if self.core==origin and not(origin and origin.retired)and item.callback and item.select_enabled~=false then self:runAction(item.callback)end;return true end
 menu.onMenuHold=function(_,item)if self.core==origin and not(origin and origin.retired)and item.hold_callback then self:runAction(item.hold_callback)end;return true end
 menu._shelf_lazy=options.lazy
 if options.lazy then
  local original=menu.onGotoPage
  menu.onGotoPage=function(m,page)
   if not self.automatic_page and page~=m.page and self.folder_visit then self.folder_visit.user_paged=true end
   local result=original(m,page)
   if not self.automatic_page then self:visibleProgress(m)end
   return result
  end
 end
 ui():show(menu)
 if options.lazy and not options.defer_lazy then self:visibleProgress(menu)end
 return menu
end
function Shelf:replaceMenu(menu,rows,title)
 if not menu or menu._closed then return end
 menu:switchItemTable(title or menu.title,rows,-1)
end
function Shelf:visibleProgress(menu)
 if menu._closed then return end
 local job=self.core.progress_job
 if job and (job.mode=='resume' or job.mode=='all')then return end
 local entries={};local first=((menu.page or 1)-1)*(menu.perpage or 14)+1
 local signature={tostring(menu.page),tostring(self.folder_generation or 0)}
 for i=first,math.min(#menu.item_table,first+(menu.perpage or 14)-1)do
  local entry=menu.item_table[i].entry;if entry and not entry.is_folder then
   entries[#entries+1]=entry;signature[#signature+1]=entry.id..':'..tostring(entry.version or entry.modified_time or '')
  end
 end
 signature=table.concat(signature,'|');if menu._lazy_signature==signature then return end
 menu._lazy_signature=signature
 if #entries>0 then
  if self.core.ensureLocalCovers then self.core:ensureLocalCovers(entries)end
  if not (self.settings and self.settings.light_mode) then self.core:lazyProgress(entries)end
 elseif self.core.cancelProgress and (not self.core.progress_job or not self.core.progress_job.mode or self.core.progress_job.mode=='visible')then self.core:cancelProgress()end
end
function Shelf:hasCredentials()
 if self.core and self.core.retired then return false end
 local c=self.core and self.core.credentials or {}
 for _,key in ipairs{'client_id','refresh_token','access_token'}do if type(c[key])~='string'or c[key]==''then return false end end
 return true
end
function Shelf:showLibrary(first_page)
 self:getCore()
 if not self:hasCredentials()then return self:showConnectionSetup()end
 return self:showFolder(self.settings.home or 'root',nil,nil,nil,first_page==true and 'home' or nil)
end
Shelf.onShowGDriveShelf=Shelf.showLibrary
function Shelf:showConnectionSetup()
 if self.connection_menu and not self.connection_menu._closed then ui():close(self.connection_menu)end
 self.connection_menu=self:menu(tr("Connect Google Drive"),{
  {text=tr("Google Drive is not connected yet."),select_enabled=false},
  {text=tr("1. Run the authorization helper on your computer and sign in with Google."),select_enabled=false},
  {text=tr("2. Copy gdriveshelf-credentials.json to this device, for example to Downloads."),select_enabled=false},
  {icon='wifi.secure.100',text=tr("Choose authorization JSON"),callback=function()self:pickCredentials()end},
  {icon='appbar.filebrowser',text=tr("Enter JSON file path"),callback=function()self:pickCredentialsByPath()end},
  {icon='info',text=tr("Which JSON file do I need?"),callback=function()self:showAuthorizationHelp()end},
  {icon='appbar.settings',text=tr("Settings"),callback=function()self:showSettings()end},
 },{icons=true,perpage=7,multiline=true})
 return self.connection_menu
end
function Shelf:showAuthorizationHelp()
 ui():show(require('ui/widget/infomessage'):new{text=tr("Use gdriveshelf-credentials.json created by authorize.py after signing in on your computer. The Desktop client JSON downloaded from Google Cloud is only an input to that utility.\n\nDownload gdriveshelf-authorize.py from the same GitHub release.\n\nDownloads is a suitable location on Android. The usual full path is:\n/storage/emulated/0/Download/gdriveshelf-credentials.json\n\nDo not share this file: it contains access tokens.")})
end
function Shelf:folderActions(folder)
 self:menu(folder.name,{
  {text=tr("Set as home folder"),callback=function()self.settings.home=folder.id;self:saveSettings();message(tr("Home folder saved"))end},
  {text=tr("Download folder and subfolders"),callback=function()
   self.core:scanFolder(folder,function(result,e)
    if not result then problem(e);return end
    ui():show(self:confirmation{text=F("Download %d files (%s)?\nPinned downloads are never removed automatically.",#result.files,bytes(result.size)),ok_text=tr("Download"),ok_callback=function()for _,entry in ipairs(result.files)do self.core:download(entry,'offline')end;self:showQueue()end})
   end)
  end},
  {text=tr("Remove downloads from this folder and subfolders"),callback=function()self:removeTree(folder.id)end},
  {text=tr("Information"),callback=function()self:showInfo(folder.id)end},
 })
end
function Shelf:offlineChildren(parent)
 local core=self.core;local needed={};local files={}
 for _,e in pairs(core.state.entries)do if e.ready and (e.pool=='auto' or e.pool=='offline') and core.storage:exists(e.path)then
  if e.parent_id==parent then files[#files+1]=e end
  local id=e.parent_id;local seen={}
  while id and not seen[id]do seen[id]=true;needed[id]=true;local folder=core.state.folders[id];id=folder and folder.parent_id end
 end end
 local result={}
 for id in pairs(needed)do
  local folder=core.state.folders[id]or{id=id,name=id,is_folder=true}
  if (parent and folder.parent_id==parent)or(not parent and (not folder.parent_id or not needed[folder.parent_id]))then result[#result+1]=folder end
 end
 for _,e in ipairs(files)do result[#result+1]=e end
 return result
end
function Shelf:showFileSort()
 local labels={natural=tr("Natural name order"),name=tr("Name"),size=tr("Size"),date=tr("Modified date")}
 local menu
 local function refresh()
  self:saveSettings()
  if menu and not menu._closed then menu:onCloseAllMenus()end
  self:requestBrowserRefresh(false)
 end
 local rows={}
 for _,mode in ipairs{'natural','name','size','date'}do
  local m=mode;rows[#rows+1]={text=((self.settings.sort or 'natural')==m and '✓ 'or '')..labels[m],callback=function()self.settings.sort=m;refresh()end}
 end
 rows[#rows+1]={text=(self.settings.reverse and '✓ 'or '○ ')..tr("Reverse order"),callback=function()self.settings.reverse=not self.settings.reverse;refresh()end}
 menu=self:menu(tr("File sorting"),rows)
end
function Shelf:activeEntry()
 local path=self.ui and self.ui.document and self.ui.document.file
 if not path or not self.core then return nil end
 for id,e in pairs(self.core.state.entries)do if e.path==path then return e end end
 local alias=(self.core.state.relocation_aliases or {})[path];if alias then return self.core.state.entries[alias]or self.core.state.docs[alias]end
end
function Shelf:applyRemote(entry,record,path,allow_pending)
 local active=self:activeEntry()
 if (active and active.id==entry.id)or self.core.active_id==entry.id then return nil,tr("Close this book before restoring progress, then reopen it.")end
 if self.core.state.sync.pending[entry.id] and not allow_pending then return nil,tr("There is new local progress. Resolve the conflict first.")end
 local cached=(self.core.state.entries or {})[entry.id]or entry
 if not record or not record.lua or not sameBook(record.book_stamp,cached)then return nil,tr("The book version has changed or cannot be verified. Progress was not applied.")end
 local data,e=SDR.decode(record.lua);if not data then return nil,e end
 data.doc_path=path
 local DocSettings=require('docsettings')
 local settings=DocSettings:open(path)
 local ok,result=pcall(settings.flush,settings,data)
 if not ok or not result then return nil,tr("Could not save KOReader metadata") end
 if not allow_pending then
  self.core.state.sync.bases[entry.id]={lua=record.lua,stamp=record.stamp,book_stamp=record.book_stamp}
  self.core:save()
 end
 return true
end
function Shelf:lastDocument()
 local state=self.core and self.core.state
 local entry=state and state.last_document and (state.docs[state.last_document]or state.entries[state.last_document])
 return entry and Library.supported(entry)and entry or nil
end
function Shelf:openLastDocument()
 local entry=self:lastDocument()
 if entry then self:openEntry(entry,true)else message(tr("No previously opened document"))end
end
function Shelf:writeChapterMark(entry,path)
 if not self.core.chapterMark or self.core:chapterMark(entry)==nil then return true end
 local settings=require('docsettings'):open(path)
 if not self.core:applyChapterMark(entry,settings.data)then return true end
 local ok,result=pcall(settings.flush,settings,settings.data)
 if not ok or not result then return nil,tr("Could not save KOReader metadata")end
 return self.core:chapterMarkApplied(entry)
end
function Shelf:openDownloadedEntry(entry,resume,path,e)
  self._end_dialog=nil
  if not path then problem(e);return end
  local DocSettings=require('docsettings')
  local cached=(self.core.state.entries or {})[entry.id]
  local hasNative=DocSettings:hasSidecarFile(path)
  local pending=self.core.state.sync.pending[entry.id]
  local remote=self.core.remote and self.core:remote(entry)
  local deferred=self.core.state.sync.deferred and self.core.state.sync.deferred[entry.id]
  local knownBase=self.core.state.sync.bases and self.core.state.sync.bases[entry.id]
  local canStage=not pending or (pending.status_only and not hasNative)
  local syncEnabled=not self.core.settings or self.core.settings.sync_enabled~=false
  if syncEnabled and cached and sameBook(cached,entry) and self.core.stageRemoteProgress
    and (deferred or (canStage and (remote or (not hasNative and knownBase))))then
   local native=hasNative and DocSettings:open(path).data or nil
   local record,why=self.core:deferredProgress(entry,native,remote)
   if not deferred and not record and not why then record,why=self.core:stageRemoteProgress(entry,remote,native)end
   if record then
    local ok
    ok,why=self:applyRemote(entry,record,path,true)
    if ok then ok,why=self.core:completeDeferredProgress(entry,record)end
   end
   if why and (type(why)~='table' or why.code~='conflict') then problem(why)end
  end
  local marked,err=self:writeChapterMark(entry,path)
  if not marked then problem(err)end
  if self.folder_menu then self.folder_menu:onCloseAllMenus()end
  self.core.active_id=entry.id;self.core.opening_id=nil
  self.core:recordOpen(entry)
  if self.ui.document then self.ui:switchDocument(path)else require('apps/reader/readerui'):showReader(path)end
  if resume and not (self.settings and self.settings.light_mode) then self.core:prefetch(entry)end
end
function Shelf:openEntry(entry,resume)
 self.core:open(entry,function(path,err)self:openDownloadedEntry(entry,resume,path,err)end)
end
function Shelf:fileActions(entry)
 local cached=self.core:cached(entry.id)
 local supported=Library.supported(entry)
 local summary=supported and self.core.chapterSummary and self.core:chapterSummary(entry)
 local read=summary and summary.status=='complete'
 local menu
 local function close()if menu and not menu._closed then menu:onCloseAllMenus()end end
 local rows={
  {icon='appbar.pageview',text=tr("Open"),select_enabled=supported,callback=function()close();self:openEntry(entry)end},
  {icon='move.down',text=tr("Download and keep offline"),select_enabled=supported,callback=function()
   close();self.core:download(entry,'offline');message(tr("File added to the download queue"))
  end},
  {icon='close',text=tr("Remove local download"),select_enabled=cached~=nil,callback=function()
   close()
   if cached then self:confirmManagedRemoval({{id=entry.id,path=cached.path,pool=cached.pool,size=cached.size}})end
  end},
  {icon='bookmark',text=tr(read and "Mark as unread" or "Mark as read"),select_enabled=supported,callback=function()
   local active=self:activeEntry()
   if active and active.id==entry.id then message(tr("Close the book first"));return end
   local ok,err=self.core:setChapterRead(entry,not read)
   if not ok then problem(err);return end
   if cached and sameBook(cached,entry) and require('docsettings'):hasSidecarFile(cached.path)then
    ok,err=self:writeChapterMark(entry,cached.path)
    if not ok then problem(err)end
   end
   close()
   if self.folder_visit then self.folder_visit.resume_started=nil;self:startFolderResume()end
  end},
  {icon='bookmark',text=tr("Recover reading progress"),select_enabled=supported,callback=function()close();self:showRecovery(entry)end},
  {icon='info',text=tr("Information"),callback=function()close();self:showInfo(entry.parent_id)end},
 }
 if self.settings and self.settings.beta_quick_preview and entry.name:lower():match('%.cbz$') then
  table.insert(rows,2,{icon='appbar.pageview',text=tr('Quick CBZ preview'),callback=function()close();self:showQuickPreview(entry)end})
 end
 if self.core.state and self.core.state.sync and self.core.state.sync.conflicts[entry.id] then
  table.insert(rows,2,{icon='notice-warning',text=tr('Compare progress versions'),callback=function()close();self:showConflict(entry)end})
 end
 menu=self:menu(entry.name,rows,{icons=true,multiline=true});return menu
end
function Shelf:showInfo(parent)
 local info=self.core:titleInfo(parent);local text={info.title or parent}
 for _,key in ipairs{'author','status','tags','publisher','year','description'}do if info[key]and info[key]~=''then text[#text+1]=tostring(info[key])end end
 local folder=self.core.state.folders[parent]or{id=parent,name=info.title or parent,is_folder=true}
 local function edit()self:editFolderMetadata(folder)end
 local function full()
  ui():show(require('ui/widget/textviewer'):new{title=tr("Information"),text=table.concat(text,'\n\n'),
   buttons_table={{{text=tr("Edit folder information"),callback=edit}}},add_default_buttons=true})
 end
 if not info.cover_path then return full()end
 local dialog
 local function image()
  ui():show(require('ui/widget/imageviewer'):new{file=info.cover_path,title_text=info.title or tr("Cover"),with_title_bar=true})
 end
 dialog=require('ui/widget/buttondialog'):new{title=info.title or tr("Information"),buttons={
  {{text=tr("Cover"),callback=image},{text=tr("Full information"),callback=function()ui():close(dialog);full()end}},
  {{text=tr("Close"),callback=function()ui():close(dialog)end},{text=tr("Edit folder information"),callback=function()ui():close(dialog);edit()end}},
 }}
 local screen=require('device').screen
 local height=math.floor(math.min(screen:scaleBySize(165),screen:getHeight()*.24))
 local width=math.floor(height*.72)
 local gap=screen:scaleBySize(10)
 dialog:addWidget(require('ui/widget/horizontalgroup'):new{align='top',not_focusable=true,
  require('ui/widget/iconwidget'):new{file=info.cover_path,width=width,height=height,is_icon=false,scale_factor=0},
  require('ui/widget/horizontalspan'):new{width=gap},
  require('ui/widget/textboxwidget'):new{text=table.concat(text,'\n'),width=dialog:getAddedWidgetAvailableWidth()-width-gap,height=height,
   face=require('ui/font'):getFace('smallinfofont'),height_adjust=true,height_overflow_show_ellipsis=true},
 })
 ui():show(dialog)
 return dialog
end
function Shelf:showQueue()
 local rows={{text=tr("Retry pending tasks"),callback=function()self.core.retry_after=nil;self.core:resume();self.core.jobs:pump();message(tr("Retry started"))end}}
 local jobs=self.core.jobs
 if self.core.index_job then local j=self.core.index_job;rows[#rows+1]={text=string.format(tr('Indexing folders: %d/%d'),j.done,j.total)..tr(' · cancel'),callback=function()self.core:cancelIndex();self:showQueue()end}end
 if self.core.deep_job then local j=self.core.deep_job;rows[#rows+1]={text=tr('Scanning covers…')..' '..j.done..'/'..j.total..tr(' · cancel'),callback=function()self.core:cancelDeepScan();self:showQueue()end}end
 if jobs.active then local key=jobs.active.key;rows[#rows+1]={text=tr("Active task: ")..key..tr(" · cancel"),callback=function()local id=key:match('^download:(.+)$');if id then self.core:cancelDownload(id)else jobs:cancel(key)end;self:showQueue()end}end
 for id,d in pairs(self.core.state.downloads)do local file_id=id
  rows[#rows+1]={text=tr("Download: ")..d.entry.name..(d.error and (' · '..d.error) or '')..tr(" · cancel"),callback=function()self.core:cancelDownload(file_id);self:showQueue()end}
 end
 for id,pending in pairs(self.core.state.sync.pending)do local e=pending.entry
  rows[#rows+1]={text=(self.core.state.sync.conflicts[id]and tr("Conflict: ")or tr("Sync: "))..e.name,callback=function()self:showConflict(e)end}
 end
 for id,conflict in pairs(self.core.state.sync.conflicts)do if not self.core.state.sync.pending[id]then local e=self.core.state.docs[id];if e then rows[#rows+1]={text=tr("Conflict: ")..e.name,callback=function()self:showConflict(e)end}end end end
 self:menu(tr("Downloads and sync"),rows)
end
function Shelf:actionNotification(text,action)
 local notice=require('ui/widget/notification'):new{text=text,timeout=6,toast=false}
 notice.onTapClose=function(owner,_,gesture)
  local inside=gesture and owner.frame and owner.frame.dimen and not gesture.pos:notIntersectWith(owner.frame.dimen)
  ui():close(owner)
  if inside then ui():nextTick(function()self:runAction(action)end);return true end
  return false
 end
 ui():show(self:trackAccountWidget(notice))
end
function Shelf:progressEntryLabel(entry)
 local folder=(self.core.state.folders or {})[entry.parent_id]
 return (folder and folder.name and folder.name..' / 'or '')..entry.name
end
function Shelf:notifyProgressConflict(entry)
 local core=self.core
 local saved=core.state.sync.conflicts[entry.id]
 if not saved then return end
 core.conflict_notified=core.conflict_notified or {}
 if core.conflict_notified[entry.id]==saved then return end
 core.conflict_notified[entry.id]=saved
 self:actionNotification(F("Compare progress · %s",self:progressEntryLabel(entry)),function()
  if self.core==core and core.state.sync.conflicts[entry.id]then self:showConflict(entry)end
 end)
end
function Shelf:notifyProgressSynced(entry)
 local core=self.core
 if core.conflict_notified then core.conflict_notified[entry.id]=nil end
 core.synced_notice=core.synced_notice or {}
 if core.synced_notice[entry.id]==os.time()then return end
 core.synced_notice[entry.id]=os.time()
 require('ui/widget/notification'):notify(F("Progress synced · %s",self:progressEntryLabel(entry)),require('ui/widget/notification').SOURCE_ALWAYS_SHOW)
end
function Shelf:showConflict(entry)
 local core=self.core
 local saved=core.state.sync.conflicts[entry.id]
 if not saved then message(tr("The local snapshot is waiting to sync. Both versions are checked before writing."));return end
 local description=SDR.describeConflict(saved)
 local function describe(version,label)
  local lines={tr(label)}
  if version.page then lines[#lines+1]=F("Page %d",math.floor(version.page))end
  if version.percent then lines[#lines+1]=string.format('%d%%',math.floor(version.percent*100+.5))end
  if version.status then lines[#lines+1]=tr(({complete='Read',reading='Reading',abandoned='Abandoned',new='Unread'})[version.status] or 'unknown')end
  if version.date then lines[#lines+1]=version.date:gsub('T',' '):gsub('Z$',' UTC')end
  if #lines==1 then lines[2]=tr("No verified reading position")end
  return table.concat(lines,' · ')
 end
 local differences={}
 local categories={annotations='Bookmarks or annotations',status='Reading status',settings='Book settings',position='Reading position'}
 for _,key in ipairs(description.differences or {})do
  differences[#differences+1]=tr(categories[key] or 'Unknown difference')
 end
 local title=self:progressEntryLabel(entry)
 local rows={
  {text=describe(description.local_version or {},'Local version'),select_enabled=false},
  {text=describe(description.remote_version or {},'Cloud version'),select_enabled=false},
 }
 if #differences>0 then rows[#rows+1]={text=tr("Differences")..' · '..table.concat(differences,', '),select_enabled=false}end
 local comparison
 local function choose(choice)
  ui():show(self:confirmation{text=tr(choice=='local' and "Use the local version? Both versions will be kept." or "Use the cloud version? Both versions will be kept."),
   ok_text=tr("Apply"),ok_callback=function()
    if self.core~=core then return end
    local intent,why=core:resolveProgressConflict(entry,choice,saved)
    if not intent then problem(why);return end
    comparison:onCloseAllMenus()
    if self.queue_menu and not self.queue_menu._closed then self:showQueue()end
    message(tr(choice=='local'and "Local version queued for sync"or "Cloud version queued for verification"))
   end})
 end
 if saved.reason=='book_changed'then
  rows[#rows+1]={text=tr('The document changed. Both versions were kept.'),select_enabled=false}
 else rows[#rows+1]={text=tr('Use local version'),select_enabled=saved.local_lua~=nil,callback=function()choose('local')end}end
 if saved.remote_lua then rows[#rows+1]={text=tr('Use cloud version'),callback=function()choose('remote')end}end
 comparison=self:menu(title,rows,{multiline=true,perpage=6})
 return comparison
end
function Shelf:snapshotCurrent()
 local entry=self:activeEntry();if not entry or not self.ui.doc_settings then return end
 local text,e=SDR.encode(self.ui.doc_settings.data);if not text then problem(e);return end
 local ok,why=self.core.storage:writeJSON(self.core.storage.root..'/snapshots/'..Storage.key(entry.id)..'.json',{lua=text,book_stamp=stamp(self.core.state.entries[entry.id]or entry)})
 if not ok then problem(why);return end
 local result;result,why=self.core:snapshot(entry,self.ui.doc_settings.data);if not result then problem(why)end
end
function Shelf:restoreSnapshot(entry)
 local record=self.core.storage:readJSON(self.core.storage.root..'/snapshots/'..Storage.key(entry.id)..'.json')
 local cached=self.core:cached(entry.id)
 if not record or not cached then message(tr("No local snapshot or downloaded book"));return end
 ui():show(self:confirmation{text=tr("Restore the local progress snapshot? Close the book first."),ok_text=tr("Restore"),ok_callback=function()
  local ok,e=self:applyRemote(entry,record,cached.path,true);if not ok then problem(e);return end
  local data=SDR.decode(record.lua);data.doc_path=cached.path;self.core:snapshot(entry,data);message(tr("Local snapshot restored"))
 end})
end
function Shelf:input(title,current,callback,input_type)
 local dialog
 local core=self.core
 dialog=require('ui/widget/inputdialog'):new{title=title,input=tostring(current or ''),input_type=input_type,buttons={{
  {text=tr("Cancel"),callback=function()ui():close(dialog)end},
  {text=tr("Save"),is_enter_default=true,callback=function()
   if core and (self.core~=core or core.retired)then ui():close(dialog);return end
   dialog._shelf_running=true
   self:runAction(function()local text=dialog:getInputText();local ok,e=callback(text);if ok~=false then ui():close(dialog)else problem(e)end end)
   dialog._shelf_running=nil
  end},
 }}}
 ui():show(self:trackAccountWidget(dialog));dialog:onShowKeyboard()
end
function Shelf:pickCredentials()
 local chooser;local path=self.settings.import_dir
 if not path or path=='/'then path=require('apps/filemanager/filemanagerutil').getHomeFolder()end
 chooser=require('ui/widget/filechooser'):new{title=tr("Select a GDriveShelf credentials JSON file"),ui=self.ui,path=path,show_unsupported=false,
  file_filter=function(name)return name:lower():match('%.json$')~=nil end,onFileSelect=function(_,item)
   self:runAction(function()
    local ok,e=self:importCredentials(item.path)
    if ok then ui():close(chooser);self:onCredentialsImported()else problem(e)end
   end)
  end}
 ui():show(chooser)
 return chooser
end
function Shelf:pickCredentialsByPath()
 self:input(tr("Full path to credentials JSON"),'',function(path)
  local ok,e=self:importCredentials(path)
  if ok then ui():nextTick(function()self:runAction(function()self:onCredentialsImported()end)end)end
  return ok,e
 end)
end
function Shelf:onCredentialsImported()
 if self.connection_menu then ui():close(self.connection_menu);self.connection_menu=nil end
 if self.connection_settings and not self.connection_settings._closed then ui():close(self.connection_settings)end
 message(tr("Credentials imported"));self:showLibrary()
end
function Shelf:pauseAccount(core)
 if self.core~=core then return false,tr('Account could not be verified')end
 if core.archive_removal or core.relocating then return false,tr('Wait for the current storage operation to finish.')end
 if core.retired then return true end
 if core.active_id or self:activeEntry() then return false,tr('Close the book before switching accounts')end
 core.retired=true
 core.jobs.hold=true
 if core.retry_tick and core.jobs.unschedule then core.jobs.unschedule(core.retry_tick)end
 if shared.requests and shared.requests.core==core then shared.requests:cancel(false);shared.requests=nil end
 local manager=ui()
 for owner in pairs(shared.owners)do
  if owner.closeQuickPreview then owner:closeQuickPreview()end
  local tracked=owner._account_widgets or {}
  local menus=owner._shelf_menus or {}
  local closed={}
  for i=#(manager._window_stack or {}),1,-1 do
   local record=manager._window_stack[i]
   local widget=record and record.widget
   if widget and (menus[widget]or tracked[widget]==core)and not widget._shelf_running then
    closed[widget]=true;tracked[widget]=nil
    manager:close(widget)
   end
  end
  for _,key in ipairs{'folder_menu','queue_menu','memory_menu','connection_settings','download_dialog','cover_download','metadata_editor','index_dialog'}do
   local item=owner[key]
   local widget=item and (item.widget or item)
   if widget and not widget._closed and not closed[widget]then manager:close(widget)end
   owner[key]=nil
  end
 end
 if core.quick_preview_session then core.quick_preview_session:close()end
 if core.cover_gallery_session then core.cover_gallery_session:close()end
 core:cancelIndex(false)
 core.jobs:clear({code='cancelled',message='Account session closed',silent=true})
 core.oncredentials=nil
 return true
end
function Shelf:reconnectPausedAccount(core)
 if self.core~=core or not core.retired then return end
 shared.core=nil
 core.credentials={}
 for owner in pairs(shared.owners)do owner.core=nil end
 self.core=nil
 local current=self:getCore()
 current:resume()
 return current
end
function Shelf:signOutAccount(core)
 local ok,err=self:pauseAccount(core)
 if not ok then return false,err end
 local path=shared.settings_dir..'/gdriveshelf-credentials.json'
 local lfs=core.storage.lfs
 for _,file in ipairs{path..'.new',path}do
  if lfs.symlinkattributes(file)and not os.remove(file)then
   self:reconnectPausedAccount(core)
   return false,tr('Could not remove local authorization')
  end
 end
 self:reconnectPausedAccount(core)
 return true
end
function Shelf:importCredentials(path)
 local credentials=self.core.storage:readJSON(path,1048576)
 if type(credentials)~='table'then return false,tr("Could not read authorization JSON. Check the file path and KOReader's storage permission.")end
 if credentials.installed or credentials.web then return false,tr("This is an OAuth client JSON. Run gdriveshelf-authorize.py on your computer first, then import the resulting gdriveshelf-credentials.json.")end
 for _,key in ipairs{'refresh_token','client_id','access_token'}do
  local value=credentials[key]
  if type(value)~='string'or value==''or #value>8192 or value:find('[%c]')then
   return false,tr("Select the JSON file created by tools/authorize.py")
  end
 end
 if credentials.account_id and (type(credentials.account_id)~='string'or #credentials.account_id>100
   or not credentials.account_id:match('^[%w_-]+$'))then return false,tr("Account could not be verified")end
 if credentials.scope and credentials.scope~='https://www.googleapis.com/auth/drive'then return false,tr("Full Google Drive access is required")end
 local core=self.core
 -- The cache marker is private to the installed credential copy.
 credentials.local_cache_account=nil
 if not credentials.account_id and core.credentials.refresh_token==credentials.refresh_token then
  credentials.local_cache_account=core.credentials.local_cache_account
 end
 local ready,why=self:pauseAccount(core)
 if not ready then return false,why end
 if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',credentials)then
  self:reconnectPausedAccount(core)
  return false,tr("Could not securely save credentials")
 end
 self:reconnectPausedAccount(core)
 self.settings.import_dir=path:match('^(.*)/')or '/';self:saveSettings();return true
end
function Shelf:showAbout()
 local size=require('device').screen:scaleBySize(100)
 local logo=require('ui/renderimage'):renderImageFile(pluginRoot..'/resources/logo.png',false,size,size)
 ui():show(require('ui/widget/infomessage'):new{
  text='Google Drive Shelf\n\n'..tr("Google Drive library for KOReader.\n\nWhole-file reading, offline downloads and native reading-progress sync.\n\nLanguage follows your KOReader interface setting."),
  image=logo,image_width=size,image_height=size,alpha=true,
 })
end
function Shelf:onSaveSettings()
 local doc=self.ui.doc_settings
 ui():nextTick(function()self:runAction(function()if doc and self.ui.doc_settings==doc then self:snapshotCurrent()end end)end)
 self:saveSettings()
end
function Shelf:onFlushSettings()self:onSaveSettings()end
function Shelf:onCloseDocument()
 self:clearReaderTransfer()
 -- ReaderUI may defer its native SaveSettings until after CloseDocument.
 -- Flush native module state first so the final snapshot includes this page.
 if self.ui.saveSettings then self.ui:saveSettings()end
 if self.settings.light_mode and self:activeEntry() then self.core.reading_sync_due=true end
 self:snapshotCurrent();if self.ui.document then self.core:finishRelocationForPath(self.ui.document.file)end;self.core.active_id=nil;self.core.opening_id=nil;self._end_dialog=nil
end
function Shelf:onPageUpdate(page)
 local entry=self:activeEntry();if not entry then return end
 local pages=self.ui.document:getPageCount()
 local percent=pages and pages>0 and (tonumber(page)or 0)/pages or 0
 if self.settings.light_mode or self.settings.immediate or percent*100>=(self.settings.threshold or 75)then self.core:prefetch(entry,percent)end
end
function Shelf:installEndHook()
 local status=self.ui.status;if not status or self._native_end then return end
 self._native_end=status.onEndOfBook
 self._native_next=status.onOpenNextOrPreviousFileInFolder
 status.onOpenNextOrPreviousFileInFolder=function(owner,previous,...)
  if self:activeEntry()and not previous then return self:runAction(function()return self:onGDriveShelfNext()end)end
  if self._native_next then return self._native_next(owner,previous,...)end
 end
 status.onEndOfBook=function(owner,...)
  if self:activeEntry()then
   local action=G_reader_settings:readSetting('end_document_action')or 'pop-up'
   if action=='next_file'then
    return self:runAction(function()
     if G_reader_settings:isTrue('end_document_auto_mark')then owner:markBook(true)end
     return self:advanceChapter()
    end)
   end
   return self:runAction(self._native_end,owner,...)
  end
  return self._native_end(owner,...)
 end
end
function Shelf:advanceChapter()
 local entry=self:activeEntry();if not entry then return false end
 if self._end_dialog then return true end
 local next_entry=self.core:next(entry)
 if not next_entry then message(tr(Catalog.kind(entry,self.core.state)=='comics'and "You have finished the last chapter in this folder."or "This is the last document in this folder."));return true end
 self._end_dialog=true
 ui():nextTick(function()
  local ok=self:runAction(function()
   local current=self:activeEntry()
   if not current or current.id~=entry.id then self._end_dialog=nil;return end
   self:openEntry(next_entry)
  end)
  if ok==false then self._end_dialog=nil end
 end)
 return true
end
function Shelf:onGDriveShelfNext()
 return self:advanceChapter()
end
function Shelf:onNetworkConnected()if self.core and not self.settings.offline then self.core:resetNetwork()end end
function Shelf:onSuspend()if self.core then self.core:suspend()end end
function Shelf:onResume()if self.core then self.core:wake()end end
require('gdriveshelf/ux')(Shelf,{shared=shared,root=pluginRoot,bytes=bytes,binaryBytes=binaryBytes,message=message,problem=problem})
require('gdriveshelf/controls')(Shelf,{shared=shared,root=pluginRoot,bytes=bytes,message=message,problem=problem})
require('gdriveshelf/preview').install(Shelf,{shared=shared,root=pluginRoot,bytes=bytes,message=message,problem=problem})
Manage.install(Shelf,{root=pluginRoot,bytes=bytes,binaryBytes=binaryBytes,message=message,problem=problem})
return Shelf
