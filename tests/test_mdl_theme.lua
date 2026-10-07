-- Themes and built-in glyphs: glyph masks, run conversion, the Theme row,
-- archive colours / inverted selection / rules / bullets, glyph fallback for
-- mods without an icon, and the "?" tile when the glyph module is absent.
-- Usage: luajit tests/test_mdl_theme.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local G, panel_module, manager_module = module('mdl_glyphs'), module('mdl_panel'), module('mdl_manager')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- 1. Glyph masks are 12x12 and runs cover exactly the filled cells.
local names = 0
for name, mask in pairs(G.MASKS) do
    names = names + 1
    check(#mask == 12, name .. ' has 12 rows')
    local filled = 0
    for _, row in ipairs(mask) do
        check(#row == 12 and not row:find('[^#%.]'), name .. ' row is 12 cells of # and .')
        for _ in row:gmatch('#') do filled = filled + 1 end
    end
    local grid = G.grid(name, {255, 1, 2, 3})
    local covered = 0
    for _, run in ipairs(grid.runs) do
        covered = covered + run[3]
        check(run[4] == 255 and run[5] == 1 and run[7] == 3, name .. ' run colour')
        check(mask[run[2] + 1]:sub(run[1] + 1, run[1] + run[3]) == string.rep('#', run[3]), name .. ' run matches mask')
    end
    check(covered == filled and filled > 0 and grid.w == 12 and grid.h == 12, name .. ' runs cover the mask')
end
check(names >= 12, 'glyph set')
check(G.grid('square', {255, 1, 2, 3}) == G.grid('square', {255, 1, 2, 3}), 'grids cached')
check(G.grid('square', {255, 1, 2, 3}).id ~= G.grid('square', {255, 9, 2, 3}).id, 'cache keyed by colour')
check(G.grid('nope', {255, 0, 0, 0}) == nil, 'unknown glyph')

-- 2. Panel.
local saved = 0
local fs = {mkdir = function() return true end, read = function() return nil end, read_head = function() return nil end,
    write = function() saved = saved + 1 return true end, list = function() return {} end}
local m = manager_module.new({base_dir = 'C:/T', platform = fs, globals = _G})
m.start()
local entries = {{id = 'a', name = 'Armor', category = 'RESOURCE', source = 'Arsenal', options = {}, types = {}, enabled = false},
    {id = 'b', name = 'Tool', category = 'MIXED', source = 'Arsenal', options = {}, types = {}, enabled = false}}
local library = {scanned = true, sources = {'Arsenal'}, entries = entries, scan = function() end, describe_types = function() return '' end}
local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
    held = function() return false end, wheel = function() return 0 end}
local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}

local function make(glyphs)
    return panel_module.new(m, input, renderer, {library = library, glyphs = glyphs, menu_probe = function() return true end})
end
local function same(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4] end
local function find_row(panel, label)
    for i, row in ipairs(panel.rows()) do if row.label == label then return i, row end end
end

local panel = make(G)
local at, theme_row = find_row(panel, 'Theme')
check(theme_row and theme_row.value == 'Helldivers' and theme_row.glyph == 'palette', 'Theme row, default Helldivers')
local list = panel.build(1920, 1080)
local A = panel_module.THEMES.archive.colors
local function has_color(items, color, kind)
    for _, item in ipairs(items) do
        if (kind == nil or item[kind]) and item.color and same(item.color, color) then return true end
    end
end
check(has_color(list, panel_module.COLORS.back, 'rect') and not has_color(list, A.back, 'rect'), 'default theme draws the Helldivers colours')
local icons = 0
for _, item in ipairs(list) do if item.icon and item.icon.id and item.icon.id:find('^resource:') then icons = icons + 1 end end
check(icons == 1, 'resource mod without an icon gets the resource glyph (' .. icons .. ')')
local glyph_ids = {}
for _, item in ipairs(list) do if item.icon and item.icon.id then glyph_ids[item.icon.id:match('^(%w+):')] = true end end
check(glyph_ids.mixed and glyph_ids.refresh and glyph_ids.palette and glyph_ids.globe == nil, 'settings and type glyphs drawn')

-- Switch theme with the row (and back with adjust -1).
theme_row.open()
local before = saved
m.flush()
check(m.config.ui.theme == 'archive' and saved > before, 'theme saved in the config')
at, theme_row = find_row(panel, 'Theme')
check(theme_row.value == 'Archive', 'row shows Archive')
panel.cursor = at
local archived = panel.build(1920, 1080)
check(has_color(archived, A.back, 'rect') and not has_color(archived, panel_module.COLORS.back, 'rect'), 'archive colours')
check(has_color(archived, A.select_fill, 'rect') and has_color(archived, A.select_text, 'text'), 'inverted selection')
check(has_color(archived, A.rule, 'rect'), 'ruled lines')
local square_bullets = 0
for _, item in ipairs(archived) do
    if item.rect and same(item.color, A.yellow) and math.abs(item.w - item.h) < 0.01 and item.w < 20 then square_bullets = square_bullets + 1 end
end
check(square_bullets >= 2, 'square bullets on title and headers (' .. square_bullets .. ')')
local ok_key = select(2, panel.build(1920, 1080))
theme_row.adjust(-1)
check(m.config.ui.theme == 'hd2', 'adjust cycles back')
check(select(2, panel.build(1920, 1080)) ~= ok_key, 'theme change changes the draw key (rebuild)')
m.config.ui.theme = 'no-such-theme'
check(find_row(panel, 'Theme') and select(2, find_row(panel, 'Theme')).value == 'Helldivers', 'unknown theme falls back')
check(has_color(panel.build(1920, 1080), panel_module.COLORS.back, 'rect'), 'unknown theme draws Helldivers')

-- 3. Without the glyph module: "?" tiles, no glyph items.
m.config.ui.theme = nil
local plain = make(nil)
local question, glyph_items = 0, 0
for _, item in ipairs(plain.build(1920, 1080)) do
    if item.text == '?' then question = question + 1 end
    if item.icon then glyph_items = glyph_items + 1 end
end
check(question >= 3 and glyph_items == 0, '"?" fallback without glyphs')

print('PASS: MDL themes and glyphs (' .. checks .. ' checks)')
