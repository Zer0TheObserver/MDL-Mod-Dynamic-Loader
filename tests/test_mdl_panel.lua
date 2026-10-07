-- MDL panel controller, icons and text helpers with fake input/renderer.
-- Usage: luajit tests/test_mdl_panel.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_manager, mdl_panel, mdl_image = module('mdl_manager'), module('mdl_panel'), module('mdl_image')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- Text helpers.
check(mdl_panel.columns('abc') == 3 and mdl_panel.columns('\228\184\173\230\150\135') == 4, 'CJK columns')
check(mdl_panel.short('abcdefghij', 6) == 'abc...', 'ascii truncation')
local cut = mdl_panel.short(string.rep('\228\184\173', 10), 9)
check(cut == '\228\184\173\228\184\173\228\184\173...', 'UTF-8 safe truncation: ' .. cut)
local lines = mdl_panel.wrap('one two three four five six seven', 10, 2)
check(#lines == 2 and lines[1] == 'one two' and lines[2]:sub(-3) == '...', 'wrap with ellipsis')

-- Icon runs.
local grid = mdl_image.runs(4, 2, function(x, y)
    if y == 0 then return x < 3 and 0xFFFF0000 or 0x00000000 end
    return x % 2 == 0 and 0xFF00FF00 or 0xFF0000FF
end)
check(#grid.runs == 5 and grid.runs[1][3] == 3 and grid.runs[1][5] == 252, 'run merge, transparency skip, quantization')

-- Manager with one loose mod and fake library/images.
local files = {}
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
local BASE = 'C:/TestData/MDL/Helldivers2'
files[BASE .. '/Mods/alpha/mod.lua'] = [[return {name = 'Alpha', options = {
    {key = 'on', label = 'On', type = 'toggle', default = false},
    {key = 'n', label = 'N', type = 'number', default = 1, min = 0, max = 2}}}]]
files[BASE .. '/Mods/alpha/icon.png'] = 'png'
local m = mdl_manager.new({base_dir = BASE, platform = platform, globals = setmetatable({}, {__index = _G})})
m.start()
m.register_boot('mods/x/some_addon', 'loaded')
m.register_boot('mods/x/absent', 'not installed')
check(m.by_id.alpha.icon == BASE .. '/Mods/alpha/icon.png', 'loose mod icon detected')
local library = {scanned = false, sources = {'Arsenal (Default Profile)'}, entries = {},
    describe_types = function() return 'unit 4' end}
function library.scan()
    library.scanned = true
    library.entries = {{name = 'Jet skin', category = 'RESOURCE', deployed = true, enabled = true, source = 'Arsenal',
        icon = 'C:/icons/jet.png', description = 'A model swap for testing.', options = {{name = 'Main', enabled = true}}},
        {name = 'MDL - Mod Dynamic Loader 1.4.0', category = 'SCRIPT', loader = 'MDL', deployed = true, enabled = true, source = 'Arsenal', options = {}},
        {name = 'Bingus Shared Loader - v18', category = 'SCRIPT', loader = 'BSL', deployed = true, enabled = true, source = 'Arsenal', options = {}}}
end
local requested = {}
local images = {get = function(path, size)
    requested[#requested + 1] = path .. '@' .. size
    return {id = 7, w = 2, h = 2, runs = {{0, 0, 2, 255, 1, 2, 3}}}
end, step = function() return false end}

local pressed, cursor, click = {}, nil, nil
local input = {
    pressed = function(...) for _, name in ipairs({...}) do if pressed[name] then return true end end return false end,
    cursor = function() if cursor then return cursor[1], cursor[2] end end,
    clicked = function(button) return click == button end,
    wheel = function() return 0 end,
}
local drawn, cleared = nil, 0
local renderer = {resolution = function() return 1920, 1080 end,
    draw = function(list) drawn = list return true end, clear = function() cleared = cleared + 1 end}
local panel = mdl_panel.new(m, input, renderer, {library = library, images = images, host = 'MDL'})
local function frame(keys, at, button)
    pressed, cursor, click = keys or {}, at, button
    panel.frame()
    m.frame(0.016)
end
local function find_text(value)
    for _, item in ipairs(drawn or {}) do if item.text == value then return item end end
end
frame()
check(not panel.visible and cleared == 0 and not library.scanned, 'hidden by default: no GUI work, library scanned lazily')
frame({esc = true})
check(panel.visible and library.scanned, 'ESC opens and scans library')
check(find_text('MOD DYNAMIC LOADER') and not find_text('MDL  MOD DYNAMIC LOADER') and find_text('LIVE LUA MODS') and find_text('SCRIPT ADDONS (LOADED AT LAUNCH)  (1)'), 'sections drawn; launch addons folded with their count')
check(not find_text('some addon') and panel.folded('addons'), 'launch addons folded by default')
-- Clicking the fold switch opens the section; the state is saved.
local fold
for _, f in ipairs(panel.geometry().folds) do if f.section == 'addons' then fold = f end end
check(fold, 'fold switch drawn')
frame({}, {fold.x + fold.w / 2, fold.y + fold.h / 2}, 'left'); frame()
check(not panel.folded('addons') and m.config.ui.collapsed and m.config.ui.collapsed.addons == false, 'opened and saved')
check(find_text('Jet skin') and find_text('RESOURCE  -  LAUNCH ONLY') and find_text('ON') and find_text('some addon'), 'library and addon rows')
-- Clicking a title without "?" folds it: the library hides its groups too.
local library_row
for i, r in ipairs(panel.rows()) do if r.fold == 'library' then library_row = i end end
local hit
for _, h in ipairs(panel.geometry().hits) do if h.index == library_row then hit = h end end
frame({}, {panel.geometry().x + 300, hit.y + hit.h / 2}, 'left'); frame()
check(panel.folded('library') and not find_text('Jet skin') and not find_text('RESOURCE  -  LAUNCH ONLY'), 'library folded with its groups')
panel.toggle_fold('library'); panel.toggle_fold('addons'); panel.toggle_fold('addons')
check(not panel.folded('library') and m.config.ui.collapsed.addons == false, 'toggle back')
frame()
check(not find_text('absent'), 'not-installed addons hidden')
check(not find_text('MDL - Mod Dynamic Loader 1.4.0') and not find_text('Bingus Shared Loader - v18'), 'MDL and BSL hidden from the library list')
check(find_text('174513429') and find_text('174513429').color == mdl_panel.COLORS.faint, 'author ID line in grey on main page')
check(not find_text('Show with ESC menu') and not find_text('F10'), 'no hotkey or ESC switch')
local wheel, id = find_text('Wheel scrolls. ON* = enabled in manager, not deployed.'), find_text('174513429')
check(wheel and id.y < wheel.y and id.x == wheel.x, 'ID sits on the line below the Wheel hint')
local icons = 0
for _, item in ipairs(drawn) do if item.icon then icons = icons + 1 end end
check(icons == 2, 'row icons drawn for loose and library mods')
frame({esc = true})
check(not panel.visible, 'second ESC closes')
frame({f10 = true})
check(not panel.visible, 'F10 no longer opens the panel')
-- Keyboard navigation (opt-in keyboard_in_menu): first selectable row is Alpha.
m.config.ui.keyboard_in_menu = true
frame({esc = true})
check(panel.visible, 'ESC reopens')
frame({enter = true})
check(panel.page == 'mod' and panel.target.id == 'alpha', 'enter opens mod page')
frame({down = true}); frame({enter = true}); frame()
check(m.by_id.alpha.status == 'enabled', 'state toggled through queue')
frame()
local list = panel.build(1920, 1080)
local on_row
for _, item in ipairs(list) do if item.text == 'On' then on_row = item end end
check(on_row, 'option row drawn')
frame(nil, {1920 - 80, on_row.y + 4}, 'left'); frame()
check(m.by_id.alpha.ctx.settings.on == true, 'mouse click toggles option')
frame({backspace = true})
check(panel.page == 'list', 'backspace returns')
-- Open the library entry by clicking its row.
list = panel.build(1920, 1080)
local jet
for _, item in ipairs(list) do if item.text == 'Jet skin' then jet = item end end
frame(nil, {jet.x + 20, jet.y + 4}, 'left')
check(panel.page == 'library' and panel.target.name == 'Jet skin', 'library detail page')
frame()
check(find_text('DEPLOYED') and find_text('RESOURCE') and find_text('Main'), 'library details')
local big = false
for _, item in ipairs(drawn) do if item.icon and item.size > 60 then big = true end end
check(big, 'large footer icon on detail page')
local seen56 = false
for _, r in ipairs(requested) do if r == 'C:/icons/jet.png@56' then seen56 = true end end
check(seen56, 'detail icon requested at 56 px')
check(find_text('Change in Arsenal + Deploy, then restart.'), 'model mods explained as launch-time')
-- Menu probe overrides the heuristic.
local probe_value = false
local probed = mdl_panel.new(m, input, renderer, {menu_probe = function() return probe_value end})
pressed = {esc = true}; probed.frame()
check(not probed.visible, 'probe false wins over ESC')
probe_value = true; pressed = {}; probed.frame()
check(probed.visible, 'probe true shows panel')
m.config.ui.follow_esc = false
local always = mdl_panel.new(m, input, renderer)
pressed = {esc = true}; always.frame()
check(always.visible, 'ESC always shows the panel (old follow_esc setting ignored)')

-- Debug build: the main title says so.
do
    local debug_panel = mdl_panel.new(m, input, renderer, {library = library, host = 'MDL', debug_build = true})
    check(debug_panel.title_for_test() == 'MOD DYNAMIC LOADER - DEBUG' and mdl_panel.new(m, input, renderer, {library = library, host = 'MDL'}).title_for_test() == 'MOD DYNAMIC LOADER', 'debug title')
end
print('PASS: MDL panel sections, library pages, icons, input and text helpers (' .. checks .. ' checks)')
