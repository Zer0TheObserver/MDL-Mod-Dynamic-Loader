-- MDL: native "MDL Settings" tab in the in-game ESC menu (independent implementation).
--
-- The ESC menu (MenuScreenType InGame) is a native screen object stored in the
-- MenuSystem (+200). Its tab bar sits inside the screen and is filled by a
-- native "set tab labels" routine (labels[], count <= 8). The screen's own
-- initializer calls it with the three localized ids GAME/SOCIAL/OPTIONS and
-- then marks the current button selected. We call the same routine with a
-- fourth id. Selecting the fourth tab makes the screen switch its content
-- panel to index 3, which closes the previous panel and opens none (static
-- analysis of the panel switch, output20260926 game.dll+0x1474370); MDL then
-- draws its own panel in that empty content area.
--
-- Everything is located by one signature in the screen initializer (unique in
-- the 2026-06-19 .. 2026-09-26 dumps, identical layout in all five):
--   lea rbx,[r15+BAR]; mov edx,imm; mov rcx,rbx; mov byte [rbx+imm],1; call ..
--   mov r8d,3; lea rdx,[rip+LABELS]; mov rcx,rbx; call SET_LABELS; mov rdx,rbx
--   mov dword [r15+STATE],3; lea rcx,[r15+16]; mov byte [r15+FLAG],sil
-- and SET_LABELS's prologue gives the count/labels/button offsets.
local M = {}

M.SIGNATURE = '49 8D 9F ?? ?? ?? ?? BA ?? ?? 00 00 48 8B CB C6 83 ?? ?? ?? ?? 01 E8 ?? ?? ?? ?? '
    .. '41 B8 03 00 00 00 48 8D 15 ?? ?? ?? ?? 48 8B CB E8 ?? ?? ?? ?? 48 8B D3 '
    .. '41 C7 87 ?? ?? ?? ?? 03 00 00 00 49 8D 4F 10 41 88 B7 ?? ?? ?? ??'
M.SET_LABELS_PROLOGUE = '48 89 54 24 10 53 56 48 83 EC 68 0F 29 74 24 30 48 8B C2 48 89 7C 24 60 48 8B F1 '
    .. '4C 89 6C 24 50 4C 89 7C 24 40 41 BF 08 00 00 00 45 3B C7 45 8B EF 45 0F 4C E8 44 89 A9'

-- Custom tab text: the game's own localized string 0x0227B3B0 is just "#TEXT";
-- its TEXT variable (name hash = top 32 bits of MurmurHash64A("TEXT")) is set
-- on the tab's text widget with the widget's native string-argument setter,
-- exactly like the game does for its own "#TEXT" labels. The setter keeps the
-- pointer, so the text buffer is anchored for the whole session.
M.LABEL_LOOP = '8B 1C A8 48 8D 8F ?? ?? ?? ?? 8B D3 E8'          -- set_labels: set_label(button text, id)
M.SET_LABEL_HEAD = '48 83 EC 28 4C 8B D9 39 91 10 01 00 00'       -- cmp [rcx+272], edx (text record id)
M.ARG_SIGNATURE = '40 53 48 83 EC 20 48 8B D9 48 81 C1 10 01 00 00 E8 ?? ?? ?? ?? 84 C0 74 ?? '
    .. '8B 93 B8 00 00 00 8B C2 83 C8 02 89 83 B8 00 00 00 3B C2 74'
M.ARG_RECORD_HEAD = '48 89 5C 24 18 57 48 83 EC 40 44 0F B6 99 58 01 00 00' -- record string setter
M.ARG_WINDOW = 0x4000    -- the setter follows set_label in the same widget class (+0x9C0 in 06..09 builds)

M.SCREEN_SLOT = 200      -- MenuSystem + 8 * 25: InGame screen object (allocator case 14)
M.PANEL_INDEX = 8        -- screen + 8: open content panel (0 GAME, 1 SOCIAL, 2 OPTIONS)
M.BUTTON_STRIDE = 3400
M.TEXT_RECORD = 272      -- text widget + 272: localized string id
M.TEXT_LABEL = 0x0227B3B0 -- localized "#TEXT" (id 36156336)
M.TEXT_ARG = 0x57F3D153   -- variable TEXT
M.DEFAULT_TEXT = 'MDL Settings'
M.MODS_TEXT = 0xF4239A23 -- localized "Mods" (id 4095973923)

local function u32(get, offset)
    return get(offset) + get(offset + 1) * 256 + get(offset + 2) * 65536 + get(offset + 3) * 16777216
end
local function i32(get, offset)
    local value = u32(get, offset)
    if value >= 2147483648 then value = value - 4294967296 end
    return value
end
local function matches(get, at, signature)
    local i = 0
    for token in signature:gmatch('%S+') do
        if token ~= '??' and get(at + i) ~= tonumber(token, 16) then return false end
        i = i + 1
    end
    return true
end
M.matches = matches

-- Decodes the initializer match at `at` (image offset) into a layout.
function M.decode(get, at)
    local layout = {
        bar = u32(get, at + 3),                    -- screen + bar
        labels_table = at + 40 + i32(get, at + 36),
        set_labels = at + 48 + i32(get, at + 44),
        state = u32(get, at + 54),                 -- screen + button[0].state
        flag = u32(get, at + 69),                  -- screen + button[0] selected flag
    }
    local fn = layout.set_labels
    assert(matches(get, fn, M.SET_LABELS_PROLOGUE), 'set-labels prologue changed')
    layout.count = u32(get, fn + 0x38)             -- bar + tab count (labels at bar + labels)
    assert(get(fn + 0x4C - 2) == 0x81 and get(fn + 0x4C - 1) == 0xC1, 'labels offset not found')
    layout.labels = u32(get, fn + 0x4C)
    layout.current = layout.count + 4              -- bar + selected tab index
    -- Button array base (lea rdi,[rsi+imm]) and the 3400-byte stride.
    local first, stride
    for i = 0, 0x140 do
        if not first and get(fn + i) == 0x48 and get(fn + i + 1) == 0x8D and get(fn + i + 2) == 0xBE then
            first = u32(get, fn + i + 3)
        end
        if not stride and matches(get, fn + i, '48 81 C7 48 0D 00 00') then stride = 3400 end
    end
    if not stride then
        for i = 0x140, 0x340 do
            if matches(get, fn + i, '48 81 C7 48 0D 00 00') then stride = 3400 break end
        end
    end
    assert(first and stride == M.BUTTON_STRIDE, 'tab button layout changed')
    layout.first_button = first
    -- Button text widget and set_label from the per-button loop.
    for i = 0, 0x1C0 do
        if matches(get, fn + i, M.LABEL_LOOP) then
            layout.text = first + i32(get, fn + i + 6)
            layout.set_label = fn + i + 17 + i32(get, fn + i + 13)
            break
        end
    end
    assert(layout.text and layout.text > first - M.BUTTON_STRIDE and layout.text < first, 'tab text widget not found')
    assert(matches(get, layout.set_label, M.SET_LABEL_HEAD), 'set_label changed')
    -- Cross-check: button[0].state measured two ways must agree.
    assert(layout.state - layout.bar - first == 2012, 'button state offset changed')
    assert(layout.flag - layout.state == 17, 'button flag offset changed')
    assert(layout.count > layout.labels and layout.count - layout.labels == 128, 'tab arrays changed')
    return layout
end

-- The string-argument setter of the tab text widget class: an ARG_SIGNATURE
-- match whose callee is the record string setter, and the only one in the
-- ARG_WINDOW after set_label (another widget class has the same shape
-- further away: +0x5D10 in the 0926 build). Only that window is scanned.
function M.find_arg_setter(get, set_label, find_all)
    local hits = find_all(function(i) return get(set_label + i) end, M.ARG_WINDOW, M.ARG_SIGNATURE, 8)
    local picked = {}
    for _, hit in ipairs(hits) do
        local at = set_label + hit
        local callee = at + 21 + i32(get, at + 17)
        if hit > 0 and matches(get, callee, M.ARG_RECORD_HEAD) then picked[#picked + 1] = at end
    end
    assert(#picked == 1, 'text argument setter matched ' .. #picked .. ' times')
    return picked[1]
end

function M.resolve(ffi, platform, find_all)
    local base = assert(platform.module('game.dll'), 'game.dll not loaded')
    local bytes = ffi.cast('const uint8_t *', base)
    local function get(i) return bytes[i] end
    local pe = u32(get, 0x3c)
    local sections, optional = get(pe + 6) + get(pe + 7) * 256, get(pe + 20) + get(pe + 21) * 256
    local text_start, text_size
    for i = 0, sections - 1 do
        local header = pe + 24 + optional + 40 * i
        if math.floor(u32(get, header + 36) / 0x20000000) % 2 == 1 then
            text_size, text_start = u32(get, header + 8), u32(get, header + 12)
            break
        end
    end
    assert(text_start, 'code section unavailable')
    local code = bytes + text_start
    local hits = find_all(function(i) return code[i] end, text_size, M.SIGNATURE, 2)
    assert(#hits == 1, 'ESC-menu tab signature matched ' .. #hits .. ' times')
    local layout = M.decode(get, text_start + hits[1])
    layout.base = base
    local expected = {}
    for i = 0, 2 do expected[i] = u32(get, layout.labels_table + 4 * i) end
    layout.expected = expected
    local found, setter = pcall(M.find_arg_setter, get, layout.set_label, find_all)
    if found then layout.set_arg = setter else layout.arg_problem = tostring(setter) end
    return layout
end

-- setter(widget, name_hash, utf8): the native keeps the pointer, so buffers
-- are anchored here for the session.
local anchors = {}
function M.native_arg(ffi, layout)
    local fn = ffi.cast('void (*)(void *, uint32_t, const char *)', layout.base + layout.set_arg)
    return function(widget, name, text)
        local buffer = anchors[text]
        if not buffer then
            buffer = ffi.new('char[?]', #text + 1)
            ffi.copy(buffer, text)
            anchors[text] = buffer
        end
        fn(ffi.cast('void *', widget), name, buffer)
    end
end

-- The native routine is set_labels(bar, const uint32_t *labels, int32_t count):
-- rcx/rdx/r8 only (r9 is zeroed before any read), count clamped to 8.
function M.native_call(ffi, layout)
    local fn = ffi.cast('void (*)(void *, const uint32_t *, int32_t)', layout.base + layout.set_labels)
    return function(bar, labels, count)
        local array = ffi.new('uint32_t[8]')
        for i = 1, count do array[i - 1] = labels[i] end
        fn(ffi.cast('void *', bar), array, count)
    end
end

-- Controller. options = {platform=, layout=, menu=(mdl_menu layout), call=fn(bar, labels, count),
--                         label=, text=, set_arg=fn(widget, name, text), log=, after_other=fn() -> bool}
-- With `text`, MDL's label is "#TEXT" and TEXT is set on the button first, so
-- the game measures the tab with the final text.
-- after_other() true (Mod Options Menu present): MDL waits for that mod's 4th
-- tab and adds itself as the 5th; the panel switch leaves every index above
-- OPTIONS empty (set_panel 0x1474370 only opens/closes 0..2), so index 4 is as
-- free as 3.
-- step() -> state table {open=, active=, tab=, panel=, slot=} or nil when unavailable.
function M.new(options)
    local platform, layout, menu = options.platform, options.layout, options.menu
    local text = options.text
    local label = options.label or (text and M.TEXT_LABEL) or M.MODS_TEXT
    local self = {calls = 0, disabled = nil}
    local base = layout.base
    local function log(line) if options.log then pcall(options.log, 'native tab: ' .. line) end end

    local function read_u32(address)
        local raw = platform.mem_read(address, 4)
        if not raw then return nil end
        return raw:byte(1) + raw:byte(2) * 256 + raw:byte(3) * 65536 + raw:byte(4) * 16777216
    end
    local function read_i32(address)
        local value = read_u32(address)
        if value and value >= 2147483648 then value = value - 4294967296 end
        return value
    end
    local function read_ptr(address)
        local raw = platform.mem_read(address, 8)
        if not raw then return nil end
        local lo = raw:byte(1) + raw:byte(2) * 256 + raw:byte(3) * 65536 + raw:byte(4) * 16777216
        local hi = raw:byte(5) + raw:byte(6) * 256 + raw:byte(7) * 65536 + raw:byte(8) * 16777216
        if hi == 0 and lo < 0x10000 or hi >= 0x8000 then return nil end
        return hi * 4294967296 + lo
    end

    function self.screen()
        local system = read_ptr(base + menu.global)
        if not system then return nil end
        local screen = read_ptr(system + M.SCREEN_SLOT)
        if not screen or screen % 8 ~= 0 then return nil end
        return screen
    end

    -- Reads the bar and checks it is the ESC menu's bar we know.
    function self.inspect(screen)
        local bar = screen + layout.bar
        local count = read_i32(bar + layout.count)
        local current = read_i32(bar + layout.current)
        local panel = read_i32(screen + M.PANEL_INDEX)
        if not (count and current and panel) then return nil end
        local labels = {}
        for i = 0, math.max(0, math.min(count, 8) - 1) do labels[i] = read_u32(bar + layout.labels + 4 * i) end
        local ours = true
        for i = 0, 2 do if labels[i] ~= layout.expected[i] then ours = false end end
        return {bar = bar, count = count, current = current, panel = panel, labels = labels, known = ours}
    end

    -- One-time dump of the bar's layout floats (tab widths/positions) so the
    -- panel placement can be calibrated from MDL.log.
    function self.calibrate(info)
        local raw = platform.mem_read(info.bar + layout.count + 24, 32)
        if not raw then return end
        local ffi = options.ffi
        local values = {}
        if ffi then
            local f = ffi.new('float[8]')
            ffi.copy(f, raw, 32)
            for i = 0, 7 do values[#values + 1] = string.format('%.1f', f[i]) end
        else
            for i = 1, 32, 4 do values[#values + 1] = string.format('%02x%02x%02x%02x', raw:byte(i + 3), raw:byte(i + 2), raw:byte(i + 1), raw:byte(i)) end
        end
        log('bar layout: ' .. table.concat(values, ' '))
    end

    local reported
    local function unexpected(info, why)
        if info and not reported then
            reported = true
            log(string.format('unexpected bar (count %s, current %s, panel %s, known %s%s); leaving it alone',
                tostring(info.count), tostring(info.current), tostring(info.panel), tostring(info.known), why and ('; ' .. why) or ''))
        end
        return nil
    end
    function self.step()
        if self.disabled then return nil end
        local screen = self.screen()
        if not screen then return nil end
        local info = self.inspect(screen)
        if info and info.count == 0 then return nil end -- screen not built yet
        local after = options.after_other and options.after_other() == true
        local slot = after and 4 or 3
        if not info or not info.known or info.count < 3 or info.count > slot + 1 or info.current < 0 or info.current >= info.count
            or info.panel < 0 or info.panel > slot then
            return unexpected(info)
        end
        if self.ours and self.slot ~= slot then self.ours = false end
        if info.count == slot + 1 and not (self.ours and info.labels[slot] == label) then
            -- Another mod's tab sits where MDL's would go: leave it, float.
            if not self.foreign_reported then
                self.foreign_reported = true
                log(string.format('tab %d (0x%x) belongs to another mod; using the floating panel', slot + 1, info.labels[slot] or 0))
            end
            return nil
        end
        if after and info.count == 3 then
            -- Wait for the other mod's 4th tab, so it never mistakes MDL's for its own.
            return nil
        end
        if info.count == slot then
            self.ours = false
            local widget = info.bar + layout.text + M.BUTTON_STRIDE * slot
            if text then
                local set, why = pcall(options.set_arg, widget, M.TEXT_ARG, text)
                if not set then
                    self.disabled = 'tab text failed: ' .. tostring(why)
                    log(self.disabled)
                    return nil
                end
            end
            local labels = {layout.expected[0], layout.expected[1], layout.expected[2]}
            if slot == 4 then labels[4] = info.labels[3] end
            labels[slot + 1] = label
            local ok, problem = pcall(options.call, info.bar, labels, slot + 1)
            self.calls = self.calls + 1
            if not ok then
                self.disabled = 'set labels failed: ' .. tostring(problem)
                log(self.disabled)
                return nil
            end
            -- The routine resets every button; restore the selected one the
            -- way the screen initializer does (state 3, flag cleared).
            local state = screen + layout.state + M.BUTTON_STRIDE * info.current
            platform.mem_write(state, '\3\0\0\0')
            platform.mem_write(screen + layout.flag + M.BUTTON_STRIDE * info.current, '\0')
            local before = info.labels[3]
            info = self.inspect(screen)
            if not info or info.count ~= slot + 1 or info.labels[slot] ~= label or read_u32(widget + M.TEXT_RECORD) ~= label
                or slot == 4 and info.labels[3] ~= before then
                self.disabled = 'tab not added (count ' .. tostring(info and info.count) .. ')'
                log(self.disabled)
                return nil
            end
            self.ours, self.slot = true, slot
            if self.calls == 1 or self.logged_slot ~= slot then
                self.logged_slot = slot
                log('added "' .. tostring(text or string.format('0x%x', label)) .. '" as ESC-menu tab ' .. (slot + 1)
                    .. (slot == 4 and string.format(' (after tab 4, 0x%x)', before or 0) or ''))
                if self.calls == 1 then self.calibrate(info) end
            end
        end
        info.slot = slot
        info.active = info.current == slot and info.panel == slot
        info.screen = screen
        return info
    end

    -- Runs fn while the bar shows one tab fewer (MDL's 5th hidden), for a mod
    -- that only accepts exactly 4 tabs (Mod Options Menu 1.1 and older). Only
    -- the count field is changed, and only when it is still MDL's 5-tab bar.
    function self.with_four_tabs(fn, ...)
        if not (self.ours and self.slot == 4) then return fn(...) end
        local screen = self.screen()
        local bar = screen and screen + layout.bar
        if not bar or read_i32(bar + layout.count) ~= 5 or read_u32(bar + layout.labels + 16) ~= label then return fn(...) end
        platform.mem_write(bar + layout.count, '\4\0\0\0')
        local results = {pcall(fn, ...)}
        if read_i32(bar + layout.count) == 4 then platform.mem_write(bar + layout.count, '\5\0\0\0') end
        if not results[1] then error(results[2], 0) end
        return unpack(results, 2, table.maxn(results))
    end

    return self
end

-- Mod Options Menu (<= 1.1) checks that the bar has exactly 4 tabs every frame.
-- Its per-frame function is the `step` upvalue of its `update` wrapper (found
-- by walking the global update chain); MDL wraps it so that, while MOM runs,
-- the bar shows 4 tabs. Returns true when wrapped.
function M.find_upvalue_function(root, wanted, others, limit)
    local queue, seen, visited = {root}, {}, 0
    while #queue > 0 and visited < (limit or 400) do
        local fn = table.remove(queue, 1)
        if type(fn) == 'function' and not seen[fn] then
            seen[fn] = true
            visited = visited + 1
            local names, index = {}, nil
            local i = 1
            while true do
                local name, value = debug.getupvalue(fn, i)
                if not name then break end
                names[name] = true
                if name == wanted and type(value) == 'function' then index = i end
                if type(value) == 'function' then queue[#queue + 1] = value end
                i = i + 1
            end
            local all = index ~= nil
            for _, other in ipairs(others or {}) do if not names[other] then all = false end end
            if all then return fn, index end
        end
    end
    return nil
end
function M.shim_mom(G, controller, log)
    local update = rawget(G, 'update')
    if type(update) ~= 'function' then return false, 'no update chain' end
    local owner, index = M.find_upvalue_function(update, 'step', {'previous_update', 'traceback'})
    if not owner then return false, 'Mod Options Menu update not found' end
    local _, step = debug.getupvalue(owner, index)
    if type(step) ~= 'function' then return false, 'step is not a function' end
    local wrapped = function(...) return controller.with_four_tabs(step, ...) end
    debug.setupvalue(owner, index, wrapped)
    if log then pcall(log, 'native tab: Mod Options Menu sees 4 tabs while it runs (MDL is tab 5)') end
    return true
end

return M
