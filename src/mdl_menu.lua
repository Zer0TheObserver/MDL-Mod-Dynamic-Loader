-- MDL: native menu state. Finds the game's MenuSystem at runtime so the panel
-- follows the real ESC menu (including menus closed by cutscenes) instead of
-- counting ESC presses.
--
-- Signature: MenuSystem pop_screen(type) - it loads the MenuSystem singleton
-- (mov rbx,[rip+x]), tests the "menu open" byte (cmp byte [rbx+imm32],0) and
-- indexes the MenuScreenType name table (lea rax,[rip+y]). It matched once in
-- every game.dll dump from 2026-06-09 to 2026-09-26; the open byte was +2177
-- (June) and +2185 later, and the name table always contained "InGame" (the
-- in-game ESC menu). MenuSystem layout: +0 current MenuScreenType (u32),
-- +open byte, +open+1 "hidden" byte (set_hidden during cutscenes).
local M = {}

M.SIGNATURE = '40 53 48 83 EC 20 48 8B 1D ?? ?? ?? ?? 8B 03 3B C2 75 ?? 80 BB ?? ?? 00 00 00 74 ?? '
    .. '44 8B C0 48 8D 15 ?? ?? ?? ?? 48 8D 05 ?? ?? ?? ?? 48 8D 0D ?? ?? ?? ?? 4E 8B 04 C0'

local function u32(get, offset)
    return get(offset) + get(offset + 1) * 256 + get(offset + 2) * 65536 + get(offset + 3) * 16777216
end
local function i32(get, offset)
    local value = u32(get, offset)
    if value >= 2147483648 then value = value - 4294967296 end
    return value
end

-- Decodes a matched pop_screen at image offset `at`.
function M.decode(get, at)
    local open = u32(get, at + 21)
    assert(open > 0 and open < 65536, 'implausible menu open offset')
    return {
        global = at + 13 + i32(get, at + 9),   -- RVA of the MenuSystem pointer
        open = open,                           -- byte: menu system active
        hidden = open + 1,                     -- byte: set_hidden(true)
        names = at + 45 + i32(get, at + 41),   -- RVA of const char *names[]
    }
end

-- options = {find_all=, decode_image=} are supplied by mdl_native_ui helpers.
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
    assert(#hits == 1, 'MenuSystem signature matched ' .. #hits .. ' times')
    local layout = M.decode(get, text_start + hits[1])
    layout.base = base
    return layout
end

-- Reads the screen-type names (up to "Count") through the platform.
function M.read_names(platform, layout)
    local names = {}
    local base = layout.base
    for index = 0, 63 do
        local raw = platform.mem_read(base + layout.names + 8 * index, 8)
        if not raw then break end
        local lo = raw:byte(1) + raw:byte(2) * 256 + raw:byte(3) * 65536 + raw:byte(4) * 16777216
        local hi = raw:byte(5) + raw:byte(6) * 256 + raw:byte(7) * 65536 + raw:byte(8) * 16777216
        local address = hi * 4294967296 + lo
        local text = platform.mem_read(address, 32) or platform.mem_read(address, 16)
        if not text then break end
        local name = text:match('^([%w_]+)%z')
        if not name then break end
        names[index] = name
        if name == 'Count' then break end
    end
    return names
end

-- Returns a probe: probe() -> open(boolean), screen name; nil when unknown.
function M.probe(platform, layout, names, wanted)
    local want = {}
    for _, name in ipairs(wanted or {'InGame'}) do want[name] = true end
    local base = layout.base
    return function()
        local raw = platform.mem_read(base + layout.global, 8)
        if not raw then return nil end
        local lo = raw:byte(1) + raw:byte(2) * 256 + raw:byte(3) * 65536 + raw:byte(4) * 16777216
        local hi = raw:byte(5) + raw:byte(6) * 256 + raw:byte(7) * 65536 + raw:byte(8) * 16777216
        if hi == 0 and lo < 0x10000 or hi >= 0x8000 then return nil end
        local system = hi * 4294967296 + lo
        local head = platform.mem_read(system, 4)
        local flags = platform.mem_read(system + layout.open, 2)
        if not head or not flags then return nil end
        local current = head:byte(1) + head:byte(2) * 256 + head:byte(3) * 65536 + head:byte(4) * 16777216
        local name = names[current] or tostring(current)
        local open = flags:byte(1) ~= 0 and flags:byte(2) == 0 and want[name] == true
        return open, name
    end
end

return M
