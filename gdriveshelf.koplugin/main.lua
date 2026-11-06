local pluginRoot=debug.getinfo(1,'S').source:sub(2):match('^(.*)/main%.lua$') or 'plugins/gdriveshelf.koplugin'
dofile(pluginRoot..'/bootstrap.lua')(pluginRoot)
local WidgetContainer=require('ui/widget/container/widgetcontainer')
local Core=require('gdriveshelf/core')
local Storage=require('gdriveshelf/storage')
local Jobs=require('gdriveshelf/jobs')
local Library=require('gdriveshelf/library')
local Metadata=require('gdriveshelf/metadata')
local SDR=require('gdriveshelf/sdr')
local shared=package.loaded['gdriveshelf/runtime'] or {owners=setmetatable({},{__mode='k'})}
package.loaded['gdriveshelf/runtime']=shared
local Shelf=WidgetContainer:extend{name='gdriveshelf',title='GDriveShelf',is_doc_only=false}
local MiB=1048576
local function ui()return require('ui/uimanager')end
local function bytes(n)return n and string.format('%.1f МиБ',n/MiB) or 'неизвестно'end
local function message(text)ui():show(require('ui/widget/infomessage'):new{text=tostring(text),timeout=5})end
local function problem(e)message(type(e)=='table' and (e.message or e.code) or e or 'Не удалось выполнить действие')end
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
  shared.core.oncredentials=function(c)if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',c)then message('Не удалось сохранить обновлённую авторизацию')end end
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
 Dispatcher:registerAction('gdriveshelf_next',{category='none',event='GDriveShelfNext',title='GDriveShelf: следующая глава',reader=true})
end
function Shelf:addToMainMenu(items)
 items.gdriveshelf={text='GDriveShelf',sub_item_table={
  {text='Библиотека Google Drive',callback=function()self:showLibrary()end},
  {text='Доступно офлайн',callback=function()self:showOffline()end},
  {text='Следующая глава',enabled_func=function()return self:activeEntry()~=nil end,callback=function()self:onGDriveShelfNext()end},
  {text='Память и кэш',callback=function()self:showMemory()end},
  {text='Очередь и синхронизация',callback=function()self:showQueue()end},
  {text='Настройки',callback=function()self:showSettings()end},
 }}
end
function Shelf:menu(title,rows,options)
 options=options or {};local Menu=require('ui/widget/menu');local Device=require('device');local menu
 menu=Menu:new{title=title,item_table=rows,width=Device.screen:getWidth(),height=Device.screen:getHeight(),
  is_borderless=true,is_popout=false,items_per_page=options.perpage,
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
 if kind=='conflict'then message('Сохранены обе версии прогресса. Выберите версию в очереди GDriveShelf.')end
end
function Shelf:showLibrary()self:showFolder(self.settings.home or 'root')end
Shelf.onShowGDriveShelf=Shelf.showLibrary
function Shelf:folderRows(parent,entries,offline)
 local rows={{text='← Библиотека и действия',callback=function()self:showFolderActions(parent,offline)end}}
 local info=self.core:titleInfo(parent)
 for _,entry in ipairs(Library.ordered(Metadata.visible(entries,self.settings.show_service),self.settings.sort,self.settings.reverse,self.core.natural))do
  local e=entry;local cached=self.core:cached(e.id);local summary=self.core.state.summaries[e.id]
  local progress=summary and summary.percent and string.format(' · %d%%',math.floor(summary.percent*100+0.5)) or ''
  local pin=cached and (cached.pool=='offline' and '★ ' or '✓ ') or ''
  local name=info.chapters[e.name] or e.name
  rows[#rows+1]={text=e.is_folder and ('▸ '..e.name) or (pin..name..progress),entry=e,
   callback=function()if e.is_folder then self:showFolder(e.id,offline)elseif Library.supported(e)then self:openEntry(e)else self:fileActions(e)end end,
   hold_callback=function()if e.is_folder then self:folderActions(e)else self:fileActions(e)end end}
 end
 if #rows==1 then rows[#rows+1]={text=offline and 'Нет загруженных глав' or 'Папка пуста',select_enabled=false}end
 return rows
end
function Shelf:showFolder(parent,offline)
 local core=self:getCore();if self.folder_menu then self.folder_menu:onCloseAllMenus()end
 self.folder_id,self.folder_offline=parent,offline
 local folder=core.state.folders[parent]or{id=parent,name=parent,is_folder=true}
 local title=folder.name..(self.settings.offline and ' · офлайн' or '')
 self.folder_entries=offline and self:offlineChildren(parent) or core:cachedList(parent)
 local menu=self:menu(title,self:folderRows(parent,self.folder_entries,offline),{lazy=not offline})
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
  {text='Домашняя папка',callback=function()self:showLibrary()end},
  {text='Родительская папка',enabled_func=function()return folder.parent_id~=nil end,callback=function()if folder.parent_id then self:showFolder(folder.parent_id,offline)end end},
  {text='Действия текущей папки',callback=function()self:folderActions(folder)end},
  {text='Информация о манге',callback=function()self:showInfo(parent)end},
  {text='Доступно офлайн',callback=function()self:showOffline()end},
  {text='Очередь и конфликты',callback=function()self:showQueue()end},
  {text='Память и кэш',callback=function()self:showMemory()end},
  {text='Настройки',callback=function()self:showSettings()end},
 })
end
function Shelf:folderActions(folder)
 self:menu(folder.name,{
  {text='Сделать домашней',callback=function()self.settings.home=folder.id;self:saveSettings();message('Домашняя папка сохранена')end},
  {text='Скачать папку рекурсивно',callback=function()
   self.core:scanFolder(folder,function(result,e)
    if not result then problem(e);return end
    ui():show(require('ui/widget/confirmbox'):new{text='Скачать '..#result.files..' файлов ('..bytes(result.size)..')?\nЗакреплённые файлы не очищаются автоматически.',ok_text='Скачать',ok_callback=function()for _,entry in ipairs(result.files)do self.core:download(entry,'offline')end;self:showQueue()end})
   end)
  end},
  {text='Удалить загрузки этой папки и вложенных',callback=function()self:removeTree(folder.id)end},
  {text='Информация о манге',callback=function()self:showInfo(folder.id)end},
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
 for _,folder in ipairs(Library.ordered(self:offlineChildren(nil),'natural',false,self.core.natural))do
  local e=folder;rows[#rows+1]={text='▸ '..e.name,callback=function()self:showFolder(e.id,true)end}
 end
 if #rows==0 then rows={{text='Нет загруженных файлов',select_enabled=false}}end
 self:menu('Доступно офлайн — по папкам',rows)
end
function Shelf:removeTree(parent)
 local ids,total={},0
 for id,e in pairs(self.core.state.entries)do
  if e.pool=='auto' or e.pool=='offline'then
   local p=e.parent_id;local seen={}
   while p and not seen[p]do if p==parent then ids[#ids+1]=id;total=total+(e.size or 0);break end;seen[p]=true;local f=self.core.state.folders[p];p=f and f.parent_id end
  end
 end
 ui():show(require('ui/widget/confirmbox'):new{text='Удалить локальные загрузки: '..#ids..' файлов, '..bytes(total)..'?\nПрогресс и очередь синхронизации сохранятся.',ok_text='Удалить',ok_callback=function()for _,id in ipairs(ids)do self.core:removeFile(id)end;self:onCoreChange('cleared')end})
end
function Shelf:activeEntry()
 local path=self.ui and self.ui.document and self.ui.document.file
 if not path or not self.core then return nil end
 for id,e in pairs(self.core.state.entries)do if e.path==path then return e end end
end
function Shelf:applyRemote(entry,record,path,allow_pending)
 local active=self:activeEntry()
 if (active and active.id==entry.id)or self.core.active_id==entry.id then return nil,'Закройте книгу перед восстановлением прогресса; затем откройте её снова.'end
 if self.core.state.sync.pending[entry.id] and not allow_pending then return nil,'Есть новый локальный прогресс. Сначала разрешите конфликт.'end
 local cached=(self.core.state.entries or {})[entry.id]or entry
 if not record or not record.lua or not sameBook(record.book_stamp,cached)then return nil,'Версия книги изменилась или не подтверждена. Старый прогресс не применён.'end
 local data,e=SDR.decode(record.lua);if not data then return nil,e end
 data.doc_path=path
 local DocSettings=require('docsettings')
 local settings=DocSettings:open(path)
 local ok,result=pcall(settings.flush,settings,data)
 if not ok or not result then return nil,'Не удалось сохранить нативные метаданные' end
 if not allow_pending then
  self.core.state.sync.bases[entry.id]={lua=record.lua,stamp=record.stamp,book_stamp=record.book_stamp}
  self.core:save()
 end
 return true
end
function Shelf:openEntry(entry)
 self.core:open(entry,function(path,e)
  if not path then problem(e);return end
  local DocSettings=require('docsettings')
  if not DocSettings:hasSidecarFile(path) and not self.core.state.sync.pending[entry.id]then
   local remote=self.core:remote(entry)
   if remote then self:applyRemote(entry,remote,path)end
  end
  if self.folder_menu then self.folder_menu:onCloseAllMenus()end
  self.core.active_id=entry.id;self.core.opening_id=nil
  if self.ui.document then self.ui:switchDocument(path)else require('apps/reader/readerui'):showReader(path)end
 end)
end
function Shelf:fileActions(entry)
 local cached=self.core:cached(entry.id)
 self:menu(entry.name,{
  {text='Открыть',callback=function()self:openEntry(entry)end},
  {text='Скачать и закрепить офлайн',callback=function()self.core:download(entry,'offline');message('Файл добавлен в очередь загрузки')end},
  {text='Удалить локальную загрузку',callback=function()
   ui():show(require('ui/widget/confirmbox'):new{text='Удалить локальный файл? Прогресс сохранится.',ok_text='Удалить',ok_callback=function()local ok,e=self.core:removeFile(entry.id);if not ok then problem(e)end end})
  end},
  {text='Применить загруженный облачный прогресс',callback=function()
   if not cached then message('Сначала скачайте книгу');return end
   local remote=self.core:remote(entry)
   ui():show(require('ui/widget/confirmbox'):new{text='Применить сохранённую облачную версию прогресса? Книга должна быть закрыта.',ok_text='Применить',ok_callback=function()local ok,e=self:applyRemote(entry,remote,cached.path);if not ok then problem(e)else message('Прогресс применён; откройте книгу')end end})
  end},
  {text='Восстановить локальный снимок',callback=function()self:restoreSnapshot(entry)end},
  {text='Информация о манге',callback=function()self:showInfo(entry.parent_id)end},
 })
end
function Shelf:showInfo(parent)
 local info=self.core:titleInfo(parent);local text={info.title or parent}
 for _,key in ipairs{'author','status','tags','publisher','year','description'}do if info[key]and info[key]~=''then text[#text+1]=tostring(info[key])end end
 local buttons={}
 if info.cover_path then buttons[1]={{text='Обложка',callback=function()ui():show(require('ui/widget/imageviewer'):new{file=info.cover_path,title_text=info.title or 'Обложка',with_title_bar=true})end}}end
 ui():show(require('ui/widget/textviewer'):new{title='Информация о манге',text=table.concat(text,'\n\n'),buttons_table=#buttons>0 and buttons or nil,add_default_buttons=true})
end
function Shelf:showMemory()
 local usage=self.core:cache():usage();local storage=self.core.storage
 local sdr=storage:treeSize(storage.root..'/snapshots')
 local function nativeSize(path)
  local sum=0;for name in storage.lfs.dir(path)do if name~='.'and name~='..'then local p=path..'/'..name;local a=storage.lfs.symlinkattributes(p);if a and a.mode=='directory'then if name:match('%.sdr$')then sum=sum+storage:treeSize(p)else sum=sum+nativeSize(p)end end end end;return sum
 end
 sdr=sdr+nativeSize(storage.root..'/files')
 local rows={{text='Свободно на диске: '..bytes(storage:freeBytes()),select_enabled=false},
 {text='Резерв: 512 МиБ · активные файлы защищены',select_enabled=false},
 {text='Прогресс/снимки: '..bytes(sdr)..' · индекс/очередь: '..bytes(storage:size(self.core.index_path)),select_enabled=false}}
 for _,pool in ipairs{'auto','offline','meta'}do
  local p=pool;local label=({auto='Автокэш чтения',offline='Закреплённые загрузки',meta='Обложки, списки и статусы'})[p]
  rows[#rows+1]={text=label..': '..bytes(usage[p])..' · очистить',callback=function()
   ui():show(require('ui/widget/confirmbox'):new{text='Очистить «'..label..'» ('..bytes(usage[p])..')?\nОткрытые файлы, нативный прогресс и очередь сохранятся.',ok_text='Очистить',ok_callback=function()self.core:clearPool(p);self:showMemory()end})
  end}
 end
 rows[#rows+1]={text='Путь кэша: '..storage.root,select_enabled=false}
 self:menu('Память и кэш',rows)
end
function Shelf:showQueue()
 local rows={{text='Повторить сохранённые задания',callback=function()self.core.retry_after=nil;self.core:resume();self.core.jobs:pump();message('Повтор запущен')end}}
 local jobs=self.core.jobs
 if jobs.active then local key=jobs.active.key;rows[#rows+1]={text='Выполняется: '..key..' · отменить',callback=function()local id=key:match('^download:(.+)$');if id then self.core:cancelDownload(id)else jobs:cancel(key)end;self:showQueue()end}end
 for id,d in pairs(self.core.state.downloads)do local file_id=id
  rows[#rows+1]={text='Загрузка: '..d.entry.name..(d.error and (' · '..d.error) or '')..' · отменить',callback=function()self.core:cancelDownload(file_id);self:showQueue()end}
 end
 for id,pending in pairs(self.core.state.sync.pending)do local e=pending.entry
  rows[#rows+1]={text=(self.core.state.sync.conflicts[id]and 'Конфликт: 'or 'Синхронизация: ')..e.name,callback=function()self:showConflict(e)end}
 end
 for id,conflict in pairs(self.core.state.sync.conflicts)do if not self.core.state.sync.pending[id]then local e=self.core.state.docs[id];if e then rows[#rows+1]={text='Конфликт: '..e.name,callback=function()self:showConflict(e)end}end end end
 self:menu('Очередь и синхронизация',rows)
end
function Shelf:showConflict(entry)
 local saved=self.core.state.sync.conflicts[entry.id]
 if not saved then message('Локальный снимок ожидает отправки. Обе версии проверяются перед записью.');return end
 local function inspect(text,title)ui():show(require('ui/widget/textviewer'):new{title=title,text=text or 'Версия отсутствует'})end
 self:menu('Конфликт: '..entry.name,{
  {text='Посмотреть локальную версию',callback=function()inspect(saved.local_lua,'Локальный прогресс')end},
  {text='Посмотреть облачную версию',callback=function()inspect(saved.remote_lua,'Облачный прогресс')end},
  {text='Использовать локальную версию',callback=function()
   ui():show(require('ui/widget/confirmbox'):new{text='Отправить локальный прогресс? Облачная версия сохранена в конфликте и будет перепроверена.',ok_text='Локальная',ok_callback=function()
    local archived=self:archiveConflict(entry,saved);if not archived then message('Не удалось сохранить обе версии конфликта');return end;local result,e=self.core:sync():resolve(entry.id,'local');if not result then problem(e);return end;self.core:save();self.core:flushPending();message('Локальная версия поставлена в очередь')
   end})
  end},
  {text='Использовать облачную версию',callback=function()
   local cached=self.core:cached(entry.id);if not cached then message('Сначала скачайте книгу');return end
   ui():show(require('ui/widget/confirmbox'):new{text='Сохранить облачный прогресс в локальные метаданные? Закройте книгу перед применением.',ok_text='Облачная',ok_callback=function()
    if not self:archiveConflict(entry,saved)then message('Не удалось сохранить обе версии конфликта');return end
    local ok,e=self:applyRemote(entry,{lua=saved.remote_lua,stamp=saved.stamp,book_stamp=saved.book_stamp},cached.path,true)
    if not ok then problem(e);return end
    local result;result,e=self.core:sync():resolve(entry.id,'remote');if not result then problem(e);return end
    self.core:save();message('Облачная версия применена. Откройте книгу снова.')
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
 if not record or not cached then message('Нет локального снимка или файла книги');return end
 ui():show(require('ui/widget/confirmbox'):new{text='Восстановить локальный снимок прогресса? Закройте книгу перед восстановлением.',ok_text='Восстановить',ok_callback=function()
  local ok,e=self:applyRemote(entry,record,cached.path,true);if not ok then problem(e);return end
  local data=SDR.decode(record.lua);data.doc_path=cached.path;self.core:snapshot(entry,data);message('Локальный снимок восстановлен')
 end})
end
function Shelf:input(title,current,callback,input_type)
 local dialog
 dialog=require('ui/widget/inputdialog'):new{title=title,input=tostring(current or ''),input_type=input_type,buttons={{
  {text='Отмена',callback=function()ui():close(dialog)end},
  {text='Сохранить',is_enter_default=true,callback=function()local text=dialog:getInputText();local ok,e=callback(text);if ok~=false then ui():close(dialog)else problem(e)end end},
 }}}
 ui():show(dialog);dialog:onShowKeyboard()
end
function Shelf:pickCredentials()
 local chooser
 chooser=require('ui/widget/filechooser'):new{title='Выберите JSON авторизации GDriveShelf',ui=self.ui,path=self.settings.import_dir or '/',show_unsupported=false,
  file_filter=function(name)return name:lower():match('%.json$')~=nil end,onFileSelect=function(_,item)ui():close(chooser);self:importCredentials(item.path)end}
 ui():show(chooser)
end
function Shelf:importCredentials(path)
 local credentials=self.core.storage:readJSON(path)
 if type(credentials)~='table' or type(credentials.refresh_token)~='string' or type(credentials.client_id)~='string' or type(credentials.access_token)~='string'then message('Это не JSON результата tools/authorize.py');return end
 if credentials.scope and credentials.scope~='https://www.googleapis.com/auth/drive'then message('Требуется полное разрешение Google Drive');return end
 if self.core.active_id then message('Закройте книгу перед сменой аккаунта');return end
 if not privateJSON(shared.settings_dir..'/gdriveshelf-credentials.json',credentials)then message('Не удалось безопасно сохранить авторизацию');return end
 if shared.core then shared.core.jobs:clear()end
 shared.core=nil
 for owner in pairs(shared.owners)do owner.core=nil end
 self.core=self:getCore();self.settings.import_dir=path:match('^(.*)/')or '/';self:saveSettings();message('Авторизация импортирована')
end
function Shelf:showSettings()
 local s=self.settings
 local function number(title,key,lo,hi)
  self:input(title,s[key],function(text)local n=tonumber(text);if not n or n~=math.floor(n)or n<lo or n>hi then return false,'Введите целое число от '..lo..' до '..hi end;s[key]=n;self:saveSettings();return true end,'number')
 end
 local function toggle(key) s[key]=not s[key];self:saveSettings()end
 local function mark(value)return value and '✓ ' or '○ 'end
 self:menu('Настройки GDriveShelf',{
  {text=mark(s.offline)..'Офлайн: запретить сеть',callback=function()self.core:setOffline(not s.offline);self:saveSettings();self:showSettings()end},
  {text='Домашняя папка: ID или ссылка',callback=function()self:input('ID/ссылка Google Drive',s.home,function(text)local id=text:match('/folders/([%w_-]+)')or text:match('[?&]id=([%w_-]+)')or text;if id~='root'and not id:match('^[%w_-]+$')then return false,'Некорректный ID папки'end;s.home=id;self:saveSettings();return true end)end},
  {text='Импортировать JSON авторизации',callback=function()self:pickCredentials()end},
  {text='Импортировать JSON по пути',callback=function()self:input('Полный путь к JSON авторизации','',function(path)self:importCredentials(path);return true end)end},
  {text='Каталог кэша',callback=function()self:input('Каталог кэша (старый кэш сохраняется)',s.cache_dir,function(path)
   if path:sub(1,1)~='/' or path:find('[%z\r\n]')then return false,'Введите абсолютный путь'end
   if self.core.active_id then return false,'Сначала закройте книгу'end
   if next(self.core.state.sync.pending)then return false,'Сначала синхронизируйте ожидающий прогресс'end
   shared.core.jobs:clear();s.cache_dir=path;self:saveSettings();shared.core=nil;for owner in pairs(shared.owners)do owner.core=nil end;self.core=self:getCore();return true
  end)end},
  {text='Автокэш: '..s.auto_mib..' МиБ',callback=function()number('Лимит автокэша, МиБ','auto_mib',1,1048576)end},
  {text='Метаданные: '..s.meta_mib..' МиБ',callback=function()number('Лимит метаданных, МиБ','meta_mib',1,1048576)end},
  {text='Предзагрузка следующих глав: '..s.prefetch,callback=function()number('Предзагрузка, 0–3 главы','prefetch',0,3)end},
  {text='Порог предзагрузки: '..s.threshold..'%',callback=function()number('Порог предзагрузки, %','threshold',0,100)end},
  {text=mark(s.immediate)..'Предзагружать сразу после открытия',callback=function()toggle('immediate');self:showSettings()end},
  {text=mark(s.sync_enabled)..'Синхронизация нативного прогресса',callback=function()toggle('sync_enabled');if s.sync_enabled then self.core:flushPending()end;self:showSettings()end},
  {text=mark(s.show_service)..'Показывать служебные файлы',callback=function()toggle('show_service');self:showSettings()end},
  {text='Сортировка: '..(s.sort or 'natural'),callback=function()
   local rows={};for _,mode in ipairs{'natural','name','size','date'}do local m=mode;rows[#rows+1]={text=m,callback=function()s.sort=m;self:saveSettings()end}end;self:menu('Сортировка',rows)
  end},
  {text=mark(s.reverse)..'Обратный порядок',callback=function()toggle('reverse');self:showSettings()end},
  {text='Сохранить локальный снимок текущей книги',callback=function()self:snapshotCurrent();message('Снимок сохранён для открытой книги GDriveShelf')end},
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
   ui():show(require('ui/widget/confirmbox'):new{text='Последняя глава в этой папке прочитана.',ok_text='Закрыть',ok_callback=function()self._end_dialog=nil end,cancel_callback=function()self._end_dialog=nil end})
   return
  end
  ui():show(require('ui/widget/confirmbox'):new{text='Открыть следующую главу?\n'..next_entry.name,ok_text='Открыть',
   ok_callback=function()self._end_dialog=nil;self:openEntry(next_entry)end,cancel_callback=function()self._end_dialog=nil end})
 end)
 return true
end
function Shelf:onGDriveShelfNext()
 local entry=self:activeEntry();local next_entry=entry and self.core:next(entry)
 if next_entry then self:openEntry(next_entry)else message('Следующей главы в текущей папке нет')end
 return true
end
function Shelf:onNetworkConnected()if self.core and not self.settings.offline then self.core.retry_after=nil;self.core:resume()end end
function Shelf:onSuspend()if self.core then self.core.sleeping=true;self.core.jobs:setOffline(true)end end
function Shelf:onResume()if self.core then self.core.sleeping=false;self.core.jobs:setOffline(self.settings.offline==true);self:onNetworkConnected()end end
return Shelf
