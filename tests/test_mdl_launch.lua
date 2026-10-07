-- Library addons loaded at launch (settled when the coordinator reports them,
-- deferred restore, "running twice"), launch addon names from the library,
-- and engine object / native memory tracking of live mods.
-- Usage: luajit tests/test_mdl_launch.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_manager, mdl_panel = module('mdl_manager'), module('mdl_panel')
local ffi = require('ffi')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

local function memory_platform(files)
    local platform = {mkdir = function() return true end, read = function(p) return files[p] end,
        read_head = function(p, n) return files[p] and files[p]:sub(1, n) end,
        write = function(p, d) files[p] = d return true end}
    function platform.list(directory)
        local out, seen = {}, {}
        for path in pairs(files) do
            local rest = path:sub(1, #directory + 1) == directory .. '/' and path:sub(#directory + 2)
            local head = rest and rest:match('^([^/]+)')
            if head and not seen[head] then seen[head] = true; out[#out + 1] = {name = head, dir = rest:find('/', 1, true) ~= nil, mtime = 0} end
        end
        table.sort(out, function(a, b) return a.name < b.name end)
        return out
    end
    return platform
end
local BASE = 'C:/TestData/MDL/Helldivers2'

-- 1. Launch settling -----------------------------------------------------
do
    local files = {[BASE .. '/MDL.cfg'] = 'return {enabled = {["arsenal:hull"] = true, ["arsenal:other"] = true}}'}
    local G = setmetatable({}, {__index = _G})
    G._G = G
    local m = mdl_manager.new({base_dir = BASE, platform = memory_platform(files), globals = G})
    local sources = {
        ['mods/codex/hull'] = 'return {name = "Hull", on_update = function() end}',
        ['mods/codex/other'] = 'return {name = "Other", on_update = function() end}',
    }
    local function resolve(name) return sources[name] end
    -- Runtime order: library scanned at init (coordinator has reported nothing yet).
    local hull = m.register_packed('arsenal:hull', {name = 'Advanced Tank Hull', author = 'Arsenal'}, 'mods/codex/hull', resolve, {launch = false})
    local other = m.register_packed('arsenal:other', {name = 'Other', author = 'Arsenal'}, 'mods/codex/other', resolve, {launch = false})
    m.start({defer_packed = true})
    check(hull.status == 'disabled' and other.status == 'disabled', 'library addons not restored before the coordinator reports')
    -- First frame: the coordinator loaded hull at launch.
    m.sync_boot({['mods/codex/hull'] = 'loaded'})
    check(hull.status == 'launch' and hull.launch, 'hull marked as loaded at launch')
    m.restore_packed()
    m.frame(0.016)
    check(hull.status == 'launch', 'hull not started a second time')
    check(other.status == 'enabled', 'other restored')
    m.restore_packed()
    check(m.enable(hull) == false, 'enabling a launch addon is refused')
    -- A rescan registers it again: the boot record keeps it at launch.
    hull = m.register_packed('arsenal:hull', {name = 'Advanced Tank Hull', author = 'Arsenal'}, 'mods/codex/hull', resolve, {})
    check(hull.status == 'launch', 'rescan keeps the launch state from the boot record')

    -- Started live first, reported loaded at launch later: flagged, not stopped.
    local late = m.register_packed('arsenal:late', {name = 'Late', author = 'HD2MM'}, 'mods/codex/late',
        function() return 'return {on_update = function() end}' end, {})
    m.request('enable', late); m.frame(0.016)
    check(late.status == 'enabled', 'late started live')
    m.register_boot('mods/codex/late', 'loaded')
    check(late.status == 'enabled' and late.double, 'running twice flagged')

    -- Panel: launch state names the manager; twice in red; launch addon names.
    local library = {scanned = true, sources = {'Arsenal (Default)'}, revision = 1, describe_types = function() return '' end,
        entries = {
            {name = 'Advanced Tank Hull 0.1.2 debug', category = 'SCRIPT', source = 'Arsenal', addon = 'mods/codex/hull',
                file = 'Advanced-Tank-Hull-0.1.2-debug', record = hull, options = {}},
            {name = 'Late One', category = 'SCRIPT', source = 'HD2MM', addon = 'mods/codex/late', file = 'late', record = late, options = {}},
        }}
    function library.scan() end
    local input = {pressed = function() return false end, cursor = function() end, clicked = function() return false end,
        wheel = function() return 0 end}
    local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}
    local panel = mdl_panel.new(m, input, renderer, {library = library, host = 'MDL'})
    -- The library row (the launch addon section has the same name, detail = addon id).
    local function row(label)
        for _, r in ipairs(panel.rows()) do
            if r.label == label and not tostring(r.detail or ''):find('^mods/') then return r end
        end
    end
    check(row('Advanced Tank Hull 0.1.2 debug').value == 'ON VIA Arsenal', 'launch state: ON VIA Arsenal')
    check(row('Late One').value == 'RUNNING TWICE' and row('Late One').tone == 'red', 'running twice shown')
    -- The launch addon section uses the library name and file name.
    check(panel.folded('addons'), 'launch addon section folded by default')
    panel.toggle_fold('addons')
    local found
    for _, r in ipairs(panel.rows()) do
        if r.detail == 'mods/codex/hull' and r.label == 'Advanced Tank Hull 0.1.2 debug' then found = r end
    end
    check(found and found.file == 'Advanced-Tank-Hull-0.1.2-debug', 'launch addon shown with its manager name and file')
    -- Stopping the live copy leaves it at launch.
    m.request('disable', late); m.frame(0.016)
    check(late.status == 'launch' and not late.double, 'live copy stopped: at launch remains')
    panel.go_for_test('mod', m.by_id['mods/codex/hull'])
    check(panel.title_for_test() == 'Advanced Tank Hull 0.1.2 debug', 'launch addon page titled with the manager name: ' .. tostring(panel.title_for_test()))
end

-- 2. Engine objects and native memory ----------------------------------------
do
    local files = {}
    files[BASE .. '/Mods/spawner/mod.lua'] = [[
local ffi = require('ffi')
pcall(ffi.cdef, 'void *malloc(size_t size); void free(void *p); void *calloc(size_t n, size_t size);')
local SR = rawget(_G, 'stingray')
local units = {}
local big, small, zeroed
return {name = 'Spawner',
    on_enable = function(ctx)
        units[1] = SR.World.spawn_unit('world', 'a')
        units[2] = stingray.World.spawn_unit('world', 'b')
        units[3] = World.spawn_unit('world', 'c')
        units[4] = _G.stingray.World.spawn_unit('world', 'd')
        GUI = World.create_screen_gui('world')
        PARTICLE = SR.World.create_particles('world', 'fx')
        big = ffi.C.malloc(1000)
        small = ffi.C.malloc(24)
        zeroed = ffi.C.calloc(4, 8)
        ffi.C.free(small)
        UNITS = units
    end,
    on_update = function() end,
    on_disable = function(ctx)
        SR.World.destroy_unit('world', units[1])
        SR.World.destroy_particles('world', PARTICLE)
        ffi.C.free(zeroed)
    end}
]]
    files[BASE .. '/Mods/plain/mod.lua'] = [[
STINGRAY_SEEN = stingray
FFI_SEEN = require('ffi')
return {name = 'Plain', on_update = function() end}
]]
    local spawned = 0
    local World = {
        spawn_unit = function(world, name) spawned = spawned + 1; return {name = name} end,
        destroy_unit = function(world, unit) unit.dead = true end,
        create_screen_gui = function() return {gui = true} end,
        destroy_gui = function() end,
        create_particles = function() return 42 end,
        destroy_particles = function() end,
        get_data = function() return 'data' end,
    }
    local Unit = {alive = function(unit) return not unit.dead end}
    local stingray = {World = World, Unit = Unit}
    local G = setmetatable({stingray = stingray, World = World}, {__index = _G})
    G._G = G
    local m = mdl_manager.new({base_dir = BASE, platform = memory_platform(files), globals = G, track_engine_default = true})
    m.start()
    local spawner, plain = m.by_id.spawner, m.by_id.plain
    m.request('enable', spawner); m.request('enable', plain); m.frame(0.016)
    check(spawner.status == 'enabled' and spawned == 4, 'spawner running: ' .. tostring(spawner.error))
    local c = m.engine_counts(spawner)
    check(c.units == 4 and c.guis == 1 and c.particles == 1, 'units / GUI / particle counted on every access path')
    check(c.native_bytes == 1032 and c.native_blocks == 2, 'malloc + calloc counted, free subtracted: ' .. c.native_bytes)
    -- A unit the game removed is not counted.
    spawner.env.UNITS[2].dead = true
    check(m.engine_counts(spawner).units == 3, 'dead unit dropped')
    -- Views keep the other functions identical.
    check(spawner.env.stingray.Unit == Unit and spawner.env.stingray.World.get_data == World.get_data, 'untracked functions unchanged')
    check(spawner.env.stingray ~= stingray, 'the mod sees a view')
    local keys = 0
    for _ in pairs(spawner.env.stingray.World) do keys = keys + 1 end
    check(keys == 7, 'pairs over the World view lists every function: ' .. keys)
    check(plain.env.STINGRAY_SEEN ~= stingray and plain.env.FFI_SEEN ~= ffi and plain.env.FFI_SEEN.new == ffi.new,
        'tracking on: views of stingray and ffi with the same functions')
    -- Stop: it destroyed one unit, the particle and the calloc block; the rest is left.
    m.request('disable', spawner); m.frame(0.016)
    local left = m.engine_counts(spawner)
    check(left.units == 2 and left.guis == 1 and left.particles == 0 and left.native_bytes == 1000, 'left behind after stopping')
    -- Tracking off: the real tables.
    m.config.ui.track_engine = false
    m.request('reload', plain); m.frame(0.016)
    check(plain.env.STINGRAY_SEEN == stingray and plain.env.FFI_SEEN == ffi and m.engine_counts(plain) == nil, 'tracking off: real stingray and ffi')
    check(m.tracking() == false, 'tracking setting read')

    -- Panel rows.
    m.config.ui.track_engine = nil
    m.request('enable', spawner); m.frame(0.016)
    local input = {pressed = function() return false end, cursor = function() end, clicked = function() return false end,
        wheel = function() return 0 end}
    local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}
    local panel = mdl_panel.new(m, input, renderer, {host = 'MDL'})
    local function row(label)
        for _, r in ipairs(panel.rows()) do if r.label == label then return r end end
    end
    check(row('Track engine objects and native memory').value == 'ON', 'settings row')
    panel.go_for_test('mod', spawner)
    check(row('Engine objects it made').value == '8 units, 2 GUIs, 1 effects' or row('Engine objects it made').value:find('^%d+ units'),
        'engine row: ' .. row('Engine objects it made').value)
    check(row('Native memory (FFI)').value:find('KB') or row('Native memory (FFI)').value:find('B'), 'native row')
    m.request('disable', spawner); m.frame(0.016)
    panel.go_for_test('mod', spawner)
    check(row('Left behind after stopping') and row('Left behind after stopping').tone == 'red', 'left behind row')
end

print('PASS: MDL launch addons, launch names, engine object tracking (' .. checks .. ' checks)')
