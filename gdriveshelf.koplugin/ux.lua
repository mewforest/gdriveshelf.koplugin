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
  if s.jump_to_resume==nil then s.jump_to_resume=true end
  if s.light_threshold==nil then s.light_threshold=95 end
  if s.known_first==nil then s.known_first=true end
  if s.load_covers==nil then s.load_covers=true end
  if s.load_metadata==nil then s.load_metadata=true end
  if s.index_hours==nil then s.index_hours=24 end
  if s.info_header==nil then s.info_header=true end
  if s.local_covers==nil then s.local_covers=true end
  if s.hide_empty==nil then s.hide_empty=true end
  if s.index_enabled and not s.index_recursive_confirmed then s.index_enabled=false;s.index_needs_confirmation=true end
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
 function Shelf:toggleLightMode()
  local enabled=not self.settings.light_mode
  self.core:setLightMode(enabled)
  self:saveSettings()
  self:requestBrowserRefresh(false)
 end
 function Shelf:orderedEntries(entries)
  local folders,files={},{}
  local downloads
  self.folder_facts=self.folder_facts or {}
  for _,entry in ipairs(entries)do
   if entry.is_folder then
    local e={};for k,v in pairs(entry)do e[k]=v end
    local facts=self.folder_facts[e.id]
    if not facts then
     downloads=downloads or Catalog.downloadStats(self.core)
     facts={info=self.core:titleInfo(e.id),stats=self.core:folderStats(e.id,downloads)}
     self.folder_facts[e.id]=facts
    end
    local info,stats=facts.info,facts.stats
    e.drive_name=entry.name
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
  for _,entry in ipairs(self:orderedEntries(Metadata.visible(entries,self.settings.show_service,info.cover)))do
   local e=entry;local cached=self.core:cached(e.id)
   local summary
   if not e.is_folder then
    if self.core.chapterSummary then summary=self.core:chapterSummary(e)
    else summary=(self.core.state.summaries or {})[e.id]end
   end
   local name=self:chapterLabel(e,info)
   local cardTitle,cardDetails=name,nil
   if e.is_folder then
    name=(e.pinned and '★ 'or '')..name..(e.author and e.author~=''and '\n'..e.author or '')
    cardTitle=(e.pinned and '★ 'or '')..cardTitle
    if e.stats then
     local details={}
     if e.stats.empty then details[#details+1]=tr('Empty folder')else
      if e.stats.folders and e.stats.folders>0 then details[#details+1]=string.format(tr('%d folders'),e.stats.folders)end
      if e.stats.count and e.stats.count>0 then details[#details+1]=string.format(tr('%d files'),e.stats.count)end
     end
     if e.stats.bytes>0 then details[#details+1]=tr('Downloaded')..': '..env.bytes(e.stats.bytes)end
     if #details>0 then name=name..'\n'..table.concat(details,' · ')end
     cardDetails=e.stats.empty and tr('Empty folder')or nil
     if self.settings.title_sort=='drive_name' and e.drive_name~=e.name then
      cardDetails=e.drive_name
      name=name..'\n'..e.drive_name
     end
    end
   else
    if self.selection then name=(self.selection[e.id]and '☑ 'or '☐ ')..name
    elseif cached then name=(cached.pool=='offline'and '★ 'or '✓ ')..name end
    if summary and summary.status=='complete'then
     name=name..' · '..tr('Read')
    elseif self.settings.light_mode and not(self.folder_visit and self.folder_visit.detailed_progress)then
     if summary or self.opened_chapters and self.opened_chapters[e.id]then name=name..' · '..tr('Previously opened')end
    elseif summary and summary.percent then
     name=name..string.format(' · %d%%',math.floor(summary.percent*100+.5))
    end
    cardTitle=name
   end
   local thumb=not e.is_folder and((self.core.localCover and self.core:localCover(e))or(self.core.thumbnail and self.core:thumbnail(e)))
   local cover=e.is_folder and e.cover_path or (thumb and self.core.storage:exists(thumb.path)and thumb.path or nil)
   local stats=e.stats or {}
   local left,right,rightIcon
   if e.is_folder then
    if (stats.direct_downloaded or 0)>0 then
     left=tostring(stats.direct_downloaded)..' ('..env.bytes(stats.direct_bytes)..')'
    end
    if (stats.count or 0)>0 then
     right=tostring(stats.count)..(stats.total_bytes and ' ('..env.bytes(stats.total_bytes)..')' or '')
     rightIcon='appbar.pageview'
    elseif (stats.folders or 0)>0 then
     right=tostring(stats.folders)
     rightIcon='appbar.filebrowser'
    end
   elseif e.size then right=env.bytes(e.size)end
   if not(e.is_folder and self.settings.hide_empty~=false and stats.empty==true)then
   rows[#rows+1]={text=name,list_title=e.is_folder and cardTitle or nil,
    list_detail=e.is_folder and (name:match('^[^\n]+\n(.+)') or ''):gsub('\n',' · ') or nil,card_title=cardTitle,card_details=cardDetails,card_left=left,card_right=right,card_left_icon=left and 'move.down',card_right_icon=rightIcon,card_fallback=left and tr('Cache')..': '..left..(right and ' · '..right or '')or right,mandatory=not e.is_folder and e.size and env.bytes(e.size)or nil,entry=e,icon=e.is_folder and 'appbar.filebrowser'or 'appbar.pageview',icon_file=cover,cover=cover~=nil,folder_progress=e.folder_progress,
    callback=function()
     if self.selection and not e.is_folder then self.selection[e.id]=not self.selection[e.id];self:refreshBrowser()
     elseif e.is_folder then self:showFolder(e.id,offline)
     elseif Library.supported(e)then if self.folder_visit then self.folder_visit.user_paged=true end;self:openEntry(e)else self:fileActions(e)end
    end,hold_callback=function()if e.is_folder then self:folderActions(e)else self:fileActions(e)end end}
   end
  end
  if #rows==0 then
   local state=(self.core.state.listings or {})[parent]
   local text=self.browser_error and tr('Could not load this folder')or (self.browser_loading and tr('Loading folder…')or (state and state.complete and tr(#Metadata.visible(entries,self.settings.show_service)>0 and 'No items match the display settings'or 'This folder is empty')or tr('Folder contents are not cached')))
   rows[1]={text=text,select_enabled=false}
  end
  return rows
 end
 function Shelf:chapterLabel(entry,info)
  local title=not entry.is_folder and self.settings.load_metadata~=false and (info.chapters or {})[entry.name]
  if type(title)=='string' and title:find('%S')then return title end
  return entry.name
 end
 function Shelf:whenVisible(widget,resume)
  local manager=UI()
  local top=manager.getTopmostVisibleWidget and manager:getTopmostVisibleWidget()
  if not top or top==widget then return true end
  if resume then
   top._shelf_reveal=top._shelf_reveal or {}
   local listeners=top._shelf_reveal
   if not next(listeners)then
    local previous=top.onCloseWidget
    top.onCloseWidget=function(closing,...)
     closing.onCloseWidget=previous
     closing._shelf_reveal=nil
     if previous then previous(closing,...)end
     for _,callback in pairs(listeners)do manager:nextTick(callback)end
    end
   end
   listeners[widget]=resume
  end
  return false
 end
 function Shelf:requestBrowserRefresh(statusOnly)
  local menu=self.folder_menu
  if not menu or menu._closed then return end
  self.browser_pending=math.max(self.browser_pending or 0,statusOnly and 1 or 2)
  if self.browser_tick then return end
  self.browser_tick=true
  UI():nextTick(function()
   self.browser_tick=nil
   if self.folder_menu==menu and self.browser_pending then self:refreshBrowser(self.browser_pending==1)
   elseif self.browser_pending and self.folder_menu then self:requestBrowserRefresh(self.browser_pending==1)end
  end)
 end
 function Shelf:browserStatus()
  if self.browser_error then return tr('Could not load this folder')end
  local parts={};local state=self.core.networkState and self.core:networkState()or'online'
  local labels={offline='Offline mode',sleep='Waiting for the device to wake',retry='Waiting before retry',auth='Authorization is required'}
  if labels[state]then parts[#parts+1]=tr(labels[state])end
  if self.core.progress_job and self.core.progress_job.parent_id==self.folder_id then parts[#parts+1]=tr('Loading reading progress…')end
  if self.browser_loading then parts[#parts+1]=tr('Loading folder…')end
  if self.core.index_job then
   local j=self.core.index_job
   parts[#parts+1]=j.done>0 and string.format(tr('%d folders checked'),j.done) or tr('Checking folders…')
  end
  if self.core.deep_job then parts[#parts+1]=tr('Scanning covers…')end
  for _,d in pairs(self.core.state.downloads or {})do
   if d.entry.parent_id==self.folder_id and d.pool=='meta'then
    parts[#parts+1]=Metadata.isCoverName(d.entry.name)and tr('Loading cover…')or tr('Loading information…')
    break
   end
  end
  if #parts==0 then parts[1]=self.folder_offline and tr('Available offline')or 'Google Drive Shelf'end
  local listing=(self.core.state.listings or {})[self.folder_id]
  if self.settings.light_mode and listing and listing.checked_at then
   parts[#parts+1]=string.format(tr('Checked %s'),os.date('%d.%m %H:%M',listing.checked_at))
  end
  return table.concat(parts,' · ')
 end
 local function gridSize(value)
  if value=='2x2' then return 2,2 end
  if value=='2x3' then return 2,3 end
  if value=='3x3' then return 3,3 end
  return 3,2
 end
 function Shelf:browserPresentation(parent,entries)
  local info=self.core:titleInfo(parent)
  local folder=self.core.state.folders[parent]or{id=parent,name=parent,is_folder=true}
  local hasFolders,comics=false,0
  local count,total,downloaded,downloadedBytes=0,0,0,0
  for _,e in ipairs(entries or {})do
   if e.is_folder and not Metadata.isService(e)then hasFolders=true end
   if Library.supported(e)then
    count=count+1
    if total then total=tonumber(e.size) and total+tonumber(e.size) or nil end
    if Catalog.kind(e,self.core.state)=='comics'then comics=comics+1 end
    local cached=self.core:cached(e.id)
    if cached then downloaded=downloaded+1;downloadedBytes=downloadedBytes+(cached.size or 0)end
   end
  end
  local kind=(self.core.state.folder_types or {})[parent]
  local comic=kind=='comics' or (kind~='books' and parent~='root' and comics>0 and (info.cover_path or info.description or (not hasFolders and comics==count)))
  comic=not not comic
  local grid=(hasFolders and self.settings.folder_view~='list')or(not hasFolders and self.settings.file_view=='grid')
  local columns,rows=gridSize(hasFolders and self.settings.folder_grid or not hasFolders and self.settings.file_grid)
  local visit=self.folder_visit or {}
  local header=self.settings.info_header~=false and comic and not visit.collapsed
  local countText=count>0 and string.format(tr('%d files'),count)or nil
  if countText and total then countText=countText..' · '..env.bytes(total)end
  local downloadedText=downloaded>0 and string.format(tr('Downloaded %d (%s)'),downloaded,env.bytes(downloadedBytes))or nil
  local resume=visit.resume
  local conflict=self.core.metadataConflict and self.core:metadataConflict(folder)~=nil
  local signature=table.concat({
   tostring(parent),tostring(folder.parent_id),info.title or folder.name,header and(info.cover_path or '')or '',
   header and(info.description or '')or '',header and(countText or '')or '',header and(downloadedText or '')or '',tostring(header),tostring(comic),
   tostring(grid),tostring(hasFolders),columns,rows,tostring(self:downloadActivity()~=nil),tostring(conflict),
   tostring(resume and resume.entry and self:chapterLabel(resume.entry,info)),
   tostring(resume and resume.entry and resume.entry.id),tostring(resume and resume.resume),
   tostring(resume and resume.summary and resume.summary.status),tostring(resume and resume.remote_time),
   tostring(self.startup_loading),tostring(self.browser_loading and self.startup_loading)
  },'|')
  return {info=info,folder=folder,hasFolders=hasFolders,comic=comic,grid=grid,header=header,columns=columns,rows=rows,stats=countText,cached=downloadedText,conflict=conflict,signature=signature}
 end
 function Shelf:revealResume()
  local visit,menu=self.folder_visit,self.folder_menu
  if not visit or not menu or visit.user_paged or visit.restored_page or self.settings.jump_to_resume==false or not visit.resume or not visit.resume.entry then return end
  for i,row in ipairs(menu.item_table)do
   if row.entry and row.entry.id==visit.resume.entry.id then
    visit.restored_page=true
    local page=math.floor((i-1)/menu.perpage)+1
    self.automatic_page=true
    if menu.page~=page then menu:onGotoPage(page)end
    self.automatic_page=nil
    return
   end
  end
 end
 function Shelf:startFolderResume(cachedOnly)
  local visit=self.folder_visit
  if not visit or not self.core.resumeChapter then return end
  if not self:browserPresentation(self.folder_id,self.folder_entries).comic then visit.resume=nil;return end
  if cachedOnly then
   visit.resume=self.core:resumeChapter(self.folder_id,self.folder_entries,nil,true)
   return
  end
  if visit.resume_started then return end
  visit.resume_started=true
  visit.resume_serial=(visit.resume_serial or 0)+1
  local serial=visit.resume_serial
  visit.resume=self.core:resumeChapter(self.folder_id,self.folder_entries,function(result)
   if self.folder_visit~=visit or visit.resume_serial~=serial or not self.folder_menu then return end
   visit.resume=result
   self:requestBrowserRefresh(false)
  end,self.folder_offline)
  self:requestBrowserRefresh(false)
 end
 function Shelf:folderAnchor(menu)
  local first=((menu.page or 1)-1)*(menu.perpage or 7)+1
  local candidate=self.folder_visit and self.folder_visit.resume
  local firstEntry
  for i=first,math.min(#menu.item_table,first+menu.perpage-1)do
   local entry=menu.item_table[i].entry
   if entry then
    firstEntry=firstEntry or entry.id
    if candidate and candidate.entry and entry.id==candidate.entry.id then return {id=entry.id,index=i}end
   end
  end
  return {id=firstEntry,index=first}
 end
 function Shelf:restoreFolderAnchor(menu,anchor)
  if not anchor then return end
  local index=anchor.index
  for i,row in ipairs(menu.item_table)do
   if row.entry and row.entry.id==anchor.id then index=i;break end
  end
  local page=math.max(1,math.min(math.floor((index-1)/menu.perpage)+1,menu.page_num))
  if menu.page~=page then
   self.automatic_page=true
   menu:onGotoPage(page)
   self.automatic_page=nil
  end
 end
 function Shelf:requestFolder(visit,parent,force)
  local core=self.core
  local known=core.state.listings[parent] and core.state.listings[parent].complete
  self.browser_loading=not known and core:online()
  local folder=core.state.folders[parent]
  local pending=core:folder(parent,folder and folder.name or parent,function(entries,cached,err)
   if self.core~=core or self.folder_visit~=visit or not self.folder_menu then return end
   if cached then return end
   self.browser_loading,self.startup_loading=false,nil
   self.browser_error=err
   if entries then
    self.folder_generation=(self.folder_generation or 0)+1
    self.folder_entries=entries
    self.opened_chapters=self.settings.light_mode and Library.matchedSidecars(entries,parent)or nil
    self.folder_facts={}
    visit.resume_started=nil
    self:startFolderResume()
   end
   self:requestBrowserRefresh(false)
  end,force)
  if pending==false or not core:online()then
   self.browser_loading,self.startup_loading=false,nil
   self:startFolderResume()
   self:requestBrowserRefresh(false)
  end
  if self.settings.light_mode and core.reading_sync_due and core:online()then
   core.reading_sync_due=nil
   core:flushPending(true)
  end
 end
 function Shelf:refreshBrowser(statusOnly)
  local m=self.folder_menu
  if not m or m._closed then return end
  if not self:whenVisible(m,function()if self.browser_pending then self:requestBrowserRefresh(self.browser_pending==1)end end)then
   self.browser_pending=math.max(self.browser_pending or 0,statusOnly and 1 or 2)
   return
  end
  self.browser_pending=nil
  if self.browser_relist then
   self.browser_relist=nil
   self.folder_entries=self.folder_offline and self:offlineChildren(self.folder_id)or self.core:cachedList(self.folder_id)
   self.opened_chapters=self.settings.light_mode and Library.matchedSidecars(self.folder_entries,self.folder_id)or nil
   local visit=self.folder_visit
   if visit then
    local listing=self.core.state.listings[self.folder_id]
    if listing and listing.dirty and not self.folder_offline then
     if not(self.core.folder_waiters and self.core.folder_waiters[self.folder_id])then self:requestFolder(visit,self.folder_id)end
    else
     visit.resume_started=nil
     self:startFolderResume()
    end
   end
  end
  local activity=self:downloadActivity()
  if self.browser_activity_present~=(activity~=nil)then
   return self:showFolder(self.folder_id,self.folder_offline,false,true)
  end
  local status=self:browserStatus()
  if m.title_bar then
   if m._shelf_status~=status then m._shelf_status=status;m.title_bar:setSubTitle(status,not statusOnly)end
   if m.title_bar.setActivity then m.title_bar:setActivity(activity)end
  end
  if statusOnly then return end
  local view=self:browserPresentation(self.folder_id,self.folder_entries or {})
  if self.browser_header_signature~=view.signature then return self:showFolder(self.folder_id,self.folder_offline,false,true)end
  local anchor=self:folderAnchor(m)
  self:replaceMenu(m,self:folderRows(self.folder_id,self.folder_entries or {},self.folder_offline))
  self:restoreFolderAnchor(m,anchor)
  self:revealResume()
  local visit=self.folder_visit
  if not self.browser_loading and not(visit and visit.resume and visit.resume.waiting) then self:visibleProgress(m)end
 end
 function Shelf:showFolder(parent,offline,force,render_only,navigation)
  local core=self:getCore()
  if not offline and not self:hasCredentials()then return self:showConnectionSetup()end
  self.browser_positions=self.browser_positions or {}
  if self.folder_menu then
   self.browser_positions[self.folder_id]=self:folderAnchor(self.folder_menu)
   self.replacing_folder=render_only==true
   close(self.folder_menu)
   self.replacing_folder=nil
  end
  if not render_only then
   if self.folder_id~=parent then self.selection=nil end
   self.folder_id,self.folder_offline=parent,offline
   self.browser_pending,self.browser_relist,self.browser_error=nil,nil,nil
   self.browser_loading=not offline and not(core.state.listings[parent] and core.state.listings[parent].complete) and core:online()
   self.folder_entries=offline and self:offlineChildren(parent)or core:cachedList(parent)
   self.opened_chapters=self.settings.light_mode and Library.matchedSidecars(self.folder_entries,parent)or nil
   self.folder_facts={}
   self.folder_visit={restored_page=force or navigation=='home' or navigation=='back'}
   if navigation=='home'then self.browser_positions[parent]=nil end
   self:startFolderResume(true)
  end
  local visit=self.folder_visit or {}
  local view=self:browserPresentation(parent,self.folder_entries)
  local folder,info,hasFolders,grid=view.folder,view.info,view.hasFolders,view.grid
  self.browser_header_signature=view.signature
  local activity=self:downloadActivity()
  self.browser_activity_present=activity~=nil
  core.catalog_visible=true
  local function action(fn)return function()self:runAction(fn)end end
  local buttons={
   {icon='home',callback=action(function()self:showLibrary(true)end)},
   {icon_file=env.root..'/resources/icons/refresh.svg',callback=action(function()self:showFolder(parent,offline,true)end)},
   {icon_file=env.root..'/resources/icons/sort.svg',callback=action(function()self:showBrowserSort()end)},
   {icon='info',callback=action(function()self:showInfo(parent)end)},
   {icon_file=env.root..'/resources/icons/actions.svg',callback=action(function()self:showFolderActions(parent,offline)end)},
  }
  table.insert(buttons,4,{icon_file=env.root..'/resources/icons/'..(grid and 'list'or 'grid')..'.svg',callback=action(function()
   local key=hasFolders and 'folder_view'or 'file_view'
   self.settings[key]=grid and 'list'or 'grid'
   self:saveSettings()
   self:showFolder(parent,offline,false,true)
  end)})
  for _,button in ipairs(buttons)do if button.icon_file then button.icon='appbar.pageview'end end
  local screen=require('device').screen
  local summary
  if view.header then
   summary={cover_path=info.cover_path,text=info.title or folder.name,description=info.description,stats=view.stats,cached=view.cached,height=math.floor(screen:getHeight()*.30)}
  end
  local resume=visit.resume
  local resumeButton
  if view.header and resume and resume.entry then
   local target=resume.entry
   local label=self:chapterLabel(target,info)
   local history=(core.state.history or {})[target.id]
   local opened=tonumber(history and history.time) or 0
   local date
   if opened>0 then
    date=string.format(tr('Last opened: %s'),os.date('%d.%m %H:%M',opened))
   elseif resume.remote_time and resume.remote_time>0 then
    date=string.format(tr('Progress updated: %s'),os.date('%d.%m %H:%M',resume.remote_time))
   end
   if resume.summary and resume.summary.status=='complete'then label=label..' · '..tr('Read')end
   resumeButton={text=tr(resume.resume and 'Continue'or 'Read chapter'),detail=label,date=date,
    enabled=true,callback=action(function()
     visit.user_paged=true
     self:openEntry(target,resume.resume)
    end)}
  end
  local function back()
   if folder.parent_id then self:showFolder(folder.parent_id,offline,nil,nil,'back')
   else close(self.folder_menu)end
  end
  local status=self:browserStatus()
  local header=require('gdriveshelf/browser').header{
   width=screen:getWidth(),title=info.title or folder.name,status=status,buttons=buttons,summary=summary,activity=activity,resume=resumeButton,
   hint=parent=='root' and not offline and self.homeFolderHint and self:homeFolderHint() or nil,
   hint_callback=action(function()self:chooseHomeFolder()end),
   brand=self.browser_loading and self.startup_loading and env.root..'/resources/logo.png' or nil,
   collapse=self.settings.info_header~=false and view.comic and action(function()
    visit.collapsed=not visit.collapsed
    self:showFolder(parent,offline,false,true)
   end)or nil,collapsed=visit.collapsed,
   conflict=view.conflict and action(function()self:showMetadataConflict(folder)end)or nil,
   activity_callback=action(function()self:showQueue()end),
   back=action(back),close=function()close(self.folder_menu)end,info=action(function()self:showInfo(parent)end)}
  local menu=self:menu(info.title or folder.name,self:folderRows(parent,self.folder_entries,offline),{
   icons=not grid,grid=grid,decorated=not grid,columns=view.columns,header=header,perpage=grid and view.columns*view.rows or 7,multiline=true,
   lazy=true,defer_lazy=true,parent_enabled=folder.parent_id~=nil,
   close=function()if not self.replacing_folder then core.catalog_visible=false end end})
  self.folder_menu=menu
  menu._shelf_status=status
  menu.onClose=function()back();return true end
  menu.onReturn=menu.onClose
  self:restoreFolderAnchor(menu,self.browser_positions[parent])
  self:revealResume()
  if render_only and not self.browser_loading and not(visit.resume and visit.resume.waiting)then self:visibleProgress(menu)end
  if not offline and not render_only then self:requestFolder(visit,parent,force)end
  return self.folder_menu
 end
 function Shelf:showBrowserSort()
  local menu
  menu=self:menu(tr('Sorting'),{
   {icon='appbar.filebrowser',text=tr('Folder sorting'),callback=function()close(menu);self:showTitleSort()end},
   {icon='appbar.pageview',text=tr('File sorting'),callback=function()close(menu);self:showFileSort()end},
  },{icons=true})
  return menu
 end
 function Shelf:showFolderActions(parent,offline)
  local folder=self.core.state.folders[parent]or{id=parent,name=parent,is_folder=true}
  local menu
  local rows={
   {icon='appbar.filebrowser',text=tr('Actions for this folder'),callback=function()close(menu);self:folderActions(folder)end},
   {icon='cre.render.reload',text=tr('Refresh folder listing and metadata'),callback=function()close(menu);self:showFolder(parent,offline,true)end},
   {icon_file=env.root..'/resources/icons/history.svg',text=tr('History'),callback=function()self:showHistory()end},
   {icon_file=env.root..'/resources/icons/select-files.svg',text=tr('Select files to keep offline'),callback=function()close(menu);self.selection=self.selection or {};self:refreshBrowser();self:showSelectionActions()end},
   {icon_file=env.root..'/resources/icons/offline-books.svg',text=tr('Available offline'),callback=function()close(menu);self:showOffline()end},
   {icon_file=env.root..'/resources/icons/queue.svg',text=tr('Downloads and sync'),callback=function()self:showQueue()end},
   {icon='column.three',text=tr('Storage and cache'),callback=function()self:showMemory()end},
   {icon='appbar.settings',text=tr('Settings'),callback=function()self:showSettings()end},
   {icon='info',text=tr('About Google Drive Shelf'),callback=function()self:showAbout()end},
  }
  if self.settings.index_enabled then
   table.insert(rows,3,{icon='cre.render.reload',text=tr('Library indexing'),callback=function()self:showIndexScreen()end})
  end
  if self.core.loadFolderProgress then
   table.insert(rows,3,{icon_file=env.root..'/resources/icons/reading-progress.svg',text=tr('Load detailed progress for all chapters'),callback=function()
    close(menu)
    self:showFolderProgress(parent,self.folder_entries)
   end})
  end
  if offline and self.offline_all_link==parent then
   table.insert(rows,2,{icon_file=env.root..'/resources/icons/offline-books.svg',text=tr('All offline downloads'),callback=function()
    close(menu);self:showOffline(true)
   end})
  end
  menu=self:menu(tr('Folder actions'),rows,{icons=true})
  return menu
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
 function Shelf:folderActions(folder)
  local menu
  local pinned=(self.core.state.folder_pins or {})[folder.id]
  local kind=(self.core.state.folder_types or {})[folder.id]or'auto'
  local rows={
   {icon='bookmark',text=pinned and tr('Unpin from top')or tr('Pin to top'),callback=function()
    self.core.state.folder_pins[folder.id]=not pinned
    self.core:save()
    close(menu)
    self:requestBrowserRefresh(false)
   end},
   {icon='home',text=tr('Set as home folder'),callback=function()
    self.settings.home=folder.id
    self:saveSettings()
    close(menu)
    env.message(tr('Home folder saved'))
   end},
   {icon_file=env.root..'/resources/icons/download-folder.svg',text=tr('Download folder (including subfolders)'),callback=function()close(menu);self:queueFolderDownload(folder)end},
   {icon='close',text=tr('Remove downloads from this folder and subfolders'),callback=function()close(menu);self:removeTree(folder.id)end},
   {icon='info',text=tr('Information'),callback=function()self:showInfo(folder.id)end},
   {icon='cre.render.reload',text=tr('Refresh folder listing and metadata'),callback=function()close(menu);self:showFolder(folder.id,false,true)end},
   {icon='appbar.pageview',text=tr('Change content type')..' · '..tr(kind),callback=function()
    local choiceMenu
    local choices={}
    for _,option in ipairs{'auto','comics','books'}do
     local value=option
     choices[#choices+1]={text=(kind==value and '✓ 'or '')..tr(value),callback=function()
      self.core.state.folder_types[folder.id]=value
      self.core:save()
      close(choiceMenu);close(menu)
      self:requestBrowserRefresh(false)
     end}
    end
    choiceMenu=self:menu(tr('Change content type'),choices)
   end},
   {icon='edit',text=tr('Edit folder information'),callback=function()close(menu);self:editFolderMetadata(folder)end},
  }
  if self.core.metadataConflict and self.core:metadataConflict(folder)then
   rows[#rows+1]={icon='info',text=tr('Folder metadata conflict'),callback=function()close(menu);self:showMetadataConflict(folder)end}
  end
  if self.settings.beta_thumbnails then
   rows[#rows+1]={icon='appbar.pageview',text=tr('Deep scan covers (beta)'),callback=function()
    close(menu)
    if not self.core:deepScan(folder)then env.message(tr('Go online to scan covers.'))end
   end}
  end
  menu=self:menu(folder.name,rows,{icons=true})
  return menu
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
  local menu
  local rows={}
  local labels={natural='Natural name order',name='Name',drive_name='Original folder name on Drive',read='Last opened (newest first)',added='Date added (newest first)',size='Downloaded size'}
  local function save()
   self:saveSettings()
   close(menu)
   self:requestBrowserRefresh(false)
  end
  for _,mode in ipairs{'natural','name','read','added','size','drive_name'}do
   local value=mode
   rows[#rows+1]={text=((self.settings.title_sort or 'natural')==mode and '✓ 'or '')..tr(labels[mode]),callback=function()self.settings.title_sort=value;save()end}
  end
  rows[#rows+1]=checked(self.settings,'title_reverse','Reverse order',function()self.settings.title_reverse=not self.settings.title_reverse;save()end)
  menu=self:menu(tr('Folder sorting'),rows)
  return menu
 end
 function Shelf:showGridSizes(key,label)
  local menu
  local rows={}
  for _,size in ipairs{'2x2','2x3','3x2','3x3'}do
   local choice=size
   rows[#rows+1]={text=((self.settings[key]or'3x2')==choice and '✓ 'or '')..choice:gsub('x',' × '),callback=function()
    self.settings[key]=choice
    self:saveSettings()
    close(menu)
    self:requestBrowserRefresh(false)
   end}
  end
  menu=self:menu(tr(label),rows)
  return menu
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
 function Shelf:openEntry(entry,resume)
  if shared.requests and shared.requests.core~=self.core then shared.requests:cancel(true);shared.requests=nil end
  shared.requests=shared.requests or Requests.new(self.core)
  if self.download_dialog and self.download_dialog.entry.id==entry.id then return end
  if self.download_dialog then
   local previous=self.download_dialog
   self.download_dialog=nil
   shared.requests:cancel(true)
   UI():close(previous.widget)
  end
  local cached=self.core:cached(entry.id)
  local dialog
  local function finish(path,err)
   self.download_dialog=nil
   self._end_dialog=nil
   if dialog then UI():close(dialog)end
   if not path then env.problem(err);return end
   self:openDownloadedEntry(entry,resume,path)
  end
  if not cached then
   if self.core.completed_downloads then self.core.completed_downloads[entry.id]=nil end
   self.core.background_downloads=self.core.background_downloads or {}
   self.core.background_downloads[entry.id]=nil
   local function dismiss(background)
    if background then self.core.background_downloads[entry.id]=true end
    shared.requests:cancel(not background)
    self.download_dialog=nil
    self._end_dialog=nil
    UI():close(dialog)
    self:requestBrowserRefresh(true)
   end
   dialog=self:transferDialog(entry,{
    {text=tr('Cancel'),callback=function()dismiss(false)end},
    {text=tr('In background without opening'),callback=function()dismiss(true)end},
   })
   dialog.onClose=function()dismiss(false);return true end
   self.download_dialog={widget=dialog,entry=entry}
   UI():show(dialog)
  end
  shared.requests:start(entry,finish)
 end
 function Shelf:downloadSummary(entry,now)
  local value=(self.core.transfer or {})[entry.id]or {}
  local state=self.core.networkState and self.core:networkState()or'online'
  local label=({retry='Waiting before retry',sleep='Waiting for the device to wake',offline='Offline mode',auth='Authorization is required'})[state]
  label=label or (value.stage=='complete'and 'Checking document…'or 'Downloading')
  local total=tonumber(value.total or entry.size)
  local received=value.received or 0
  local percent=total and total>0 and math.max(0,math.min(1,received/total))or nil
  local text=env.bytes(received)
  if percent then text=text..' / '..env.bytes(total)..string.format(' · %d%%',math.floor(percent*100))end
  local elapsed=value.started and math.max(0,(value.sampled or now or os.time())-value.started)
  if elapsed and elapsed>=1 then
   text=text..' · '..string.format(tr('%s elapsed'),self:transferDuration(elapsed))
   if state=='online' and value.stage~='complete' and percent and percent>0 and percent<1 and elapsed>=3 and (value.samples or 0)>=2 then
    text=text..' · '..string.format(tr('about %s left'),self:transferDuration(elapsed*(1-percent)/percent))
   end
  end
  return tr(label),text,percent
 end
 function Shelf:transferDuration(seconds)
  seconds=math.floor(seconds+.5)
  if seconds<60 then return string.format(tr('%d s'),seconds)end
  if seconds<3600 then return string.format(tr('%d min %02d s'),math.floor(seconds/60),seconds%60)end
  return string.format(tr('%d h %02d min'),math.floor(seconds/3600),math.floor(seconds/60)%60)
 end
 function Shelf:downloadTitle(entry)
  local stage,detail=self:downloadSummary(entry)
  return stage..'\n'..entry.name..'\n'..detail
 end
 function Shelf:transferDialog(entry,buttons)
  local dialog=require('ui/widget/buttondialog'):new{title=self:downloadTitle(entry),buttons={buttons}}
  local _,_,percent=self:downloadSummary(entry)
  if percent then
   local bar=require('ui/widget/progresswidget'):new{width=dialog:getAddedWidgetAvailableWidth(),
    height=require('device').screen:scaleBySize(8),bordersize=1,radius=0,percentage=percent,not_focusable=true,parent=dialog}
   dialog:addWidget(bar)
   dialog._transfer_bar=bar
  end
  return dialog
 end
 function Shelf:updateReaderTransfer(entry)
  local footer=self.ui and self.ui.view and self.ui.view.footer
  local active=self:activeEntry()
  if not self.settings.reader_prefetch_status or not footer or not footer.addAdditionalFooterContent or not active then
   return self:clearReaderTransfer()
  end
  local nextChapter=self.core:next(active)
  local value=nextChapter and (self.core.transfer or {})[nextChapter.id]
  if entry and nextChapter and entry.id~=nextChapter.id then return end
  if not value then return self:clearReaderTransfer()end
  local total=tonumber(value.total)
  local label=tr('Downloading next chapter')
  local line=total and total>0 and label..' · '..math.min(100,math.floor(value.received/total*100))..'%' or label
  if not self._reader_transfer then
   self._reader_transfer={footer=footer,initial=footer.settings and footer.settings.additional_content}
   local state=self._reader_transfer
   state.render=function()return state.text end
   footer:addAdditionalFooterContent(state.render)
  end
  if self._reader_transfer.text~=line then
   self._reader_transfer.text=line
   if footer.onRefreshAdditionalContent then footer:onRefreshAdditionalContent()end
  end
 end
 function Shelf:clearReaderTransfer()
  local state=self._reader_transfer
  if not state then return end
  self._reader_transfer=nil
  state.footer:removeAdditionalFooterContent(state.render)
  if state.initial and state.footer.settings then state.footer.settings.additional_content=true end
  if state.footer.maybeUpdateFooter then state.footer:maybeUpdateFooter()end
 end
 local statusEvents={transfer=true,network_state=true,queued=true,download=true,indexing=true,progress_state=true,scanning=true,folder_scanning=true,relocating=true,sync_error=true}
 function Shelf:onCoreChange(kind,entry,err)
  if self.folder_menu and not self.folder_menu._closed then
   local statusOnly=statusEvents[kind]
   if kind=='indexed' or kind=='light_mode'then self.browser_relist=true end
   if kind=='light_mode'then self.folder_menu._lazy_signature=nil end
   if not statusOnly and self.folder_facts then
    if kind=='indexed' or not entry then
     self.folder_facts={}
    else
     local id=entry.is_folder and entry.id or entry.parent_id or entry.id
     local seen={}
     while id and not seen[id]do
      seen[id]=true
      self.folder_facts[id]=nil
      local folder=self.core.state.folders[id]
      id=folder and folder.parent_id
     end
    end
   end
   self:requestBrowserRefresh(statusOnly)
  end
  local q=self.queue_menu
  local now=os.time()
  if q and not q._closed and not self.queue_tick and (kind~='transfer' or self.queue_painted~=now) and self:whenVisible(q,function()if self.queue_menu==q and not q._closed then self:showQueue()end end)then
   self.queue_tick=true
   UI():nextTick(function()
    self.queue_tick=nil
    if self.queue_menu==q and not q._closed and self:whenVisible(q)then self.queue_painted=now;self:showQueue()end
   end)
  end
  local d=self.download_dialog or self.cover_download or self.queue_download
  if (kind=='transfer' or kind=='network_state')and d and (not entry or entry.id==d.entry.id)then
   local function paint()
    if self.download_dialog~=d and self.cover_download~=d and self.queue_download~=d then return end
    if kind=='transfer' then
     if d.updated==now then return end
     d.updated=now
    end
    local title=self:downloadTitle(d.entry)
    local _,_,percent=self:downloadSummary(d.entry)
    if d.widget._transfer_bar and percent then d.widget._transfer_bar:setPercentage(percent)end
    if d.widget.title~=title then d.widget:setTitle(title)end
   end
   if self:whenVisible(d.widget,paint)then paint()end
  end
  if self.updateIndexScreen then self:updateIndexScreen(kind,err)end
  if self.updateFolderProgressScreen then self:updateFolderProgressScreen(kind,err)end
  if kind=='folder_scanning'and self.scan_dialog and self.core.folder_scan and self:whenVisible(self.scan_dialog)then
   self.scan_dialog:setTitle(tr('Checking folder contents…')..' '..self.core.folder_scan.done)
  end
  if kind=='relocating'and self.move_dialog and err and self:whenVisible(self.move_dialog)then self.move_dialog:setTitle(tr('Moving documents…')..' '..err.received..' / '..tostring(err.total or '?'))end
  if kind=='download' or kind=='transfer' or kind=='downloaded' or kind=='error'then self:updateReaderTransfer(entry)end
  if kind=='downloaded' and entry and self.core.background_downloads and self.core.background_downloads[entry.id] then
   self.core.background_downloads[entry.id]=nil
   self.core.completed_downloads=self.core.completed_downloads or {}
   self.core.completed_downloads[entry.id]=entry
   local core=self.core
   UI():nextTick(function()
    if self.core~=core or core.retired or not core.completed_downloads[entry.id]then return end
    self:actionNotification(string.format(tr('Downloaded %s'),entry.name),function()
     if self.core==core and core:cached(entry.id)then core.completed_downloads[entry.id]=nil;self:openEntry(entry)end
    end,tr('Open'))
   end)
  end
  if kind=='conflict' and entry then self:notifyProgressConflict(entry)end
  if kind=='sync_resolved' and entry and err and err.choice=='local' and (err.action=='pushed' or err.action=='same')then
   self:notifyProgressSynced(entry)
  end
 end
 function Shelf:showSettings()
  local menu
  local rows={
   checked(self.settings,'offline','Offline mode',function()self.core:setOffline(not self.settings.offline);self:saveSettings();close(menu);self:showSettings()end),
   checked(self.settings,'light_mode','Light mode (less background work)',function()self:toggleLightMode();close(menu);self:showSettings()end),
  }
  for _,category in ipairs{
   {'connection','wifi.secure.100','Connection and startup'}, {'catalog','appbar.filebrowser','Catalog and appearance'},
   {'downloads','column.three','Downloads and storage'}, {'reading','bookmark','Reading and sync'},
   {'experimental','appbar.tools','Experimental'},
  }do local id=category[1];rows[#rows+1]={icon=category[2],text=tr(category[3]),callback=function()self:showSettingsCategory(id)end}end
  rows[#rows+1]={icon='info',text=tr('About Google Drive Shelf'),callback=function()self:showAbout()end}
  menu=self:menu(tr('Google Drive Shelf settings'),rows,{icons=true})
  return menu
 end
 function Shelf:showSettingsCategory(category)
  local s=self.settings;local rows={};local title,menu
  local function reopen()close(menu);self:showSettingsCategory(category)end
  local function toggle(key,label,after)
   rows[#rows+1]=checked(s,key,label,function()s[key]=not s[key];self:saveSettings();if after then after()end;reopen()end)
  end
  local function number(key,label,lo,hi)
   rows[#rows+1]={text=tr(label)..': '..tostring(s[key]or 0),callback=function()self:input(tr(label),s[key]or 0,function(value)
    local n=tonumber(value);if not n or n~=math.floor(n)or n<lo or n>hi then return false,tr('Invalid value')end
    s[key]=n;self:saveSettings();return true
   end,'number')end}
  end
  if category=='connection'then
   title='Connection and startup'
   rows=self:connectionRows(function()if menu and not menu._closed then reopen()end end)
  elseif category=='catalog'then
   title='Catalog and appearance'
   rows={
    {icon='appbar.filebrowser',text=tr('Folder sorting'),callback=function()self:showTitleSort()end},
    {icon='appbar.pageview',text=tr('File sorting'),callback=function()self:showFileSort()end},
    {text=tr('Folder view')..': '..tr(s.folder_view or 'grid'),callback=function()s.folder_view=s.folder_view~='list'and 'list'or 'grid';self:saveSettings();reopen()end},
   }
   rows[#rows+1]={text=tr('Folder grid size')..' · '..(s.folder_grid or '3x2'),callback=function()self:showGridSizes('folder_grid','Folder grid size')end}
   rows[#rows+1]={text=tr('Chapter grid size')..' · '..(s.file_grid or '3x2'),callback=function()self:showGridSizes('file_grid','Chapter grid size')end}
   toggle('jump_to_resume','Go to the chapter page when opening a folder')
   toggle('known_first','Show known folders first');toggle('load_covers','Download folder covers');toggle('load_metadata','Download descriptive metadata');toggle('show_service','Show service files')
   toggle('hide_empty','Hide empty folders');toggle('info_header','Comic folder information header');toggle('local_covers','Create covers for downloaded documents')
   rows[#rows+1]=checked(s,'index_enabled','Index home folder recursively',function()
    if s.index_enabled then s.index_enabled=false;self.core:cancelIndex();self:saveSettings();reopen()else self:enableRecursiveIndex()end
   end)
   rows[#rows+1]={icon='cre.render.reload',text=tr('Refresh home catalog now'),callback=function()
    UI():show(self:confirmation{text=tr('Check the home folder and fetch recent Drive changes? Saved files and reading progress will be kept.'),
     ok_text=tr('Refresh'),ok_callback=function()close(menu);self:showFolder(s.home or 'root',false,'home')end})
   end}
   rows[#rows+1]={icon='cre.render.reload',text=tr('Reindex library'),callback=function()self:reindexLibrary()end}
  elseif category=='downloads'then
   title='Downloads and storage'
   rows={
    {icon='column.three',text=tr('Storage and cache'),callback=function()self:showMemory()end},
    {icon='appbar.filebrowser',text=tr('Document folder'),callback=function()self:showDocumentFolder()end},
   }
  elseif category=='reading'then
   title='Reading and sync'
   number('prefetch','Chapters to prefetch',0,3);number('threshold','Prefetch threshold, %',0,100)
   toggle('immediate','Prefetch immediately after opening');toggle('prefetch_books','Prefetch the next ordinary book')
   number('light_prefetch','Chapters to prefetch in light mode',0,3)
   number('light_threshold','Light mode prefetch threshold, %',0,100)
   toggle('reader_prefetch_status','Show next-chapter download in reader')
   toggle('sync_enabled','Sync reading progress (.sdr)',function()if s.sync_enabled then self.core:flushPending()end end)
   rows[#rows+1]={icon='info',text=tr('How progress sync works'),callback=function()
    env.message(tr('Progress can be stored beside books or centrally in KOReader. Cloud sync exports native .sdr data to the Drive folder, visible to everyone with access. With sync disabled, reading stays local.'))
   end}
   local modes={farthest='Farthest position',freshest='More recent position',manual='Choose manually'}
   rows[#rows+1]={icon='info',text=tr('Progress conflicts')..' · '..tr(modes[s.sync_conflict_policy] or modes.farthest),callback=function()
    local options,picker={}
    for _,mode in ipairs{'farthest','freshest','manual'}do
     options[#options+1]={text=tr(modes[mode]),checked=(s.sync_conflict_policy or 'farthest')==mode,callback=function()
      s.sync_conflict_policy=mode;self:saveSettings();close(picker);reopen()
     end}
    end
    picker=self:menu(tr('Progress conflicts'),options,{icons=true,back=true})
   end}
   rows[#rows+1]={icon_file=env.root..'/resources/icons/queue.svg',text=tr('Downloads and sync'),callback=function()self:showQueue()end}
  elseif category=='experimental'then
   title='Experimental'
   rows[#rows+1]={text=tr('Beta features are optional. Cover scanning uses network, battery and metadata-cache space. Unsupported archives are skipped; complete remote CBZ downloads are never used for thumbnails.'),select_enabled=false}
   toggle('beta_quick_preview','Quick CBZ preview')
   toggle('beta_thumbnails','Chapter thumbnails (beta)',function()if not s.beta_thumbnails then s.beta_auto_scan=false;if self.core.cancelDeepScan then self.core:cancelDeepScan()end end end)
   toggle('beta_auto_scan','Automatically deep scan home (beta)',function()if not s.beta_auto_scan and self.core.cancelDeepScan then self.core:cancelDeepScan()end;if s.beta_auto_scan then s.beta_thumbnails=true;if self.core.deepScan then self.core:deepScan({id=s.home,name=s.home},true)end end end)
   rows[#rows+1]={text=tr('Automatic scan interval')..': '..tostring(s.index_hours or 24)..' '..tr('hours'),callback=function()
    local choices={};for _,hours in ipairs{1,6,24,72,168}do local value=hours;choices[#choices+1]={text=tostring(hours)..' '..tr('hours'),callback=function()s.index_hours=value;self:saveSettings()end}end;self:menu(tr('Automatic scan interval'),choices)
   end}
  end
  menu=self:menu(tr(title or category),rows,{icons=true,multiline=true,back=true})
  if category=='connection'then self.connection_settings=menu end
  return menu
 end
 function Shelf:chooseBooksFolder(after)
  local path=self.core.storage.books_dir
  UI():show(require('ui/widget/pathchooser'):new{path=path,select_directory=true,show_files=false,onConfirm=function(chosen)self:runAction(function()local ok,err=self:moveBooks(chosen,after);if not ok then env.problem(err)end end)end})
 end
 function Shelf:moveBooks(path,after)
  if type(path)~='string'or path:sub(1,1)~='/'or path:find('[%z\r\n]')then return false,tr('Enter an absolute path')end
  if self:activeEntry()then return false,tr('Close the book first')end
  if self.core.archive_removal then return false,tr('Wait for the current storage operation to finish.')end
  local dialog;local visible=false
  local function cancel()self.core.jobs:cancel('relocate')end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Moving documents…'),buttons={{{text=tr('Cancel'),callback=cancel}}}}
  dialog.onClose=function()cancel();return true end
  local ok,err=self.core:relocateBooks(path,function(done,why)
   if visible then UI():close(dialog)end;self.move_dialog=nil
   if done then self.settings.books_dir=self.core.storage.books_dir;self:saveSettings();if after then after()end;env.message(tr('Document folder updated'))
   elseif why and why.code=='cancelled'then env.message(tr('Move cancelled; the original folder is kept.'))else env.problem(why)end
  end)
  if ok and self.core.relocating then visible=true;self.move_dialog=dialog;UI():show(dialog)end
  return ok,err
 end
 local oldResume=Shelf.onResume
 function Shelf:onResume(...)
  if oldResume then oldResume(self,...)end
  if self.core and self.core.catalog_visible and not self.settings.light_mode and self.core.catalogRefresh then self.core:catalogRefresh(false)end
 end
 local oldInit=Shelf.init
 function Shelf:init()
  oldInit(self);self.title='Google Drive Shelf'
  require('gdriveshelf/integration').install(self,shared)
 end
end
