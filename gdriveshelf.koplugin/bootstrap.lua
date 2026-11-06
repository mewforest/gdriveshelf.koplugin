-- Plugin modules are namespaced to avoid KOReader's own cache.lua and metadata modules.
return function(base)
 for _,name in ipairs{'cache','metadata','library','storage','jobs','sdr','sync','core','providers/gdrive'} do
  local path=base..'/'..name..'.lua'
  package.preload['gdriveshelf/'..name]=function() return assert(loadfile(path))() end
 end
end
