-- luajit dump_stopped_gc.lua <in.lua> <out.bc>
-- string.dump(strip) of a chunk compiled with the GC stopped, so interned
-- strings (and hence table-template key order) do not depend on when a
-- collection happened to run.
collectgarbage('stop')
local input = assert(io.open(arg[1], 'rb'))
local text = input:read('*a')
input:close()
local chunk = assert(loadstring(text, '=module'))
local output = assert(io.open(arg[2], 'wb'))
output:write(string.dump(chunk, true))
output:close()
