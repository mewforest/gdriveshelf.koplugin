local H=require('tests/helper');local R=require('gdriveshelf/requests')
H.test('cancel detaches opening before a synchronous cancellation callback',function()
 local finish,opened;local c={open=function(_,_,fn)finish=fn end,cancelDownload=function()finish(nil,{code='cancelled'})end}
 local r=R.new(c);r:start({id='a'},function()opened=true end);r:cancel(true);finish('/book');assert(not opened)
end)
H.test('background download completion never steals the screen',function()
 local finish,opened;local r=R.new{open=function(_,_,fn)finish=fn end}
 r:start({id='a'},function()opened=true end);r.core.opening_id='a';r:cancel(false);finish('/book');assert(not opened and not r.core.opening_id)
end)
H.test('late completion of an older selection cannot open the wrong book',function()
 local callbacks={};local opened
 local r=R.new{open=function(_,e,fn)callbacks[e.id]=fn end,cancelDownload=function()end}
 r:start({id='a'},function()opened='a'end);r:start({id='b'},function()opened='b'end)
 callbacks.a('/a');assert(not opened);callbacks.b('/b');H.eq(opened,'b')
end)
