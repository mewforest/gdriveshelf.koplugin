local H=require('tests/helper')
local locale={current_lang='C'};package.loaded.gettext=locale
local I=require('gdriveshelf/i18n')
H.test('English is the default and unsupported locale fallback',function()
 H.eq(I.gettext('Settings'),'Settings');locale.current_lang='de_DE';H.eq(I.gettext('Settings'),'Settings')
end)
H.test('Russian follows active KOReader locale without reloading modules',function()
 locale.current_lang='ru';H.eq(I.gettext('Settings'),'Настройки')
 locale.current_lang='en_GB';H.eq(I.gettext('Settings'),'Settings')
 locale.current_lang='ru_RU.UTF-8';H.eq(I.gettext('Settings'),'Настройки')
end)
H.test('formatted labels preserve their values in either language',function()
 locale.current_lang='C';H.eq(I.format('Automatic cache: %d MiB',3072),'Automatic cache: 3072 MiB')
 locale.current_lang='ru';H.eq(I.format('Automatic cache: %d MiB',3072),'Автокэш: 3072 МиБ')
end)
package.loaded['ui/widget/container/widgetcontainer']={extend=function(_,t)return t end}
package.loaded['ui/uimanager']={show=function()end,nextTick=function()end}
local Plugin=dofile('gdriveshelf.koplugin/main.lua')
local p=setmetatable({settings={auto_mib=3072,meta_mib=256,prefetch=1,threshold=75},core={}},{__index=Plugin})
local title,rows,options
p.menu=function(_,t,r,o)title,rows,options=t,r,o end
H.test('settings screens and actions render in English and Russian',function()
 locale.current_lang='C';p:showSettings();H.eq(title,'Google Drive Shelf settings');assert(rows[1].text:find('Offline',1,true));assert(rows[2].text:find('Light mode',1,true));assert(rows[4].text=='Catalog and appearance')
 locale.current_lang='ru';p:showSettings();H.eq(title,'Настройки Google Drive Shelf');assert(rows[1].text:find('Офлайн',1,true));assert(rows[2].text:find('Лёгкий режим',1,true))
end)
H.test('settings rows request native monochrome icons',function()
 locale.current_lang='C';p:showSettings();assert(options and options.icons)
 for _,row in ipairs(rows)do assert(row.checked~=nil or row.icon or row.icon_file,'Missing settings icon for '..row.text)end
end)
print('localization tests passed')
