local H=require('tests/helper')
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
package.loaded['ui/uimanager']={nextTick=function(_,callback)callback()end}
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local function instance()
 local p=setmetatable({settings={},core={state={folders={},entries={},folder_pins={},folder_types={},listings={},summaries={}},cached=function()return nil end,folderStats=function()return {bytes=0}end,titleInfo=function()return {title='Title',chapters={}}end}},{__index=Plugin})
 p.menu=function(_,title,rows,options)return {title=title,item_table=rows,options=options}end
 p.saveSettings=function()end;return p
end
H.test('main menu opens the library directly and keeps settings separate',function()
 local p=instance();local items={};p:addToMainMenu(items)
 assert(items.gdriveshelf and items.gdriveshelf.callback and not items.gdriveshelf.sub_item_table)
 assert(items.gdriveshelf_settings and items.gdriveshelf_settings.callback)
end)
H.test('settings expose independent offline and light mode checkboxes',function()
 local p=instance();local m=p:showSettings();assert(m and #m.item_table==8)
 assert(m.item_table[1].checked~=nil and m.item_table[2].checked~=nil)
end)
H.test('folder contents have no navigation or action pseudo-file',function()
 local p=instance();local rows=p:folderRows('p',{{id='a',name='1.cbz',parent_id='p'}},false)
 H.eq(#rows,1);H.eq(rows[1].entry.id,'a')
end)
H.test('only confirmed empty folders are hidden, containers and unknown folders stay',function()
 local p=instance();p.core.folderStats=function(_,id)return ({empty={bytes=0,count=0,folders=0,empty=true},container={bytes=0,count=0,folders=2,empty=false},unknown={bytes=0}})[id]end
 local input={{id='empty',name='Empty',is_folder=true},{id='container',name='Container',is_folder=true},{id='unknown',name='Unknown',is_folder=true}}
 local rows=p:folderRows('p',input,false);H.eq(#rows,2)
 for _,row in ipairs(rows)do assert(row.entry.id~='empty');assert(not row.text:find('Empty folder',1,true))end
 p.settings.hide_empty=false;H.eq(#p:folderRows('p',input,false),3)
end)
H.test('local covers and file sizes do not require remote beta previews',function()
 local p=instance();p.core.localCover=function()return {path='/safe/preview.png'}end;p.core.storage={exists=function()return true end}
 local row=p:folderRows('p',{{id='a',name='1.cbz',parent_id='p',size=6291456}},false)[1]
 H.eq(row.icon_file,'/safe/preview.png');assert(row.mandatory and row.mandatory:find('6',1,true))
end)
H.test('transfer progress updates status without rebuilding the folder body',function()
 local p=instance();p.folder_menu={};local statusOnly
 p.refreshBrowser=function(_,value)statusOnly=value end
 p:onCoreChange('transfer',{id='a'});H.eq(statusOnly,true)
end)
H.test('stable comic header and file grid do not depend on remote beta features',function()
 local p=instance();p.settings.file_view='grid';p.core.state.folders.p={name='Comics',id='p',parent_id='home'}
 local entries={{id='a',name='1.cbz',parent_id='p',size=1000}}
 local view=p:browserPresentation('p',entries)
 assert(view.header and view.grid);H.eq(view.rows,1);H.eq(view.columns,3)
 H.eq(view.stats,'In cloud: 1 file · 1 kB');H.eq(view.cached,'On device: 0 files · 0 B')
 p.folder_visit={collapsed=true}
 local collapsed=p:browserPresentation('p',entries)
 assert(not collapsed.header);H.eq(collapsed.rows,2)
 p.folder_visit=nil;p.settings.info_header=false
 local hidden=p:browserPresentation('p',entries)
 assert(not hidden.header);H.eq(hidden.rows,2)
end)
H.test('the comic header shows the reading date and the resume row omits the opened suffix',function()
 local p=instance();p.settings.light_mode=true
 local chapter={id='a',name='1.cbz',parent_id='p'}
 p.core.state.summaries.a={status='reading'}
 p.core.state.last_opened={p=1700000000}
 p.folder_visit={resume={entry=chapter,resume=true}}
 local view=p:browserPresentation('p',{chapter})
 H.eq(view.reading_date,'Last opened: '..os.date('%d.%m %H:%M',1700000000))
 H.eq(p:folderRows('p',{chapter},false,view.resume_id)[1].text,'1.cbz')
 p.folder_visit.collapsed=true
 view=p:browserPresentation('p',{chapter})
 H.eq(p:folderRows('p',{chapter},false,view.resume_id)[1].text,'1.cbz')
end)
H.test('offline chapters use the full cloud listing for totals when available',function()
 local p=instance();p.folder_offline=true
 local chapter={id='a',name='1.cbz',parent_id='p',size=1000}
 p.core.cached=function(_,id)if id=='a'then return chapter end end
 local view=p:browserPresentation('p',{chapter})
 H.eq(view.stats,nil);H.eq(view.cached,'On device: 1 file · 1 kB')
 p.core.state.listings.p={complete=true}
 p.core.cachedList=function()return {chapter,{id='b',name='2.cbz',parent_id='p',size=2000}}end
 view=p:browserPresentation('p',{chapter})
 H.eq(view.stats,'In cloud: 2 files · 3 kB');H.eq(view.cached,'On device: 1 file · 1 kB')
end)
H.test('catalog settings expose explicit recursive consent and stable cover controls',function()
 local p=instance();local rows=p:showSettingsCategory('catalog').item_table;local text={}
 for _,row in ipairs(rows)do text[#text+1]=row.text end
 local all=table.concat(text,'\n');assert(all:find('recursively',1,true));assert(all:find('Hide empty',1,true));assert(all:find('downloaded documents',1,true))
 local beta=p:showSettingsCategory('experimental').item_table
 for _,row in ipairs(beta)do assert(not row.text:find('information header',1,true))end
end)
H.test('hiding known empty children does not mislabel their parent as empty',function()
 local p=instance();p.core.state.listings.p={complete=true};p.core.folderStats=function()return{empty=true,bytes=0}end
 local rows=p:folderRows('p',{{id='e',name='Empty',is_folder=true}},false)
 assert(rows[1].text:find('display settings',1,true))
end)
H.test('empty imported chapter titles fall back to the original filename',function()
 local p=instance();p.core.titleInfo=function()return{chapters={['2.cbz']='  \n '}}end
 local row=p:folderRows('p',{{id='b',name='2.cbz',parent_id='p'}},false)[1]
 H.eq(row.text,'2.cbz')
end)
H.test('a covered folder does not paint status over settings',function()
 local p=instance();local paints=0
 local settings={}
 package.loaded['ui/uimanager']={getTopmostVisibleWidget=function()return settings end,nextTick=function(_,f)f()end}
 p.folder_menu={title_bar={setSubTitle=function()paints=paints+1 end}}
 p.core.state.downloads={}
 p:refreshBrowser(true)
 H.eq(paints,0);assert(p.browser_pending)
end)
H.test('home shortcut explicitly resets the page and keeps the home folder',function()
 local p=instance()
 p.settings.home='library'
 p.getCore=function()return p.core end
 p.hasCredentials=function()return true end
 p.showFolder=function(_,parent,offline,force,render_only,navigation)
  H.eq(parent,'library');H.eq(navigation,'home')
  assert(not offline and not force and not render_only)
 end
 p:showLibrary(true)
end)
H.test('list-to-grid restores the page containing the visible resume chapter',function()
 local p=instance()
 local rows={}
 for i=1,42 do rows[i]={entry={id='chapter-'..i}} end
 p.folder_visit={resume={entry={id='chapter-29'}}}
 local anchor=p:folderAnchor{page=5,perpage=7,item_table=rows}
 H.eq(anchor.id,'chapter-29')
 local grid={page=1,perpage=6,page_num=7,item_table=rows,onGotoPage=function(menu,page)menu.page=page end}
 p:restoreFolderAnchor(grid,anchor)
 H.eq(grid.page,5)
end)
H.test('root and ZIP alone do not generate a comic header, while user overrides do',function()
 local p=instance()
 assert(not p:browserPresentation('root',{{id='a',name='1.cbz',parent_id='root'}}).header)
 assert(not p:browserPresentation('p',{{id='b',name='backup.zip',parent_id='p'}}).header)
 p.core.state.folder_types.root='comics'
 assert(p:browserPresentation('root',{{id='a',name='1.cbz',parent_id='root'}}).header)
end)
