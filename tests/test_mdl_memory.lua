-- Memory estimate per live mod (mdl_memory + manager scope), allocation
-- rate, update times (library + loose mods), and the panel: sort switches,
-- time line, memory rows, cost page.
-- Usage: luajit tests/test_mdl_memory.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_memory, mdl_manager, mdl_panel, mdl_library = module('mdl_memory'), module('mdl_manager'), module('mdl_panel'), module('mdl_library')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- Size model helpers.
check(mdl_memory.pow2(5) == 8 and mdl_memory.pow2(1) == 1, 'pow2')
check(mdl_memory.table_bytes(0, 0) == 40 and mdl_memory.table_bytes(3, 0) == 40 + 4 * 8 and mdl_memory.table_bytes(0, 3) == 40 + 4 * 24,
    'table size model')
check(mdl_memory.format(512) == '512 B' and mdl_memory.format(2048) == '2 KB' and mdl_memory.format(3 * 1048576) == '3.00 MB', 'format')

-- Time helpers.
check(mdl_library.iso_time('2026-10-03T18:24:41.641Z') == 1791051881, 'ISO UTC')
check(mdl_library.iso_time('2000-03-01T00:00:00+01:00') == 951865200, 'ISO offset')
check(mdl_library.iso_time('nonsense') == nil and mdl_library.iso_time(nil) == nil, 'ISO invalid')
check(mdl_library.unix_time(134041000000000000) == 1759626400 and mdl_library.unix_time(0) == nil, 'FILETIME')
check(mdl_manager.unix_time(134041000000000000) == 1759626400 and mdl_manager.unix_time(1234) == 1234, 'manager FILETIME')
do
    local date = os.date
    os.date = nil
    check(mdl_library.format_time(1791051881) == '2026-10-03 18:24', 'UTC fallback format')
    check(mdl_library.format_time(951782340) == '2000-02-28 23:59', 'UTC fallback before a leap day')
    os.date = date
end

-- Manager with two loose mods and a shared global ----------------------------
local files = {}
local mtime = {}
local platform = {mkdir = function() return true end, read = function(p) return files[p] end,
    read_head = function(p, n) return files[p] and files[p]:sub(1, n) end,
    write = function(p, d) files[p] = d return true end}
function platform.list(directory)
    local out, seen = {}, {}
    for path in pairs(files) do
        local rest = path:sub(1, #directory + 1) == directory .. '/' and path:sub(#directory + 2)
        local head = rest and rest:match('^([^/]+)')
        if head and not seen[head] then
            seen[head] = true
            out[#out + 1] = {name = head, dir = rest:find('/', 1, true) ~= nil, mtime = mtime[path] or 0}
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end
local BASE = 'C:/TestData/MDL/Helldivers2'
-- Heavy: ~1000 strings of 100 bytes in a local table, a global of its own,
-- and references to shared things (a library function, a shared table).
files[BASE .. '/Mods/heavy/mod.lua'] = [[
local data = {}
for i = 1, 1000 do data[i] = string.rep(string.char(65 + i % 26), 90) .. tostring(i) end
local floor = math.floor
local shared_fn = Shared.fn
local shared_big = Shared.big
_G.HeavyGlobal = {list = data}
return {name = 'Heavy', on_update = function(ctx, dt) local _ = data[1], floor, shared_fn, shared_big end}
]]
-- Light: a few locals; holds Heavy's global and Shared.big, which are not its own.
files[BASE .. '/Mods/light/mod.lua'] = [[
local mine = {1, 2, 3}
local theirs = HeavyGlobal
local big = Shared.big
local churn = 0
return {name = 'Light', on_update = function(ctx, dt)
    local garbage = {}
    for i = 1, 200 do garbage[i] = {i} end
    churn = churn + #garbage
    local _ = mine, theirs, big
end}
]]
mtime[BASE .. '/Mods/heavy'] = 0
mtime[BASE .. '/Mods/heavy/mod.lua'] = 134041000000000000          -- 2025-10-05
mtime[BASE .. '/Mods/light/mod.lua'] = 134041000000000000 + 864000000000 -- one day later
local big = {}
for i = 1, 5000 do big[i] = {i} end
local G = setmetatable({Shared = {fn = function() return big end, big = big}}, {__index = _G})
G._G = G
local m = mdl_manager.new({base_dir = BASE, platform = platform, globals = G})
m.start()
local heavy, light = m.by_id.heavy, m.by_id.light
check(heavy.updated == 1759626400 and light.updated == 1759626400 + 86400, 'loose mod update time from its newest .lua file')
m.request('enable', heavy); m.request('enable', light)
m.frame(0.016)
check(heavy.status == 'enabled' and light.status == 'enabled', 'both running')
check(rawget(G, 'HeavyGlobal') and heavy.globals.HeavyGlobal, 'global owned by heavy')

local clock_value = 0
local function measurer(stop_sources, clock)
    return mdl_memory.new({G = G, scope = m.memory_scope, stop_sources = stop_sources, clock = clock or os.clock})
end
local mem = measurer({[m.own_source] = true})
mem.request(heavy); mem.request(light)
check(mem.busy() and mem.result(heavy).state == 'measuring', 'queued')
while mem.step(1) do end
local rh, rl = mem.result(heavy), mem.result(light)
check(rh.state == 'done' and rl.state == 'done', 'both measured')
-- 1000 strings of ~93 bytes: at least 100 KB with their table.
check(rh.bytes > 100000 and rh.bytes < 400000, 'heavy estimate in range: ' .. rh.bytes)
check(rl.bytes < 30000, 'light does not count heavy\'s global, Shared.big or MDL: ' .. rl.bytes)
check(rh.counts.string >= 1000 and rh.counts.table >= 2, 'object counts')
check(rh.objects > 1000 and not rh.truncated, 'objects counted, not truncated')

-- Without MDL's own chunk excluded the walk leaks into the loader (ctx
-- functions -> manager): far bigger. Shows why stop_sources matters.
local leaky = measurer({})
leaky.request(light)
while leaky.step(1) do end
local leaky_bytes = leaky.result(light).bytes
check(leaky.result(light).bytes > rl.bytes * 3, 'MDL functions excluded: ' .. leaky.result(light).bytes .. ' vs ' .. rl.bytes)

-- Resumable: a clock that jumps 1 ms per read stops every slice early.
local ticks = 0
local sliced = measurer({[m.own_source] = true}, function() ticks = ticks + 1; return ticks * 0.001 end)
sliced.request(heavy)
local slices = 0
while sliced.step(0.0005) do slices = slices + 1 end
check(slices > 3, 'measured over several slices: ' .. slices)
check(sliced.result(heavy).bytes == rh.bytes, 'same result when sliced')

-- Stale after a reload; unavailable when not running.
m.request('reload', heavy)
m.frame(0.016)
local stale_result, stale = mem.result(heavy)
check(stale_result == nil and stale == true, 'result from before the reload is stale')
m.request('disable', light)
m.frame(0.016)
mem.request(light)
while mem.step(1) do end
check(mem.result(light).state == 'unavailable', 'stopped mod: unavailable')
check(m.memory_scope(light) == nil, 'no scope for a stopped mod')
mem.forget(light)
check(mem.results[light] == nil, 'forget')

-- Allocation rate: Light allocates ~200 small tables per update.
m.request('enable', light)
m.frame(0.016)
collectgarbage('collect')
collectgarbage('stop')
for _ = 1, 60 do m.frame(0.016) end
collectgarbage('restart')
check(light.alloc and light.alloc > 100, 'allocation rate measured: ' .. tostring(light.alloc))
check(not heavy.alloc or heavy.alloc < light.alloc, 'heavy allocates less per update than light')
local off = mdl_manager.new({base_dir = BASE .. '2', platform = platform, globals = G, gc_count = false})
check(off.frame and true, 'gc_count = false accepted')

-- Panel: sort switches, time lines, memory rows, cost page -----------------
local library = {scanned = true, sources = {'Arsenal (Default)'}, revision = 1, format_time = mdl_library.format_time,
    describe_types = function() return 'unit 2' end}
library.entries = {
    {name = 'Charlie skin', category = 'RESOURCE', source = 'Arsenal', file = 'charlie', updated = 300, bytes = 3 * 1048576, options = {}},
    {name = 'alpha skin', category = 'RESOURCE', source = 'Arsenal', file = 'alpha', updated = 100, options = {}},
    {name = 'Bravo skin', category = 'RESOURCE', source = 'Arsenal', file = 'bravo', updated = 200, options = {}},
    {name = 'Delta skin', category = 'RESOURCE', source = 'Arsenal', file = 'delta', options = {}},
}
function library.scan() end
local pressed, cursor, click = {}, nil, nil
local input = {
    pressed = function(...) for _, name in ipairs({...}) do if pressed[name] then return true end end return false end,
    cursor = function() if cursor then return cursor[1], cursor[2] end end,
    clicked = function(button) return click == button end,
    wheel = function() return 0 end,
}
local drawn
local renderer = {resolution = function() return 1920, 1080 end, draw = function(list) drawn = list return true end, clear = function() end}
local panel_memory = measurer({[m.own_source] = true})
local panel = mdl_panel.new(m, input, renderer, {library = library, host = 'MDL', memory = panel_memory,
    heap_kb = function() return 2048 end})
local function frame(keys, at, button)
    pressed, cursor, click = keys or {}, at, button
    panel.frame()
    m.frame(0.016)
end
local function labels(section_title)
    local out, inside = {}, false
    for _, row in ipairs(panel.rows()) do
        if row.header or row.separator then inside = row.header == section_title
        elseif inside and row.label then out[#out + 1] = row.label end
    end
    return table.concat(out, ',')
end
local function row_with(field, value)
    for i, row in ipairs(panel.rows()) do if row[field] == value then return row, i end end
end
frame({esc = true})
check(panel.visible, 'panel open')
local title = select(1, row_with('sort', 'resource')).header
check(labels(title) == 'Charlie skin,alpha skin,Bravo skin,Delta skin', 'library order by default: ' .. labels(title) .. ' / ' .. tostring(title))
check(row_with('sort', 'loose') and row_with('sort', 'resource'), 'sections carry a sort switch')

-- Click the switch drawn on the resource group header.
local function chip_of(section)
    for _, chip in ipairs(drawn and panel.geometry and panel.geometry().chips or {}) do
        if chip.section == section then return chip end
    end
end
check(panel.geometry, 'geometry accessor')
local chip = chip_of('resource')
check(chip, 'sort switch drawn')
local function click_chip(section, button)
    local c = chip_of(section)
    frame({}, {c.x + c.w / 2, c.y + c.h / 2}, button or 'left')
    frame({}, nil, nil)
end
local text_found = false
for _, item in ipairs(drawn) do if item.text == 'SORT: LOAD ORDER' then text_found = true end end
check(text_found, 'switch shows the current mode')
click_chip('resource')
check(panel.sort_mode('resource') == 'name', 'click: A-Z')
check(labels(title) == 'alpha skin,Bravo skin,Charlie skin,Delta skin', 'A-Z, case-insensitive')
check(m.config.ui.sort and m.config.ui.sort.resource == 'name', 'saved in the config')
click_chip('resource')
check(panel.sort_mode('resource') == 'time', 'click: newest')
check(labels(title) == 'Charlie skin,Bravo skin,alpha skin,Delta skin', 'newest first, no time last')
local charlie = select(1, row_with('label', 'Charlie skin'))
check(charlie.file:find('^charlie   %d%d%d%d%-%d%d%-%d%d %d%d:%d%d$'), 'time shown under the mod: ' .. charlie.file)
check(select(1, row_with('label', 'Delta skin')).file:find('no time', 1, true), 'missing time marked')
click_chip('resource', 'right')
check(panel.sort_mode('resource') == 'name', 'right click steps back')
click_chip('resource')
click_chip('resource')
check(panel.sort_mode('resource') == 'order' and m.config.ui.sort == nil, 'back to load order; nothing left in the config')
-- Live Lua mods section: by name and by time.
panel.cycle_sort('loose')
check(labels('LIVE LUA MODS') == 'Heavy,Light', 'loose by name')
panel.cycle_sort('loose')
check(labels('LIVE LUA MODS') == 'Light,Heavy', 'loose newest first')
panel.cycle_sort('loose')

-- Library page: update time and file size.
local entry = library.entries[1]
panel.go_for_test('library', entry)
local updated = row_with('label', 'Updated')
check(updated and updated.value:find('^%d%d%d%d%-'), 'library page: updated')
local size = row_with('label', 'Files on disk')
check(size and size.value == '3.00 MB', 'library page: files on disk')

-- Mod page: memory and allocation rows; measured in slices by panel.frame.
panel.go_for_test('mod', heavy)
local mem_row = row_with('label', 'Lua memory (estimate)')
check(mem_row and (mem_row.value == 'MEASURING' or mem_row.value:find('^~')), 'memory row: ' .. tostring(mem_row and mem_row.value))
for _ = 1, 50 do frame() if not panel_memory.busy() then break end end
mem_row = row_with('label', 'Lua memory (estimate)')
check(mem_row.value:find('^~%d+ KB$'), 'memory row measured: ' .. mem_row.value)
panel.go_for_test('mod', light)
for _ = 1, 50 do frame() if not panel_memory.busy() then break end end
check(row_with('label', 'Lua allocation'), 'allocation row')
-- Cost page lists every running live mod.
panel.go_for_test('cost')
check(row_with('label', 'Lua heap, whole game').value == '2.00 MB', 'heap total')
local heavy_row = row_with('label', 'Heavy')
check(heavy_row and heavy_row.value:find('^~'), 'cost page memory of Heavy: ' .. tostring(heavy_row and heavy_row.value))
check(row_with('label', 'Measure again'), 'measure again row')

print(string.format('heavy %d B, light %d B, leaky %d B, light alloc %.0f KB/s', rh.bytes, rl.bytes, leaky_bytes, light.alloc))
print('PASS: MDL memory estimate, allocation rate, update times and sorting (' .. checks .. ' checks)')
