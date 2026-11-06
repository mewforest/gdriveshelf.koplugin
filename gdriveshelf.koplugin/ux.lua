-- Shelf-facing interactions; core storage/network behavior stays independently testable.
return function(Shelf,env)
 local tr=require('gdriveshelf/i18n').gettext
 local Catalog=require('gdriveshelf/catalog');local Library=require('gdriveshelf/library');local Metadata=require('gdriveshelf/metadata')
 local Requests=require('gdriveshelf/requests');local shared=env.shared
 local function UI()return require('ui/uimanager')end
 local function checked(s,key,text,callback)return {text=(s[key]and '☑ 'or '☐ ')..tr(text),checked=s[key]==true,callback=callback}end
 local function close(m)if m and not m._closed then m:onCloseAllMenus()end end
 local oldLoad=Shelf.loadSettings
 function Shelf:loadSettings()
  local s=oldLoad(self)
  if s.known_first==nil then s.known_first=true end
  if s.load_covers==nil then s.load_covers=true end
  if s.load_metadata==nil then s.load_metadata=true end
  if s.index_hours==nil then s.index_hours=24 end
  return s
 end
 function Shelf:onDispatcherRegisterActions()
  local dispatcher=require('dispatcher')
  for _,a in ipairs{
   {'gdriveshelf_open','ShowGDriveShelf','Google Drive Shelf: open home folder',true},
   {'gdriveshelf_history','GDriveShelfHistory','Google Drive Shelf: history',true},
   {'gdriveshelf_current','GDriveShelfCurrent','Google Drive Shelf: current document folder',true},
   {'gdriveshelf_next','GDriveShelfNext','Google Drive Shelf: next file',false},
  }do dispatcher:registerAction(a[1],{category='none',event=a[2],title=tr(a[3]),general=a[4],reader=not a[4]})end
 end
 function Shelf:addToMainMenu(items)
  items.gdriveshelf={text='Google Drive Shelf',callback=function()self:runAction(function()self:showLibrary()end)end}
  items.gdriveshelf_settings={text=tr('Google Drive Shelf settings'),callback=function()self:runAction(function()self:showSettings()end)end}
  for _,context in ipairs{'filemanager','reader'}do
   local ok,order=pcall(require,'ui/elements/'..context..'_menu_order')
   if ok and order.main then
    for _,id in ipairs{'gdriveshelf_settings','gdriveshelf'}do
     local found=false;for _,value in ipairs(order.main)do if value==id then found=true end end
     if not found then table.insert(order.main,2,id)end
    end
   end
  end
 end
 function Shelf:onGDriveShelfCurrent()
  local entry=self:activeEntry();if entry then self:showFolder(entry.parent_id)else self:showLibrary()end;return true
 end
 function Shelf:onGDriveShelfHistory()self:showHistory();return true end
 function Shelf:orderedEntries(entries)
  local folders,files={},{}
  for _,entry in ipairs(entries)do
   if entry.is_folder then
    local e={};for k,v in pairs(entry)do e[k]=v end
    local info=self.core:titleInfo(e.id);local stats=self.core:folderStats(e.id)
    e.name=info.title or e.name;e.author=info.author;e.cover_path=info.cover_path;e.folder_progress=info.progress and info.progress.ratio
    e.last_read=(self.core.state.last_opened or {})[e.id]or 0;e.size=stats.bytes;e.stats=stats
    e.pinned=(self.core.state.folder_pins or {})[e.id]
    e.known=e.cover_path~=nil or info.author~=nil or info.description~=nil or e.last_read>0 or e.name~=entry.name
    folders[#folders+1]=e
   else files[#files+1]=entry end
  end
  local result=Catalog.order(folders,self.settings.title_sort or 'natural',self.settings.title_reverse,self.settings.known_first,self.core.natural)
  for _,e in ipairs(Library.ordered(files,self.settings.sort,self.settings.reverse,self.core.natural))do result[#result+1]=e end
  return result
 end
 function Shelf:folderRows(parent,entries,offline)
  local rows={};local info=self.core:titleInfo(parent)
  for _,entry in ipairs(self:orderedEntries(Metadata.visible(entries,self.settings.show_service)))do
   local e=entry;local cached=self.core:cached(e.id);local summary=(self.core.state.summaries or {})[e.id]
   local name=self.settings.load_metadata~=false and(info.chapters or {})[e.name]or nil;name=name or e.name
   local cardTitle,cardDetails=name,nil
   if e.is_folder then
    name=(e.pinned and '★ 'or '')..name..(e.author and e.author~=''and '\n'..e.author or '')
    cardTitle=(e.pinned and '★ 'or '')..cardTitle
    if e.stats then
     local details={}
     if e.stats.count~=nil then details[#details+1]=e.stats.count==0 and tr('Empty folder')or string.format(tr('%d files'),e.stats.count)end
     if e.stats.bytes>0 then details[#details+1]=tr('Downloaded')..': '..env.bytes(e.stats.bytes)end
     if #details>0 then name=name..'\n'..table.concat(details,' · ')end
     local compact={}
     if e.stats.count~=nil then compact[#compact+1]=e.stats.count==0 and tr('Empty folder')or string.format(tr('%d files'),e.stats.count)end
     if e.stats.bytes>0 then compact[#compact+1]='✓ '..env.bytes(e.stats.bytes)end
     cardDetails=table.concat(compact,'\n')
    end
   else
    if self.selection then name=(self.selection[e.id]and '☑ 'or '☐ ')..name
    elseif cached then name=(cached.pool=='offline'and '★ 'or '✓ ')..name end
    if summary and summary.percent then name=name..string.format(' · %d%%',math.floor(summary.percent*100+.5))end
    cardTitle=name
   end
   local thumb=self.settings.beta_thumbnails and not e.is_folder and self.core:thumbnail(e)
   local cover=e.is_folder and e.cover_path or (self.settings.beta_thumbnails and thumb and self.core.storage:exists(thumb.path)and thumb.path or nil)
   rows[#rows+1]={text=name,card_title=cardTitle,card_details=cardDetails,entry=e,icon=e.is_folder and 'appbar.filebrowser'or 'appbar.pageview',icon_file=cover,cover=cover~=nil,folder_progress=e.folder_progress,
    callback=function()
     if self.selection and not e.is_folder then self.selection[e.id]=not self.selection[e.id];self:refreshBrowser()
     elseif e.is_folder then self:showFolder(e.id,offline)
     elseif Library.supported(e)then self:openEntry(e)else self:fileActions(e)end
    end,hold_callback=function()if e.is_folder then self:folderActions(e)else self:fileActions(e)end end}
  end
  if #rows==0 then
   local state=(self.core.state.listings or {})[parent]
   local text=self.browser_error and tr('Could not load this folder')or (self.browser_loading and tr('Loading folder…')or (state and state.complete and tr('This folder is empty')or tr('Folder contents are not cached')))
   rows[1]={text=text,select_enabled=false}
  end
  return rows
 end
 function Shelf:browserStatus()
  if self.browser_error then return tr('Could not load this folder')end
  local parts={};if self.browser_loading then parts[#parts+1]=tr('Loading folder…')end
  if self.core.index_job then local j=self.core.index_job;parts[#parts+1]=string.format(tr('Indexing folders: %d/%d'),j.done,j.total)end
  if self.core.deep_job then parts[#parts+1]=tr('Scanning covers…')end
  for _,d in pairs(self.core.state.downloads)do if d.entry.parent_id==self.folder_id and d.pool=='meta'then parts[#parts+1]=d.entry.name:lower()=='cover.jpg'and tr('Loading cover…')or tr('Loading information…');break end end
  if #parts==0 then parts[1]=self.folder_offline and tr('Available offline')or 'Google Drive Shelf'end
  return table.concat(parts,' · ')
 end
 function Shelf:refreshBrowser()
  local m=self.folder_menu;if not m or m._closed then return end
  if m.title_bar then m.title_bar:setSubTitle(self:browserStatus(),true)end
  -- Preserve item order during background indexing, then regroup once complete.
  local rows=self:folderRows(self.folder_id,self.folder_entries or {},self.folder_offline)
  if self.core.index_job and m.item_table then
   local rank={};for i,row in ipairs(m.item_table)do if row.entry then rank[row.entry.id]=i end end
   table.sort(rows,function(a,b)return(rank[a.entry and a.entry.id]or 1e9)<(rank[b.entry and b.entry.id]or 1e9)end)
  end
  self:replaceMenu(m,rows)
 end
 function Shelf:showFolder(parent,offline,force,render_only)
  local core=self:getCore()
  if not offline and not self:hasCredentials()then return self:showConnectionSetup()end
  self.browser_positions=self.browser_positions or {}
  if self.folder_menu then self.browser_positions[self.folder_id]={page=self.folder_menu.page};close(self.folder_menu)end
  if self.folder_id~=parent then self.selection=nil end
  self.folder_id,self.folder_offline=parent,offline;self.browser_error=nil;self.browser_loading=not offline and not render_only and core:online()
  self.folder_entries=offline and self:offlineChildren(parent)or core:cachedList(parent)
  local folder=core.state.folders[parent]or {id=parent,name=parent,is_folder=true};local info=core:titleInfo(parent)
  local hasFolders=false;for _,e in ipairs(self.folder_entries)do if e.is_folder and not Metadata.isService(e)then hasFolders=true;break end end
  local grid=(hasFolders and self.settings.folder_view=='grid')or(not hasFolders and self.settings.beta_thumbnails and self.settings.file_view=='grid')
  local function action(fn)return function()self:runAction(fn)end end
  local buttons={
   {icon='home',callback=action(function()self:showLibrary()end)},
   {icon_file=env.root..'/resources/icons/refresh.svg',callback=action(function()self:showFolder(parent,offline,true)end)},
   {icon_file=env.root..'/resources/icons/sort.svg',callback=action(function()self:showBrowserSort()end)},
   {icon_file=env.root..'/resources/icons/actions.svg',callback=action(function()self:showFolderActions(parent,offline)end)},
   {icon='info',callback=action(function()self:showInfo(parent)end)},
  }
  if hasFolders or self.settings.beta_thumbnails then table.insert(buttons,4,{icon_file=env.root..'/resources/icons/'..(grid and 'list'or 'grid')..'.svg',callback=action(function()
   local key=hasFolders and 'folder_view'or 'file_view';self.settings[key]=grid and 'list'or 'grid';self:saveSettings();self:showFolder(parent,offline)
  end)})end
  for _,button in ipairs(buttons)do if button.icon_file then button.icon='appbar.pageview'end end
  local summary
  if self.settings.beta_header and not self.header_collapsed and (info.cover_path or info.description)then
   summary={cover_path=info.cover_path,text=(info.title or folder.name)..(info.author and '\n'..info.author or '')..'\n'..(info.description or ''):sub(1,260),height=math.floor(require('device').screen:getHeight()*.16)}
  end
  local width=require('device').screen:getWidth()
  local header=require('gdriveshelf/browser').header{width=width,title=info.title or folder.name,status=self:browserStatus(),buttons=buttons,summary=summary,
   back=action(function()if folder.parent_id then self:showFolder(folder.parent_id,offline)else close(self.folder_menu)end end),
   close=function()close(self.folder_menu)end,info=action(function()self:showInfo(parent)end)}
  local menu=self:menu(info.title or folder.name,self:folderRows(parent,self.folder_entries,offline),{icons=not grid,grid=grid,header=header,perpage=grid and 9 or 7,multiline=true,lazy=not offline})
  self.folder_menu=menu
  menu.onClose=function()if folder.parent_id then self:showFolder(folder.parent_id,offline)else menu:onCloseAllMenus()end;return true end
  menu.onReturn=function()if folder.parent_id then self:showFolder(folder.parent_id,offline)else menu:onCloseAllMenus()end;return true end
  local position=self.browser_positions[parent];if position and position.page then menu:onGotoPage(math.min(position.page,menu.page_num))end
  if not offline and not render_only then core:folder(parent,folder.name,function(entries,cached,err)
   if self.folder_menu~=menu or menu._closed then return end
   if not cached then self.browser_loading=false;self.browser_error=err end
   if entries then
    self.folder_entries=entries
    local nowHasFolders=false;for _,e in ipairs(entries)do if e.is_folder and not Metadata.isService(e)then nowHasFolders=true;break end end
    if not cached and nowHasFolders~=hasFolders then self:showFolder(parent,offline,false,true);return end
   end;self:refreshBrowser()
  end,force)end
  return menu
 end
 function Shelf:showBrowserSort()
  return self:menu(tr('Sorting'),{
   {icon='appbar.filebrowser',text=tr('Folder sorting'),callback=function()self:showTitleSort()end},
   {icon='appbar.pageview',text=tr('File sorting'),callback=function()self:showFileSort()end},
  },{icons=true})
 end
 function Shelf:showFolderActions(parent,offline)
  local folder=self.core.state.folders[parent]or{id=parent,name=parent,is_folder=true}
  return self:menu(tr('Folder actions'),{
   {icon='appbar.filebrowser',text=tr('Actions for this folder'),callback=function()self:folderActions(folder)end},
   {icon='cre.render.reload',text=tr('Refresh folder information'),callback=function()self:showFolder(parent,offline,true)end},
   {icon='bookmark',text=tr('History'),callback=function()self:showHistory()end},
   {icon='move.down',text=tr('Select files to keep offline'),callback=function()self.selection=self.selection or {};self:refreshBrowser();self:showSelectionActions()end},
   {icon='bookmark',text=tr('Available offline'),callback=function()self:showOffline()end},
   {icon='move.down',text=tr('Downloads and sync'),callback=function()self:showQueue()end},
   {icon='column.three',text=tr('Storage and cache'),callback=function()self:showMemory()end},
   {icon='appbar.settings',text=tr('Settings'),callback=function()self:showSettings()end},
  },{icons=true})
 end
 function Shelf:showSelectionActions()
  local dialog
  dialog=require('ui/widget/buttondialog'):new{title=tr('Select files'),buttons={
   {{text=tr('Select all'),callback=function()for _,e in ipairs(self.folder_entries)do if Library.supported(e)then self.selection[e.id]=true end end;UI():close(dialog);self:refreshBrowser();self:showSelectionActions()end}},
   {{text=tr('Download selected'),callback=function()for _,e in ipairs(self.folder_entries)do if self.selection[e.id]and Library.supported(e)then self.core:download(e,'offline')end end;self.selection=nil;UI():close(dialog);self:refreshBrowser()end}},
   {{text=tr('Choose files in the list'),callback=function()UI():close(dialog)end}},
   {{text=tr('Cancel selection'),callback=function()self.selection=nil;UI():close(dialog);self:refreshBrowser()end}},
  }};UI():show(dialog)
 end
 local oldFolderActions=Shelf.folderActions
 function Shelf:folderActions(folder)
  local original=self.menu;local result
  self.menu=function(owner,title,rows,options)
   rows[2].callback=function()owner:queueFolderDownload(folder)end
   local pinned=owner.core.state.folder_pins[folder.id]
   table.insert(rows,1,{icon='bookmark',text=pinned and tr('Unpin from top')or tr('Pin to top'),callback=function()owner.core.state.folder_pins[folder.id]=not pinned;owner.core:save();owner:refreshBrowser()end})
   rows[#rows+1]={icon='cre.render.reload',text=tr('Refresh folder information'),callback=function()owner:showFolder(folder.id,false,true)end}
   rows[#rows+1]={icon='appbar.pageview',text=tr('Content type'),callback=function()
    local choices={};for _,kind in ipairs{'auto','comics','books'}do local value=kind;choices[#choices+1]={text=tr(value),callback=function()owner.core.state.folder_types[folder.id]=value;owner.core:save()end}end
    owner:menu(tr('Content type'),choices)
   end}
   if owner.settings.beta_header then rows[#rows+1]={icon='info',text=tr('Expand/collapse information header'),callback=function()owner.header_collapsed=not owner.header_collapsed;owner:showFolder(owner.folder_id,owner.folder_offline)end}end
   if owner.settings.beta_thumbnails then rows[#rows+1]={icon='appbar.pageview',text=tr('Deep scan covers (beta)'),callback=function()if not owner.core:deepScan(folder)then env.message(tr('Go online to scan covers.'))end end}end
   local icons={'home','move.down','close','info'};for i,row in ipairs(rows)do row.icon=row.icon or icons[(i-2)%4+1]end
   return original(owner,title,rows,{icons=true})
  end
  local ok,err=xpcall(function()result=oldFolderActions(self,folder)end,debug.traceback);self.menu=original
  if not ok then error(err)end;return result
 end
 function Shelf:queueFolderDownload(folder)
  if not self.core:online()then env.message(tr('Go online to discover files for download.'));return end
  local dialog
  local function cancel()self.core:cancelFolderScan();if dialog then UI():close(dialog)end;self.scan_dialog=nil end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Checking folder contents…'),buttons={{{text=tr('Cancel'),callback=cancel}}}}
  dialog.onClose=function()cancel();return true end;self.scan_dialog=dialog;UI():show(dialog)
  self.core:scanFolder(folder,function(result,err)
   UI():close(dialog);self.scan_dialog=nil
   if not result then env.problem(err);return end
   UI():show(self:confirmation{text=string.format(tr('Download %d files (%s)?'),#result.files,env.bytes(result.size)),ok_text=tr('Download'),ok_callback=function()for _,entry in ipairs(result.files)do self.core:download(entry,'offline')end;self:showQueue()end})
  end)
 end
 function Shelf:showTitleSort()
  local rows={};local labels={natural='Natural name order',name='Name',read='Last opened (newest first)',added='Date added (newest first)',size='Downloaded size'}
  for _,mode in ipairs{'natural','name','read','added','size'}do local value=mode;rows[#rows+1]={text=((self.settings.title_sort or 'natural')==mode and '✓ 'or '')..tr(labels[mode]),callback=function()self.settings.title_sort=value;self:saveSettings();self:refreshBrowser()end}end
  rows[#rows+1]=checked(self.settings,'title_reverse','Reverse order',function()self.settings.title_reverse=not self.settings.title_reverse;self:saveSettings();self:refreshBrowser()end)
  return self:menu(tr('Folder sorting'),rows)
 end
 function Shelf:showHistory()
  local rows={}
  for _,record in ipairs(self.core:history())do
   local r=record;local info=r.folder_id and self.core:titleInfo(r.folder_id)or {}
   rows[#rows+1]={text=r.folder_id and(info.title..'\n'..r.entry.name)or r.entry.name,icon='bookmark',icon_file=info.cover_path,cover=info.cover_path~=nil,
    callback=function()self:openEntry(r.entry,true)end,hold_callback=function()if r.folder_id then self:showFolder(r.folder_id)else self:fileActions(r.entry)end end}
  end
  if #rows==0 then rows={{text=tr('No reading history yet'),select_enabled=false}}end
  return self:menu(tr('Google Drive Shelf history'),rows,{icons=true,perpage=7,multiline=true})
 end
 local oldOpen=Shelf.openEntry
 function Shelf:openEntry(entry,resume)
  shared.requests=shared.requests or Requests.new(self.core)
  local cached=self.core:cached(entry.id)
  if shared.requests.core~=self.core then shared.requests:cancel(true);shared.requests=Requests.new(self.core)end
  local dialog
  local function finish(path,err)
   if dialog then UI():close(dialog)end;self.download_dialog=nil;self._end_dialog=nil
   if not path then env.problem(err);return end
   -- The native opener retains progress restoration and end-action integration.
   oldOpen(self,entry,resume)
  end
  if not cached then
   dialog=require('ui/widget/buttondialog'):new{title=tr('Downloading')..'\n'..entry.name..'\n'..env.bytes((self.core.transfer and self.core.transfer[entry.id]or{}).received or 0)..(entry.size and ' / '..env.bytes(entry.size)or ''),buttons={{
    {text=tr('Cancel'),callback=function()shared.requests:cancel(true);UI():close(dialog);self.download_dialog=nil;self._end_dialog=nil end},
    {text=tr('In background'),callback=function()shared.requests:cancel(false);UI():close(dialog);self.download_dialog=nil;self._end_dialog=nil end},
   }}}
   dialog.onClose=function()shared.requests:cancel(true);UI():close(dialog);self.download_dialog=nil;self._end_dialog=nil;return true end
   UI():show(dialog);self.download_dialog={widget=dialog,entry=entry}
  end
  shared.requests:start(entry,finish)
 end
 local oldChange=Shelf.onCoreChange
 function Shelf:onCoreChange(kind,entry,err)
  if self.folder_menu and not self.folder_menu._closed then self:refreshBrowser()end
  local d=self.download_dialog
  if kind=='transfer'and d and entry and entry.id==d.entry.id then
   local value=(self.core.transfer or {})[entry.id]
   if value and d.widget.setTitle then
    local text=tr(value.stage=='complete'and 'Checking document…'or 'Downloading')..'\n'..entry.name..'\n'..env.bytes(value.received)..(value.total and ' / '..env.bytes(value.total)or '')
    if value.total and value.total>0 then text=text..string.format(' · %d%%',math.floor(value.received/value.total*100))end
    d.widget:setTitle(text)
   end
  end
  if kind=='folder_scanning'and self.scan_dialog and self.core.folder_scan then
   self.scan_dialog:setTitle(tr('Checking folder contents…')..' '..self.core.folder_scan.done)
  end
  if kind=='relocating'and self.move_dialog and err then self.move_dialog:setTitle(tr('Moving documents…')..' '..err.received..' / '..tostring(err.total or '?'))end
  if kind=='conflict'then env.message(tr('Both progress versions were preserved. Choose a version in Downloads and sync.'))end
 end
 function Shelf:showSettings()
  local rows={checked(self.settings,'offline','Offline mode',function()self.core:setOffline(not self.settings.offline);self:saveSettings();self:showSettings()end)}
  for _,category in ipairs{
   {'connection','wifi.secure.100','Connection and startup'}, {'catalog','appbar.filebrowser','Catalog and appearance'},
   {'downloads','column.three','Downloads and storage'}, {'reading','bookmark','Reading and sync'},
   {'experimental','appbar.tools','Experimental'},
  }do local id=category[1];rows[#rows+1]={icon=category[2],text=tr(category[3]),callback=function()self:showSettingsCategory(id)end}end
  rows[#rows+1]={icon='info',text=tr('About Google Drive Shelf'),callback=function()self:showAbout()end}
  return self:menu(tr('Google Drive Shelf settings'),rows,{icons=true})
 end
 function Shelf:showSettingsCategory(category)
  local s=self.settings;local rows={};local title
  local function toggle(key,label,after)
   rows[#rows+1]=checked(s,key,label,function()s[key]=not s[key];self:saveSettings();if after then after()end;self:showSettingsCategory(category)end)
  end
  local function number(key,label,lo,hi)
   rows[#rows+1]={text=tr(label)..': '..tostring(s[key]or 0),callback=function()self:input(tr(label),s[key]or 0,function(value)
    local n=tonumber(value);if not n or n~=math.floor(n)or n<lo or n>hi then return false,tr('Invalid value')end
    s[key]=n;self:saveSettings();return true
   end,'number')end}
  end
  if category=='connection'then
   title='Connection and startup'
   rows={
    {icon='wifi.secure.100',text=tr('Choose authorization JSON'),callback=function()self:pickCredentials()end},
    {icon='appbar.filebrowser',text=tr('Enter JSON file path'),callback=function()self:pickCredentialsByPath()end},
    {icon='home',text=tr('Home folder: ID or link'),callback=function()self:input(tr('Google Drive folder ID or link'),s.home,function(value)
     local id=value:match('/folders/([%w_-]+)')or value:match('[?&]id=([%w_-]+)')or value
     if id~='root'and not id:match('^[%w_-]+$')then return false,tr('Invalid folder ID')end;s.home=id;self:saveSettings();return true
    end)end},
    {icon='home',text=tr('Start with Google Drive Shelf'),callback=function()require('gdriveshelf/integration').chooseStartup(self)end},
    {icon='appbar.navigation',text=tr('Gesture shortcuts'),callback=function()env.message(tr('In KOReader gesture settings, choose General → Google Drive Shelf: open home folder, history, or current document folder.'))end},
   }
  elseif category=='catalog'then
   title='Catalog and appearance'
   rows={
    {icon='appbar.filebrowser',text=tr('Folder sorting'),callback=function()self:showTitleSort()end},
    {icon='appbar.pageview',text=tr('File sorting'),callback=function()self:showFileSort()end},
    {text=tr('Folder view')..': '..tr(s.folder_view or 'list'),callback=function()s.folder_view=s.folder_view=='grid'and 'list'or 'grid';self:saveSettings();self:showSettingsCategory(category)end},
   }
   toggle('known_first','Show known folders first');toggle('load_covers','Download folder covers');toggle('load_metadata','Download descriptive metadata');toggle('show_service','Show service files')
   toggle('index_enabled','Index home folder',function()if s.index_enabled then self.core:indexHome()else self.core:cancelIndex()end end)
   rows[#rows+1]={text=tr('Recheck folders')..': '..(s.index_hours==0 and tr('Disabled')or tostring(s.index_hours)..' '..tr('hours')),callback=function()
    local choices={};for _,hours in ipairs{0,1,6,24,72,168}do local value=hours;choices[#choices+1]={text=hours==0 and tr('Disabled')or tostring(hours)..' '..tr('hours'),callback=function()s.index_hours=value;self:saveSettings()end}end
    self:menu(tr('Recheck folders'),choices)
   end}
   rows[#rows+1]={icon='cre.render.reload',text=tr('Refresh home catalog now'),callback=function()self:showFolder(s.home,false,true)end}
  elseif category=='downloads'then
   title='Downloads and storage'
   rows={
    {icon='column.three',text=tr('Storage and cache'),callback=function()self:showMemory()end},
    {icon='appbar.filebrowser',text=tr('Document folder'),callback=function()self:chooseBooksFolder()end},
    {text=tr('Document folder: enter path'),callback=function()self:input(tr('Document folder'),self.core.storage.books_dir,function(path)return self:moveBooks(path)end)end},
   }
   number('auto_mib','Temporary reading cache limit, MiB',1,1048576);number('meta_mib','Metadata cache limit, MiB',1,1048576)
  elseif category=='reading'then
   title='Reading and sync'
   number('prefetch','Chapters to prefetch',0,3);number('threshold','Prefetch threshold, %',0,100)
   toggle('immediate','Prefetch immediately after opening');toggle('prefetch_books','Prefetch the next ordinary book')
   toggle('sync_enabled','Sync KOReader reading progress',function()if s.sync_enabled then self.core:flushPending()end end)
   rows[#rows+1]={text=tr('Progress can be stored beside books or centrally in KOReader. Cloud sync exports native .sdr data to the Drive folder, visible to everyone with access. With sync disabled, reading stays local.'),select_enabled=false}
   rows[#rows+1]={icon='move.down',text=tr('Downloads and sync'),callback=function()self:showQueue()end}
   rows[#rows+1]={icon='bookmark',text=tr('Save a snapshot of the current book'),callback=function()self:snapshotCurrent()end}
  elseif category=='experimental'then
   title='Experimental'
   rows[#rows+1]={text=tr('Beta features are optional. Cover scanning uses network, battery and metadata-cache space. Unsupported archives are skipped; complete remote CBZ downloads are never used for thumbnails.'),select_enabled=false}
   toggle('beta_header','Expanded information header (beta)')
   toggle('beta_thumbnails','Chapter thumbnails (beta)',function()if not s.beta_thumbnails then s.beta_auto_scan=false;if self.core.cancelDeepScan then self.core:cancelDeepScan()end end end)
   toggle('beta_auto_scan','Automatically deep scan home (beta)',function()if not s.beta_auto_scan and self.core.cancelDeepScan then self.core:cancelDeepScan()end;if s.beta_auto_scan then s.beta_thumbnails=true;if self.core.deepScan then self.core:deepScan({id=s.home,name=s.home},true)end end end)
  end
  return self:menu(tr(title or category),rows,{icons=true,multiline=true})
 end
 function Shelf:chooseBooksFolder()
  local path=self.core.storage.books_dir
  UI():show(require('ui/widget/pathchooser'):new{path=path,select_directory=true,show_files=false,onConfirm=function(chosen)self:runAction(function()local ok,err=self:moveBooks(chosen);if not ok then env.problem(err)end end)end})
 end
 function Shelf:moveBooks(path)
  if type(path)~='string'or path:sub(1,1)~='/'or path:find('[%z\r\n]')then return false,tr('Enter an absolute path')end
  if self:activeEntry()then return false,tr('Close the book first')end
  local dialog;local visible=false
  local function cancel()self.core.jobs:cancel('relocate')end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Moving documents…'),buttons={{{text=tr('Cancel'),callback=cancel}}}}
  dialog.onClose=function()cancel();return true end
  local ok,err=self.core:relocateBooks(path,function(done,why)
   if visible then UI():close(dialog)end;self.move_dialog=nil
   if done then self.settings.books_dir=self.core.storage.books_dir;self:saveSettings();env.message(tr('Document folder updated'))
   elseif why and why.code=='cancelled'then env.message(tr('Move cancelled; the original folder is kept.'))else env.problem(why)end
  end)
  if ok and self.core.relocating then visible=true;self.move_dialog=dialog;UI():show(dialog)end
  return ok,err
 end
 local oldMemory=Shelf.showMemory
 function Shelf:showMemory()
  local storage=self.core.storage
  if not storage.diskStats then return oldMemory(self)end
  local stats=storage:diskStats();local usage=self.core:cache():usage()
  local function bar(label,value,limit)return {label=label..': '..env.bytes(value)..(limit and ' / '..env.bytes(limit)or ''),value=limit and math.min(1,value/math.max(1,limit))or nil}end
  local bars={bar(tr('Disk used'),stats.total and stats.total-(stats.free or 0)or 0,stats.total),
   bar(tr('Temporary reading cache'),usage.auto,(self.settings.auto_mib or 3072)*1048576),bar(tr('Metadata cache'),usage.meta,(self.settings.meta_mib or 256)*1048576)}
  local header=require('gdriveshelf/browser').header{width=require('device').screen:getWidth(),title=tr('Storage and cache'),status=tr('Free space')..': '..env.bytes(stats.free),buttons={},bars=bars,close=function()close(self.memory_menu)end,back=function()close(self.memory_menu)end}
  local original=self.menu;self.menu=function(owner,title,rows,options)
   table.remove(rows,1);rows[#rows]={text=tr('Document folder')..': '..storage.books_dir,select_enabled=false}
   local menu=original(owner,title,rows,{header=header,perpage=7,multiline=true});owner.memory_menu=menu;return menu
  end
  local ok,err=xpcall(function()oldMemory(self)end,debug.traceback);self.menu=original;if not ok then error(err)end
 end
 local oldInit=Shelf.init
 function Shelf:init()
  oldInit(self);self.title='Google Drive Shelf'
  require('gdriveshelf/integration').install(self,shared)
 end
end
