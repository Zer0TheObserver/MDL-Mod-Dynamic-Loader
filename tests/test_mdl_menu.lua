-- Native ESC-menu state (MenuSystem), the ESC fallback resync, and the
-- panel's idle cost (no rebuilds / no GUI work while nothing changes).
-- Usage: luajit tests/test_mdl_menu.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_menu, mdl_native_ui, mdl_manager, mdl_panel = module('mdl_menu'), module('mdl_native_ui'), module('mdl_manager'), module('mdl_panel')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- 1. Signature and decoding on pop_screen bytes from the 2026-06-09 and
--    2026-09-26 game.dll dumps.
for _, fixture in ipairs({
    {rva = 0x10593e0, global = 0x1a92e28, open = 2177, names = 0x1511fa0,
     hex = '40534883ec20488b1d3b9aa3008b033bc2755c80bb81080000007453448bc0488d1592785a00488d05938b4b00488d0d34785a004e8b04c0'},
    {rva = 0x1438350, global = 0x347ce38, open = 2185, names = 0x21d90a0,
     hex = '40534883ec20488b1ddb4a04028b033bc2755c80bb89080000007453448bc0488d151228e900488d05230dda00488d0dec25e9004e8b04c0'},
}) do
    local image = {}
    for i = 1, #fixture.hex, 2 do image[fixture.rva + (i - 1) / 2] = tonumber(fixture.hex:sub(i, i + 1), 16) end
    local start = fixture.rva - 0x400
    for i = start, fixture.rva - 1 do image[i] = (i * 29) % 251 end
    local function get(i) return image[i] or 0 end
    local hits = mdl_native_ui.find_all(function(i) return get(start + i) end, 0x400 + #fixture.hex / 2, mdl_menu.SIGNATURE, 2)
    check(#hits == 1 and start + hits[1] == fixture.rva, 'MenuSystem signature found once')
    local layout = mdl_menu.decode(get, fixture.rva)
    check(layout.global == fixture.global and layout.open == fixture.open and layout.hidden == fixture.open + 1
        and layout.names == fixture.names, string.format('decoded layout %x', fixture.rva))
end

-- 2. Probe over fake process memory.
local memory = {}
local platform = {}
function platform.mem_read(address, size)
    local out = {}
    for i = 0, size - 1 do
        local b = memory[address + i]
        if b == nil then return nil end
        out[#out + 1] = string.char(b)
    end
    return table.concat(out)
end
local function put(address, bytes) for i = 1, #bytes do memory[address + i - 1] = bytes:byte(i) end end
local function u64(v) local t = {} for i = 1, 8 do t[i] = string.char(v % 256); v = math.floor(v / 256) end return table.concat(t) end
local function u32(v) return u64(v):sub(1, 4) end
local BASE, SYSTEM = 0x10000000, 0x20000000
local layout = {base = BASE, global = 0x100, open = 2185, hidden = 2186, names = 0x200}
local names_list = {'None', 'Agreement', 'InGame', 'Count'}
for i, name in ipairs(names_list) do
    put(BASE + 0x200 + 8 * (i - 1), u64(0x30000000 + 64 * i))
    put(0x30000000 + 64 * i, name .. string.rep('\0', 40 - #name))
end
local names = mdl_menu.read_names(platform, layout)
check(names[0] == 'None' and names[2] == 'InGame' and names[3] == 'Count' and names[4] == nil, 'screen names read')
local probe = mdl_menu.probe(platform, layout, names, {'InGame'})
check(probe() == nil, 'null MenuSystem pointer is unknown')
put(BASE + 0x100, u64(SYSTEM))
put(SYSTEM, u32(0)); put(SYSTEM + 2185, '\0\0')
local open, name = probe()
check(open == false and name == 'None', 'closed menu')
put(SYSTEM, u32(2)); put(SYSTEM + 2185, '\1\0')
open, name = probe()
check(open == true and name == 'InGame', 'ESC menu open')
put(SYSTEM + 2186, '\1')
check(probe() == false, 'hidden by a cutscene counts as closed')
put(SYSTEM + 2186, '\0'); put(SYSTEM, u32(1))
open, name = probe()
check(open == false and name == 'Agreement', 'other screens do not show the panel')

-- 3. Panel: native probe drives visibility; ESC fallback resyncs on context change.
local fs = {mkdir = function() return true end, read = function() return nil end, read_head = function() return nil end,
    write = function() return true end, list = function() return {} end}
local m = mdl_manager.new({base_dir = 'C:/T', platform = fs, globals = setmetatable({}, {__index = _G})})
m.start()
local pressed = {}
local input = {pressed = function(...) for _, n in ipairs({...}) do if pressed[n] then return true end end return false end,
    cursor = function() return nil end, clicked = function() return false end, held = function() return false end,
    wheel = function() return 0 end}
local draws, clears, resolutions = 0, 0, 0
local renderer = {resolution = function() resolutions = resolutions + 1 return 1920, 1080 end,
    draw = function() draws = draws + 1 return true end, clear = function() clears = clears + 1 end}
local native_open = false
local panel = mdl_panel.new(m, input, renderer, {menu_probe = function() return native_open end})
pressed = {esc = true}; panel.frame(); pressed = {}
check(not panel.visible, 'ESC ignored when the native state says closed')
native_open = true; panel.frame()
check(panel.visible and panel.native, 'native open shows the panel')
native_open = false; panel.frame()
check(not panel.visible and clears == 1, 'native close (e.g. cutscene) hides it')
-- Idle cost while hidden: no resolution queries, no drawing.
local r0, d0 = resolutions, draws
for _ = 1, 100 do panel.frame() end
check(resolutions == r0 and draws == d0, 'hidden panel does no GUI work')
-- Idle cost while shown: one rebuild, then none.
native_open = true
panel.frame()
local builds = panel.builds
for _ = 1, 50 do panel.frame() end
check(panel.builds == builds, 'no rebuilds while nothing changes (' .. tostring(builds) .. ')')
m.save(); panel.frame(); panel.frame()
check(panel.builds == builds + 1, 'a manager change triggers exactly one rebuild')

local serial = 1
local fallback = mdl_panel.new(m, input, renderer, {context_serial = function() return serial end})
pressed = {esc = true}; fallback.frame(); pressed = {}
check(fallback.visible and not fallback.native, 'ESC fallback opens')
serial = 2; fallback.frame()
check(not fallback.visible, 'world change (level load / cutscene) resets the fallback')
pressed = {esc = true}; fallback.frame(); pressed = {}
check(fallback.visible, 'next ESC opens again, in sync')

-- 4. Per-mod frame cost.
local t = 0
local files = {['C:/T/Mods/slow/mod.lua'] = 'return {on_update = function() Clock.t = Clock.t + 0.002 end}'}
local fs2 = {mkdir = function() return true end, read = function(p) return files[p] end, read_head = function() return nil end,
    write = function() return true end}
function fs2.list(d) if d == 'C:/T/Mods' then return {{name = 'slow', dir = true, mtime = 0}} end return {} end
local Clock = {t = 0}
local m2 = mdl_manager.new({base_dir = 'C:/T', platform = fs2, globals = setmetatable({Clock = Clock}, {__index = _G}),
    clock = function() return Clock.t end})
m2.start(); m2.enable(m2.by_id.slow)
for _ = 1, 10 do m2.frame(0.016) end
check(m2.by_id.slow.cost and math.abs(m2.by_id.slow.cost - 2) < 1e-6 and math.abs(m2.by_id.slow.peak - 2) < 1e-6, 'frame cost measured in ms')

print('PASS: MDL native menu state, fallback resync, idle cost and frame cost (' .. checks .. ' checks)')
