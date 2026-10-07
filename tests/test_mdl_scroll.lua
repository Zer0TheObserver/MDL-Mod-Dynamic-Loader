-- Long lists: scrollbar, range label, wheel, paging, thumb dragging.
-- Usage: luajit tests/test_mdl_scroll.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_manager, mdl_panel = module('mdl_manager'), module('mdl_panel')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

local files = {}
local BASE = 'C:/TestData/MDL/Helldivers2'
for i = 1, 40 do files[string.format('%s/Mods/mod%02d/mod.lua', BASE, i)] = 'return {name = "Mod ' .. string.format('%02d', i) .. '"}' end
local platform = {mkdir = function() return true end, read = function(p) return files[p] end,
    read_head = function(p, n) return files[p] and files[p]:sub(1, n) end, write = function(p, d) files[p] = d return true end}
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
local m = mdl_manager.new({base_dir = BASE, platform = platform, globals = setmetatable({}, {__index = _G})})
m.start()

local state = {pressed = {}, cursor = nil, click = nil, held = false, wheel = 0}
local input = {
    pressed = function(...) for _, n in ipairs({...}) do if state.pressed[n] then return true end end return false end,
    cursor = function() if state.cursor then return state.cursor[1], state.cursor[2] end end,
    clicked = function(b) return state.click == b end,
    held = function(b) return b == 'left' and state.held end,
    wheel = function() return state.wheel end,
}
local drawn
local renderer = {resolution = function() return 1920, 1080 end, draw = function(list) drawn = list return true end, clear = function() end}
local panel = mdl_panel.new(m, input, renderer)
local function frame(opts)
    opts = opts or {}
    state.pressed, state.cursor, state.click, state.held, state.wheel = opts.keys or {}, opts.at, opts.click, opts.held or false, opts.wheel or 0
    panel.frame()
    m.frame(0.016)
end
local function find(pattern)
    for _, item in ipairs(drawn or {}) do if item.text and item.text:find(pattern) then return item end end
end
local function bar_rects()
    local track, thumb
    for _, item in ipairs(drawn) do
        if item.rect and item.z == 905 then track = item end
        if item.rect and item.z == 906 then thumb = item end
    end
    return track, thumb
end

frame({keys = {esc = true}})
local total = #panel.rows()
local track, thumb = bar_rects()
check(track and thumb and thumb.h < track.h, 'scrollbar drawn for a long list')
local label = find('^1%-%d+ / ' .. total .. '$')
check(label, 'range label in header')
local shown = tonumber(label.text:match('^1%-(%d+)'))
check(shown < total, 'list longer than the panel: ' .. shown .. ' of ' .. total)
check(find('^mod01$') and not find('^mod40$'), 'first page visible')
-- Wheel scrolls three rows without jumping back to the cursor.
frame({at = {1920 - 300, 200}, wheel = -1}); frame()
check(panel.scroll == 3 and find('^4%-'), 'wheel down scrolls 3 rows')
frame({at = {1920 - 300, 200}, wheel = 1}); frame()
check(panel.scroll == 0, 'wheel up scrolls back')
-- Click on the track below the thumb pages down.
track, thumb = bar_rects()
frame({at = {track.x + 2, track.y + 5}, click = 'left'}); frame()
check(panel.scroll == shown - 1, 'track click pages down')
-- Drag the thumb to the bottom.
track, thumb = bar_rects()
frame({at = {thumb.x + 2, thumb.y + thumb.h - 2}, click = 'left', held = true})
check(panel.dragging, 'thumb grabbed')
frame({at = {thumb.x + 2, track.y - 500}, held = true})
frame({at = {thumb.x + 2, track.y - 500}, held = false}); frame()
check(panel.scroll == total - shown and not panel.dragging, 'drag to bottom reaches the end')
check(find('^mod40$') and find('Auto reload changed Lua files'), 'last rows visible')
-- Clicking a row after scrolling acts on that row.
local last = find('^mod40$')
frame({at = {last.x + 30, last.y + 4}, click = 'left'}); frame()
check(panel.page == 'mod' and panel.target.id == 'mod40', 'row click after scrolling opens the right mod')

print('PASS: MDL long-list scrolling (' .. checks .. ' checks)')
