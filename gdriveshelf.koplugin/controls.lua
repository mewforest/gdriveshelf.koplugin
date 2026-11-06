-- Native dialogs and queue presentation; cloud/state mutations stay in Core.
return function(Shelf,env)
 local tr=require('gdriveshelf/i18n').gettext
 local function UI()return require('ui/uimanager')end
 local function folder(core,value)return type(value)=='table'and value or(core.state.folders[value]or{id=value,name=value,is_folder=true})end
 local function close(menu)if menu and not menu._closed then menu:onCloseAllMenus()end end
 local function excerpt(text)
  local result={};for char in (text or''):gmatch('[%z\1-\127\194-\244][\128-\191]*')do result[#result+1]=char;if #result==100 then return table.concat(result)..'…'end end;return table.concat(result)
 end
 local function snapshot(core,id)
  return core.storage:readJSON(core.storage.root..'/snapshots/'..require('gdriveshelf/storage').key(id)..'.json')
 end
 function Shelf:downloadActivity()
  local core=self.core;local downloads=core.state.downloads or{};local selected
  local active=core.jobs and core.jobs.active;local id=active and active.key:match('^download:(.+)$')
  if id and downloads[id]then selected={id=id,data=downloads[id]}end
  if not selected then
   for _,job in ipairs(core.jobs and core.jobs.queue or{})do local key=job.key:match('^download:(.+)$');if key and downloads[key]then selected={id=key,data=downloads[key]};break end end
  end
  if not selected then for key,data in pairs(downloads)do selected={id=key,data=data};break end end
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
   self.core:reindexHome();self:showSettingsCategory('catalog')
  end})
 end
 function Shelf:reindexLibrary()
  if not self.settings.index_enabled or not self.settings.index_recursive_confirmed then return self:enableRecursiveIndex()end
  UI():show(self:confirmation{text=tr('Rebuild the catalog from this home folder? Saved documents and reading progress will be kept.'),ok_text=tr('Reindex library'),ok_callback=function()self.core:reindexHome();env.message(tr('Catalog rebuild queued'))end})
 end
 function Shelf:showQueue()
  local core=self.core;local rows={{text=tr('Retry pending tasks'),callback=function()core:resetNetwork();core.jobs:pump();self:showQueue()end}}
  local state=core.networkState and core:networkState()or'online'
  if state~='online'then rows[#rows+1]={text=tr(({retry='Waiting before retry',offline='Offline mode',sleep='Waiting for the device to wake',auth='Authorization is required'})[state]or state),select_enabled=false}end
  if core.index_job then local j=core.index_job;rows[#rows+1]={text=string.format(tr('Indexing folders: %d/%d'),j.done or 0,j.total or 0)..tr(' · cancel'),callback=function()core:cancelIndex();self:showQueue()end}end
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
 function Shelf:editFolderMetadata(value,draft)
  local item=folder(self.core,value);local info=self.core:titleInfo(item.id)
  draft=draft or{values={title=info.title or item.name,description=info.description or''}}
  if self.metadata_editor then close(self.metadata_editor)end
  local menu
  local function field(key,label,multiline)
   local dialog
   dialog=require('ui/widget/inputdialog'):new{title=tr(label),input=draft.values[key]or'',fullscreen=multiline,allow_newline=multiline,buttons={{
    {text=tr('Cancel'),id='close',callback=function()UI():close(dialog)end},
    {text=tr('Save'),is_enter_default=true,callback=function()draft.values[key]=dialog:getInputText();UI():close(dialog);self:editFolderMetadata(item,draft)end},
   }}}
   UI():show(dialog);dialog:onShowKeyboard()
  end
  local function extract()
   close(menu);self:extractCoverForEditor(item,draft)
  end
  local rows={
   {text=tr('Title')..': '..(draft.values.title or''),callback=function()field('title','Title',false)end},
   {text=tr('Description')..': '..excerpt(draft.values.description),callback=function()field('description','Description',true)end},
   {text=tr('Choose cover image'),callback=function()
    close(menu);local chooser
    chooser=require('ui/widget/filechooser'):new{title=tr('Choose cover image'),path=self.settings.cover_import_dir or require('apps/filemanager/filemanagerutil').getHomeFolder(),ui=self.ui,show_unsupported=false,
     file_filter=function(name)return name:lower():match('%.png$')or name:lower():match('%.jpe?g$')or name:lower():match('%.webp$')end,
     onFileSelect=function(_,selected)
      self:runAction(function()draft.cover=selected.path;self.settings.cover_import_dir=selected.path:match('^(.*)/');self:saveSettings();UI():close(chooser);self:editFolderMetadata(item,draft)end)
     end}
    UI():show(chooser)
   end},
   {text=tr('Cover from first document (beta)'),callback=extract},
   {text=tr('Reset custom cover'),callback=function()draft.cover=false;self:editFolderMetadata(item,draft)end},
   {text=tr('Save metadata'),callback=function()
    if draft.values.title==''then draft.values.title=nil end
    local ok,err=self.core:saveFolderMetadata(item,draft.values,draft.cover)
    if not ok then env.problem(err);return end
    close(menu);self.metadata_editor=nil;env.message(tr('Saved locally. Changes will sync when online.'))
   end},
   {text=tr('Cancel'),callback=function()close(menu);self.metadata_editor=nil end},
  }
  local cover=draft.cover~=false and(draft.cover or info.cover_path)or nil
  if cover then table.insert(rows,4,{text=tr('Preview cover'),callback=function()UI():show(require('ui/widget/imageviewer'):new{file=cover,title_text=draft.values.title or item.name,with_title_bar=true})end})end
  menu=self:menu(tr('Edit folder information'),rows,{multiline=true,perpage=8});self.metadata_editor=menu;return menu
 end
 function Shelf:extractCoverForEditor(item,draft)
  local token={};self.cover_request=token;local dialog;local key
  local function cancel()if self.cover_request~=token then return end;self.cover_request=nil;if key then self.core.jobs:cancel(key)end;UI():close(dialog)end
  dialog=require('ui/widget/buttondialog'):new{title=tr('Extracting cover…'),buttons={{{text=tr('Cancel'),callback=cancel}}}}
  dialog.onClose=function()cancel();return true end;UI():show(dialog)
  local accepted,job=self.core:extractFolderCover(item,function(path,err)
   if self.cover_request~=token then return end;self.cover_request=nil;UI():close(dialog)
   if not path then env.problem(err);return end
   draft=draft or{values={title=self.core:titleInfo(item.id).title,description=self.core:titleInfo(item.id).description or''}};draft.cover=path;self:editFolderMetadata(item,draft)
  end)
  if accepted then key=type(job)=='string'and job or nil end
 end
 function Shelf:showMetadataConflict(value)
  local item=folder(self.core,value);local issue=self.core:metadataConflict(item)
  if not issue then return self:editFolderMetadata(item)end
  local rows={{text=tr('Both metadata versions were preserved.'),select_enabled=false}}
  for _,choice in ipairs{'local','remote'}do
   local selected=choice;local values=issue[choice..'_values']
   rows[#rows+1]={text=tr(choice=='local'and'View local version'or'View remote version'),select_enabled=values~=nil,callback=function()UI():show(require('ui/widget/textviewer'):new{title=tr('Folder information'),text=(values.title or'')..'\n\n'..(values.description or'')})end}
   rows[#rows+1]={text=tr(choice=='local'and'Use local version'or'Use remote version'),select_enabled=issue.code~='ambiguous_metadata'and values~=nil,callback=function()
    UI():show(self:confirmation{text=tr('Use this version of the folder information?'),ok_text=tr('Apply'),ok_callback=function()local ok,err=self.core:resolveMetadataConflict(item,selected);if not ok then env.problem(err)else env.message(tr('Folder information updated'))end end})
   end}
  end
  return self:menu(tr('Folder metadata conflict'),rows,{multiline=true,perpage=7})
 end
end
