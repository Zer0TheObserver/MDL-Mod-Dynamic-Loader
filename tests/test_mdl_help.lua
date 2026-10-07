-- "?" help page and the empty-folder hints.
-- Usage: luajit tests/test_mdl_help.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_manager, mdl_panel = module('mdl_manager'), module('mdl_panel')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

local files = {}
local platform = {mkdir = function() return true end, read = function(p) return files[p] end,
    read_head = function() return nil end, write = function(p, d) files[p] = d return true end, list = function() return {} end}
local m = mdl_manager.new({base_dir = 'C:/T', platform = platform, globals = setmetatable({}, {__index = _G})})
m.start()
local state = {}
local input = {pressed = function(...) for _, n in ipairs({...}) do if state.pressed[n] then return true end end return false end,
    cursor = function() if state.at then return state.at[1], state.at[2] end end,
    clicked = function(b) return state.click == b end, held = function() return false end, wheel = function() return 0 end}
local drawn
local renderer = {resolution = function() return 1920, 1080 end, draw = function(list) drawn = list return true end, clear = function() end}
local panel = mdl_panel.new(m, input, renderer)
local function frame(keys, at, click) state.pressed, state.at, state.click = keys or {}, at, click; panel.frame() end
local function find(text) for _, item in ipairs(drawn or {}) do if item.text == text then return item end end end
local function starts(prefix) for _, item in ipairs(drawn or {}) do if item.text and item.text:sub(1, #prefix) == prefix then return item end end end

frame({esc = true})
check(starts('Put mods in') and find('...or the Arsenal library (script addons, below)'), 'folder hint plus Arsenal line')
local q = find('?')
check(q and q.color == mdl_panel.COLORS.yellow, 'help button drawn in the header')
frame(nil, {q.x + 2, q.y + 2}, 'left'); frame()
check(panel.page == 'help' and find('HELP'), 'help page opens')
for _, word in ipairs({'SCRIPT', 'RESOURCE', 'MIXED', 'MOD TYPES', 'LAUNCH ONLY'}) do
    check(find(word), 'first help page shows ' .. word)
end
local labels = {}
for _, row in ipairs(panel.rows()) do labels[row.label or row.header] = true end
for _, word in ipairs({'STATES', 'ON', 'ON*', 'OFF', 'LIVE ON', 'AT LAUNCH', 'IDLE', 'ERROR', 'ARSENAL DEPLOY', 'What Deploy does', 'Resource mods', 'Script addons'}) do
    check(labels[word], 'help covers ' .. word)
end
check(starts('   Lua code only.'), 'wrapped explanation lines')
check(find('174513429'), 'author ID on help page')
-- Help is longer than the panel: scrollbar and the deploy section further down.
check(starts('1-'), 'help list scrolls')
local wheel_input = input.wheel
input.wheel = function() return -1 end
for _ = 1, 12 do frame(nil, {1920 - 300, 300}) end
input.wheel = wheel_input
frame()
check(find('ARSENAL DEPLOY') and starts('   Arsenal copies the enabled mods'), 'deploy explanation reachable by scrolling')
-- Clicking explanation text does nothing (no flash).
local line = starts('   Arsenal copies')
frame(nil, {line.x + 20, line.y + 4}, 'left'); frame()
check(not panel.flash_text, 'help text is quiet')
-- ? again returns to the list.
q = find('?')
frame(nil, {q.x + 2, q.y + 2}, 'left'); frame()
check(panel.page == 'list' and find('MOD DYNAMIC LOADER'), '? toggles back to the list')
-- Every help row fits without truncation.
frame(nil, {q.x + 2, q.y + 2}, 'left'); frame()
for _, item in ipairs(drawn) do
    if item.text then check(not item.text:find('%.%.%.$') or item.text == '...', 'no truncated help text: ' .. item.text) end
end
print('PASS: MDL help page and hints (' .. checks .. ' checks)')
