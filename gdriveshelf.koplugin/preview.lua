-- A preview has its own short-lived byte budget and never opens a document.
local Zip=require('gdriveshelf/zipcover')
local Thumbnails=require('gdriveshelf/thumbnails')
local SDR=require('gdriveshelf/sdr')
local MiB=1048576
local P={}
local function problem(code,message)return {code=code,message=message}end
local function limitError()return problem('preview_limit','Archive preview byte limit reached')end
local function changed()return problem('changed','The archive changed. Refresh the folder and try again.')end
local function matches(entry,current)
 return current and not current.trashed and not current.is_folder
  and entry.version~=nil and current.version~=nil and tostring(entry.version)==tostring(current.version)
  and current.id==entry.id and current.parent_id==entry.parent_id and current.name==entry.name
  and tonumber(current.size)==tonumber(entry.size) and (not entry.checksum or current.checksum==entry.checksum)
end

function P.readPage(entry,provider,local_path,index,number,limit,destination,width,height,render)
 local file
 if local_path then
  file=io.open(local_path,'rb')
  if not file then return {bytes=0,error=problem('io','Cannot read local archive')}end
 else
  local current,err=provider:stat(entry.id)
  if not matches(entry,current)then return {bytes=0,error=err or changed()}end
 end
 local read,charged=Zip.partialReader(entry,function(first,last)
  if file then
   if file:seek('set',first)then return file:read(last-first+1)end
  else
   return provider:range(entry,first,last,last-first+1)
  end
 end,file~=nil,limit)
 local err,data
 local new_index=not index
 if new_index then index,err=Zip.previewIndex(entry,read)end
 if index then data,err=Zip.previewPage(index,number,read)end
 if file then file:close()end
 local bytes=charged()
 if not data then return {bytes=bytes,error=err}end
 if not file then
  local current;current,err=provider:stat(entry.id)
  if not matches(entry,current)then return {bytes=bytes,error=err or changed()}end
 end
 local value;value,err=(render or Thumbnails.render)(data,destination,width,height)
 if value then return {value=value,index=new_index and index or nil,bytes=bytes}end
 return {bytes=bytes,error=err}
end

local Session={};Session.__index=Session
local function localStamp(core,entry,path)
 if not path then return nil end
 local attr=core.storage.lfs.attributes(path)
 if not attr or attr.mode~='file' or attr.size~=tonumber(entry.size)then return nil end
 return table.concat({attr.dev or '',attr.ino or '',attr.modification or '',attr.change or '',attr.size},':')
end
function P.new(core,entry,width,height)
 if core.retired then return nil,problem('cancelled','Cancelled')end
 local size=tonumber(entry.size)
 if not (entry.name or ''):lower():match('%.cbz$') or not size or size<23 or size>9007199254740991 or size~=math.floor(size)then
  return nil,problem('preview_format','This CBZ archive format is unsupported')
 end
 local cached=core:cached(entry.id)
 local path=cached and SDR.sameBook(entry,cached) and cached.path
 local stamp=localStamp(core,entry,path)
 if not stamp then
  path=nil
  if not core:online()then return nil,problem('offline','Connect to preview this CBZ or open a downloaded copy.')end
  if not entry.version then return nil,changed()end
 end
 if core.quick_preview_session then core.quick_preview_session:close()end
 core.quick_preview_sequence=(core.quick_preview_sequence or 0)+1
 local key='quick-preview-'..core.jobs.nonce..'-'..core.quick_preview_sequence
 local self=setmetatable({core=core,entry=entry,key=key,path=path,stamp=stamp,
  remaining=math.min(32*MiB,size-1),width=math.min(width,1600),height=math.min(height,2000),generation=0},Session)
 core.quick_preview_session=self
 return self
end
function Session:check()
 local core=self.core
 if self.closed or core.retired or core.quick_preview_session~=self then return nil,problem('cancelled','Cancelled')end
 local current=core.state.docs[self.entry.id]
 if current and self.entry.version and not matches(self.entry,current)then return nil,changed()end
 if self.path and localStamp(core,self.entry,self.path)~=self.stamp then return nil,changed()end
 return true
end
local function removeLater(jobs,path)
 os.remove(path)
 if jobs.schedule then jobs.schedule(function()os.remove(path)end,1)end
end
function Session:close()
 if self.closed then return end
 self.closed=true
 local core=self.core
 if core.quick_preview_session==self then core.quick_preview_session=nil end
 local job=self.job
 if job then
  self.job=nil
  core.jobs:cancel(job.key);removeLater(core.jobs,job.path)
 end
 if self.rendered then os.remove(self.rendered);self.rendered=nil end
end
function Session:page(number,callback)
 if self.job then return end
 local current,err=self:check()
 if not current then callback(nil,err);return end
 local image=self.index and self.index.images[number]
 if not image and (self.index or number~=1)then return end
 if not self.path and not self.core:online()then
  callback(nil,problem('offline','Connect to preview this CBZ or open a downloaded copy.'));return
 end
 self.generation=self.generation+1
 local key=self.key..'-'..self.generation
 local path=self.core.jobs.dir..'/result-'..key..'.png'
 local job={key=key,path=path}
 self.job=job
 local allowance
 local function before()
  local ok,why=self:check()
  if not ok then return nil,why end
  -- Jobs may be restarted on wake. Reserve the next attempt before any
  -- network I/O and retain reservations whose workers never reported back.
  local maximum=image and (math.min(image.compressed,8*MiB)+30) or (9*MiB+65557+52)
  allowance=self.path and maximum or math.min(maximum,self.remaining)
  if not self.path then
   if allowance<22 then return nil,limitError()end
   self.remaining=self.remaining-allowance
  end
  return true
 end
 local function work(provider)
  return P.readPage(self.entry,provider,self.path,self.index,number,allowance,path,self.width,self.height)
 end
 local function finish(result,why)
  if self.job~=job then os.remove(path);return end
  self.job=nil
  if result and not self.path then self.remaining=self.remaining+math.max(0,allowance-result.bytes)end
  local ok,stale=self:check()
  if not ok or not result or not result.value then
   os.remove(path)
   callback(nil,stale or (result and result.error) or why or problem('preview','Cannot render this page'))
   return
  end
  self.index=result.index or self.index
  local previous=self.rendered
  self.rendered=path
  callback({path=path,page=number,total=#self.index.images})
  if previous then os.remove(previous)end
 end
 local queued
 if self.path then
  queued=self.core.jobs:enqueue(key,function()return work(nil)end,finish,true,before,nil,true,{timeout=20})
 else
  -- Worker errors return a result envelope with charged bytes. This avoids
  -- automatic network retries replaying partial reads outside the session budget.
  queued=self.core:network(key,work,finish,true,before,nil,false,{timeout=45})
 end
 if not queued and self.job==job then finish(nil,problem('worker','Cannot start page preview'))end
end

function P.install(Shelf)
 local tr=require('gdriveshelf/i18n').gettext
 function Shelf:closeQuickPreview()
  if self.quick_preview then self.quick_preview()end
 end
 function Shelf:showQuickPreview(entry)
  local UI=require('ui/uimanager')
  local Screen=require('device').screen
  local core=self.core
  self:closeQuickPreview()
  local session,err=P.new(core,entry,Screen:getWidth(),Screen:getHeight())
  local viewer,waiting
  local function closeWaiting()
   if not waiting then return end
   local dialog=waiting;waiting=nil;UI:close(dialog)
  end
  local function close()
   self.quick_preview=nil
   if session then session:close()end
   closeWaiting()
   if viewer then local old=viewer;viewer=nil;UI:close(old)end
  end
  local function fallback(why)
   close()
   if self.core~=core or (why and why.code=='cancelled')then return end
   local detail=why and tr(why.message or 'Cannot render this page')or tr('Cannot render this page')
   UI:show(self:confirmation{text=detail..'\n\n'..tr('Open the chapter normally?'),ok_text=tr('Open'),ok_callback=function()
    if self.core==core then self:openEntry(entry)end
   end})
  end
  if not session then fallback(err);return end
  self.quick_preview=close
  local function showPage(number)
   if waiting or session.closed then return end
   local dialog=require('ui/widget/buttondialog'):new{title=tr('Loading preview page…'),buttons={{{text=tr('Cancel'),callback=close}}}}
   dialog.onClose=function()close();return true end
   waiting=dialog;UI:show(dialog)
   session:page(number,function(result,why)
    closeWaiting()
    if session.closed or self.core~=core then close();return end
    if not result then fallback(why);return end
    local title=string.format(tr('Preview · page %d of %d'),result.page,result.total)
    if viewer then
     viewer.file=result.path
     viewer._images_list_cur=result.page
     viewer.title_bar:setTitle(title,true)
     viewer:update()
    else
     -- A list-backed ImageViewer supplies native page gestures, hardware
     -- keys and page indicators. Page acquisition remains asynchronous.
     viewer=require('ui/widget/imageviewer'):new{image={},file=result.path,images_list_nb=result.total,
      title_text=title,fullscreen=true}
     viewer.switchToImageNum=function(_,target)
      if target~=viewer._images_list_cur and target>=1 and target<=result.total then showPage(target)end
     end
     local previous=viewer.onCloseWidget
     viewer.onCloseWidget=function(widget)
      viewer=nil
      if previous then previous(widget)end
      if self.quick_preview==close then close()end
     end
     UI:show(viewer)
    end
   end)
  end
  showPage(1)
 end
end
return P
