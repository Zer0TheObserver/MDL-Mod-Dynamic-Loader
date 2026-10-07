-- Composes the MDL startup coordinator and runtime the way build_mdl.py does
-- (without vanilla Wwise bytecode) and runs them with a fake Stingray:
--   A. MDL owns startup: BSL API 1 compatibility, boot-disable, runtime start,
--      update/shutdown chaining with preserved results, panel drawing.
--   B. Bingus Shared Loader owns startup and starts the runtime by discovery.
-- Usage: luajit tests/test_mdl_integration.lua <src directory> [build directory]
local source = assert(arg[1])
local function read(name)
    local file = assert(io.open(source .. '/' .. name .. '.lua', 'rb'))
    local text = file:read('*a')
    file:close()
    return text
end
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

local ROOT = os.tmpname()
os.remove(ROOT)
assert(os.execute('mkdir -p "' .. ROOT .. '/MDL/Helldivers2/Mods/demo" "' .. ROOT .. '/Game/bin" "' .. ROOT .. '/Game/data"'))
local function write(path, data)
    local file = assert(io.open(path, 'wb')); file:write(data); file:close()
end
local BASE = ROOT .. '/MDL/Helldivers2'
write(BASE .. '/Mods/demo/mod.lua', 'return {name = "Demo", on_update = function(ctx, dt) Ticks.n = Ticks.n + 1 end, on_disable = function() Ticks.off = true end}')

-- Real-filesystem stand-in for mdl_platform (Linux test host).
local platform_source = [[
local P = {}
function P.new()
    local root = TEST_ROOT
    local p = {}
    function p.localappdata() return root end
    function p.base_dir() return root .. '/MDL/Helldivers2' end
    function p.game_dir() return root .. '/Game' end
    function p.mkdir(path) os.execute('mkdir -p "' .. path .. '"') return true end
    function p.list(directory, pattern)
        local out = {}
        local pipe = io.popen('ls -1p "' .. directory .. '" 2>/dev/null')
        for line in pipe:lines() do
            local dir = line:sub(-1) == '/'
            local name = dir and line:sub(1, -2) or line
            local glob = pattern and ('^' .. pattern:gsub('%.', '%%.'):gsub('%*', '.*') .. '$')
            if not glob or name:match(glob) then out[#out + 1] = {name = name, dir = dir, mtime = 0, size = 0} end
        end
        pipe:close()
        return out
    end
    function p.read(path, limit)
        local file = io.open(path, 'rb'); if not file then return nil end
        local data = limit and file:read(limit) or file:read('*a'); file:close(); return data
    end
    function p.read_head(path, n) return p.read(path, n) end
    function p.write(path, data) local f = io.open(path, 'wb'); if not f then return false end f:write(data) f:close() return true end
    function p.module(name) return TEST_MODULE and TEST_MODULE(name) or nil end
    function p.mem_read(address, size) return TEST_MEM_READ and TEST_MEM_READ(address, size) or nil end
    function p.mem_write(address, data) return TEST_MEM_WRITE and TEST_MEM_WRITE(address, data) or false end
    function p.wide(s) return s end
    function p.now() return TEST_NOW and TEST_NOW() or os.clock() end
    return p
end
return P
]]

local WITH_LAB = false   -- debug build (MDL_DEBUG = true)
local function runtime_chunk()
    local parts = {'-- HD2-Addon: mods/mdl/runtime\n', "local MDL_VERSION = 'test'\n",
        'local MDL_DEBUG = ' .. tostring(WITH_LAB) .. '\n',
        'local mdl_platform = (function()\n' .. platform_source .. '\nend)()\n'}
    local names = {'mdl_json', 'mdl_logs', 'mdl_manager', 'mdl_library', 'mdl_image', 'mdl_native_ui', 'mdl_menu', 'mdl_nativetab',
        'mdl_reslab', 'mdl_i18n', 'mdl_lang', 'mdl_glyphs', 'mdl_atlas', 'mdl_anim', 'mdl_probe', 'mdl_memory', 'mdl_panel'}
    for _, name in ipairs(names) do
        parts[#parts + 1] = 'local ' .. name .. ' = (function()\n' .. read(name) .. '\nend)()\n'
    end
    -- Test hook: the native set_labels call is replaced (the fake image has no real code).
    parts[#parts + 1] = 'if TEST_NATIVE_CALL then mdl_nativetab.native_call = TEST_NATIVE_CALL end\n'
    parts[#parts + 1] = 'if TEST_NATIVE_ARG then mdl_nativetab.native_arg = TEST_NATIVE_ARG end\n'
    parts[#parts + 1] = read('mdl_runtime')
    return table.concat(parts)
end
local function boot_chunk()
    return 'local addon_discovery = nil\nlocal jit_budget = (function()\n' .. read('jit_budget') .. '\nend)()\n' .. read('mdl_boot')
end

local function fake_stingray(log, installed)
    local function v3(x, y, z) return {x = x, y = y, z = z or 0} end
    local S = {}
    S.Vector3 = setmetatable({x = function(v) return v.x end, y = function(v) return v.y end}, {__call = function(_, ...) return v3(...) end})
    S.Vector2 = setmetatable({x = function(v) return v.x end, y = function(v) return v.y end}, {__call = function(_, x, y) return v3(x, y) end})
    S.Color = function(a, r, g, b) return {a, r, g, b} end
    S.IdString64 = {from_hex = function(hex) return 'id:' .. hex end}
    S.Material = {set_scalar = function() end, set_vector2 = function() end, set_vector4 = function() end, set_texture = function() end}
    S.Application = {can_get = function(kind, name) return installed[name] == true end,
        worlds = function() return {'main', 'ui'} end, main_world = function() return 'main' end}
    S.World = {create_screen_gui = function(world) log.guis = (log.guis or 0) + 1 return {world = world} end,
        destroy_gui = function() log.destroyed = (log.destroyed or 0) + 1 end}
    S.Gui = {resolution = function() return 1920, 1080 end, material = function() return {} end,
        rect = function() return 1 end,
        text = function(_, text) log.texts = log.texts or {}; log.texts[#log.texts + 1] = text return 1 end,
        text_extents = function() return v3(0, 0), v3(10, 10), v3(10, 0) end}
    log.keys = {}
    S.Keyboard = {button_id = function(name) return name end, pressed = function(id) return log.keys[id] == true end}
    S.Mouse = {axis_id = function(name) return name end, button_id = function(name) return name end,
        axis = function() return v3(-1, -1) end, pressed = function() return false end}
    return S
end

local function environment(stingray, required, extra_update)
    local env = setmetatable({print = function() end, stingray = stingray, TEST_ROOT = ROOT,
        os = {getenv = function(name) if name == 'LOCALAPPDATA' then return ROOT end end, clock = os.clock, date = os.date,
            execute = os.execute, remove = os.remove}}, {__index = _G})
    env._G = env
    env.require = function(name)
        if name == 'ffi' or name == 'bit' then return require(name) end
        required[#required + 1] = name
        if name == 'mods/mdl/runtime' then
            return setfenv(assert(loadstring(runtime_chunk(), '@mods/mdl/runtime')), env)()
        end
        local previous = env.update
        env.update = function(...) return previous(...) end
        return true
    end
    return env
end

-- A. MDL owns startup --------------------------------------------------------
do
    write(BASE .. '/MDL.cfg', 'return {boot_disabled = {["mods/cowboybingus/hellpod_steering_unlocked"] = true, ["mods/mdl/runtime"] = true},'
        .. ' enabled = {demo = true}, ui = {font = "aa", material = "bb", atlas = "cc", arsenal_dir = "' .. ROOT .. '/none"}}')
    local log, required = {}, {}
    local installed = {['mods/cowboybingus/better_stratagem_bounce'] = true, ['mods/cowboybingus/hellpod_steering_unlocked'] = true,
        ['mods/mdl/runtime'] = true}
    local env = environment(fake_stingray(log, installed), required)
    env.Ticks = {n = 0}
    local game_updates, game_shutdowns = 0, 0
    env.update = function() game_updates = game_updates + 1 return 1, nil, 3, nil end
    env.shutdown = function() game_shutdowns = game_shutdowns + 1 return 'bye' end
    setfenv(assert(loadstring(boot_chunk(), '=mdl_boot')), env)()
    local loader, mdl = env.CowboyBingusModLoader, env.MDL
    check(loader and loader.api == 1 and loader.provider == 'MDL' and type(loader.open_log) == 'function', 'BSL API 1 compatibility object')
    check(loader.modules['mods/cowboybingus/better_stratagem_bounce'] == 'loaded', 'registered addon started')
    check(loader.modules['mods/cowboybingus/hellpod_steering_unlocked'] == 'disabled by user', 'boot-disable honored')
    check(loader.modules['mods/mdl/runtime'] == 'loaded', 'runtime cannot be boot-disabled and is started last')
    check(mdl and mdl.status == 'ready' and mdl.host == 'MDL', 'runtime ready: ' .. tostring(mdl and mdl.error))
    check(mdl.manager.by_id.demo.status == 'enabled', 'remembered live mod enabled')
    local a, b, c, d = env.update(0.1)
    check(a == 1 and b == nil and c == 3 and select('#', env.update(0.1)) == 4, 'update results preserved')
    check(game_updates == 2 and env.Ticks.n == 2, 'game and live mods tick')
    check(mdl.manager.by_id['mods/cowboybingus/better_stratagem_bounce'].status == 'enabled', 'boot addons mirrored')
    log.keys.esc = true; env.update(0.1); log.keys.esc = nil
    check(mdl.panel.visible and log.texts and log.texts[1] == 'MOD DYNAMIC LOADER', 'panel drawn with configured font')
    env.update(0.1)
    check(log.guis == 1, 'unchanged panel not rebuilt')
    -- Boot toggle is available when MDL owns startup.
    local addon = mdl.manager.by_id['mods/cowboybingus/better_stratagem_bounce']
    check(mdl.manager.disable(addon) and addon.status == 'restart', 'boot addon switched off for next launch')
    check(env.shutdown() == 'bye' and game_shutdowns == 1 and env.Ticks.off, 'shutdown chained, live mods disabled')
    local cfg = io.open(BASE .. '/MDL.cfg'):read('*a')
    check(cfg:find('better_stratagem_bounce', 1, true) and cfg:find('demo', 1, true), 'config persisted')
    local mdl_log = io.open(BASE .. '/Logs/MDL.log')
    check(mdl_log and mdl_log:read('*a'):find('ready'), 'MDL.log written')
    -- Second coordinator execution is a no-op.
    local before = env.update
    setfenv(assert(loadstring(boot_chunk())), env)()
    check(env.update == before, 'coordinator guard')
end

-- B. Bingus Shared Loader owns startup ---------------------------------------
do
    local log, required = {}, {}
    local env = environment(fake_stingray(log, {}), required)
    env.CowboyBingusModLoader = {version = 17, api = 1, modules = {['mods/x/addon'] = 'loaded'}}
    local ticks = 0
    env.update = function() ticks = ticks + 1 return 'x' end
    local mdl = env.require('mods/mdl/runtime')
    check(mdl.status == 'ready' and mdl.host == 'Bingus Shared Loader', 'runtime under BSL')
    check(env.require('mods/mdl/runtime') == mdl, 'second start returns the same instance')
    check(env.update() == 'x' and ticks == 1, 'update chain intact')
    local addon = mdl.manager.by_id['mods/x/addon']
    check(addon and not mdl.manager.disable(addon), 'BSL-hosted addons are not switched off by MDL')
end


-- C. Native ESC menu + MODS tab over a fake game.dll image in real memory ----
do
    local ffi = require('ffi')
    local SIZE = 0x40000
    local mem = ffi.new('uint8_t[?]', SIZE)
    local base = tonumber(ffi.cast('uintptr_t', mem))
    local function inside(a, n) return a >= base and a + n <= base + SIZE end
    local function put(rva, value, size) for i = 0, size - 1 do mem[rva + i] = math.floor(value / 256 ^ i) % 256 end end
    local function u32(rva) return mem[rva] + mem[rva + 1] * 256 + mem[rva + 2] * 65536 + mem[rva + 3] * 16777216 end
    local function hex(rva, text) for i = 1, #text, 2 do mem[rva + (i - 1) / 2] = tonumber(text:sub(i, i + 1), 16) end end
    -- PE header with one executable section .text at 0x1000 (size 0x3000).
    put(0x3c, 0x80, 4); put(0x80 + 6, 1, 2); put(0x80 + 20, 0xF0, 2)
    local section = 0x80 + 24 + 0xF0
    put(section + 8, 0x9000, 4); put(section + 12, 0x1000, 4); put(section + 36, 0x60000020, 4)
    -- MenuSystem pop_screen (real 0926 bytes, displacements retargeted).
    local POP, GLOBAL, NAMES = 0x1100, 0xA000, 0xA100
    hex(POP, '40534883ec20488b1ddb4a04028b033bc2755c80bb89080000007453448bc0488d151228e900488d05230dda00488d0dec25e9004e8b04c0')
    put(POP + 9, GLOBAL - (POP + 13), 4); put(POP + 41, NAMES - (POP + 45), 4)
    for i = 0, 15 do
        local name = i == 14 and 'InGame' or i == 15 and 'Count' or ('S' .. i)
        local at = 0xA400 + 16 * i
        for j = 1, #name do mem[at + j - 1] = name:byte(j) end
        put(NAMES + 8 * i, base + at, 8)
    end
    -- ESC screen initializer + set_labels (real 0926 bytes), table/call retargeted.
    local INIT, SET_LABELS, TABLE = 0x1800, 0x2000, 0xA300
    hex(INIT, '498d9fe0040000bab6030000488bcbc6838de0000001e8925d330041b803000000488d1535dae901488bcbe8ad713300488bd341c787dc2f000003000000498d4f104188b7ed2f0000e8ff8a')
    put(INIT + 36, TABLE - (INIT + 40), 4); put(INIT + 44, SET_LABELS - (INIT + 48), 4)
    hex(SET_LABELS, '488954241053564883ec680f29742430488bc248897c2460488bf14c896c24504c897c244041bf08000000453bc7458bef450f4ce84489a968e000004885d274244585ed741f4d63c54881c1e8df00004e8d048500000000e843dc8e00488b842488000000f30f1035b3c0c10033ff89be80e000004963cd4585ed0f8ec10100004889ac24900000008bef4c89642458448d67014c89742448488dbe202300000f297c2420f30f103d7fc8c1004d63fd8b1ca8488d8f48fdffff8bd3e87f12c9ff4c8db7b0faffff498bcee800430000498bcee8e8bfc9ff418b0681c3292319c5c1e809a80175664c8b059128cc014533c9418bd1418bc9498d40080f1f40004c39087414ffc248ffc14883c0184881f9000400007ce9eb2e413b50047e04418950048bc2488d0440488d4001498d04c04885c0741141ff004c89308958084489480c4c89481041810e00020000b867666666458bc441f7ecc1fa028bc2c1e81f03d08d049203c0442bc0448987e80700008b07c1e81283e00f83f807741783f80875224533c9ba357b2aab488bcfe83c6fc9ffeb104533c9ba357b2aab488bcfe8da1bc9ff0f28ce498bcee8cfdcc9ff488d8f78060000c787dc070000010000000f57c9c687ed07000000e8afdcc9fff30f1097bcfafffff30f5997ccfafffff30f589680e00000f30f119680e00000453be5740cf30f58d7f30f119680e00000488b84248800000041ffc448ffc54881c7480d000049')
    -- set_label (called from the set_labels loop at +0xBC), the string-argument
    -- setter 0x9C0 after it and its record setter; the other widget class's
    -- setter lies outside the window.
    local SET_LABEL, ARG, REC, OTHER = 0x3000, 0x39C0, 0x4000, 0x8C00
    put(SET_LABELS + 0xBD, SET_LABEL - (SET_LABELS + 0xC1), 4)
    hex(SET_LABEL, '4883ec284c8bd93991100100000f84800000008991100100')
    for _, at in ipairs({ARG, OTHER}) do
        hex(at, '40534883ec20488bd94881c110010000e84bd8ffff84c0745b8b93b80000008bc283c8028983b80000003bc27446f7d2')
        put(at + 17, REC - (at + 21), 4)
    end
    hex(REC, '48895c2418574883ec40440fb699580100004533c9498bf8')
    local stock = {0xd876b36e, 0x78934e12, 0x8c02bd80}
    for i = 1, 3 do put(TABLE + 4 * (i - 1), stock[i], 4) end
    -- MenuSystem (InGame open) and the ESC screen.
    local SYSTEM, SCREEN = 0xB000, 0x10000
    put(GLOBAL, base + SYSTEM, 8)
    put(SYSTEM, 14, 4); mem[SYSTEM + 2185] = 1; mem[SYSTEM + 2186] = 0
    put(SYSTEM + 200, base + SCREEN, 8)
    local BAR = SCREEN + 1248
    put(BAR + 57448, 3, 4); put(BAR + 57452, 0, 4); put(SCREEN + 8, 0, 4)
    for i = 1, 3 do put(BAR + 57320 + 4 * (i - 1), stock[i], 4) end

    local calls = {}
    local log, required = {}, {}
    local env = environment(fake_stingray(log, {}), required)
    env.TEST_MODULE = function(name) return name == 'game.dll' and base or nil end
    env.TEST_MEM_READ = function(a, n) if inside(a, n) then return ffi.string(ffi.cast('const char *', a), n) end end
    env.TEST_MEM_WRITE = function(a, data) if inside(a, #data) then ffi.copy(ffi.cast('void *', a), data, #data) return true end end
    env.TEST_NATIVE_CALL = function(_, layout)
        return function(bar, labels, count)
            calls[#calls + 1] = {bar = bar, labels = labels, count = count}
            put(bar - base + layout.count, count, 4)
            for i = 1, count do
                put(bar - base + layout.labels + 4 * (i - 1), labels[i], 4)
                put(bar - base + layout.text + 3400 * (i - 1) + 272, labels[i], 4)
            end
        end
    end
    local args = {}
    env.TEST_NATIVE_ARG = function(_, layout)
        args.setter = layout.set_arg
        return function(widget, name, text) args[#args + 1] = {widget = widget, name = name, text = text} end
    end
    env.update = function() return 'g' end
    write(BASE .. '/MDL.cfg', 'return {ui = {font = "aa", material = "bb", atlas = "cc", arsenal_dir = "' .. ROOT .. '/none"}}')
    env.CowboyBingusModLoader = {version = 17, api = 1, modules = {}}
    local mdl = env.require('mods/mdl/runtime')
    check(mdl.status == 'ready' and mdl.native_tab, 'native tab resolved: ' .. tostring(mdl.error))
    env.update(0.016)
    check(#calls == 1 and calls[1].bar == base + BAR and calls[1].count == 4 and calls[1].labels[4] == 0x0227B3B0
        and calls[1].labels[1] == stock[1], '"#TEXT" tab added through set_labels')
    check(args.setter == ARG and #args == 1 and args[1].widget == base + BAR + 8296 + 3 * 3400 and args[1].name == 0x57F3D153
        and args[1].text == 'MDL Settings', 'tab text "MDL Settings" set through the resolved argument setter')
    check(u32(BAR + 57448) == 4 and u32(SCREEN + 12252) == 3, 'bar has 4 tabs, selected button restored')
    check(mdl.menu_probe and mdl.tab_state and not mdl.tab_state.active and not mdl.panel.visible and mdl.panel.mode == 'tab',
        'GAME tab selected: MDL panel hidden')
    put(BAR + 57452, 3, 4); put(SCREEN + 8, 3, 4)
    env.update(0.016)
    check(mdl.panel.visible and mdl.panel.mode == 'tab' and #calls == 1, 'MDL Settings tab selected: panel shown in the content area')
    put(BAR + 57452, 2, 4); put(SCREEN + 8, 2, 4)
    env.update(0.016)
    check(not mdl.panel.visible, 'OPTIONS tab: panel hidden again')
    mem[SYSTEM + 2185] = 0
    env.update(0.016)
    check(not mdl.panel.visible and mdl.tab_state == nil, 'menu closed')
    -- Mod Options Menu present: tab left to it, floating panel.
    mem[SYSTEM + 2185] = 1
    put(BAR + 57448, 3, 4)
    env.ModOptionsMenu = {}
    env.update(0.016)
    check(#calls == 1 and mdl.panel.visible and mdl.panel.mode == 'float', 'MOM present: floating panel, bar untouched')
    mdl.write_log(true)
    local text = io.open(BASE .. '/Logs/MDL.log'):read('*a')
    check(text:find('native tab: bar +1248', 1, true) and text:find('added "MDL Settings"', 1, true) and text:find('selected MDL', 1, true)
        and text:find('bar layout', 1, true) and text:find('set_arg +0x39c0', 1, true) and text:find('Mod Options Menu present', 1, true), 'native tab logged')

    -- Mod Options Menu 1.1 in the update chain: it keeps tab 4, MDL becomes tab 5,
    -- and MOM only ever sees a 4-tab bar while it runs.
    do
        put(BAR + 57448, 3, 4); put(BAR + 57452, 0, 4); put(SCREEN + 8, 0, 4)
        for i = 0, 4 do put(BAR + 57320 + 4 * i, i < 3 and stock[i + 1] or 0, 4) end
        mem[SYSTEM + 2185] = 1
        local first_call = #calls
        local env2 = environment(fake_stingray({}, {}), {})
        for _, key in ipairs({'TEST_MODULE', 'TEST_MEM_READ', 'TEST_MEM_WRITE', 'TEST_NATIVE_CALL', 'TEST_NATIVE_ARG'}) do env2[key] = env[key] end
        env2.CowboyBingusModLoader = {version = 17, api = 1, modules = {}}
        env2.update = function() return 'g2' end
        local mom_counts = {}
        do -- MOM 1.1's shape: update wrapper with upvalues step / traceback / previous_update
            local previous_update = env2.update
            local traceback = debug.traceback
            local step = function(dt)
                local count = u32(BAR + 57448)
                mom_counts[#mom_counts + 1] = count
                if count == 3 then put(BAR + 57448, 4, 4); put(BAR + 57320 + 12, 0xc67c7faf, 4) end
            end
            env2.update = function(dt)
                xpcall(step, traceback, dt)
                return previous_update(dt)
            end
        end
        env2.ModOptionsMenu = {api = 1, version = 2}
        local mdl2 = env2.require('mods/mdl/runtime')
        for _ = 1, 3 do check(env2.update(0.016) == 'g2', 'game update still reached') end
        local last = calls[#calls]
        check(#calls == first_call + 1 and last.count == 5 and last.labels[4] == 0xc67c7faf and last.labels[5] == 0x0227B3B0,
            'MDL added as tab 5 after MOM\'s tab: ' .. tostring(#calls - first_call))
        check(u32(BAR + 57448) == 5, 'bar shows 5 tabs')
        local saw_five = false
        for _, count in ipairs(mom_counts) do if count ~= 3 and count ~= 4 then saw_five = true end end
        check(#mom_counts == 3 and not saw_five, 'MOM saw 3 then 4 tabs only')
        put(BAR + 57452, 4, 4); put(SCREEN + 8, 4, 4)
        env2.update(0.016)
        check(mdl2.panel.visible and mdl2.panel.mode == 'tab' and mdl2.tab_state.slot == 4, 'tab 5 selected: MDL panel in the content area')
        check(mdl2.memory and mdl2.memory.step and not mdl2.memory.busy(), 'memory estimate compiled in and idle')
        put(BAR + 57452, 3, 4); put(SCREEN + 8, 3, 4)
        env2.update(0.016)
        check(not mdl2.panel.visible, 'MOM\'s tab selected: MDL hidden')
        mdl2.write_log(true)
        local text2 = io.open(BASE .. '/Logs/MDL.log'):read('*a')
        check(text2:find('Mod Options Menu 2 found; MDL is tab 5', 1, true) and text2:find('as ESC-menu tab 5', 1, true), 'logged')
    end
end


-- D. Live addons that reach the real globals (Advanced Tank Camera pattern) ---
-- `rawget(_G, 'update')` / `_G.update` / `rawset(_G, 'update', f)` must see the
-- loader's stand-in and capture, never the game's real update chain (which
-- contains MDL itself): calling it from a live update recursed every frame.
do
    local log, required = {}, {}
    local env = environment(fake_stingray(log, {}), required)
    env.CowboyBingusModLoader = {version = 17, api = 1, modules = {}}
    local game_updates, depth, max_depth = 0, 0, 0
    env.update = function()
        depth = depth + 1; max_depth = math.max(max_depth, depth)
        game_updates = game_updates + 1
        if depth > 20 then depth = depth - 1; error('recursed') end
        depth = depth - 1
        return 'game'
    end
    local mdl = env.require('mods/mdl/runtime')
    check(mdl.status == 'ready', 'runtime ready for sandbox test')
    local real_update = env.update
    env.Hits = {}
    local sources = {
        rawget_update = "if rawget(_G,'CamGuard') then return end rawset(_G,'CamGuard',true)\n"
            .. "local o = rawget(_G,'update')\nif type(o)~='function' then Hits.rawget_missing = true return end\n"
            .. "function update(...) Hits.rawget_update = (Hits.rawget_update or 0) + 1; return o(...) end",
        dot_update = "local o = _G.update\n_G.update = function(...) Hits.dot_update = (Hits.dot_update or 0) + 1; return o(...) end",
        rawset_update = "local o = update\nrawset(_G, 'update', function(...) Hits.rawset_update = (Hits.rawset_update or 0) + 1; return o(...) end)",
        plain_update = "local o = update\nfunction update(...) Hits.plain_update = (Hits.plain_update or 0) + 1; return o(...) end",
    }
    local records = {}
    for name, body in pairs(sources) do
        local text = '-- HD2-Addon: mods/test/' .. name .. '\n' .. body
        records[name] = mdl.manager.register_packed('lib:' .. name, {name = name}, 'mods/test/' .. name,
            function(resource) if resource == 'mods/test/' .. name then return text end end, {})
        check(mdl.manager.enable(records[name]), name .. ' enables: ' .. tostring(records[name].error))
    end
    check(env.update == real_update and rawget(env, 'CamGuard') == true, 'real update untouched; shared globals still reach _G')
    game_updates, max_depth = 0, 0
    check(env.update(0.1) == 'game', 'update chain returns the game result')
    check(game_updates == 1 and max_depth == 1, 'game update ran exactly once, no recursion (' .. game_updates .. ', depth ' .. max_depth .. ')')
    for name in pairs(sources) do
        check(env.Hits[name] == 1 and records[name].status == 'enabled', name .. ' ticked once and stays enabled')
    end
    check(not env.Hits.rawget_missing, 'rawget(_G, "update") sees a function')
    for name in pairs(sources) do mdl.manager.disable(records[name]) end
    env.update(0.1)
    check(env.Hits.rawget_update == 1 and env.Hits.dot_update == 1 and game_updates == 2, 'disabled live addons stop ticking')
    -- Safety net: a live update that still gets hold of the outer update
    -- (e.g. through a saved reference) cannot re-run the frame.
    local sneaky = mdl.manager.register_packed('lib:sneaky', {name = 'sneaky'}, 'mods/test/sneaky', function(resource)
        if resource == 'mods/test/sneaky' then
            return "local o = Outer\nfunction update(...) Hits.sneaky = (Hits.sneaky or 0) + 1; return o(...) end"
        end end, {})
    env.Outer = real_update
    check(mdl.manager.enable(sneaky), 'sneaky enables')
    game_updates, max_depth = 0, 0
    env.update(0.1)
    check(game_updates == 1 and max_depth == 1 and env.Hits.sneaky == 1, 're-entrant update is ignored (' .. game_updates .. ')')
    check(sneaky.warning and sneaky.warning:find('re-entered', 1, true), 'the mod gets a warning: ' .. tostring(sneaky.warning))
end


-- E. Debug build: Resource Lab compiled in -----------------------------------
do
    WITH_LAB = true
    local log, required = {}, {}
    local stingray = fake_stingray(log, {})
    stingray.Application.can_get = function() return false end
    local env = environment(stingray, required)
    env.CowboyBingusModLoader = {version = 17, api = 1, modules = {}}
    env.update = function() return 'g' end
    write(BASE .. '/MDL.cfg', 'return {ui = {font = "aa", material = "bb", atlas = "cc", arsenal_dir = "' .. ROOT .. '/none"}}')
    local mdl = env.require('mods/mdl/runtime')
    check(mdl.status == 'ready' and mdl.lab, 'debug runtime creates the lab: ' .. tostring(mdl.error))
    for _ = 1, 5 do env.update(0.016) end
    check(mdl.lab and not mdl.lab.resolved(), 'lab keeps running when the engine is not found (offline)')
    local rows = mdl.panel.rows()
    local entry
    for _, row in ipairs(rows) do if row.label == 'Resource Lab (debug)' then entry = row end end
    check(entry, 'main page links the lab')
    entry.open()
    local lab_rows = mdl.panel.rows()
    check(mdl.panel.page == 'lab' and lab_rows[2].header == 'PACKAGE MONITOR', 'lab page opens')
    -- Texture probe: settings row, off by default; the probe fails safe offline.
    check(mdl.probe, 'debug runtime creates the texture probe')
    local probe_row
    for _, row in ipairs(mdl.panel.rows()) do if row.label == 'Texture probe (debug)' then probe_row = row end end
    if not probe_row then
        mdl.panel.page = 'list'
        for _, row in ipairs(mdl.panel.rows()) do if row.label == 'Texture probe (debug)' then probe_row = row end end
    end
    check(probe_row and probe_row.value == 'OFF', 'probe row, off by default')
    probe_row.open()
    for _ = 1, 3 do env.update(0.016) end
    check(mdl.status == 'ready', 'runtime survives the probe frame')
    WITH_LAB = false
end

-- F. Player build: live resource switch without the lab, localisation ---------------
do
    local log, required = {}, {}
    local stingray = fake_stingray(log, {})
    stingray.Application.can_get = function() return false end
    local env = environment(stingray, required)
    env.CowboyBingusModLoader = {version = 17, api = 1, modules = {}}
    env.update = function() return 'g' end
    write(BASE .. '/MDL.cfg', 'return {ui = {font = "aa", material = "bb", atlas = "cc", language = "zh-CN", arsenal_dir = "' .. ROOT .. '/none"}}')
    local mdl = env.require('mods/mdl/runtime')
    check(mdl.status == 'ready' and mdl.lab and mdl.i18n and mdl.i18n.code == 'zh-CN', 'player runtime: live switch and language ready: ' .. tostring(mdl.error))
    for _ = 1, 3 do env.update(0.016) end
    local rows = mdl.panel.rows()
    local labels = {}
    for _, row in ipairs(rows) do labels[#labels + 1] = tostring(row.label or row.header) end
    local text = table.concat(labels, '|')
    check(not text:find('Resource Lab', 1, true), 'no lab page in the player build')
    check(not mdl.probe and not text:find('Texture probe', 1, true), 'no texture probe in the player build')
    check(text:find('重新扫描 mod 和库', 1, true) and text:find('语言', 1, true), 'rows in the chosen language: ' .. text)
    local file = io.open(BASE .. '/Languages/en.json', 'rb')
    check(file and file:read('*a'):find('"row.rescan": "Rescan mods and library"', 1, true), 'language templates written')
    if file then file:close() end
    check(io.open(BASE .. '/Languages/zh-CN.json', 'rb') and io.open(BASE .. '/Languages/README.txt', 'rb'), 'zh-CN file and README written')
    -- Language row cycles and saves.
    for _, row in ipairs(rows) do
        if row.label == '语言' then row.open() end
    end
    check(mdl.i18n.auto and mdl.manager.config.ui.language == nil, 'language row: chosen language -> automatic (saved as no choice)')
    for _, row in ipairs(mdl.panel.rows()) do
        if row.label == '语言' or row.label == 'Language' then row.open() break end
    end
    check(mdl.i18n.code == 'en' and not mdl.i18n.auto and mdl.manager.config.ui.language == 'en', 'language row switches and saves')
    for _ = 1, 3 do env.update(0.5) end
    if mdl.manager.flush then mdl.manager.flush() end
    local saved = io.open(BASE .. "/MDL.cfg", "rb"):read("*a")
    check(saved:find('language = "en"', 1, true), 'saved in MDL.cfg')
    -- Library watch: a manager file appearing (a mod imported while the game
    -- runs) triggers a rescan once it has been stable for one check.
    local clock = 100
    env.TEST_NOW = function() return clock end
    mdl.library.scan()
    mdl.manager.config.ui.auto_reload = true
    local revision = mdl.library.revision
    for _ = 1, 3 do clock = clock + 3; env.update(0.016) end
    check(mdl.library.revision == revision, 'no rescan while nothing changed')
    os.execute('mkdir -p "' .. ROOT .. '/none"')
    write(ROOT .. '/none/hd2a_data.json', '{"selectedProfile":"default","modsList":{}}')
    clock = clock + 3; env.update(0.016)
    check(mdl.library.revision == revision, 'first sight of a change waits for it to settle')
    clock = clock + 3; env.update(0.016)
    check(mdl.library.revision == revision + 1, 'stable change rescans the library')
    clock = clock + 3; env.update(0.016)
    check(mdl.library.revision == revision + 1, 'rescanned once')
end

os.execute('rm -rf "' .. ROOT .. '"')
print('PASS: MDL startup coordinator + runtime (MDL-hosted, BSL-hosted, native "MDL Settings" tab) (' .. checks .. ' checks)')
