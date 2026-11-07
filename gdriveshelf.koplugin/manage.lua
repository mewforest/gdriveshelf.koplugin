-- Local archive management and account settings. Index and reading data stay
-- outside the archive selection, even when both cache pools are selected.
local M={}
local tr=require('gdriveshelf/i18n').gettext
local F=require('gdriveshelf/i18n').format
local accountKeys={'home','books_dir','index_enabled','index_recursive_confirmed','index_needs_confirmation'}
function M.accountHome(settings,account)
 if not settings.home_account then settings.home_account=account;return true end
 if settings.home_account==account then return false end
 local homes=settings.account_homes or {}
 local previous={}
 for _,key in ipairs(accountKeys)do previous[key]=settings[key]end
 homes[settings.home_account]=previous
 local target=homes[account]or {}
 for _,key in ipairs(accountKeys)do settings[key]=target[key]end
 settings.home=settings.home or 'root'
 settings.account_homes,settings.home_account=homes,account
 return true
end

function M.inBranch(folders,id,parent)
 local seen={}
 while id and not seen[id]do
  if id==parent then return true end
  seen[id]=true
  local folder=folders[id];id=folder and folder.parent_id
 end
 return false
end
local function isArchive(entry)return entry.pool=='auto' or entry.pool=='offline'end
local function target(id,entry,size)
 return {id=id,path=entry.path,pool=entry.pool,size=size or entry.size or 0,
  parent_id=entry.parent_id,name=entry.name or id}
end
function M.inventory(core)
 local groups={}
 local registry=core.storage:bookRegistry()
 for id,entry in pairs(core.state.entries)do
  if entry.ready and isArchive(entry)then
   local owned,attr=core.storage:managedPath(entry,registry)
   if owned and attr then
    local parent=entry.parent_id or 'root'
    local group=groups[parent]
    if not group then
     local folder=core.state.folders[parent]
     group={id=parent,name=folder and folder.name or tr('Google Drive'),entries={},size=0}
     groups[parent]=group
    end
    local item=target(id,entry,attr.size)
    group.entries[#group.entries+1]=item;group.size=group.size+item.size
   end
  end
 end
 local function larger(a,b)
  if a.size~=b.size then return a.size>b.size end
  return a.id<b.id
 end
 local result={}
 for _,group in pairs(groups)do table.sort(group.entries,larger);result[#result+1]=group end
 table.sort(result,larger)
 return result
end
local function targetsInPool(core,pool)
 local entries={}
 for id,entry in pairs(core.state.entries)do
  if entry.ready and (entry.pool==pool or (not pool and isArchive(entry)))then
   entries[#entries+1]=target(id,entry)
  end
 end
 return entries
end
function M.remove(core,targets,schedule,done)
 if core.archive_removal then return false end
 local registry
 local result={removed=0,skipped=0,failed=0}
 core.archive_removal=result
 local index=1
 local function step()
  local ids={}
  local protected=core:protected()
  for i=index,math.min(index+11,#targets)do
   local item=targets[i]
   local entry=core.state.entries[item.id]
   if not entry or protected[item.id] or entry.path~=item.path or entry.pool~=item.pool then
    result.skipped=result.skipped+1
   else
    if isArchive(entry) and not registry then registry=core.storage:bookRegistry()or {}end
    local owned=core.storage:managedPath(entry,registry)
    if owned then ids[#ids+1]=item.id else result.skipped=result.skipped+1 end
   end
  end
  core:evict(ids,true)
  for _,id in ipairs(ids)do
   if core.state.entries[id]then result.failed=result.failed+1 else result.removed=result.removed+1 end
  end
  index=index+12
  if index<=#targets then schedule(step);return end
  core.archive_removal=nil
  if result.removed>0 then
   local ok=core:save()
   if not ok then result.save_failed=true end
   core:emit('cleared')
  end
  done(result)
 end
 schedule(step)
 return true
end
function M.storageStats(core)
 local storage=core.storage
 local total=storage:treeSize(storage.root..'/snapshots')
 local docsettings=require('docsettings')
 local locations={'doc','dir'}
 if not docsettings.isHashLocationEnabled or docsettings.isHashLocationEnabled()then locations[3]='hash'end
 local seen={}
 for id,entry in pairs(core.state.docs)do
  local cached=core.state.entries[id]
  local path=cached and cached.path or entry.local_path
  if path then
   for _,location in ipairs(locations)do
    local dir=docsettings:getSidecarDir(path,location)
    if dir and dir~=''and not seen[dir]then
     seen[dir]=true
     total=total+storage:treeSize(dir)
    end
   end
  end
 end
 return {disk=storage:diskStats(),usage=core:cache():usage(),progress=total,index=storage:size(core.index_path)}
end

function M.install(Shelf,env)
 local function UI()return require('ui/uimanager')end
 local function close(widget)if widget and not widget._closed then UI():close(widget)end end
 local function schedule(fn)UI():scheduleIn(.01,fn)end
 local labels={auto='Temporary reading cache',offline='Offline downloads',meta='Covers, listings and metadata'}
 local actions={auto='Clear temporary reading cache',offline='Remove offline downloads',meta='Clear covers and metadata'}
 local function measure(core,key,work,done)
  return core.jobs:enqueue(key,work,done,true,nil,nil,true,{timeout=30})
 end
 function Shelf:confirmManagedRemoval(targets,finished)
  local core=self.core
  if #targets==0 then env.message(tr('No downloaded files'));return end
  local size=0
  for _,entry in ipairs(targets)do size=size+(tonumber(entry.size)or 0)end
  UI():show(self:confirmation{text=F('Remove %d cached files (%s)?\nOpen files, progress and sync queues are kept.',#targets,env.bytes(size)),
   ok_text=tr('Remove'),ok_callback=function()
    if self.core~=core then return end
    self:runManagedRemoval(core,targets,finished)
   end})
 end
 function Shelf:runManagedRemoval(core,targets,finished)
  if core.relocating or core.archive_removal then env.message(tr('Wait for the current storage operation to finish.'));return end
  local notice=require('ui/widget/infomessage'):new{text=tr('Removing cached files…')}
  UI():show(notice)
  M.remove(core,targets,schedule,function(result)
   close(notice)
   if self.core~=core then return end
   if finished and finished(result)then return end
   if result.failed>0 or result.save_failed then
    env.message(tr('Some cache changes could not be saved.'))
   elseif result.skipped>0 then
    env.message(F('%d files removed, %d kept.',result.removed,result.skipped))
   else env.message(F('%d files removed.',result.removed))end
  end)
 end
 function Shelf:removeTree(parent)
  local entries={}
  for _,item in ipairs(targetsInPool(self.core))do
   if M.inBranch(self.core.state.folders,item.parent_id,parent)then entries[#entries+1]=item end
  end
  self:confirmManagedRemoval(entries)
 end
 function Shelf:showManagedDownloads()
  local core=self.core
  local folders=self:menu(tr('Choose downloads to remove'),{{text=tr('Checking local downloads…'),select_enabled=false}},
   {icons=true,multiline=true,back=true})
  local function list()
   measure(core,'storage-inventory',function()return M.inventory(core)end,function(groups)
    if self.core~=core or folders._closed then return end
    local rows={}
    for _,group in ipairs(groups or {})do
     rows[#rows+1]={icon='appbar.filebrowser',text=group.name,mandatory=env.bytes(group.size),callback=function()
      local selected,documents={},nil
      local function rowsForFolder()
       local rows={{text=tr('Remove all downloads in this folder'),icon_file=env.root..'/resources/icons/trash.svg',callback=function()
        self:confirmManagedRemoval(group.entries,function()close(documents);list()end)
       end},{text=tr('Remove selected files'),icon='check',callback=function()
        local targets={}
        for _,entry in ipairs(group.entries)do if selected[entry.id]then targets[#targets+1]=entry end end
        self:confirmManagedRemoval(targets,function()close(documents);list()end)
       end}}
       for _,entry in ipairs(group.entries)do
        rows[#rows+1]={text=entry.name,checked=selected[entry.id]==true,mandatory=env.bytes(entry.size),callback=function()
         selected[entry.id]=not selected[entry.id]
         self:replaceMenu(documents,rowsForFolder())
        end}
       end
       return rows
      end
      documents=self:menu(group.name,rowsForFolder(),{icons=true,multiline=true,back=true})
     end}
    end
    if #rows==0 then rows[1]={text=tr(groups and 'No downloaded files'or 'Could not check local downloads'),select_enabled=false}end
    self:replaceMenu(folders,rows)
   end)
  end
  list()
  return folders
 end
 local function memoryBars(stats,settings)
  local disk,usage=stats.disk or {},stats.usage or {}
  local used=disk.total and (disk.used or disk.total-(disk.free or 0))
  local function bar(label,value,limit,format)
   return {label=tr(label)..' · '..env.bytes(value)..(limit and ' / '..format(limit)or ''),
    value=value and limit and math.min(1,value/math.max(1,limit))or 0}
  end
  return {bar('Disk used',used,disk.total,env.bytes),
   bar(labels.auto,usage.auto,(settings.auto_mib or 3072)*1048576,env.binaryBytes),
   bar('Metadata cache',usage.meta,(settings.meta_mib or 256)*1048576,env.binaryBytes),
   {label=tr('Safety reserve: 512 MiB · active files are protected')}}
 end
 function Shelf:showMemory()
  if self.memory_menu and not self.memory_menu._closed then return self.memory_menu end
  local core,menu,header=self.core
  local stats={}
  local function refresh()
   if self.core~=core or menu._closed then return end
   if self.memory_measuring==menu then self.memory_measure_again=menu;return end
   self.memory_measuring=menu
   measure(core,'storage-stats',function()return M.storageStats(core)end,function(result)
    if self.memory_measuring==menu then self.memory_measuring=nil end
    if self.core~=core or menu._closed then return end
    local function paint()
     if self.core~=core or menu._closed then return end
     stats=result or {}
     header:setBars(memoryBars(stats,self.settings))
     header:setSubTitle(F('Free space: %s',env.bytes(stats.disk and stats.disk.free)),true)
     self:replaceMenu(menu,menu.memoryRows())
    end
    if self:whenVisible(menu,paint)then paint()end
    if self.memory_measure_again==menu then self.memory_measure_again=nil;refresh()end
   end)
  end
  local function rows()
   local result={
    {text=F('Document folder: %s',core.storage.books_dir),select_enabled=false},
    {text=F('Progress and snapshots: %s · index and queue: %s',env.bytes(stats.progress),env.bytes(stats.index)),select_enabled=false},
    {icon_file=env.root..'/resources/icons/trash.svg',text=tr('Choose downloads to remove'),callback=function()self:showManagedDownloads()end},
    {icon='appbar.settings',text=tr('Cache limits'),callback=function()self:showCacheLimits(refresh)end},
   }
   for _,pool in ipairs{'auto','offline','meta'}do
    result[#result+1]={icon_file=env.root..'/resources/icons/trash.svg',text=tr(actions[pool]),mandatory=env.bytes(stats.usage and stats.usage[pool]),
     callback=function()self:confirmManagedRemoval(targetsInPool(core,pool),refresh)end}
   end
   return result
  end
  header=require('gdriveshelf/browser').header{width=require('device').screen:getWidth(),title=tr('Storage and cache'),
   status=tr('Checking storage…'),buttons={},bars=memoryBars(stats,self.settings),close=function()close(menu)end,back=function()close(menu)end}
  menu=self:menu(tr('Storage and cache'),rows(),{header=header,icons=true,perpage=7,multiline=true,close=function()
   if self.memory_menu==menu then self.memory_menu=nil end
   if self.memory_measuring==menu then
    self.memory_measuring=nil
    core.jobs:cancel('storage-stats')
   end
   if self.memory_measure_again==menu then self.memory_measure_again=nil end
  end})
  self.memory_menu=menu;menu.memoryRows=rows;menu.refreshMemory=refresh
  refresh()
  return menu
 end
 function Shelf:showCacheLimits(after)
  local menu
  local function rows()
   local result={}
   for _,choice in ipairs{{'auto_mib','Temporary reading cache limit, MiB',3072},{'meta_mib','Metadata cache limit, MiB',256}}do
    local key,label,default=choice[1],tr(choice[2]),choice[3]
    local current=self.settings[key]or default
    result[#result+1]={text=label,mandatory=tostring(current),callback=function()
     self:input(label,current,function(value)
      local number=tonumber(value)
      if not number or number~=math.floor(number)or number<1 or number>1048576 then return false,tr('Invalid value')end
      self.settings[key]=number;self:saveSettings()
      self:replaceMenu(menu,rows())
      if after then after()end
      return true
     end,'number')
    end}
   end
   return result
  end
  menu=self:menu(tr('Cache limits'),rows(),{multiline=true,back=true})
  return menu
 end
 function Shelf:showDocumentFolder()
  local menu
  local function complete()
   close(menu)
   if self.memory_menu and self.memory_menu.refreshMemory then self.memory_menu.refreshMemory()end
  end
  menu=self:menu(tr('Document folder'),{{text=self.core.storage.books_dir,select_enabled=false},
   {text=tr('Choose document folder'),icon='appbar.filebrowser',callback=function()self:chooseBooksFolder(complete)end},
   {text=tr('Enter an absolute path'),icon='edit',callback=function()
    self:input(tr('Document folder'),self.core.storage.books_dir,function(path)return self:moveBooks(path,complete)end)
   end},
  },{icons=true,multiline=true,back=true})
  return menu
 end
 function Shelf:showOffline(all)
  local home=self.settings.home
  if not all and home and home~='root' and #self:offlineChildren(home)>0 then
   self.offline_all_link=home
   return self:showFolder(home,true)
  end
  local rows={}
  for _,folder in ipairs(self:orderedEntries(self:offlineChildren(nil)))do
   local e=folder
   rows[#rows+1]={text=e.name..(e.author and e.author~=''and ' · '..e.author or ''),
    icon='appbar.filebrowser',icon_file=e.cover_path,cover=e.cover_path~=nil,folder_progress=e.folder_progress,
    callback=function()self:showFolder(e.id,true)end}
  end
  if #rows==0 then rows[1]={text=tr('No downloaded files'),select_enabled=false}end
  return self:menu(tr('Available offline — folders'),rows,{icons=true,perpage=8,multiline=true,back=true})
 end
 local function identity(credentials)
  for _,key in ipairs{'account_email','account_name'}do
   local value=credentials[key]
   if type(value)=='string'and #value>0 and #value<=320 and not value:find('[%c]')then return value end
  end
  return nil
 end
 function Shelf:homeFolderHint()
  if self:hasCredentials()and (not self.settings.home or self.settings.home=='root')then
   return tr('Choose a home folder for your library')
  end
 end
 function Shelf:chooseHomeFolder(after)
  local menu
  menu=self:menu(tr('Home folder'),{
   {text=tr('In the library, long-press a folder and choose Set as home folder.'),select_enabled=false},
   {text=tr('Enter folder ID or link'),icon='edit',callback=function()
    self:input(tr('Google Drive folder ID or link'),self.settings.home,function(value)
     local id=value:match('/folders/([%w_-]+)')or value:match('[?&]id=([%w_-]+)')or value
     if not id:match('^[%w_-]+$')then return false,tr('Invalid folder ID')end
     self.settings.home=id;self:saveSettings()
     close(menu)
     if after then after()end
     return true
    end)
   end},
  },{icons=true,multiline=true,back=true})
  return menu
 end
 function Shelf:showConnectionMethods(connected)
  local menu
  menu=self:menu(tr(connected and 'Switch account'or 'Connect Google Drive'),{
   {icon='wifi.secure.100',text=tr('Choose authorization JSON'),callback=function()close(menu);self:pickCredentials()end},
   {icon='appbar.filebrowser',text=tr('Enter JSON file path'),callback=function()close(menu);self:pickCredentialsByPath()end},
   {icon='info',text=tr('Which JSON file do I need?'),callback=function()self:showAuthorizationHelp()end},
  },{icons=true,multiline=true,back=true})
  return menu
 end
 function Shelf:showLogout()
  local core=self.core
  if core.active_id or self:activeEntry() then env.message(tr('Close the book before switching accounts'));return end
  local dialog
  local function signOut(clear)
   close(dialog)
   if self.core~=core then return end
   local function complete(result)
    local ok,err=self:signOutAccount(core)
    if not ok then env.problem(err);return true end
    self:showConnectionSetup()
    local summary=result and result.skipped>0 and F('%d files removed, %d kept.',result.removed,result.skipped)
    local notice=tr('Signed out. Delete the original authorization JSON from this device if you no longer need it.')
    env.message(summary and summary..'\n'..notice or notice)
    return true
   end
   if not clear then complete();return end
   local entries=targetsInPool(core)
   if #entries==0 then complete();return end
   if core.relocating or core.archive_removal then env.message(tr('Wait for the current storage operation to finish.'));return end
   local ok,err=self:pauseAccount(core)
   if not ok then env.problem(err);return end
   self:runManagedRemoval(core,entries,function(result)
    if result.failed>0 or result.save_failed then self:reconnectPausedAccount(core);return end
    return complete(result)
   end)
  end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Sign out of Google Drive?'),text=tr('Reading progress and sync queues are kept.'),
   buttons={{{text=tr('Sign out and keep downloads'),callback=function()self:runAction(signOut,false)end}},
    {{text=tr('Sign out and remove downloads'),callback=function()self:runAction(signOut,true)end}},
    {{text=tr('Cancel'),callback=function()close(dialog)end}}}}
  UI():show(self:trackAccountWidget(dialog))
 end
 function Shelf:connectionRows(reopen)
  local core=self.core
  local connected=self:hasCredentials()
  local account=connected and identity(core.credentials)
  local folder=connected and self.settings.home
  local folderRecord=folder and core.state.folders[folder]
  local folderLabel
  if folder and folder~='root'then folderLabel=folderRecord and folderRecord.name or tr('Folder selected')else folderLabel=tr('Not selected')end
  local startup=G_reader_settings and G_reader_settings:readSetting('start_with','filemanager')or 'filemanager'
  local startupLabel=({gdriveshelf='Google Drive Shelf',filemanager='File browser',history='History',
   favorites='Favorites',folder_shortcuts='Folder shortcuts',last='Most recent document'})[startup]or 'File browser'
  local rows={
   {text=account and F('Account: %s',account) or tr(connected and 'Account connected'or 'Google Drive is not connected yet.'),select_enabled=false},
   {icon='wifi.secure.100',text=tr(connected and 'Switch account'or 'Connect Google Drive'),callback=function()self:showConnectionMethods(connected)end},
   {icon='home',text=F('Home folder: %s',folderLabel),select_enabled=connected,callback=function()self:chooseHomeFolder(reopen)end},
   {icon='appbar.navigation',text=F('Start with: %s',tr(startupLabel)),callback=function()
    env.message(tr('Change this in KOReader’s file browser menu → Start with.'))
   end},
   {icon='info',text=tr('Diagnostics'),callback=function()self:showDiagnostics()end},
   {icon='appbar.navigation',text=tr('Gesture shortcuts'),callback=function()
    env.message(tr('In KOReader gesture settings, choose General → Google Drive Shelf: open home folder, history, or current document folder.'))
   end},
  }
  if connected then
   table.insert(rows,3,{icon='close',text=tr('Sign out'),callback=function()self:showLogout()end})
   if not account and core:online()then
    table.insert(rows,2,{icon='info',text=tr('Look up account name'),callback=function()
     core:network('account-profile',function(provider)return provider:accountProfile()end,function(profile,err)
      if self.core~=core then return end
      if not profile then env.problem(err);return end
      local id=core.credentials.account_id
      if id and id~=profile.permissionId then env.problem(tr('Account could not be verified'));return end
      core.credentials.account_email=profile.emailAddress
      core.credentials.account_name=profile.displayName
      if core.oncredentials then core.oncredentials(core.credentials)end
      reopen()
     end,true)
    end})
   end
  end
  return rows
 end
end
return M
