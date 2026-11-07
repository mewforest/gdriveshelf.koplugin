-- Native dialogs and queue presentation; cloud/state mutations stay in Core.
return function(Shelf,env)
 local tr=require('gdriveshelf/i18n').gettext
 local function UI()return require('ui/uimanager')end
 local function folder(core,value)return type(value)=='table'and value or(core.state.folders[value]or{id=value,name=value,is_folder=true})end
 local function close(menu)
  if not menu or menu._closed then return end
  if menu.onCloseAllMenus then menu:onCloseAllMenus()else UI():close(menu)end
 end
 local function excerpt(text)
  local result={};for char in (text or''):gmatch('[%z\1-\127\194-\244][\128-\191]*')do result[#result+1]=char;if #result==100 then return table.concat(result)..'…'end end;return table.concat(result)
 end
 local function snapshot(core,id)
  return core.storage:readJSON(core.storage.root..'/snapshots/'..require('gdriveshelf/storage').key(id)..'.json')
 end
 function Shelf:downloadActivity()
  local core=self.core;local downloads=core.state.downloads or{};local selected
  local background=core.background_downloads or{}
  for id in pairs(background)do if not downloads[id]then background[id]=nil end end
  local active=core.jobs and core.jobs.active;local id=active and active.key:match('^download:(.+)$')
  if id and background[id] and downloads[id]then selected={id=id,data=downloads[id]}end
  if not selected then
   for _,job in ipairs(core.jobs and core.jobs.queue or{})do local key=job.key:match('^download:(.+)$');if key and background[key] and downloads[key]then selected={id=key,data=downloads[key]};break end end
  end
  if not selected then for key in pairs(background)do selected={id=key,data=downloads[key]};break end end
  if not selected then return nil end
  local name=selected.data.entry.name;local value=(core.transfer or{})[selected.id]
  local state=core.networkState and core:networkState()or'online'
  if state=='retry'or state=='sleep'then return string.format(tr('Waiting for connection: %s'),name)end
  if state=='offline'then return string.format(tr('Queued for online mode: %s'),name)end
  if state=='auth'then return tr('Authorization is required to continue downloads')end
  if selected.data.error then return string.format(tr('Download needs attention: %s'),name)end
  local text=string.format(tr('Downloading: %s'),name)
  if value then
   if value.total and value.total>0 then text=string.format('%d%% · %s / %s · %s',math.min(100,math.floor(value.received/value.total*100)),env.bytes(value.received),env.bytes(value.total),name)
   else text=text..' · '..env.bytes(value.received)end
  else text=string.format(tr('Queued: %s'),name)end
  return text
 end
 function Shelf:enableRecursiveIndex()
  if not self.settings.home or self.settings.home=='root'then env.message(tr('Choose a home folder before indexing.'));return end
  UI():show(self:confirmation{text=tr('Index this home folder and all its subfolders? The first pass may take time. Documents and SDR contents will not be downloaded. Later updates use the Drive change log.'),ok_text=tr('Index library'),ok_callback=function()
   self.settings.index_enabled=true;self.settings.index_recursive_confirmed=true;self.settings.index_needs_confirmation=nil;self:saveSettings()
   self:showIndexScreen(function()self.core:reindexHome()end)
  end})
 end
 function Shelf:reindexLibrary()
  if not self.settings.index_enabled or not self.settings.index_recursive_confirmed then return self:enableRecursiveIndex()end
  UI():show(self:confirmation{text=tr('Rebuild the catalog from this home folder? Saved documents and reading progress will be kept.'),ok_text=tr('Reindex library'),ok_callback=function()self:showIndexScreen(function()self.core:reindexHome()end)end})
 end
 local indexPhase={idle='Ready to check the library',prepare='Preparing the index…',listing='Checking folders…',
  changes='Checking Drive changes…',applying='Saving changes…',paused='Indexing paused',error='Indexing interrupted',complete='Library index is up to date'}
 function Shelf:indexScreenText()
  local status=self.core:indexStatus()
  local network=self.core:networkState()
  local lines={tr('Library indexing'),tr(indexPhase[status.phase]or indexPhase.prepare)}
  local label=({offline='Offline mode',sleep='Waiting for the device to wake',retry='Waiting before retry',auth='Authorization is required'})[network]
  if label then lines[#lines+1]=tr(label)end
  if status.discovered>0 then
   lines[#lines+1]=string.format(tr('%d checked · %d found so far'),status.done,status.discovered)
  end
  if status.elapsed>0 then lines[#lines+1]=string.format(tr('Elapsed: %d min %02d s'),math.floor(status.elapsed/60),status.elapsed%60)end
  local recent={}
  for _,event in ipairs(status.recent)do
   local label=indexPhase[event.phase]
   if label and label~=indexPhase[status.phase] and recent[#recent]~=label then recent[#recent+1]=label end
  end
  if #recent>0 then lines[#lines+1]=table.concat(recent,' · '):gsub('…','')end
  if status.error then lines[#lines+1]=tr('Open the downloads queue to check the connection and retry.')end
  lines[#lines+1]='\n'..tr('The first check may take a while on slower devices. Keep KOReader open to let it finish.')
  return table.concat(lines,'\n')
 end
 function Shelf:showIndexScreen(start)
  local old=self.index_dialog
  if old then return old end
  local dialog
  local function dismiss(pause)
   if self.index_dialog~=dialog then return end
   self.index_dialog=nil
   if pause and self.core.index_job then self.core:cancelIndex()end
   UI():close(dialog)
  end
  dialog=require('ui/widget/buttondialog'):new{title=self:indexScreenText(),buttons={
   {{text=tr('Pause'),id='pause',callback=function()if self.core.index_job then self.core:cancelIndex()end end},
    {text=tr('Resume'),id='resume',callback=function()
     if not self.core:online()then env.message(tr('Go online to index the library.'));return end
     self.core:catalogRefresh(true);self:updateIndexScreen('indexing')
    end}},
   {{text=tr('Close'),callback=function()dismiss(true)end},
    {text=tr('In background'),callback=function()dismiss(false)end}},
  }}
  dialog.onClose=function()dismiss(true);return true end
  local status=self.core:indexStatus()
  local bar=require('ui/widget/progresswidget'):new{width=dialog:getAddedWidgetAvailableWidth(),
   height=require('device').screen:scaleBySize(8),bordersize=1,radius=0,
   percentage=status.discovered>0 and math.min(1,status.done/status.discovered)or 0,
   not_focusable=true,parent=dialog}
  dialog:addWidget(bar)
  dialog._index_bar=bar
  self.index_dialog=dialog
  UI():show(dialog)
  self:updateIndexScreen('indexed')
  if start then UI():nextTick(function()
   if self.index_dialog~=dialog then return end
   if self.core:online()then start()
   else env.message(tr('Go online to index the library.'))end
   self:updateIndexScreen('indexed')
  end)end
  return dialog
 end
 function Shelf:updateIndexScreen(kind)
  if kind~='indexing' and kind~='indexed' and kind~='network_state'then return end
  local dialog=self.index_dialog
  if not dialog then return end
  local function update()
   if self.index_dialog~=dialog then return end
   local now=os.time()
   if kind=='indexing' and dialog._index_updated==now then return end
   local status=self.core:indexStatus()
   local title=self:indexScreenText()
   local bar=dialog._index_bar
   local percent=status.discovered>0 and math.min(1,status.done/status.discovered)or 0
   if title~=dialog.title or bar.percentage~=percent then
    dialog._index_updated=now
    bar:setPercentage(percent)
    dialog:setTitle(title)
   end
   dialog:getButtonById('pause'):enableDisable(status.running==true)
   dialog:getButtonById('resume'):enableDisable(not status.running and status.phase~='complete')
  end
  if self:whenVisible(dialog,update)then update()end
 end
 function Shelf:showFolderProgress(parent,entries)
  local dialog
  local visit=self.folder_visit
  local function resumeAfterProgress(completed)
   if not visit or self.folder_visit~=visit then return end
   if completed or (visit.resume and visit.resume.waiting) then visit.resume_started=nil;self:startFolderResume()end
   self:requestBrowserRefresh(false)
  end
  local function closeProgress(cancel,completed)
   if self.progress_dialog~=dialog then return end
   self.progress_dialog=nil
   if cancel and self.core.progress_job and self.core.progress_job.mode=='all'then self.core:cancelProgress()end
   UI():close(dialog)
   resumeAfterProgress(completed)
  end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Loading reading progress…'),buttons={{
   {text=tr('Cancel'),callback=function()closeProgress(true)end},
  }}}
  dialog.onClose=function()closeProgress(true);return true end
  self.progress_dialog=dialog
  UI():show(dialog)
  if visit then visit.detailed_progress=true end
  local queued=self.core:loadFolderProgress(parent,entries,function(err)
   closeProgress(false,not err)
   if err then env.problem(err)end
  end)
  if not queued then
   if visit then visit.detailed_progress=nil end
   closeProgress(false)
   env.message(tr('No cloud progress to load, or the connection is unavailable.'))
  end
 end
 function Shelf:updateFolderProgressScreen(kind)
  local dialog,job=self.progress_dialog,self.core.progress_job
  if kind~='progress_state' or not dialog or not job or job.mode~='all'then return end
  local function update()
   if self.progress_dialog~=dialog then return end
   local title=tr('Loading reading progress…')..'\n'..job.done..' / '..job.total
   if dialog.title~=title then dialog:setTitle(title)end
  end
  if self:whenVisible(dialog,update)then update()end
 end
 function Shelf:showQueue()
  local core=self.core;local rows={{text=tr('Retry pending tasks'),callback=function()core:resetNetwork(nil,true);core.jobs:pump();self:showQueue()end}}
  local state=core.networkState and core:networkState()or'online'
  if state~='online'then rows[#rows+1]={text=tr(({retry='Waiting before retry',offline='Offline mode',sleep='Waiting for the device to wake',auth='Authorization is required'})[state]or state),select_enabled=false}end
  local index=core:indexStatus()
  if index.running or index.paused then rows[#rows+1]={text=tr('Library indexing')..' · '..tr(indexPhase[index.phase]),callback=function()self:showIndexScreen()end}end
  if core.deep_job then local j=core.deep_job;rows[#rows+1]={text=tr('Scanning covers…')..' '..j.done..'/'..j.total..tr(' · cancel'),callback=function()core:cancelDeepScan();self:showQueue()end}end
  local list={};for id,data in pairs(core.state.downloads or{})do list[#list+1]={id=id,data=data}end
  table.sort(list,function(a,b)return a.data.entry.name<b.data.entry.name end)
  for _,record in ipairs(list)do
   local id,data=record.id,record.data;local value=(core.transfer or{})[id]
   local active=core.jobs.active and core.jobs.active.key=='download:'..id
   local text=(active and tr('Downloading')or tr('Queued'))..' · '..data.entry.name
   if value then text=text..'\n'..env.bytes(value.received)..(value.total and ' / '..env.bytes(value.total)or'')end
   if data.error then text=text..'\n'..tr('Download needs attention')end
   rows[#rows+1]={text=text,callback=function()
    UI():show(require('ui/widget/buttondialog'):new{title=data.entry.name,buttons={{
     {text=tr('Open'),callback=function()self:openEntry(data.entry)end},
     {text=tr('Cancel download'),callback=function()core:cancelDownload(id);self:showQueue()end},
    }}})
   end}
  end
  for id,pending in pairs(core.state.sync.pending)do local e=pending.entry;rows[#rows+1]={text=tr(core.state.sync.conflicts[id]and'Conflict: 'or'Sync: ')..e.name,callback=function()self:showConflict(e)end}end
  for id,pending in pairs(core.folder_metadata and core.folder_metadata.pending or{})do
   local item=folder(core,id);rows[#rows+1]={text=tr(pending.conflict and'Metadata conflict: 'or'Metadata waiting to sync: ')..(core:titleInfo(id).title or item.name),callback=function()if pending.conflict then self:showMetadataConflict(item)else self:editFolderMetadata(item)end end}
  end
  if #rows==1 then rows[#rows+1]={text=tr('No pending tasks'),select_enabled=false}end
  if self.queue_menu and not self.queue_menu._closed then self:replaceMenu(self.queue_menu,rows);return self.queue_menu end
  self.queue_menu=self:menu(tr('Downloads and sync'),rows,{multiline=true,perpage=7});return self.queue_menu
 end
 function Shelf:showRecovery(entry)
  local cached=self.core:cached(entry.id);local remote=self.core:remote(entry);local localCopy=snapshot(self.core,entry.id)
  local function date(path)local a=self.core.storage.lfs and self.core.storage.lfs.attributes(path);return a and os.date('%Y-%m-%d %H:%M',a.modification)or tr('unknown')end
  local rows={
   {text=tr('Apply downloaded cloud copy')..'\n'..(remote and remote.stamp and remote.stamp.modified_time or tr('No downloaded cloud copy')),select_enabled=cached~=nil and remote~=nil,callback=function()
    if self:activeEntry()then env.message(tr('Close the book first'));return end
    UI():show(self:confirmation{text=tr('Replace local reading progress with this downloaded cloud copy?'),ok_text=tr('Apply'),ok_callback=function()local ok,err=self:applyRemote(entry,remote,cached.path);if not ok then env.problem(err)else env.message(tr('Progress applied. Open the book to continue.'))end end})
   end},
   {text=tr('Restore last local copy')..'\n'..(localCopy and date(self.core.storage.root..'/snapshots/'..require('gdriveshelf/storage').key(entry.id)..'.json')or tr('No local snapshot')),select_enabled=cached~=nil and localCopy~=nil,callback=function()self:restoreSnapshot(entry)end},
   {text=tr('These are recovery copies, not a history of every reading position. Close the document before restoring.'),select_enabled=false},
  }
  return self:menu(tr('Recover reading progress'),rows,{multiline=true,perpage=6})
 end
 function Shelf:showDiagnostics()
  close(self.diagnostics_menu)
  local logger=self.core.logger;local dir=logger and logger.dir or''
  self.diagnostics_menu=self:menu(tr('Diagnostics'),{
   {text=tr('Diagnostic logging'),checked=self.settings.diagnostics==true,callback=function()
    if not self.settings.diagnostics then local ok=self.core.storage:mkdir(dir);if not ok then env.message(tr('Cannot create the diagnostics folder'));return end end
    self.settings.diagnostics=not self.settings.diagnostics;self:saveSettings();self:showDiagnostics()
   end},
   {text=tr('Maximum 2 MiB. File names, IDs, tokens, paths and response contents are excluded.'),select_enabled=false},
   {text=tr('Log folder')..': '..dir,select_enabled=false},
   {text=tr('Export diagnostic log'),callback=function()
    self:input(tr('Export diagnostic log'),require('datastorage'):getDataDir()..'/gdriveshelf-diagnostics.txt',function(path)
     local ok=logger and logger:export(path);if not ok then return false,tr('Could not export diagnostics')end;env.message(tr('Diagnostic log exported'));return true
    end)
   end},
   {text=tr('Clear diagnostic log'),callback=function()local ok=logger and logger:clear();env.message(tr(ok and'Diagnostic log cleared'or'Could not clear diagnostics'))end},
  },{icons=true,multiline=true,perpage=7});return self.diagnostics_menu
 end
 local function imageViewer(path,title)
  UI():show(require('ui/widget/imageviewer'):new{file=path,title_text=title,with_title_bar=true})
 end
 local function coverWidget(path,width,height,title)
  local Geom=require('ui/geometry')
  local dimen=Geom:new{w=width,h=height}
  local widget
  if path then
   local image=require('ui/widget/iconwidget'):new{file=path,width=width,height=height,scale_factor=0,is_icon=false}
   widget=require('ui/widget/container/inputcontainer'):new{dimen=dimen,image}
   widget.ges_events={ShowCover={require('ui/gesturerange'):new{ges='tap',range=dimen}}}
   widget.onShowCover=function()imageViewer(path,title);return true end
  else
   widget=require('ui/widget/container/centercontainer'):new{dimen=dimen,require('ui/widget/textboxwidget'):new{
    text=tr('No cover'),width=width,alignment='center',face=require('ui/font'):getFace('smallinfofont')}}
  end
  return widget
 end
 local function replaceCover(draft,value,cleanup)
  if draft.cleanup then draft.cleanup()end
  draft.cover,draft.cleanup=value,cleanup
 end
 function Shelf:editFolderMetadata(value,draft)
  local item=folder(self.core,value);local info=self.core:titleInfo(item.id)
  draft=draft or {values={title=info.title or item.name,description=info.description or''}}
  draft.item=item
  local old=self.metadata_editor
  if old then
   if old._draft==draft then old._refreshing=true end
   close(old)
  end
  local screen=require('device').screen
  local dialog
  local function redraw()self:editFolderMetadata(item,draft)end
  local function field(key,label,multiline)
   local input
   input=require('ui/widget/inputdialog'):new{title=tr(label),input=draft.values[key]or'',fullscreen=multiline,allow_newline=multiline,buttons={{
    {text=tr('Cancel'),id='close',callback=function()UI():close(input)end},
    {text=tr('Save'),is_enter_default=true,callback=function()draft.values[key]=input:getInputText();UI():close(input);redraw()end},
   }}}
   UI():show(input);input:onShowKeyboard()
  end
  local function chooseImage()
   local chooser
   chooser=require('ui/widget/filechooser'):new{title=tr('Choose cover image'),path=self.settings.cover_import_dir or require('apps/filemanager/filemanagerutil').getHomeFolder(),ui=self.ui,show_unsupported=false,
    file_filter=require('gdriveshelf/metadata').isImageName,
    onFileSelect=function(_,selected)
     self:runAction(function()
      self.settings.cover_import_dir=selected.path:match('^(.*)/');self:saveSettings();UI():close(chooser)
      self:prepareEditorCover(draft,function(done)return self.core:prepareFolderCover(selected.path,done)end)
     end)
    end}
   UI():show(chooser)
  end
  local function button(text,callback)
   return {text=tr(text),height=screen:scaleBySize(38),callback=function()self:runAction(callback)end}
  end
  local rows={
   {button('Choose cover image',chooseImage)},
   {button('Use first page (quick)',function()self:extractCoverForEditor(item,draft)end)},
   {button('Choose a page from a volume…',function()self:chooseCoverVolume(item,draft)end)},
   {button('Use automatic cover',function()replaceCover(draft,false);redraw()end),
    button('Hide cover',function()replaceCover(draft,true);redraw()end)},
   {button('Cancel',function()close(dialog)end),button('Save',function()
    local ok,err=self.core:saveFolderMetadata(item,draft.values,draft.cover)
    if not ok then env.problem(err);return end
    close(dialog);env.message(tr('Saved locally. Changes will sync when online.'))
   end)},
  }
  dialog=require('ui/widget/buttondialog'):new{title=tr('Edit folder information'),width_factor=.94,buttons=rows}
  local cover=info.cover_path
  if draft.cover==false then cover=info.automatic_cover_path
  elseif draft.cover==true then cover=nil
  elseif type(draft.cover)=='string'then cover=draft.cover end
  local panelWidth=dialog:getAddedWidgetAvailableWidth()
  local coverHeight=math.min(screen:scaleBySize(108),math.floor(screen:getHeight()*.17))
  local coverWidth=math.floor(coverHeight*.74)
  local gap=screen:scaleBySize(8)
  local V=require('ui/widget/verticalgroup')
  local HS=require('ui/widget/horizontalspan')
  local VS=require('ui/widget/verticalspan')
  local Text=require('ui/widget/textwidget')
  local Button=require('ui/widget/button')
  local fields=V:new{align='left'}
  local fieldLayout={}
  local fieldWidth=panelWidth-coverWidth-gap
  for _,spec in ipairs{{'title','Title',false},{'description','Description',true}}do
   local key,label,multiline=spec[1],spec[2],spec[3]
   fields[#fields+1]=Text:new{text=tr(label),face=require('ui/font'):getFace('smallinfofont'),bold=true}
   local current=draft.values[key] or ''
   local edit=Button:new{text=current~=''and excerpt(current)or tr('None'),width=fieldWidth,height=screen:scaleBySize(30),
    text_font_face='cfont',text_font_size=16,text_font_bold=false,padding_h=gap,padding_v=0,avoid_text_truncation=false,align='left',
    callback=function()self:runAction(function()field(key,label,multiline)end)end}
   fields[#fields+1]=edit
   fields[#fields+1]=VS:new{width=math.floor(gap/2)}
   fieldLayout[#fieldLayout+1]={edit}
  end
  dialog:addWidget(require('ui/widget/horizontalgroup'):new{align='top',not_focusable=true,
   coverWidget(cover,coverWidth,coverHeight,draft.values.title or item.name),HS:new{width=gap},fields})
  for i,row in ipairs(fieldLayout)do table.insert(dialog.layout,i,row)end
  dialog._draft=draft
  local onClose=dialog.onCloseWidget
  dialog.onCloseWidget=function(widget,...)
   onClose(widget,...)
   if self.metadata_editor==widget then self.metadata_editor=nil end
   if not widget._refreshing then replaceCover(draft,nil)end
  end
  self.metadata_editor=dialog
  UI():show(dialog)
  return dialog
 end
 function Shelf:prepareEditorCover(draft,start)
  local editor=self.metadata_editor
  local token={};self.cover_request=token
  local dialog,key
  local function cancel()
   if self.cover_request~=token then return end
   self.cover_request=nil
   if key then self.core.jobs:cancel(key)end
   close(dialog)
  end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Extracting cover…'),buttons={{{text=tr('Cancel'),callback=cancel}}}}
  dialog.onClose=function()cancel();return true end
  UI():show(dialog)
  key=start(function(path,err,cleanup)
   if self.cover_request~=token then if cleanup then cleanup()end;return end
   self.cover_request=nil;close(dialog)
   if self.metadata_editor~=editor or editor._draft~=draft then if cleanup then cleanup()end;return end
   if not path then env.problem(err);return end
   replaceCover(draft,path,cleanup)
   self:editFolderMetadata(draft.item,draft)
  end)
 end
 function Shelf:extractCoverForEditor(item,draft)
  draft.item=item
  self:prepareEditorCover(draft,function(done)
   local accepted,key=self.core:extractFolderCover(item,done)
   return accepted and type(key)=='string'and key or nil
  end)
 end
 function Shelf:chooseCoverVolume(item,draft)
  local Library=require('gdriveshelf/library')
  local info=self.core:titleInfo(item.id)
  local rows,menu={}
  for _,entry in ipairs(Library.ordered(self.core:cachedList(item.id),'natural'))do
   if self.core:coverGallerySupported(entry)then
    rows[#rows+1]={text=self:chapterLabel(entry,info),icon='appbar.pageview',mandatory=entry.size and env.bytes(entry.size),
     callback=function()
      close(menu)
      if self.core:cached(entry.id)then self:showCoverGallery(item,draft,entry);return end
      if not self.core:online()then env.message(tr('Connect to download this volume.'));return end
      UI():show(self:confirmation{text=tr('Download this volume to choose a cover page?'),ok_text=tr('Download'),ok_callback=function()
       self:downloadForCover(item,draft,entry)
      end})
     end}
   end
  end
  if #rows==0 then env.message(tr('No documents support choosing a cover page.'));return end
  menu=self:menu(tr('Choose a volume'),rows,{icons=true,multiline=true,back=true})
  return menu
 end
 function Shelf:downloadForCover(item,draft,entry)
  local dialog
  local editor=self.metadata_editor
  local active=true
  local function cancel()
   if not active then return end
   active=false;self.cover_download=nil
   self.core:cancelDownload(entry.id);close(dialog)
  end
  dialog=require('ui/widget/buttondialog'):new{title=self:downloadTitle(entry),buttons={{{text=tr('Cancel'),callback=cancel}}}}
  dialog.onClose=function()cancel();return true end
  self.cover_download={entry=entry,widget=dialog}
  UI():show(dialog)
  self.core:download(entry,'auto',function(path,err)
   if not active then return end
   active=false;self.cover_download=nil;close(dialog)
   if self.metadata_editor~=editor then return end
   if path then self:showCoverGallery(item,draft,entry)else env.problem(err)end
  end)
 end
 function Shelf:showCoverGallery(item,draft,entry)
  local gallery,err=self.core:coverGallery(entry)
  if not gallery then env.problem(err);return end
  local editor=self.metadata_editor
  local menu,wait
  local finished,changing
  local function exit()
   if finished then return end
   finished=true;gallery:close();close(wait);close(menu)
  end
  local function waiting(text)
   wait=require('ui/widget/buttondialog'):new{title=tr(text),buttons={{{text=tr('Cancel'),callback=exit}}}}
   wait.onClose=function()exit();return true end
   UI():show(wait)
  end
  local function selectPage(page)
   waiting('Preparing cover…')
   gallery:select(page,function(path,why)
    if finished then return end
    close(wait);wait=nil
    if not path then env.problem(why);return end
    if self.metadata_editor~=editor then exit();return end
    finished=true;gallery:release();close(menu)
    replaceCover(draft,path,function()gallery:close()end)
    self:editFolderMetadata(item,draft)
   end)
  end
  local function load(first)
   waiting('Loading page previews…')
   gallery:load(first,function(result,why)
    if finished then return end
    close(wait);wait=nil
    if not result then exit();env.problem(why);return end
    local rows={}
    for _,page in ipairs(result.pages)do
     rows[#rows+1]={text=string.format(tr('Page %d'),page.number),icon_file=page.path,
      select_enabled=page.path~=nil,callback=function()
       UI():show(self:confirmation{text=string.format(tr('Use page %d as the folder cover?'),page.number),
        ok_text=tr('Apply'),ok_callback=function()selectPage(page.number)end})
      end}
    end
    local screen=require('device').screen
    local title=tr('Choose a cover page')
    local header=require('gdriveshelf/browser').header{title=title,
     status=string.format(tr('Pages %d–%d of %d'),result.first,result.first+#result.pages-1,result.total),
     width=screen:getWidth(),back=exit,close=exit,buttons={
      {icon='chevron.left',enabled=result.first>1,callback=function()load(math.max(1,result.first-6))end},
      {icon='chevron.right',enabled=result.first+5<result.total,callback=function()load(result.first+6)end},
     }}
    changing=true;close(menu);changing=false
    menu=self:menu(title,rows,{grid=true,columns=2,perpage=6,header=header,close=function()if not changing then exit()end end})
   end)
  end
  load(1)
 end
 function Shelf:showMetadataConflict(value)
  local item=folder(self.core,value);local issue=self.core:metadataConflict(item)
  if not issue then return self:editFolderMetadata(item)end
  local dialog
  local function choose(choice)
   local ok,err=self.core:resolveMetadataConflict(item,choice)
   if not ok then env.problem(err);return end
   close(dialog)
   env.message(tr(choice=='local'and 'Saved locally. Changes will sync when online.'or'Folder information updated'))
  end
  local buttons={}
  if issue.code~='ambiguous_metadata' then
   buttons[1]={
    {text=tr('Use local version'),enabled=issue.local_values~=nil,callback=function()choose('local')end},
    {text=tr('Use cloud version'),enabled=issue.remote_values~=nil,callback=function()choose('remote')end},
   }
  end
  buttons[#buttons+1]={{text=tr('Close'),callback=function()close(dialog)end}}
  dialog=require('ui/widget/buttondialog'):new{title=tr('Folder metadata conflict'),width_factor=.94,buttons=buttons}
  local H=require('ui/widget/horizontalgroup')
  local V=require('ui/widget/verticalgroup')
  local HS=require('ui/widget/horizontalspan')
  local Screen=require('device').screen
  local gap=Screen:scaleBySize(8)
  local width=math.floor((dialog:getAddedWidgetAvailableWidth()-gap)/2)
  local row=H:new{align='top',not_focusable=true}
  for i,choice in ipairs{'local','remote'}do
   if i==2 then row[#row+1]=HS:new{width=gap}end
   local values=issue[choice..'_values']
   local cover=issue[choice..'_preview_path']
   local title=tr(choice=='local'and'Local version'or'Cloud version')
   local details=values and ((values.title or tr('None'))..'\n'..excerpt(values.description))or tr('Version unavailable')
   if values and values.cover_hidden then details=details..'\n'..tr('Cover hidden')
   elseif values and values.cover and not cover then details=details..'\n'..tr('Cover preview unavailable')end
   local Text=require('ui/widget/textboxwidget')
   local Font=require('ui/font')
   row[#row+1]=V:new{align='center',
    Text:new{text=title,width=width,face=Font:getFace('cfont',16),bold=true,alignment='center'},
    coverWidget(cover,width,Screen:scaleBySize(95),title),
    Text:new{text=details,width=width,face=Font:getFace('smallinfofont'),height=Screen:scaleBySize(100),height_adjust=true,height_overflow_show_ellipsis=true},
   }
  end
  dialog:addWidget(row)
  UI():show(dialog)
  return dialog
 end
end
