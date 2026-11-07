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
function Shelf:confirmation(options)
 for _,key in ipairs{'ok_callback','cancel_callback'}do
  local callback=options[key]
  if callback then options[key]=function(...)return self:runAction(callback,...)end end
 end
 return require('ui/widget/confirmbox'):new(options)
end
local function privateJSON(path,data)
 local ffi=require('ffi');require('ffi/posix_h')
 -- KOReader 2026.07's POSIX declarations do not include fchmod yet.
 ffi.cdef[[int fchmod(int, mode_t);]]
 local json=require('json');local text=json.encode(data)
 -- Start private even while the atomic replacement is being written.
 local bit=require('bit')
 local tmp=path..'.new';os.remove(tmp)
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
  local account=credentials.account_id and Storage.key(credentials.account_id) or require('ffi/sha2').sha256(credentials.refresh_token or 'unconfigured')
  local storage=Storage.new{root=self.settings.cache_dir..'/drive-'..account,books_dir=self.settings.books_dir or self.settings.cache_dir..'/Books',account=account,json=json}
  local jobs=Jobs.new{storage=storage,dir=storage.root..'/jobs'}
  local provider=require('gdriveshelf/providers/gdrive')
  shared.core=Core.new{storage=storage,jobs=jobs,current_path=self.ui.document and self.ui.document.file,credentials=credentials,settings=self.settings,
   provider_factory=function(c)return provider.new{credentials=c,ca_file=pluginRoot..'/cacert.pem'}end,
   onchange=function(kind,entry,e)for owner in pairs(shared.owners)do owner:onCoreChange(kind,entry,e)end end}
  local logdir=require('datastorage'):getDataDir()..'/gdriveshelf/logs'
  if self.settings.diagnostics then storage:mkdir(logdir)end
  local version='0.0.0-dev';local vf=io.open(pluginRoot..'/PACKAGE_VERSION','rb')
  if vf then version=(vf:read(64)or version):gsub('%s+$','');vf:close()end
  shared.core.logger=require('gdriveshelf/diagnostics').new{dir=logdir,enabled=function()return self.settings.diagnostics==true end,version=version,runtime=jit.os..' '..jit.arch}
  jobs.logger=shared.core.logger
  shared.core.oncredentials=function(c)if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',c)then message(tr("Could not save refreshed credentials"))end end
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
 ui():nextTick(function()self:runAction(function()if not self.ui.tearing_down then core:resume();if current and self.settings.immediate then core:prefetch(current)end end end)end)
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
 if options.parent_enabled~=nil then
  local update=MenuClass.updatePageInfo
  MenuClass=MenuClass:extend{updatePageInfo=function(m,...)
   if update then update(m,...)end
   if m.page_return_arrow then m.page_return_arrow:showHide(options.parent_enabled);m.page_return_arrow:enableDisable(options.parent_enabled)end
  end}
 end
 local top=ui().getTopmostVisibleWidget and ui():getTopmostVisibleWidget()
 local nested=not options.header and (options.back or (top and top._shelf_menu))
 local function closed()
  if menu._closed then return end
  menu._closed=true
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
 local onCloseWidget=menu.onCloseWidget
 menu.onCloseWidget=function(m,...)
  if onCloseWidget then onCloseWidget(m,...)end
  closed()
 end
 if nested then menu.onLeftButtonTap=function(m)m:onCloseAllMenus();return true end end
 menu.onMenuSelect=function(_,item)if item.callback and item.select_enabled~=false then self:runAction(item.callback)end;return true end
 menu.onMenuHold=function(_,item)if item.hold_callback then self:runAction(item.hold_callback)end;return true end
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
function Shelf:showOffline()
 local rows={}
 for _,folder in ipairs(self:orderedEntries(self:offlineChildren(nil)))do
  local e=folder;rows[#rows+1]={text=e.name..(e.author and e.author~=''and ' · '..e.author or ''),icon='appbar.filebrowser',icon_file=e.cover_path,cover=e.cover_path~=nil,folder_progress=e.folder_progress,callback=function()self:showFolder(e.id,true)end}
 end
 if #rows==0 then rows={{text=tr("No downloaded files"),select_enabled=false}}end
 self:menu(tr("Available offline — folders"),rows,{icons=true,perpage=8,multiline=true})
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
function Shelf:removeTree(parent)
 local ids,total={},0
 for id,e in pairs(self.core.state.entries)do
  if e.pool=='auto' or e.pool=='offline'then
   local p=e.parent_id;local seen={}
   while p and not seen[p]do if p==parent then ids[#ids+1]=id;total=total+(e.size or 0);break end;seen[p]=true;local f=self.core.state.folders[p];p=f and f.parent_id end
  end
 end
 ui():show(self:confirmation{text=F("Remove %d local downloads (%s)?\nReading progress and pending sync will be kept.",#ids,bytes(total)),ok_text=tr("Remove"),ok_callback=function()for _,id in ipairs(ids)do self.core:removeFile(id)end;self:onCoreChange('cleared')end})
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
  local pending=self.core.state.sync.pending[entry.id]
  if not DocSettings:hasSidecarFile(path) and (not pending or pending.status_only)then
   local remote=self.core:remote(entry)
   if remote then self:applyRemote(entry,remote,path,pending and pending.status_only)end
  end
  local marked,err=self:writeChapterMark(entry,path)
  if not marked then problem(err)end
  if self.folder_menu then self.folder_menu:onCloseAllMenus()end
  self.core.active_id=entry.id;self.core.opening_id=nil
  self.core:recordOpen(entry)
  if self.ui.document then self.ui:switchDocument(path)else require('apps/reader/readerui'):showReader(path)end
  if resume then self.core:prefetch(entry)end
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
   ui():show(self:confirmation{text=tr("Remove the local file? Reading progress will be kept."),ok_text=tr("Remove"),ok_callback=function()local ok,e=self.core:removeFile(entry.id);if not ok then problem(e)end end})
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
 menu=self:menu(entry.name,rows,{icons=true,multiline=true});return menu
end
function Shelf:showInfo(parent)
 local info=self.core:titleInfo(parent);local text={info.title or parent}
 for _,key in ipairs{'author','status','tags','publisher','year','description'}do if info[key]and info[key]~=''then text[#text+1]=tostring(info[key])end end
 local folder=self.core.state.folders[parent]or{id=parent,name=info.title or parent,is_folder=true}
 local buttons={{{text=tr("Edit folder information"),callback=function()self:editFolderMetadata(folder)end}}}
 if info.cover_path then buttons[#buttons+1]={{text=tr("Cover"),callback=function()ui():show(require('ui/widget/imageviewer'):new{file=info.cover_path,title_text=info.title or tr("Cover"),with_title_bar=true})end}}end
 ui():show(require('ui/widget/textviewer'):new{title=tr("Information"),text=table.concat(text,'\n\n'),buttons_table=#buttons>0 and buttons or nil,add_default_buttons=true})
end
function Shelf:showMemory()
 local usage=self.core:cache():usage();local storage=self.core.storage
 local sdr=storage:treeSize(storage.root..'/snapshots')
 local function nativeSize(path)
  if storage.lfs.attributes(path,'mode')~='directory'then return 0 end
  local sum=0;for name in storage.lfs.dir(path)do if name~='.'and name~='..'then local p=path..'/'..name;local a=storage.lfs.symlinkattributes(p);if a and a.mode=='directory'then if name:match('%.sdr$')then sum=sum+storage:treeSize(p)else sum=sum+nativeSize(p)end end end end;return sum
 end
 local counted={}
 local ok,DocSettings=pcall(require,'docsettings')
 if ok and DocSettings.getSidecarDir then
  for id,entry in pairs(self.core.state.docs or {})do
   local path=(self.core.state.entries[id]or{}).path or entry.local_path
   if path and Library.supported(entry)then for _,location in ipairs{'doc','dir','hash'}do
    local good,dir=pcall(DocSettings.getSidecarDir,DocSettings,path,location)
    if good and dir and not counted[dir]then counted[dir]=true;sdr=sdr+storage:treeSize(dir)end
   end end
  end
 else sdr=sdr+nativeSize(storage.books_dir or storage.root..'/Books')end
 local rows={{text=F("Free disk space: %s",bytes(storage:freeBytes())),select_enabled=false},
 {text=tr("Safety reserve: 512 MiB · active files are protected"),select_enabled=false},
 {text=F("Progress and snapshots: %s · index and queue: %s",bytes(sdr),bytes(storage:size(self.core.index_path))),select_enabled=false}}
 for _,pool in ipairs{'auto','offline','meta'}do
  local p=pool;local label=({auto=tr("Temporary reading cache"),offline=tr("Offline downloads"),meta=tr("Covers, listings and metadata")})[p]
  rows[#rows+1]={text=label..': '..bytes(usage[p])..tr(" · clear"),callback=function()
   ui():show(self:confirmation{text=F("Clear “%s” (%s)?\nOpen files, reading progress and pending sync will be kept.",label,bytes(usage[p])),ok_text=tr("Clear"),ok_callback=function()self.core:clearPool(p);self:showMemory()end})
  end}
 end
 rows[#rows+1]={text=F("Cache location: %s",storage.root),select_enabled=false}
 self:menu(tr("Storage and cache"),rows)
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
function Shelf:showConflict(entry)
 local saved=self.core.state.sync.conflicts[entry.id]
 if not saved then message(tr("The local snapshot is waiting to sync. Both versions are checked before writing."));return end
 local function inspect(text,title)ui():show(require('ui/widget/textviewer'):new{title=title,text=text or tr("No version available")})end
 self:menu(tr("Conflict: ")..entry.name,{
  {text=tr("View local version"),callback=function()inspect(saved.local_lua,tr("Local progress"))end},
  {text=tr("View cloud version"),callback=function()inspect(saved.remote_lua,tr("Cloud progress"))end},
  {text=tr("Use local version"),callback=function()
   ui():show(self:confirmation{text=tr("Upload local progress? The cloud version has been preserved and will be checked again."),ok_text=tr("Local"),ok_callback=function()
    local archived=self:archiveConflict(entry,saved);if not archived then message(tr("Could not preserve both conflict versions"));return end;local result,e=self.core:sync():resolve(entry.id,'local');if not result then problem(e);return end;self.core:save();self.core:flushPending();message(tr("Local version queued for sync"))
   end})
  end},
  {text=tr("Use cloud version"),callback=function()
   local cached=self.core:cached(entry.id);if not cached then message(tr("Download the book first"));return end
   ui():show(self:confirmation{text=tr("Restore cloud progress locally? Close the book before applying it."),ok_text=tr("Cloud"),ok_callback=function()
    if not self:archiveConflict(entry,saved)then message(tr("Could not preserve both conflict versions"));return end
    local ok,e=self:applyRemote(entry,{lua=saved.remote_lua,stamp=saved.stamp,book_stamp=saved.book_stamp},cached.path,true)
    if not ok then problem(e);return end
    local result;result,e=self.core:sync():resolve(entry.id,'remote');if not result then problem(e);return end
    self.core:chapterCloudResolved(entry,result)
    local savedOk,saveError=self.core:save()
    if not savedOk then problem(saveError);return end
    self.core:emit('progress',entry);message(tr("Cloud version applied. Reopen the book."))
   end})
  end},
 })
end
function Shelf:archiveConflict(entry,saved)
 return self.core.storage:writeJSON(self.core.storage.root..'/snapshots/'..Storage.key(entry.id)..'-conflict-'..os.time()..'.json',saved)
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
 dialog=require('ui/widget/inputdialog'):new{title=title,input=tostring(current or ''),input_type=input_type,buttons={{
  {text=tr("Cancel"),callback=function()ui():close(dialog)end},
  {text=tr("Save"),is_enter_default=true,callback=function()self:runAction(function()local text=dialog:getInputText();local ok,e=callback(text);if ok~=false then ui():close(dialog)else problem(e)end end)end},
 }}}
 ui():show(dialog);dialog:onShowKeyboard()
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
 message(tr("Credentials imported"));self:showLibrary()
end
function Shelf:importCredentials(path)
 local credentials=self.core.storage:readJSON(path)
 if type(credentials)~='table'then return false,tr("Could not read authorization JSON. Check the file path and KOReader's storage permission.")end
 if credentials.installed or credentials.web then return false,tr("This is an OAuth client JSON. Run gdriveshelf-authorize.py on your computer first, then import the resulting gdriveshelf-credentials.json.")end
 for _,key in ipairs{'refresh_token','client_id','access_token'}do if type(credentials[key])~='string'or credentials[key]==''then return false,tr("Select the JSON file created by tools/authorize.py")end end
 if credentials.scope and credentials.scope~='https://www.googleapis.com/auth/drive'then return false,tr("Full Google Drive access is required")end
 if self.core.active_id then return false,tr("Close the book before switching accounts")end
 if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',credentials)then return false,tr("Could not securely save credentials")end
 if shared.core then shared.core.jobs:clear()end
 shared.core=nil
 for owner in pairs(shared.owners)do owner.core=nil end
 self.core=self:getCore();self.settings.import_dir=path:match('^(.*)/')or '/';self:saveSettings();return true
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
 if self.settings.immediate or percent*100>=(self.settings.threshold or 75)then self.core:prefetch(entry)end
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
return Shelf
