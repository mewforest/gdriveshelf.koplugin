local H=require('tests/helper')
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
local closed=0
package.loaded['ui/uimanager']={show=function()end,close=function()closed=closed+1 end,nextTick=function(_,callback)callback()end}
package.loaded['apps/filemanager/filemanagerutil']={getHomeFolder=function()return '/storage/emulated/0'end}
local chooserOptions
package.loaded['ui/widget/filechooser']={new=function(_,o)chooserOptions=o;return o end}
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local function instance(credentials)
 local p=setmetatable({settings={},ui={},core={credentials=credentials or {},storage={readJSON=function()end}}},{__index=Plugin})
 p.getCore=function(self)return self.core end
 return p
end
H.test('first library visit shows setup without browsing Drive',function()
 local p=instance();local setup=false
 p.showConnectionSetup=function()setup=true end;p.showFolder=function()error('Must not list an unconnected Drive')end
 p:showLibrary();assert(setup)
end)
H.test('configured credentials enter the saved home folder',function()
 local p=instance({client_id='demo-client',refresh_token='demo-refresh',access_token='demo-access'});p.settings.home='library'
 local home;p.showFolder=function(_,id)home=id end;p:showLibrary();H.eq(home,'library')
 p.core.credentials.refresh_token='';assert(not p:hasCredentials())
end)
H.test('credential chooser starts at KOReader home and remembers a successful import folder',function()
 local p=instance();p:pickCredentials();H.eq(chooserOptions.path,'/storage/emulated/0')
 p.settings.import_dir='/';p:pickCredentials();H.eq(chooserOptions.path,'/storage/emulated/0')
 p.settings.import_dir='/storage/emulated/0/Download';p:pickCredentials();H.eq(chooserOptions.path,p.settings.import_dir)
end)
H.test('credential chooser opens on KOReader versions without getHomeFolder',function()
 local old_util=package.loaded['apps/filemanager/filemanagerutil']
 local old_settings=G_reader_settings
 local home='/storage/emulated/0/Books'
 package.loaded['apps/filemanager/filemanagerutil']={getDefaultDir=function()return '/storage/emulated/0'end}
 G_reader_settings={readSetting=function(_,key)H.eq(key,'home_dir');return home end}
 local p=instance()
 H.eq(p:pickCredentials().path,home)
 home=nil
 H.eq(p:pickCredentials().path,'/storage/emulated/0')
 G_reader_settings=old_settings
 package.loaded['apps/filemanager/filemanagerutil']=old_util
end)
H.test('setup exposes direct JSON chooser and path actions',function()
 local p=instance();local rows
 p.menu=function(_,_,r)rows=r;return {}end
 p.showSettings=function()end;p.showAuthorizationHelp=function()end
 local chosen,typed=false,false;p.pickCredentials=function()chosen=true end;p.pickCredentialsByPath=function()typed=true end
 p:showConnectionSetup();for _,r in ipairs(rows)do if r.callback then r.callback()end end
 assert(chosen and typed)
end)
H.test('Desktop client JSON is rejected with actionable explanation',function()
 local p=instance();p.core.storage.readJSON=function()return {installed={client_id='demo-client'}}end
 local ok,e=p:importCredentials('/Download/client.json');H.eq(ok,false);assert(e:find('authorize.py',1,true))
end)
H.test('path import returns failure so the input stays open for correction',function()
 local p=instance();p.importCredentials=function()return false,'Cannot read file'end
 local callback;p.input=function(_,_,_,cb)callback=cb end;p:pickCredentialsByPath()
 local ok,e=callback('/missing.json');H.eq(ok,false);H.eq(e,'Cannot read file')
end)
print('onboarding tests passed')
H.test('typed home and folder action both save the selection and offer indexing',function()
 local p=instance();local rows,prompt,saved
 p.menu=function(_,_,items)rows=items;return {onCloseAllMenus=function()end}end
 p.saveSettings=function()saved=p.settings.home end
 p.confirmation=function(_,o)prompt=o;return o end
 p.core.state={folder_pins={},folder_types={}}
 p.core.cancelIndex=function()end
 p.core.online=function()return true end
 p.input=function(_,_,_,cb)assert(cb('https://drive.google.com/drive/folders/library'))end
 p:chooseHomeFolder();rows[2].callback()
 H.eq(saved,'library');assert(prompt and not p.settings.index_enabled)
 prompt=nil
 p:folderActions({id='another',name='Another',is_folder=true});rows[2].callback()
 H.eq(saved,'another');assert(prompt and not p.settings.index_enabled)
end)
H.test('failed chooser import keeps the file browser open for another selection',function()
 local p=instance();p.importCredentials=function()return false,'Cannot read file'end
 package.loaded['ui/widget/infomessage']={new=function(_,o)return o end}
 p:pickCredentials();local before=closed;chooserOptions:onFileSelect({path='/bad.json'});H.eq(closed,before)
end)
