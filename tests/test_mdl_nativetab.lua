-- Native ESC-menu "MDL Settings" tab (mdl_nativetab): signature decode on bytes from
-- the 2026-09-26 game.dll dump, the tab controller over fake process memory,
-- and the panel's tab placement.
-- Usage: luajit tests/test_mdl_nativetab.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local tab, native_ui, manager_module, panel_module = module('mdl_nativetab'), module('mdl_native_ui'), module('mdl_manager'), module('mdl_panel')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- 1. Decode ------------------------------------------------------------------
local INIT_RVA, SET_LABELS_RVA = 0x1473a73, 0x17aac50
local INIT = '498d9fe0040000bab6030000488bcbc6838de0000001e8925d330041b803000000488d1535dae901488bcbe8ad713300488bd341c787dc2f000003000000498d4f104188b7ed2f0000e8ff8a'
local SET_LABELS = '488954241053564883ec680f29742430488bc248897c2460488bf14c896c24504c897c244041bf08000000453bc7458bef450f4ce84489a968e000004885d274244585ed741f4d63c54881c1e8df0000'
    .. '4e8d048500000000e843dc8e00488b842488000000f30f1035b3c0c10033ff89be80e000004963cd4585ed0f8ec10100004889ac24900000008bef4c89642458448d67014c89742448488dbe20230000'
    .. '0f297c2420f30f103d7fc8c1004d63fd8b1ca8488d8f48fdffff8bd3e87f12c9ff4c8db7b0faffff498bcee800430000498bcee8e8bfc9ff418b0681c3292319c5c1e809a80175664c8b059128cc0145'
    .. '33c9418bd1418bc9498d40080f1f40004c39087414ffc248ffc14883c0184881f9000400007ce9eb2e413b50047e04418950048bc2488d0440488d4001498d04c04885c0741141ff004c893089580844'
    .. '89480c4c89481041810e00020000b867666666458bc441f7ecc1fa028bc2c1e81f03d08d049203c0442bc0448987e80700008b07c1e81283e00f83f807741783f80875224533c9ba357b2aab488bcfe8'
    .. '3c6fc9ffeb104533c9ba357b2aab488bcfe8da1bc9ff0f28ce498bcee8cfdcc9ff488d8f78060000c787dc070000010000000f57c9c687ed07000000e8afdcc9fff30f1097bcfafffff30f5997ccfaff'
    .. 'fff30f589680e00000f30f119680e00000453be5740cf30f58d7f30f119680e00000488b84248800000041ffc448ffc54881c7480d000049'
local image = {}
local function place(rva, hex) for i = 1, #hex, 2 do image[rva + (i - 1) / 2] = tonumber(hex:sub(i, i + 1), 16) end end
place(INIT_RVA, INIT); place(SET_LABELS_RVA, SET_LABELS)
-- set_label, the two string-argument candidates next to it (only the first
-- calls the record string setter) and the other widget class further away.
local SET_LABEL_RVA, ARG_RVA, ARG2_RVA, REC_RVA, REC2_RVA = 0x143bf90, 0x143c950, 0x143c9d0, 0x143a1b0, 0x143a300
place(SET_LABEL_RVA, '4883ec284c8bd93991100100000f84800000008991100100')
place(ARG_RVA, '40534883ec20488bd94881c110010000e84bd8ffff84c0745b8b93b80000008bc283c8028983b80000003bc27446f7d2')
place(ARG2_RVA, '40534883ec20488bd94881c110010000e81bd9ffff84c0745b8b93b80000008bc283c8028983b80000003bc27446f7d2')
place(REC_RVA, '48895c2418574883ec40440fb699580100004533c9498bf8')
place(REC2_RVA, '48895c24084889742410574883ec200fb699580100004533')
local OTHER_CLASS = 0x1441ca0
place(OTHER_CLASS, '40534883ec20488bd94881c110010000e8' .. string.format('%02x%02x%02x%02x',
    (REC_RVA - (OTHER_CLASS + 21)) % 256, math.floor((REC_RVA - (OTHER_CLASS + 21)) / 256) % 256,
    math.floor((REC_RVA - (OTHER_CLASS + 21)) / 65536) % 256, math.floor(((REC_RVA - (OTHER_CLASS + 21)) % 4294967296) / 16777216) % 256)
    .. '84c0745b8b93b80000008bc283c8028983b80000003bc27446f7d2')
local start = INIT_RVA - 0x300
for i = start, INIT_RVA - 1 do image[i] = (i * 31) % 253 end
local function get(i) return image[i] or 0 end
local hits = native_ui.find_all(function(i) return get(start + i) end, 0x300 + #INIT / 2, tab.SIGNATURE, 2)
check(#hits == 1 and start + hits[1] == INIT_RVA, 'screen initializer signature found once')
local layout = tab.decode(get, INIT_RVA)
check(layout.bar == 1248 and layout.state == 12252 and layout.flag == 12269, 'bar/state/flag offsets')
check(layout.set_labels == SET_LABELS_RVA and layout.labels_table == 0x33114d0, 'set_labels and label table')
check(layout.count == 57448 and layout.labels == 57320 and layout.current == 57452 and layout.first_button == 8992, 'bar layout')
check(layout.text == 8296 and layout.set_label == SET_LABEL_RVA, 'button text widget and set_label')
check(tab.find_arg_setter(get, layout.set_label, native_ui.find_all) == ARG_RVA, 'text argument setter (record setter callee, same class)')
image[REC_RVA + 9] = 0x20
check(not pcall(tab.find_arg_setter, get, layout.set_label, native_ui.find_all), 'no setter when the record setter changed')
image[REC_RVA + 9] = 0x40
-- Hash of the TEXT variable: top 32 bits of MurmurHash64A (the game passes 0x57F3D153 with "#TEXT").
local hasher = module('mdl_library').hasher(require('ffi'), require('bit'))
local raw = hasher('TEXT')
local hi = raw:byte(5) + raw:byte(6) * 256 + raw:byte(7) * 65536 + raw:byte(8) * 16777216
check(tab.TEXT_ARG == 0x57F3D153 and hi == tab.TEXT_ARG, 'TEXT argument hash = top 32 bits of MurmurHash64A')
check(tab.MODS_TEXT == 4095973923 and tab.TEXT_LABEL == 36156336, 'string ids match the game table')
-- A changed prologue is refused rather than guessed.
local saved = image[SET_LABELS_RVA + 0x2A]
image[SET_LABELS_RVA + 0x2A] = 0x09
check(not pcall(tab.decode, get, INIT_RVA), 'changed set_labels prologue rejected')
image[SET_LABELS_RVA + 0x2A] = saved

-- 2. Controller over fake memory ---------------------------------------------
local BASE, SYSTEM, SCREEN = 0x7FF600000000, 0x20000000, 0x30000000
layout.base = BASE
layout.expected = {[0] = 0xd876b36e, 0x78934e12, 0x8c02bd80}
local menu = {global = 0x347ce38}
local memory = {}
local function put(address, value, size)
    for i = 0, size - 1 do memory[address + i] = math.floor(value / 256 ^ i) % 256 end
end
local function peek(address) local v = 0 for i = 3, 0, -1 do v = v * 256 + (memory[address + i] or 0) end return v end
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
function platform.mem_write(address, data)
    for i = 1, #data do memory[address + i - 1] = data:byte(i) end
    return true
end
local bar = SCREEN + layout.bar
local function reset_screen(count, current, panel)
    for i = 0, 8 * 3400 + 64 do memory[SCREEN + layout.first_button + i] = 0 end
    put(bar + layout.count, count, 4); put(bar + layout.current, current, 4); put(SCREEN + tab.PANEL_INDEX, panel, 4)
    for i = 0, 7 do put(bar + layout.labels + 4 * i, i < 3 and layout.expected[i] or 0, 4) end
    for i = 0, 31 do memory[bar + layout.count + 24 + i] = 0 end
end
put(BASE + menu.global, SYSTEM, 8)
put(SYSTEM + tab.SCREEN_SLOT, SCREEN, 8)
reset_screen(3, 2, 2)
local calls, logs = {}, {}
local function fake_call(target, labels, count)
    calls[#calls + 1] = {bar = target, labels = labels, count = count}
    -- Emulates the native routine: stores labels/count, resets button states.
    put(target + layout.count, count, 4)
    for i = 1, count do put(target + layout.labels + 4 * (i - 1), labels[i], 4) end
    for i = 0, count - 1 do
        put(SCREEN + layout.state + 3400 * i, 1, 4); memory[SCREEN + layout.flag + 3400 * i] = 1
        put(target + layout.text + 3400 * i + tab.TEXT_RECORD, labels[i + 1], 4)
    end
end
local args = {}
local function fake_arg(widget, name, text) args[#args + 1] = {widget = widget, name = name, text = text, calls = #calls} end
local controller = tab.new({platform = platform, layout = layout, menu = menu, call = fake_call, text = 'MDL Settings', set_arg = fake_arg,
    log = function(l) logs[#logs + 1] = l end})
local info = controller.step()
check(#calls == 1 and calls[1].bar == bar and calls[1].count == 4 and calls[1].labels[4] == tab.TEXT_LABEL
    and calls[1].labels[1] == 0xd876b36e and calls[1].labels[3] == 0x8c02bd80, 'fourth label "#TEXT" added with the stock three')
check(#args == 1 and args[1].widget == bar + 8296 + 3 * 3400 and args[1].name == 0x57F3D153 and args[1].text == 'MDL Settings'
    and args[1].calls == 0, 'TEXT = "MDL Settings" set on the 4th button before the labels')
check(peek(SCREEN + layout.state + 3400 * 2) == 3 and memory[SCREEN + layout.flag + 3400 * 2] == 0, 'selected button restored')
check(peek(SCREEN + layout.state) == 1, 'other buttons left to the game')
check(info and info.count == 4 and not info.active, 'OPTIONS still selected')
check(logs[1]:find('added "MDL Settings"', 1, true) and logs[2]:find('bar layout'), 'tab and calibration logged')
info = controller.step()
check(#calls == 1 and info.count == 4, 'no second call while the tab exists')
put(bar + layout.current, 3, 4); put(SCREEN + tab.PANEL_INDEX, 3, 4)
info = controller.step()
check(info.active and #calls == 1, 'MODS tab active when bar and panel are 3')
put(SCREEN + tab.PANEL_INDEX, 1, 4)
check(not controller.step().active, 'panel switch pending is not active')
-- Screen rebuilt by the game (e.g. the menu reopened): re-added.
reset_screen(3, 0, 0)
info = controller.step()
check(#calls == 2 and info.count == 4 and peek(SCREEN + layout.state) == 3 and #args == 2, 'tab re-added after the game rebuilt the bar')
-- A 4th tab this controller did not add (another mod): not claimed.
local other = tab.new({platform = platform, layout = layout, menu = menu, call = fake_call, log = function(l) logs[#logs + 1] = l end})
check(other.step() == nil and #calls == 2 and logs[#logs]:find('another mod'), 'foreign 4th tab left alone')
put(bar + layout.current, 3, 4); put(SCREEN + tab.PANEL_INDEX, 3, 4)
check(other.step() == nil, 'foreign tab never reported active')
-- Screen not built yet: silent, no call.
reset_screen(0, 0, 0)
check(controller.step() == nil and #calls == 2, 'empty bar skipped')
-- Unknown labels (another mod changed the bar): leave it alone.
reset_screen(3, 0, 0)
put(bar + layout.labels + 4, 0x12345678, 4)
local before = #logs
check(controller.step() == nil and #calls == 2 and #logs == before + 1 and logs[#logs]:find('leaving it alone'), 'foreign bar untouched')
check(controller.step() == nil and #logs == before + 1, 'reported once')
-- Five tabs (someone else added one): untouched.
reset_screen(5, 0, 0)
for i = 3, 4 do put(bar + layout.labels + 4 * i, 0x1111 + i, 4) end
check(controller.step() == nil and #calls == 2, 'bar with 5 tabs untouched')
-- No menu system.
put(BASE + menu.global, 0, 8)
check(controller.step() == nil, 'no MenuSystem')
put(BASE + menu.global, SYSTEM, 8)
-- Native call that does nothing: disabled, not retried.
reset_screen(3, 0, 0)
local dud = tab.new({platform = platform, layout = layout, menu = menu, call = function() end})
check(dud.step() == nil and dud.disabled and dud.disabled:find('not added'), 'ineffective call disables')
check(dud.step() == nil, 'stays disabled')
local failing = tab.new({platform = platform, layout = layout, menu = menu, call = function() error('access violation') end})
check(failing.step() == nil and failing.disabled:find('access violation'), 'failing call disables')
reset_screen(3, 0, 0)
local before_calls = #calls
local bad_text = tab.new({platform = platform, layout = layout, menu = menu, call = fake_call, text = 'X', set_arg = function() error('bad arg') end})
check(bad_text.step() == nil and bad_text.disabled:find('bad arg') and #calls == before_calls, 'text failure disables before touching the bar')
-- Label written but the text widget did not take it: disabled.
reset_screen(3, 0, 0)
local lost = tab.new({platform = platform, layout = layout, menu = menu, text = 'X', set_arg = fake_arg,
    call = function(target, labels, count) fake_call(target, labels, count); put(target + layout.text + 3 * 3400 + tab.TEXT_RECORD, 0, 4) end})
check(lost.step() == nil and lost.disabled:find('not added'), 'text widget verified')
-- Plain localized id (ui.tab_label): no text argument.
reset_screen(3, 0, 0)
local plain_args = #args
local plain = tab.new({platform = platform, layout = layout, menu = menu, call = fake_call, label = tab.MODS_TEXT})
check(plain.step() and #args == plain_args and calls[#calls].labels[4] == tab.MODS_TEXT, 'plain label id without text')

-- 2b. Mod Options Menu present: MDL waits for its 4th tab and becomes the 5th --------
do
    local MOM_LABEL = 0xc67c7faf
    reset_screen(3, 1, 1)
    local mom_present = true
    local five_calls = #calls
    local five = tab.new({platform = platform, layout = layout, menu = menu, call = fake_call, text = 'MDL Settings', set_arg = fake_arg,
        log = function(l) logs[#logs + 1] = l end, after_other = function() return mom_present end})
    check(five.step() == nil and #calls == five_calls, 'waits while MOM has not added its tab')
    -- MOM adds MODS as tab 4.
    put(bar + layout.count, 4, 4); put(bar + layout.labels + 12, MOM_LABEL, 4)
    local info5 = five.step()
    local call5 = calls[#calls]
    check(#calls == five_calls + 1 and call5.count == 5 and call5.labels[4] == MOM_LABEL and call5.labels[5] == tab.TEXT_LABEL,
        'MDL added as tab 5 after MOM\'s tab')
    check(args[#args].widget == bar + 8296 + 4 * 3400 and args[#args].text == 'MDL Settings', 'text set on the 5th button')
    check(info5 and info5.slot == 4 and info5.count == 5 and not info5.active, 'slot 4, SOCIAL still selected')
    check(peek(SCREEN + layout.state + 3400 * 1) == 3, 'selected button restored')
    check(table.concat(logs, '\n'):find('as ESC-menu tab 5 (after tab 4, 0xc67c7faf)', 1, true), 'logged')
    put(bar + layout.current, 3, 4); put(SCREEN + tab.PANEL_INDEX, 3, 4)
    check(not five.step().active, 'MOM\'s tab selected: MDL hidden')
    put(bar + layout.current, 4, 4); put(SCREEN + tab.PANEL_INDEX, 4, 4)
    check(five.step().active and #calls == five_calls + 1, 'tab 5 selected: MDL shown, no new call')
    -- MOM's update sees exactly 4 tabs while it runs; the bar has 5 again afterwards.
    local seen, game = nil, 0
    local G = {}
    do
        local previous_update = function(dt) game = game + 1; return 'game' end
        local traceback = debug.traceback
        local step = function(dt) seen = peek(bar + layout.count) end
        G.update = function(dt)
            xpcall(step, traceback, dt)
            return previous_update(dt)
        end
    end
    do -- an outer wrapper (MDL or another addon) around MOM's
        local inner = G.update
        G.update = function(dt) return inner(dt) end
    end
    local shim_logs = {}
    check(tab.shim_mom(G, five, function(l) shim_logs[#shim_logs + 1] = l end) == true and shim_logs[1]:find('MDL is tab 5', 1, true),
        'MOM step found through the update chain and wrapped')
    check(G.update(0.016) == 'game' and seen == 4 and peek(bar + layout.count) == 5 and game == 1, 'MOM sees 4 tabs, the bar keeps 5')
    -- Errors inside MOM's step still reach MOM's own xpcall; the bar is restored.
    local failing_step = function() error('mom failure') end
    local ok_fail, message = pcall(five.with_four_tabs, failing_step)
    check(not ok_fail and tostring(message):find('mom failure') and peek(bar + layout.count) == 5, 'errors propagate, count restored')
    -- Without MDL's 5th tab the wrapper changes nothing.
    reset_screen(4, 0, 0); put(bar + layout.labels + 12, MOM_LABEL, 4)
    five.ours = false
    G.update(0.016)
    check(seen == 4 and peek(bar + layout.count) == 4, 'no 5th tab: untouched')
    check(tab.shim_mom({update = function() end}, five) == false, 'no MOM in the chain: not wrapped')
    -- A 5th tab that is not MDL's: left alone.
    reset_screen(5, 0, 0); put(bar + layout.labels + 12, MOM_LABEL, 4); put(bar + layout.labels + 16, 0x4444, 4)
    check(five.step() == nil and #calls == five_calls + 1, 'foreign 5th tab left alone')
    -- Menu rebuilt with MOM: waits again, then re-added.
    reset_screen(3, 0, 0)
    check(five.step() == nil, 'rebuilt bar: waits for MOM again')
    put(bar + layout.count, 4, 4); put(bar + layout.labels + 12, MOM_LABEL, 4)
    check(five.step().slot == 4 and #calls == five_calls + 2, 're-added as tab 5')
end

-- 3. Panel follows the tab ----------------------------------------------------
local files = {}
local fs = {mkdir = function() return true end, read = function(p) return files[p] end, read_head = function() return nil end,
    write = function(p, d) files[p] = d return true end, list = function() return {} end}
local m = manager_module.new({base_dir = 'C:/T', platform = fs, globals = _G})
m.start()
local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
    held = function() return false end, wheel = function() return 0 end}
local drawn, cleared = 0, 0
local last_list
local renderer = {resolution = function() return 1920, 1080 end,
    draw = function(list) drawn = drawn + 1; last_list = list return true end, clear = function() cleared = cleared + 1 end}
local menu_open, state = true, nil
local panel = panel_module.new(m, input, renderer, {menu_probe = function() return menu_open end, tab_state = function() return state end})
panel.frame()
check(panel.visible and panel.mode == 'float', 'no tab: floating panel')
local function min_x(list)
    local x = math.huge
    for _, item in ipairs(list) do
        local px = item.x or item[2]
        if type(px) == 'number' and px < x then x = px end
    end
    return x
end
local float_x = min_x(last_list)
state = {active = false}
panel.frame()
check(not panel.visible and panel.mode == 'tab' and cleared == 1, 'tab mode hides the panel on other tabs')
state = {active = true}
panel.frame()
check(panel.visible and panel.mode == 'tab', 'shown on the MODS tab')
local tab_x = min_x(last_list)
local widest, tallest, biggest = 0, 0, 0
for _, item in ipairs(last_list) do
    if item.rect then widest = math.max(widest, item.w); tallest = math.max(tallest, item.h) end
    if item.text and item.size then biggest = math.max(biggest, item.size) end
end
check(math.abs(widest - 1240) < 1 and tallest > 800 and biggest >= 30, 'tab page is wide, full height, larger text (' .. widest .. 'x' .. tallest .. ')')
check(tab_x < float_x and math.abs(tab_x - (1920 - 1240) / 2) < 40, 'centred in the content area (' .. tab_x .. ' vs ' .. float_x .. ')')
m.config.ui.tab_x = 300
state = {active = false}; panel.frame(); state = {active = true}
panel.frame()
check(math.abs(min_x(last_list) - 300) < 40, 'ui.tab_x override')
menu_open = false
panel.frame()
check(not panel.visible, 'menu closed hides the panel in tab mode too')

print('PASS: MDL native "MDL Settings" tab (decode, controller, placement) (' .. checks .. ' checks)')
