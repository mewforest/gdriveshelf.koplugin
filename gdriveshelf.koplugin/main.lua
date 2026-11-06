local pluginRoot=debug.getinfo(1,'S').source:sub(2):match('^(.*)/main%.lua$') or 'plugins/gdriveshelf.koplugin'
dofile(pluginRoot..'/bootstrap.lua')(pluginRoot)
local WidgetContainer=require('ui/widget/container/widgetcontainer')
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
local function bytes(n)
 if not n then return tr("unknown")end
 local units={'B','KiB','MiB','GiB','TiB'};local i=1
 while n>=1024 and i<#units do n=n/1024;i=i+1 end
 local value=string.format('%.1f',n):gsub('%.0$','')
 return value..' '..tr(units[i])
end
local function message(text)ui():show(require('ui/widget/infomessage'):new{text=tostring(text),timeout=5})end
local function problem(e)message(tr(type(e)=='table' and (e.message or e.code) or e or "Could not complete the action"))end
local function stamp(e)return {id=e.id,version=e.version,checksum=e.checksum,modified_time=e.modified_time}end
local function sameBook(a,b)return SDR.sameBook(a,b)end
local function privateJSON(path,data)
 local ffi=require('ffi');require('ffi/posix_h')
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
  local storage=Storage.new{root=self.settings.cache_dir..'/drive-'..account,json=json}
  local jobs=Jobs.new{storage=storage,dir=storage.root..'/jobs'}
  local provider=require('gdriveshelf/providers/gdrive')
  shared.core=Core.new{storage=storage,jobs=jobs,credentials=credentials,settings=self.settings,
   provider_factory=function(c)return provider.new{credentials=c,ca_file=pluginRoot..'/cacert.pem'}end,
   onchange=function(kind,entry,e)for owner in pairs(shared.owners)do owner:onCoreChange(kind,entry,e)end end}
  shared.core.oncredentials=function(c)if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',c)then message(tr("Could not save refreshed credentials"))end end
  local BookList=require('ui/widget/booklist')
  local cmp=BookList.collates.natural.init_sort_func()
  shared.core.natural=function(a,b)BookList.collates.natural.item_func(a);BookList.collates.natural.item_func(b);return cmp(a,b)end
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
 ui():nextTick(function()if not self.ui.tearing_down then core:resume();if current and self.settings.immediate then core:prefetch(current)end end end)
end
function Shelf:onDispatcherRegisterActions()
 local Dispatcher=require('dispatcher')
 Dispatcher:registerAction('gdriveshelf_open',{category='none',event='ShowGDriveShelf',title='GDriveShelf',general=true})
 Dispatcher:registerAction('gdriveshelf_next',{category='none',event='GDriveShelfNext',title=tr("GDriveShelf: next chapter"),reader=true})
end
function Shelf:addToMainMenu(items)
 items.gdriveshelf={text='GDriveShelf',sub_item_table={
  {text=tr("Google Drive library"),callback=function()self:showLibrary()end},
  {text=tr("Open last document"),enabled_func=function()return self:lastDocument()~=nil end,callback=function()self:openLastDocument()end},
  {text=tr("Available offline"),callback=function()self:showOffline()end},
  {text=tr("Next chapter"),enabled_func=function()return self:activeEntry()~=nil end,callback=function()self:onGDriveShelfNext()end},
  {text=tr("Storage and cache"),callback=function()self:showMemory()end},
  {text=tr("Downloads and sync"),callback=function()self:showQueue()end},
  {text=tr("Settings"),callback=function()self:showSettings()end},
 }}
end
function Shelf:menu(title,rows,options)
 options=options or {};local Menu=require('ui/widget/menu');local Device=require('device');local menu
 local MenuClass=Menu
 if options.icons then
  MenuClass=Menu:extend{is_enable_shortcut=true,getItemShortCutIcon=function(m,dimen,key,style)
   local slot;for i,k in ipairs(m.item_shortcuts)do if k==key then slot=i;break end end
   local index=slot and (m.items_max_lines and m.page_items[m.page][slot] or ((m.page or 1)-1)*m.perpage+slot)
   local row=index and m.item_table[index]
   if not row or not (row.icon or row.icon_file)then return Menu.getItemShortCutIcon(m,dimen,key,style)end
   local size=math.floor(math.min(dimen.w,dimen.h)*0.75)
   return require('ui/widget/container/centercontainer'):new{dimen=dimen,
    require('ui/widget/iconwidget'):new{file=row.icon_file,icon=row.icon,width=size,height=size,alpha=true,is_icon=not row.cover,scale_factor=row.cover and 0 or nil}}
  end}
 end
 menu=MenuClass:new{title=title,item_table=rows,width=Device.screen:getWidth(),height=Device.screen:getHeight(),
  is_borderless=true,is_popout=false,items_per_page=options.perpage,multilines_forced=options.multiline,
  close_callback=function()menu._closed=true;if self.folder_menu==menu then self.folder_menu=nil end;if options.close then options.close()end end}
 menu.onMenuSelect=function(_,item)if item.callback and item.select_enabled~=false then item.callback()end;return true end
 menu.onMenuHold=function(_,item)if item.hold_callback then item.hold_callback()end;return true end
 if options.lazy then
  local original=menu.onGotoPage
  menu.onGotoPage=function(m,page)local result=original(m,page);m._lazy_page=nil;self:visibleProgress(m);return result end
 end
 ui():show(menu)
 if options.lazy then self:visibleProgress(menu)end
 return menu
end
function Shelf:replaceMenu(menu,rows,title)
 if not menu or menu._closed then return end
 local page=menu.page or 1
 menu:switchItemTable(title or menu.title,rows)
 menu.page=math.max(1,math.min(page,menu.page_num or 1));menu:updateItems(1,true)
end
function Shelf:visibleProgress(menu)
 if menu._closed or menu._lazy_page==menu.page then return end
 menu._lazy_page=menu.page
 local entries={};local first=((menu.page or 1)-1)*(menu.perpage or 14)+1
 for i=first,math.min(#menu.item_table,first+(menu.perpage or 14)-1)do
  local entry=menu.item_table[i].entry;if entry and not entry.is_folder then entries[#entries+1]=entry end
 end
 if #entries>0 then self.core:lazyProgress(entries)end
end
function Shelf:onCoreChange(kind,entry,e)
 if self.folder_menu and not self.folder_menu._closed and (not entry or entry.parent_id==self.folder_id)then
  local rows=self:folderRows(self.folder_id,self.folder_entries or {},self.folder_offline)
  self:replaceMenu(self.folder_menu,rows)
 end
 if kind=='conflict'then message(tr("Both progress versions were preserved. Choose a version in Downloads and sync."))end
end
function Shelf:hasCredentials()
 local c=self.core and self.core.credentials or {}
 for _,key in ipairs{'client_id','refresh_token','access_token'}do if type(c[key])~='string'or c[key]==''then return false end end
 return true
end
function Shelf:showLibrary()
 self:getCore()
 if not self:hasCredentials()then return self:showConnectionSetup()end
 self:showFolder(self.settings.home or 'root')
end
Shelf.onShowGDriveShelf=Shelf.showLibrary
function Shelf:showConnectionSetup()
 if self.connection_menu and not self.connection_menu._closed then ui():close(self.connection_menu)end
 self.connection_menu=self:menu(tr("Connect Google Drive"),{
  {icon='notice-info',text=tr("Google Drive is not connected yet."),select_enabled=false},
  {icon='appbar.tools',text=tr("1. Run the authorization helper on your computer and sign in with Google."),select_enabled=false},
  {icon='move.down',text=tr("2. Copy gdriveshelf-credentials.json to this device, for example to Downloads."),select_enabled=false},
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
function Shelf:orderedEntries(entries)
 local folders,files={},{}
 for _,entry in ipairs(entries)do
  if entry.is_folder then
   local e={};for k,v in pairs(entry)do e[k]=v end
   local info=self.core:titleInfo(e.id)
   e.name=info.title or e.name;e.author=info.author;e.cover_path=info.cover_path
   e.last_read=(self.core.state.last_opened or {})[e.id]or 0
   folders[#folders+1]=e
  else files[#files+1]=entry end
 end
 local result=Library.ordered(folders,self.settings.title_sort or 'natural',self.settings.title_reverse,self.core.natural)
 for _,e in ipairs(Library.ordered(files,self.settings.sort,self.settings.reverse,self.core.natural))do result[#result+1]=e end
 return result
end
function Shelf:folderRows(parent,entries,offline)
 local rows={{icon='appbar.navigation',text=tr("← Library and actions"),callback=function()self:showFolderActions(parent,offline)end}}
 local info=self.core:titleInfo(parent)
 for _,entry in ipairs(self:orderedEntries(Metadata.visible(entries,self.settings.show_service)))do
  local e=entry;local cached=self.core:cached(e.id);local summary=self.core.state.summaries[e.id]
  local progress=summary and summary.percent and string.format(' · %d%%',math.floor(summary.percent*100+0.5)) or ''
  local pin=cached and (cached.pool=='offline' and '★ ' or '✓ ') or ''
  local name=info.chapters[e.name] or e.name
  rows[#rows+1]={text=e.is_folder and (e.name..(e.author and e.author~=''and ' · '..e.author or '')) or (pin..name..progress),entry=e,
   icon=e.is_folder and 'appbar.filebrowser' or 'appbar.pageview',icon_file=e.is_folder and e.cover_path or nil,cover=e.is_folder and e.cover_path~=nil,
   callback=function()if e.is_folder then self:showFolder(e.id,offline)elseif Library.supported(e)then self:openEntry(e)else self:fileActions(e)end end,
   hold_callback=function()if e.is_folder then self:folderActions(e)else self:fileActions(e)end end}
 end
 if #rows==1 then rows[#rows+1]={text=offline and tr("No downloaded chapters") or tr("This folder is empty"),select_enabled=false}end
 return rows
end
function Shelf:showFolder(parent,offline)
 local core=self:getCore();if self.folder_menu then self.folder_menu:onCloseAllMenus()end
 if not offline and not self:hasCredentials()then return self:showConnectionSetup()end
 self.folder_id,self.folder_offline=parent,offline
 local folder=core.state.folders[parent]or{id=parent,name=parent,is_folder=true}
 local title=folder.name..(self.settings.offline and tr(" · offline") or '')
 self.folder_entries=offline and self:offlineChildren(parent) or core:cachedList(parent)
 local menu=self:menu(title,self:folderRows(parent,self.folder_entries,offline),{lazy=not offline,icons=true,perpage=8,multiline=true})
 self.folder_menu=menu
 if offline then return end
 core:folder(parent,folder.name,function(entries,cached,e)
  if menu._closed or self.folder_id~=parent then return end
  if not entries then problem(e);return end
  self.folder_entries=entries;self:replaceMenu(menu,self:folderRows(parent,entries,false),title)
  if not cached then menu._lazy_page=nil;self:visibleProgress(menu)end
 end)
end
function Shelf:showFolderActions(parent,offline)
 local folder=self.core.state.folders[parent]or{id=parent,name=parent,is_folder=true}
 self:menu('GDriveShelf',{
  {icon='home',text=tr("Home folder"),callback=function()self:showLibrary()end},
  {icon='book.opened',text=tr("Open last document"),select_enabled=self:lastDocument()~=nil,dim=self:lastDocument()==nil,callback=function()self:openLastDocument()end},
  {icon='back.top',text=tr("Parent folder"),enabled_func=function()return folder.parent_id~=nil end,callback=function()if folder.parent_id then self:showFolder(folder.parent_id,offline)end end},
  {icon='appbar.filebrowser',text=tr("Folder actions"),callback=function()self:folderActions(folder)end},
  {icon='info',text=tr("Series information"),callback=function()self:showInfo(parent)end},
  {icon='appbar.navigation',text=tr("Title sorting"),callback=function()self:showTitleSort()end},
  {icon='bookmark',text=tr("Available offline"),callback=function()self:showOffline()end},
  {icon='move.down',text=tr("Downloads and conflicts"),callback=function()self:showQueue()end},
  {icon='column.three',text=tr("Storage and cache"),callback=function()self:showMemory()end},
  {icon='appbar.settings',text=tr("Settings"),callback=function()self:showSettings()end},
 },{icons=true})
end
function Shelf:folderActions(folder)
 self:menu(folder.name,{
  {text=tr("Set as home folder"),callback=function()self.settings.home=folder.id;self:saveSettings();message(tr("Home folder saved"))end},
  {text=tr("Download folder and subfolders"),callback=function()
   self.core:scanFolder(folder,function(result,e)
    if not result then problem(e);return end
    ui():show(require('ui/widget/confirmbox'):new{text=F("Download %d files (%s)?\nPinned downloads are never removed automatically.",#result.files,bytes(result.size)),ok_text=tr("Download"),ok_callback=function()for _,entry in ipairs(result.files)do self.core:download(entry,'offline')end;self:showQueue()end})
   end)
  end},
  {text=tr("Remove downloads from this folder and subfolders"),callback=function()self:removeTree(folder.id)end},
  {text=tr("Series information"),callback=function()self:showInfo(folder.id)end},
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
  local e=folder;rows[#rows+1]={text=e.name..(e.author and e.author~=''and ' · '..e.author or ''),icon='appbar.filebrowser',icon_file=e.cover_path,cover=e.cover_path~=nil,callback=function()self:showFolder(e.id,true)end}
 end
 if #rows==0 then rows={{text=tr("No downloaded files"),select_enabled=false}}end
 self:menu(tr("Available offline — folders"),rows,{icons=true,perpage=8,multiline=true})
end
function Shelf:showTitleSort()
 local labels={natural=tr("Natural name order"),name=tr("Name"),read=tr("Last opened (newest first)"),added=tr("Date added (newest first)")}
 local rows={}
 local function refresh()
  self:saveSettings()
  if self.folder_menu and not self.folder_menu._closed then self:replaceMenu(self.folder_menu,self:folderRows(self.folder_id,self.folder_entries or {},self.folder_offline))end
 end
 for _,mode in ipairs{'natural','name','read','added'}do
  local m=mode;rows[#rows+1]={text=(self.settings.title_sort==m or (not self.settings.title_sort and m=='natural'))and '✓ '..labels[m]or labels[m],callback=function()self.settings.title_sort=m;refresh();self:showTitleSort()end}
 end
 rows[#rows+1]={text=(self.settings.title_reverse and '✓ 'or '○ ')..tr("Reverse order"),callback=function()self.settings.title_reverse=not self.settings.title_reverse;refresh();self:showTitleSort()end}
 self:menu(tr("Title sorting"),rows)
end
function Shelf:removeTree(parent)
 local ids,total={},0
 for id,e in pairs(self.core.state.entries)do
  if e.pool=='auto' or e.pool=='offline'then
   local p=e.parent_id;local seen={}
   while p and not seen[p]do if p==parent then ids[#ids+1]=id;total=total+(e.size or 0);break end;seen[p]=true;local f=self.core.state.folders[p];p=f and f.parent_id end
  end
 end
 ui():show(require('ui/widget/confirmbox'):new{text=F("Remove %d local downloads (%s)?\nReading progress and pending sync will be kept.",#ids,bytes(total)),ok_text=tr("Remove"),ok_callback=function()for _,id in ipairs(ids)do self.core:removeFile(id)end;self:onCoreChange('cleared')end})
end
function Shelf:activeEntry()
 local path=self.ui and self.ui.document and self.ui.document.file
 if not path or not self.core then return nil end
 for id,e in pairs(self.core.state.entries)do if e.path==path then return e end end
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
function Shelf:openEntry(entry,resume)
 self.core:open(entry,function(path,e)
  if not path then problem(e);return end
  local DocSettings=require('docsettings')
  if not DocSettings:hasSidecarFile(path) and not self.core.state.sync.pending[entry.id]then
   local remote=self.core:remote(entry)
   if remote then self:applyRemote(entry,remote,path)end
  end
  if self.folder_menu then self.folder_menu:onCloseAllMenus()end
  self.core.active_id=entry.id;self.core.opening_id=nil
  self.core.state.last_opened=self.core.state.last_opened or {};self.core.state.last_opened[entry.parent_id]=os.time();self.core.state.last_document=entry.id;self.core:save()
  if self.ui.document then self.ui:switchDocument(path)else require('apps/reader/readerui'):showReader(path)end
  if resume then self.core:prefetch(entry)end
 end)
end
function Shelf:fileActions(entry)
 local cached=self.core:cached(entry.id)
 self:menu(entry.name,{
  {text=tr("Open"),callback=function()self:openEntry(entry)end},
  {text=tr("Download and keep offline"),callback=function()self.core:download(entry,'offline');message(tr("File added to the download queue"))end},
  {text=tr("Remove local download"),callback=function()
   ui():show(require('ui/widget/confirmbox'):new{text=tr("Remove the local file? Reading progress will be kept."),ok_text=tr("Remove"),ok_callback=function()local ok,e=self.core:removeFile(entry.id);if not ok then problem(e)end end})
  end},
  {text=tr("Apply cached cloud progress"),callback=function()
   if not cached then message(tr("Download the book first"));return end
   local remote=self.core:remote(entry)
   ui():show(require('ui/widget/confirmbox'):new{text=tr("Apply the cached cloud progress? Close the book first."),ok_text=tr("Apply"),ok_callback=function()local ok,e=self:applyRemote(entry,remote,cached.path);if not ok then problem(e)else message(tr("Progress applied. Open the book to continue."))end end})
  end},
  {text=tr("Restore a local snapshot"),callback=function()self:restoreSnapshot(entry)end},
  {text=tr("Series information"),callback=function()self:showInfo(entry.parent_id)end},
 })
end
function Shelf:showInfo(parent)
 local info=self.core:titleInfo(parent);local text={info.title or parent}
 for _,key in ipairs{'author','status','tags','publisher','year','description'}do if info[key]and info[key]~=''then text[#text+1]=tostring(info[key])end end
 local buttons={}
 if info.cover_path then buttons[1]={{text=tr("Cover"),callback=function()ui():show(require('ui/widget/imageviewer'):new{file=info.cover_path,title_text=info.title or tr("Cover"),with_title_bar=true})end}}end
 ui():show(require('ui/widget/textviewer'):new{title=tr("Series information"),text=table.concat(text,'\n\n'),buttons_table=#buttons>0 and buttons or nil,add_default_buttons=true})
end
function Shelf:showMemory()
 local usage=self.core:cache():usage();local storage=self.core.storage
 local sdr=storage:treeSize(storage.root..'/snapshots')
 local function nativeSize(path)
  local sum=0;for name in storage.lfs.dir(path)do if name~='.'and name~='..'then local p=path..'/'..name;local a=storage.lfs.symlinkattributes(p);if a and a.mode=='directory'then if name:match('%.sdr$')then sum=sum+storage:treeSize(p)else sum=sum+nativeSize(p)end end end end;return sum
 end
 sdr=sdr+nativeSize(storage.root..'/files')
 local rows={{text=F("Free disk space: %s",bytes(storage:freeBytes())),select_enabled=false},
 {text=tr("Safety reserve: 512 MiB · active files are protected"),select_enabled=false},
 {text=F("Progress and snapshots: %s · index and queue: %s",bytes(sdr),bytes(storage:size(self.core.index_path))),select_enabled=false}}
 for _,pool in ipairs{'auto','offline','meta'}do
  local p=pool;local label=({auto=tr("Automatic reading cache"),offline=tr("Pinned downloads"),meta=tr("Covers, listings and metadata")})[p]
  rows[#rows+1]={text=label..': '..bytes(usage[p])..tr(" · clear"),callback=function()
   ui():show(require('ui/widget/confirmbox'):new{text=F("Clear “%s” (%s)?\nOpen files, reading progress and pending sync will be kept.",label,bytes(usage[p])),ok_text=tr("Clear"),ok_callback=function()self.core:clearPool(p);self:showMemory()end})
  end}
 end
 rows[#rows+1]={text=F("Cache location: %s",storage.root),select_enabled=false}
 self:menu(tr("Storage and cache"),rows)
end
function Shelf:showQueue()
 local rows={{text=tr("Retry pending tasks"),callback=function()self.core.retry_after=nil;self.core:resume();self.core.jobs:pump();message(tr("Retry started"))end}}
 local jobs=self.core.jobs
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
   ui():show(require('ui/widget/confirmbox'):new{text=tr("Upload local progress? The cloud version has been preserved and will be checked again."),ok_text=tr("Local"),ok_callback=function()
    local archived=self:archiveConflict(entry,saved);if not archived then message(tr("Could not preserve both conflict versions"));return end;local result,e=self.core:sync():resolve(entry.id,'local');if not result then problem(e);return end;self.core:save();self.core:flushPending();message(tr("Local version queued for sync"))
   end})
  end},
  {text=tr("Use cloud version"),callback=function()
   local cached=self.core:cached(entry.id);if not cached then message(tr("Download the book first"));return end
   ui():show(require('ui/widget/confirmbox'):new{text=tr("Restore cloud progress locally? Close the book before applying it."),ok_text=tr("Cloud"),ok_callback=function()
    if not self:archiveConflict(entry,saved)then message(tr("Could not preserve both conflict versions"));return end
    local ok,e=self:applyRemote(entry,{lua=saved.remote_lua,stamp=saved.stamp,book_stamp=saved.book_stamp},cached.path,true)
    if not ok then problem(e);return end
    local result;result,e=self.core:sync():resolve(entry.id,'remote');if not result then problem(e);return end
    self.core:save();message(tr("Cloud version applied. Reopen the book."))
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
 ui():show(require('ui/widget/confirmbox'):new{text=tr("Restore the local progress snapshot? Close the book first."),ok_text=tr("Restore"),ok_callback=function()
  local ok,e=self:applyRemote(entry,record,cached.path,true);if not ok then problem(e);return end
  local data=SDR.decode(record.lua);data.doc_path=cached.path;self.core:snapshot(entry,data);message(tr("Local snapshot restored"))
 end})
end
function Shelf:input(title,current,callback,input_type)
 local dialog
 dialog=require('ui/widget/inputdialog'):new{title=title,input=tostring(current or ''),input_type=input_type,buttons={{
  {text=tr("Cancel"),callback=function()ui():close(dialog)end},
  {text=tr("Save"),is_enter_default=true,callback=function()local text=dialog:getInputText();local ok,e=callback(text);if ok~=false then ui():close(dialog)else problem(e)end end},
 }}}
 ui():show(dialog);dialog:onShowKeyboard()
end
function Shelf:pickCredentials()
 local chooser;local path=self.settings.import_dir
 if not path or path=='/'then path=require('apps/filemanager/filemanagerutil').getHomeFolder()end
 chooser=require('ui/widget/filechooser'):new{title=tr("Select a GDriveShelf credentials JSON file"),ui=self.ui,path=path,show_unsupported=false,
  file_filter=function(name)return name:lower():match('%.json$')~=nil end,onFileSelect=function(_,item)
   local ok,e=self:importCredentials(item.path)
   if ok then ui():close(chooser);self:onCredentialsImported()else problem(e)end
  end}
 ui():show(chooser)
 return chooser
end
function Shelf:pickCredentialsByPath()
 self:input(tr("Full path to credentials JSON"),'',function(path)
  local ok,e=self:importCredentials(path)
  if ok then ui():nextTick(function()self:onCredentialsImported()end)end
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
function Shelf:showSettings()
 local s=self.settings
 local sort_labels={natural=tr("Natural name order"),name=tr("Name"),size=tr("Size"),date=tr("Modified date")}
 local function number(title,key,lo,hi)
  self:input(title,s[key],function(text)local n=tonumber(text);if not n or n~=math.floor(n)or n<lo or n>hi then return false,F("Enter a whole number from %d to %d",lo,hi) end;s[key]=n;self:saveSettings();return true end,'number')
 end
 local function toggle(key) s[key]=not s[key];self:saveSettings()end
 local function mark(value)return value and '✓ ' or '○ 'end
 self:menu(tr("GDriveShelf settings"),{
  {icon='wifi.open.0',text=mark(s.offline)..tr("Offline mode: disable network"),callback=function()self.core:setOffline(not s.offline);self:saveSettings();self:showSettings()end},
  {icon='home',text=tr("Home folder: ID or link"),callback=function()self:input(tr("Google Drive folder ID or link"),s.home,function(text)local id=text:match('/folders/([%w_-]+)')or text:match('[?&]id=([%w_-]+)')or text;if id~='root'and not id:match('^[%w_-]+$')then return false,tr("Invalid folder ID")end;s.home=id;self:saveSettings();return true end)end},
  {icon='wifi.secure.100',text=tr("Import credentials JSON"),callback=function()self:pickCredentials()end},
  {icon='appbar.filebrowser',text=tr("Import credentials by file path"),callback=function()self:pickCredentialsByPath()end},
  {icon='appbar.filebrowser',text=tr("Cache folder"),callback=function()self:input(tr("Cache folder (existing cache is kept)"),s.cache_dir,function(path)
   if path:sub(1,1)~='/' or path:find('[%z\r\n]')then return false,tr("Enter an absolute path")end
   if self.core.active_id then return false,tr("Close the book first")end
   if next(self.core.state.sync.pending)then return false,tr("Sync pending reading progress first")end
   shared.core.jobs:clear();s.cache_dir=path;self:saveSettings();shared.core=nil;for owner in pairs(shared.owners)do owner.core=nil end;self.core=self:getCore();return true
  end)end},
  {icon='column.three',text=F("Automatic cache: %d MiB",s.auto_mib),callback=function()number(tr("Automatic cache limit, MiB"),'auto_mib',1,1048576)end},
  {icon='appbar.pageview',text=F("Metadata cache: %d MiB",s.meta_mib),callback=function()number(tr("Metadata cache limit, MiB"),'meta_mib',1,1048576)end},
  {icon='chevron.last',text=F("Chapters to prefetch: %d",s.prefetch),callback=function()number(tr("Chapters to prefetch (0–3)"),'prefetch',0,3)end},
  {icon='position.marker',text=F("Prefetch starts at: %d%%",s.threshold),callback=function()number(tr("Prefetch threshold, %"),'threshold',0,100)end},
  {icon='cre.render.working',text=mark(s.immediate)..tr("Prefetch immediately after opening"),callback=function()toggle('immediate');self:showSettings()end},
  {icon='cre.render.reload',text=mark(s.sync_enabled)..tr("Sync KOReader reading progress"),callback=function()toggle('sync_enabled');if s.sync_enabled then self.core:flushPending()end;self:showSettings()end},
  {icon='appbar.filebrowser',text=mark(s.show_service)..tr("Show service files"),callback=function()toggle('show_service');self:showSettings()end},
  {icon='appbar.navigation',text=F("Sort order: %s",sort_labels[s.sort or 'natural']or sort_labels.natural),callback=function()
   local rows={};for _,mode in ipairs{'natural','name','size','date'}do local m=mode;rows[#rows+1]={text=sort_labels[m],callback=function()s.sort=m;self:saveSettings()end}end;self:menu(tr("Sort order"),rows)
  end},
  {icon='move.down',text=mark(s.reverse)..tr("Reverse order"),callback=function()toggle('reverse');self:showSettings()end},
  {icon='bookmark',text=tr("Save a snapshot of the current book"),callback=function()self:snapshotCurrent();message(tr("Snapshot saved for the current GDriveShelf book"))end},
  {icon='appbar.navigation',text=tr("Title sorting"),callback=function()self:showTitleSort()end},
  {icon_file=pluginRoot..'/resources/logo.png',text=tr("About GDriveShelf"),callback=function()self:showAbout()end},
 },{icons=true})
end
function Shelf:showAbout()
 local size=require('device').screen:scaleBySize(100)
 local logo=require('ui/renderimage'):renderImageFile(pluginRoot..'/resources/logo.png',false,size,size)
 ui():show(require('ui/widget/infomessage'):new{
  text='GDriveShelf\n\n'..tr("Google Drive library for KOReader.\n\nWhole-file reading, offline downloads and native reading-progress sync.\n\nLanguage follows your KOReader interface setting."),
  image=logo,image_width=size,image_height=size,alpha=true,
 })
end
function Shelf:onSaveSettings()
 local doc=self.ui.doc_settings
 ui():nextTick(function()if doc and self.ui.doc_settings==doc then self:snapshotCurrent()end end)
 self:saveSettings()
end
function Shelf:onFlushSettings()self:onSaveSettings()end
function Shelf:onCloseDocument()
 -- ReaderUI may defer its native SaveSettings until after CloseDocument.
 -- Flush native module state first so the final snapshot includes this page.
 if self.ui.saveSettings then self.ui:saveSettings()end
 self:snapshotCurrent();self.core.active_id=nil;self.core.opening_id=nil;self._end_dialog=nil
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
 status.onEndOfBook=function(owner,...)
  if self:activeEntry()then self:onEndOfBook();return true end
  return self._native_end(owner,...)
 end
end
function Shelf:onEndOfBook()
 local entry=self:activeEntry();if not entry or self._end_dialog then return end
 local next_entry=self.core:next(entry)
 self._end_dialog=true
 ui():nextTick(function()
  if not self:activeEntry()then self._end_dialog=nil;return end
  if not next_entry then
   ui():show(require('ui/widget/confirmbox'):new{text=tr("You have finished the last chapter in this folder."),ok_text=tr("Close"),ok_callback=function()self._end_dialog=nil end,cancel_callback=function()self._end_dialog=nil end})
   return
  end
  ui():show(require('ui/widget/confirmbox'):new{text=tr("Open the next chapter?\n")..next_entry.name,ok_text=tr("Open"),
   ok_callback=function()self._end_dialog=nil;self:openEntry(next_entry)end,cancel_callback=function()self._end_dialog=nil end})
 end)
 return true
end
function Shelf:onGDriveShelfNext()
 local entry=self:activeEntry();local next_entry=entry and self.core:next(entry)
 if next_entry then self:openEntry(next_entry)else message(tr("No next chapter in this folder"))end
 return true
end
function Shelf:onNetworkConnected()if self.core and not self.settings.offline then self.core.retry_after=nil;self.core:resume()end end
function Shelf:onSuspend()if self.core then self.core.sleeping=true;self.core.jobs:setOffline(true)end end
function Shelf:onResume()if self.core then self.core.sleeping=false;self.core.jobs:setOffline(self.settings.offline==true);self:onNetworkConnected()end end
return Shelf
