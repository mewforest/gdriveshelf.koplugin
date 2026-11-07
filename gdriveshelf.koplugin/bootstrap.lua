-- Plugin modules are namespaced to avoid KOReader's own cache.lua and metadata modules.
return function(base)
 for _,name in ipairs{'manage','controls','diagnostics','indexer','progress','localcovers','overrides','relocation','thumbnails','scanning','zipcover','preview','ux','integration','browser','requests','catalog','i18n','cache','metadata','library','storage','jobs','sdr','sync','syncqueue','core','providers/gdrive'} do
  local path=base..'/'..name..'.lua'
  package.preload['gdriveshelf/'..name]=function() return assert(loadfile(path))() end
 end
end
