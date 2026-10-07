-- Offline checks for the MDL runtime manager and native font lookup.
-- Usage: luajit tests/test_mdl_manager.lua <src directory>
local source = assert(arg[1], 'source directory required')
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local hot_manager, hot_panel, hot_native_ui = module('mdl_manager'), module('mdl_panel'), module('mdl_native_ui')
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end

-- In-memory platform ---------------------------------------------------------
local function fake_platform()
    local files, memory, clock = {}, {}, 0
    local p = {files = files, memory = memory}
    function p.tick() clock = clock + 1 end
    function p.put(path, text) files[path] = {data = text, mtime = clock} end
    function p.mkdir() return true end
    function p.list(directory)
        local result, seen = {}, {}
        local prefix = directory .. '/'
        for path, file in pairs(files) do
            if path:sub(1, #prefix) == prefix then
                local rest = path:sub(#prefix + 1)
                local head = rest:match('^([^/]+)')
                local is_dir = rest:find('/', 1, true) ~= nil
                if not seen[head] then
                    seen[head] = true
                    result[#result + 1] = {name = head, dir = is_dir, mtime = file.mtime}
                end
            end
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end
    function p.read(path) return files[path] and files[path].data end
    function p.read_head(path, n) return files[path] and files[path].data:sub(1, n) end
    function p.write(path, data) p.put(path, data) return true end
    function p.module() return 0x1000 end
    function p.address_key(address) return address end
    function p.mem_read(address, size)
        local out = {}
        for i = 0, size - 1 do out[#out + 1] = string.char(memory[address + i] or 0) end
        return table.concat(out)
    end
    function p.mem_write(address, bytes)
        for i = 1, #bytes do memory[address + i - 1] = bytes:byte(i) end
        return true
    end
    return p
end

local BASE = 'C:/TestData/MDL/Helldivers2'
local function new_manager(platform, globals, extra)
    local options = {base_dir = BASE, platform = platform, globals = globals}
    for k, v in pairs(extra or {}) do options[k] = v end
    return hot_manager.new(options)
end
local function sandbox_globals()
    local G = setmetatable({}, {__index = _G})
    G._G = G
    G.require = require
    return G
end

-- 1. Serializer round trip ----------------------------------------------------
do
    local value = {enabled = {alpha = true, ['with-dash'] = true}, settings = {alpha = {speed = 1.5, mode = 'fast', on = false}},
        list = {1, 2, 'three'}, ui = {}}
    local text = 'return ' .. hot_manager.serialize(value)
    local parsed = hot_manager.parse_config(text)
    check(parsed.enabled.alpha and parsed.enabled['with-dash'], 'serializer keys')
    check(parsed.settings.alpha.speed == 1.5 and parsed.settings.alpha.mode == 'fast' and parsed.settings.alpha.on == false, 'serializer values')
    check(parsed.list[3] == 'three', 'serializer arrays')
    check(hot_manager.parse_config('os.exit()') == nil, 'config chunk cannot reach globals')
    check(hot_manager.parse_config('return {') == nil, 'broken config ignored')
end

-- 2. Lifecycle, dispatch, native write restore, globals, require ---------------
do
    local platform = fake_platform()
    local G = sandbox_globals()
    for i = 0, 3 do platform.memory[0x5000 + i] = 0x90 end
    platform.put(BASE .. '/Mods/alpha/mod.lua', [[
        local ctx = ...
        local helper = require('lib/helper')
        return {
            name = 'Alpha', version = '1.0', author = 'test', description = 'demo',
            options = {
                {key = 'speed', label = 'Speed', type = 'number', default = 2, min = 0, max = 3, step = 1},
                {key = 'on', label = 'On', type = 'toggle', default = true},
                {key = 'mode', label = 'Mode', type = 'choice', default = 'a', choices = {'a', 'b'}},
                {key = 'go', label = 'Go', type = 'action'},
            },
            on_enable = function(ctx)
                assert(ctx.write(0x5000, '\204\204'))
                ctx.global('AlphaState', {n = 0})
                rawset(_G, 'AlphaRaw', true)
                ctx.cdef('typedef struct { int v; } alpha_t; int abs(int);')
                ctx.on_cleanup(function() Counter.cleaned = Counter.cleaned + 1 end)
                enabled_count = (enabled_count or 0) + 1
            end,
            on_update = function(ctx, dt) AlphaState.n = AlphaState.n + helper.one() end,
            on_setting = function(ctx, key, value) last_setting = key .. '=' .. tostring(value) end,
            on_action = function(ctx, key) acted = key end,
        }
    ]])
    platform.put(BASE .. '/Mods/alpha/lib/helper.lua', 'return {one = function() return 1 end}')
    platform.put(BASE .. '/Mods/legacy/mod.lua', [[
        local previous = update
        update = function(dt, ...) Counter.ticks = (Counter.ticks or 0) + 1; if previous then return previous(dt, ...) end end
        local old_shutdown = shutdown
        shutdown = function() Counter.shut = true end
        rawset(_G, 'LegacyGuard', true)
    ]])
    platform.put(BASE .. '/Mods/broken/mod.lua', 'return {on_update = function() error("boom") end}')
    platform.put(BASE .. '/Mods/bad id!/mod.lua', 'return {}')
    G.Counter = {cleaned = 0}
    local m = new_manager(platform, G)
    m.start()
    check(#m.mods == 3, 'scan finds valid mod folders only')
    local alpha, legacy, broken = m.by_id.alpha, m.by_id.legacy, m.by_id.broken
    check(alpha.status == 'disabled', 'mods start disabled')
    check(m.enable(alpha), 'alpha enables')
    check(alpha.info.name == 'Alpha' and alpha.ctx.settings.speed == 2, 'metadata and defaults')
    check(platform.memory[0x5000] == 204 and G.AlphaState and rawget(G, 'AlphaRaw'), 'write and globals applied')
    check(rawget(G, 'enabled_count') == nil, 'mod-private globals stay in its environment')
    m.frame(0.016); m.frame(0.016)
    check(G.AlphaState.n == 2, 'on_update dispatched each frame')
    -- Reload keeps one write record and restores after teardown.
    check(m.reload(alpha), 'reload')
    check(G.Counter.cleaned == 1 and platform.memory[0x5000] == 204, 'reload ran cleanup and re-applied write')
    check(m.disable(alpha), 'disable')
    check(platform.memory[0x5000] == 0x90 and platform.memory[0x5001] == 0x90, 'native bytes restored')
    check(rawget(G, 'AlphaState') == nil and rawget(G, 'AlphaRaw') == nil, 'tracked globals cleared')
    check(G.Counter.cleaned == 2, 'cleanup on disable')
    -- Legacy global-chain mod: update/shutdown captured, never touching G.update.
    G.update = function() return 'game' end
    check(m.enable(legacy), 'legacy enables')
    check(G.update() == 'game', 'global update untouched by loose legacy mod')
    m.frame(0.1)
    check(G.Counter.ticks == 1, 'legacy update captured and dispatched')
    m.disable(legacy)
    check(G.Counter.shut and rawget(G, 'LegacyGuard') == nil, 'legacy shutdown called and guard cleared for reload')
    m.frame(0.1)
    check(G.Counter.ticks == 1, 'disabled legacy no longer ticks')
    check(m.enable(legacy) and rawget(G, 'LegacyGuard'), 'legacy re-enables after guard cleanup')
    -- Error isolation: auto-disable after repeated failures without stopping others.
    m.enable(broken)
    for _ = 1, 6 do m.frame(0.1) end
    check(broken.status == 'error' and broken.error:find('boom'), 'repeated errors auto-disable')
    check(G.Counter.ticks >= 7, 'failing mod does not stop others')
    -- Settings requests are queued and applied on the next frame.
    m.enable(alpha)
    local option = alpha.def.options[1]
    m.request('set_option', alpha, option, 3)
    m.request('action', alpha, alpha.def.options[4])
    m.frame(0.1)
    check(alpha.ctx.settings.speed == 3 and G.last_setting == nil and alpha.env.last_setting == 'speed=3', 'setting applied')
    check(alpha.env.acted == 'go', 'action dispatched')
    -- Persistence: a new manager re-enables remembered mods with saved values.
    m.frame(0)
    local saved = hot_manager.parse_config(platform.read(BASE .. '/MDL.cfg'))
    check(saved.enabled.alpha and saved.enabled.legacy and not saved.enabled.broken, 'enabled set persisted')
    check(saved.settings.alpha.speed == 3, 'settings persisted')
    m.shutdown()
    check(platform.memory[0x5000] == 0x90, 'shutdown restores writes')
    local m2 = new_manager(platform, sandbox_globals())
    m2.start()
    check(m2.by_id.alpha.status == 'enabled' and m2.by_id.alpha.ctx.settings.speed == 3, 'restart restores state')
    -- Auto reload on file change.
    m2.config.ui.auto_reload = true
    local before = m2.by_id.alpha.env
    platform.tick()
    platform.put(BASE .. '/Mods/alpha/lib/helper.lua', 'return {one = function() return 10 end}')
    m2.frame(3)
    check(m2.by_id.alpha.env ~= before, 'changed file triggers reload')
    -- Missing folder cannot be enabled; syntax error reports cleanly.
    platform.put(BASE .. '/Mods/syntax/mod.lua', 'return {')
    m2.scan()
    local ok = m2.enable(m2.by_id.syntax)
    check(not ok and m2.by_id.syntax.status == 'error', 'syntax errors reported')
end

-- 3. Conflicting write restore is skipped, not forced -----------------------
do
    local platform = fake_platform()
    platform.memory[0x6000] = 1
    platform.put(BASE .. '/Mods/w/mod.lua', 'return {on_enable = function(ctx) assert(ctx.write(0x6000, "\\2")) end}')
    local m = new_manager(platform, sandbox_globals())
    m.start()
    m.enable(m.by_id.w)
    platform.memory[0x6000] = 7
    m.disable(m.by_id.w)
    check(platform.memory[0x6000] == 7 and m.by_id.w.error:find('changed'), 'foreign change is preserved')
    local m3 = new_manager(platform, sandbox_globals())
    m3.scan()
    local ok = m3.enable(m3.by_id.w)
    check(ok, 'expected-bytes write passes when original matches')
end

-- 4. Boot addons ------------------------------------------------------------
do
    local platform = fake_platform()
    local G = sandbox_globals()
    local required = {}
    G.stingray = {Application = {can_get = function(kind, name) return name ~= 'mods/x/gone' end}}
    G.require = function(name) required[#required + 1] = name return true end
    G.CowboyBingusModLoader = {modules = {}}
    local hosted = new_manager(platform, G)
    hosted.register_boot('mods/x/hosted', 'loaded')
    check(not hosted.disable(hosted.by_id['mods/x/hosted']) and hosted.by_id['mods/x/hosted'].error:find('Bingus'), 'BSL-hosted addons cannot be switched off')
    local m = new_manager(platform, G, {boot_control = true})
    m.sync_boot({['mods/x/live'] = 'loaded', ['mods/mdl/runtime'] = 'loaded'})
    check(m.by_id['mods/x/live'] and m.by_id['mods/mdl/runtime'], 'sync_boot mirrors coordinator table')
    m.register_boot('mods/x/live', 'loaded')
    m.register_boot('mods/x/off', 'disabled by user')
    m.register_boot('mods/x/gone', 'not installed')
    m.start()
    local live, off = m.by_id['mods/x/live'], m.by_id['mods/x/off']
    check(live.status == 'enabled' and off.status == 'disabled' and m.by_id['mods/x/gone'].status == 'missing', 'boot statuses')
    m.toggle(live)
    check(live.status == 'restart' and m.config.boot_disabled['mods/x/live'], 'boot disable applies next launch')
    m.toggle(live)
    check(live.status == 'enabled' and not m.config.boot_disabled['mods/x/live'], 'boot disable can be undone')
    m.toggle(off)
    check(off.status == 'enabled' and required[1] == 'mods/x/off', 'boot addon can start mid-session')
    check(G.CowboyBingusModLoader.modules['mods/x/off'] == 'loaded', 'shared status updated')
end

-- 6. Native font initializer signature (fixtures from 2026-09-05 and 2026-09-26 dumps,
--    reduced to the signature, displacement fields and store markers).
do
    local fixtures = {
        {rva = 0xf553c0, font = 0x2a750d8, atlas = 0x2a75d58, material = 0x2ac7058,
         head = '48895c240848896c2410488974241848897c24204154415641570f57c08bc10f57c94c8d2517ac0aff33db0f11055e1cb701488d3cc50000000033c04e8b9427',
         tail = '4b898421d850a70233c04b898421585da702'},
        {rva = 0x11f62b0, font = 0x3772268, atlas = 0x3772ee8, material = 0x37c5478,
         head = '48895c240848896c2410488974241848897c24204154415641570f57c08bc10f57c94c8d25279de0fe33db0f11058ef15c02488d3cc50000000033c04e8b9427',
         tail = '4b8984216822770333c04b898421e82e7703'},
    }
    for _, fixture in ipairs(fixtures) do
        local image = {}
        local function put(offset, hex)
            for i = 1, #hex, 2 do image[offset + (i - 1) / 2] = tonumber(hex:sub(i, i + 1), 16) end
        end
        local noise = 0x3000
        for i = 0, noise - 1 do image[fixture.rva - noise + i] = (i * 37) % 251 end
        put(fixture.rva, fixture.head)
        put(fixture.rva + 0x25e, fixture.tail)
        local function get(i) return image[i] or 0 end
        local start = fixture.rva - noise
        local hits = hot_native_ui.find_all(function(i) return get(start + i) end, noise + 0x270, hot_native_ui.SIGNATURE, 2)
        check(#hits == 1 and start + hits[1] == fixture.rva, 'signature found once')
        local slots = hot_native_ui.decode(get, fixture.rva)
        check(slots.font == fixture.font and slots.atlas == fixture.atlas and slots.material == fixture.material,
            string.format('decode offsets %x', fixture.rva))
    end
    -- read_fonts formats hashes like the native panel code.
    local platform = fake_platform()
    local function put64(address, hi, lo)
        for i = 0, 3 do platform.memory[address + i] = math.floor(lo / 256 ^ i) % 256 end
        for i = 0, 3 do platform.memory[address + 4 + i] = math.floor(hi / 256 ^ i) % 256 end
    end
    put64(0x100 + 0x10, 0x11223344, 0x55667788)
    put64(0x100 + 0x20, 0x0a0b0c0d, 0x01020304)
    put64(0x100 + 0x30, 0x0, 0x19000)
    put64(0x19000 + 24, 0xdeadbeef, 0x00c0ffee)
    local fonts = hot_native_ui.read_fonts(platform, {base = 0x100, font = 0x10, atlas = 0x20, material = 0x30})
    check(fonts.font == '1122334455667788' and fonts.atlas == '0a0b0c0d01020304' and fonts.material == 'deadbeef00c0ffee', 'font hashes')
    check(hot_native_ui.read_fonts(platform, {base = 0x100, font = 0x40, atlas = 0x20, material = 0x30}) == nil, 'unready font')
end

-- 7. resolve_slots over a synthetic in-memory PE image (FFI path).
do
    local ffi = require('ffi')
    local n = 0x40000
    local img = ffi.new('uint8_t[?]', n)
    local function w32(o, v) ffi.cast('uint32_t *', img + o)[0] = v end
    local function w16(o, v) ffi.cast('uint16_t *', img + o)[0] = v end
    w32(0x3c, 0x80); w32(0x80, 0x4550); w16(0x86, 1); w16(0x94, 0xf0); w32(0x80 + 24 + 56, n)
    local section = 0x80 + 24 + 0xf0
    w32(section + 8, 0x30000); w32(section + 12, 0x1000); w32(section + 36, 0x60000020)
    local rva = 0x2000
    local head = '48895c240848896c2410488974241848897c24204154415641570f57c08bc10f57c94c8d25279de0fe33db0f11058ef15c02488d3cc50000000033c04e8b9427'
    for i = 1, #head, 2 do img[rva + (i - 1) / 2] = tonumber(head:sub(i, i + 1), 16) end
    ffi.cast('int32_t *', img + rva + 0x25)[0] = -(rva + 0x29)
    ffi.cast('int32_t *', img + rva + 0x2e)[0] = 0x100 - (rva + 0x32)
    local tail = '4b8984216822770333c04b898421e82e7703'
    for i = 1, #tail, 2 do img[rva + 0x25e + (i - 1) / 2] = tonumber(tail:sub(i, i + 1), 16) end
    local slots = hot_native_ui.resolve_slots(ffi, {module = function() return img end})
    check(slots.font == 0x3772268 and slots.atlas == 0x3772ee8 and slots.material == 0x108 and slots.initializer == rva,
        'resolve_slots over PE image')
    -- A second copy makes the signature ambiguous and must be refused.
    ffi.copy(img + rva + 0x8000, img + rva, 0x270)
    check(not pcall(hot_native_ui.resolve_slots, ffi, {module = function() return img end}), 'ambiguous signature refused')
end

print('PASS: MDL manager lifecycle, restore, legacy capture, boot toggles, persistence and font signature (' .. checks .. ' checks)')
