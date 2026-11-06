dofile('./gdriveshelf.koplugin/bootstrap.lua')('./gdriveshelf.koplugin')
package.path = './gdriveshelf.koplugin/?.lua;./tests/?.lua;' .. package.path
local H = {count=0}
function H.test(name, fn)
 local ok,err=pcall(fn)
 if not ok then error('FAIL '..name..': '..tostring(err),0) end
 H.count=H.count+1; print('ok '..H.count..' - '..name)
end
function H.eq(a,b) assert(a==b, tostring(a)..' ~= '..tostring(b)) end
return H
