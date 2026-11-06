local H=require('tests/helper');local ok,Logger=pcall(require,'diagnostics')
assert(ok,'diagnostics module is required for bounded opt-in logging')
local ffi=require('ffi');pcall(ffi.cdef,'int mkdir(const char *, unsigned int);')
local function withDir(fn)
 local dir=os.tmpname();os.remove(dir);assert(ffi.C.mkdir(dir,448)==0)
 local good,why=pcall(fn,dir)
 for _,name in ipairs{'diagnostics.log','diagnostics.previous.log','export.txt'}do os.remove(dir..'/'..name)end
 os.remove(dir);assert(good,why)
end
local function read(path)local f=io.open(path,'rb');if not f then return ''end;local text=f:read('*a');f:close();return text end
H.test('diagnostics OFF performs no IO even for hostile input and enabled callbacks',function()
 local open=io.open;local calls=0;io.open=function()calls=calls+1;error('private path')end
 local good,why=pcall(function()
  local log=Logger.new{dir='/not-created',version='0.1.0',runtime='Linux arm64'}
  assert(not log:event('job',{taskref=1}));log.enabled=function()error('private callback')end;assert(not log:event('job',{}));H.eq(calls,0)
 end)
 io.open=open;assert(good,why)
end)
H.test('whitelist excludes secrets, arbitrary enums and UI filenames from export',function()
 withDir(function(dir)
  local secret='SECRET_access_token_file.cbz_https://private.invalid/path'
  local log=Logger.new{dir=dir,enabled=function()return true end,version=secret,runtime=secret}
  assert(log:event('request',{operation='download',status=503,bytes=25,duration=2,error='network',taskref=7,message=secret,path=secret,filename=secret,headers={secret},url=secret,account=secret}))
  assert(log:event('ui_error',{module=secret,line=45,error=secret,operation=secret}))
  assert(not log:event(secret,{error=secret}));assert(log:export(dir..'/export.txt'))
  local text=read(dir..'/export.txt');assert(text:find('operation=download',1,true)and text:find('status=503',1,true)and text:find('taskref=7',1,true));assert(not text:find('SECRET',1,true)and not text:find('.cbz',1,true))
  assert(log:clear());H.eq(read(dir..'/diagnostics.log'),'');H.eq(read(dir..'/diagnostics.previous.log'),'')
 end)
end)
H.test('rotation keeps two bounded files and exports oldest then newest',function()
 withDir(function(dir)
  local log=Logger.new{dir=dir,enabled=function()return true end,version='0.1.0-dev',runtime='Linux arm64'}
  assert(log:event('job',{taskref=1,transition='queued'}));local line=read(dir..'/diagnostics.log')
  local f=assert(io.open(dir..'/diagnostics.log','wb'));assert(f:write(line:rep(math.floor(1048576/#line))));f:close()
  assert(log:event('job',{taskref=2,transition='completed'}))
  local first,second=read(dir..'/diagnostics.previous.log'),read(dir..'/diagnostics.log');assert(#first>0 and #first<=1048576 and #second<=1048576 and #first+#second<=2097152)
  assert(log:export(dir..'/export.txt'));H.eq(read(dir..'/export.txt'),first..second)
  assert(not log:export(dir..'/diagnostics.log'))
 end)
end)
H.test('readonly and throwing filesystems never escape logging export or clear',function()
 withDir(function(dir)
  local log=Logger.new{dir=dir,enabled=function()return true end}
  local open,remove,rename=io.open,os.remove,os.rename
  io.open=function()error('SECRET filesystem error')end;os.remove=function()error('SECRET remove')end;os.rename=function()error('SECRET rename')end
  local good,why=pcall(function()assert(not log:event('job',{taskref=1}));assert(not log:export(dir..'/export.txt'));assert(not log:clear())end)
  io.open,os.remove,os.rename=open,remove,rename;assert(good,why)
  log.enabled=function()return true end;io.open=function()return nil,'permission denied PRIVATE'end
  good,why=pcall(function()assert(not log:event('job',{taskref=2}));assert(not log:export(dir..'/export.txt'))end)
  io.open=open;assert(good,why)
 end)
end)
H.test('clear reports a read-only filesystem without exposing its error text',function()
 withDir(function(dir)
  local log=Logger.new{dir=dir,enabled=function()return true end};assert(log:event('job',{taskref=1}))
  local remove=os.remove;os.remove=function()return nil,'PRIVATE filesystem path',13 end
  local good,result,why=pcall(log.clear,log);os.remove=remove
  assert(good and not result and why=='io');assert(#read(dir..'/diagnostics.log')>0)
 end)
end)
H.test('export cannot silently omit an unreadable rotated segment',function()
 withDir(function(dir)
  local log=Logger.new{dir=dir,enabled=function()return true end};assert(log:event('job',{taskref=1}))
  local open=io.open;io.open=function(path,mode)if path==dir..'/diagnostics.previous.log'then return nil,'PRIVATE permission error',13 end;return open(path,mode)end
  local good,result,why=pcall(log.export,log,dir..'/export.txt');io.open=open
  assert(good and not result and why=='io')
 end)
end)
H.test('diagnostics refuses writing logs inside the installed plugin',function()
 local log=Logger.new{dir='/tmp/gdriveshelf.koplugin/logs',enabled=function()return true end}
 assert(not log:event('job',{taskref=1}))
end)
