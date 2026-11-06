local root=debug.getinfo(1,'S').source:sub(2):match('^(.*)/_meta%.lua$') or 'plugins/gdriveshelf.koplugin'
local I18N=dofile(root..'/i18n.lua')
return {
 name='gdriveshelf',
 version='0.0.0-dev',
 fullname='Google Drive Shelf',
 description=I18N.gettext('Google Drive library with offline downloads, independent caches and native KOReader reading-progress sync.'),
}
