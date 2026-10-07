-- UI atlas, animations and MDL's own frame cost in the panel (1.8.0):
-- atlas cells (uv, flips, colour vs tinted mask, decorations, fallback when
-- bitmaps fail), animation overlay (selection glide, open cover, blink,
-- retained rect updates), self-cost row and footer.
-- Usage: luajit tests/test_mdl_ui_atlas.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local A, Anim, G, P, M, UI = module('mdl_atlas'), module('mdl_anim'), module('mdl_glyphs'), module('mdl_panel'), module('mdl_manager'),
    module('mdl_native_ui')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- 1. Generated atlas table.
check(A.size == 512 and #A.ICONS == 16 and A.MATERIAL:match('^%x+$') and #A.MATERIAL == 16, 'atlas header')
for _, name in ipairs(A.ICONS) do
    for _, key in ipairs({name, name .. '_mask'}) do
        local uv = A.cells[key]
        check(uv and uv[1] >= 0 and uv[3] <= 1 and uv[1] < uv[3] and uv[2] < uv[4], 'cell ' .. key)
    end
end
for _, key in ipairs({'paper', 'corner', 'rule', 'scan', 'grain', 'orient'}) do check(A.cells[key], 'decoration ' .. key) end

-- 2. Animation maths.
local anim = Anim.new()
local colours = function(name) return ({select_fill = {255, 1, 1, 1}, select_text = {255, 2, 2, 2}, hover = {70, 3, 3, 3},
    select = {255, 4, 4, 4}, back = {214, 5, 5, 5}, yellow = {255, 6, 6, 6}})[name] end
local g = {panel = {x = 0, y = 0, w = 600, h = 400}, sel = {x = 3, y = 300, w = 594, h = 34, page = 1, s = 1}}
anim.open(10)
local items, key, busy = anim.items(g, 10, colours)
local by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.open_cover and math.abs(by.open_cover.h - 400) < 1e-6 and busy, 'open: fully covered at start')
items, key, busy = anim.items(g, 10 + Anim.OPEN / 2, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.open_cover.h < 400 and by.open_cover.h > 0 and by.open_edge, 'open: cover shrinking, edge line')
items, key, busy = anim.items(g, 10 + Anim.OPEN + 0.01, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(not by.open_cover and by.sel_fill and by.sel_fill.y == 300 and not busy, 'open done; selection at its row; idle')
local idle_key = key
check(select(2, anim.items(g, 20, colours)) == idle_key, 'idle: key stable (no GUI work)')
g.sel = {x = 3, y = 266, w = 594, h = 34, page = 1, s = 1}
items, key, busy = anim.items(g, 30, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.sel_fill.y == 300 and busy, 'glide starts at the old row')
items = anim.items(g, 30 + Anim.GLIDE / 2, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.sel_fill.y < 300 and by.sel_fill.y > 266, 'glide in between: ' .. by.sel_fill.y)
items, key, busy = anim.items(g, 30 + Anim.GLIDE + 0.01, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.sel_fill.y == 266 and not busy, 'glide arrives')
g.sel = {x = 3, y = 100, w = 594, h = 34, page = 2, s = 1}
items = anim.items(g, 40, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.sel_fill.y == 100, 'new page: no glide (snap)')
g.sel.inverted = true
items = anim.items(g, 41, colours)
by = {}
for _, it in ipairs(items) do by[it.name] = it end
check(by.sel_fill.color[2] == 1 and by.sel_mark.color[2] == 2, 'inverted selection colours')
g.title_end = {x = 100, y = 360, h = 20}
local k1 = select(2, anim.items(g, 0.1, colours, {blink = true}))
local k2 = select(2, anim.items(g, 0.1 + Anim.BLINK, colours, {blink = true}))
check(k1 ~= k2, 'blink toggles the key')

-- 3. Renderer overlay: rect once, update_rect after, destroy when gone, reset with the GUI.
do
    local calls = {}
    local id = 0
    local engine = {IdString64 = {from_hex = function(h) return h end},
        Vector3 = function(x, y, z) return {x, y, z} end, Vector2 = function(x, y) return {x, y} end,
        Color = function(a, r, gg, b) return {a, r, gg, b} end,
        Material = {set_scalar = function() end, set_vector2 = function() end, set_vector4 = function() end, set_texture = function() end},
        Application = {main_world = function() return 'w' end, worlds = function() return {'w'} end},
        World = {create_screen_gui = function() return {} end, destroy_gui = function() calls[#calls + 1] = 'destroy_gui' end},
        Gui = {resolution = function() return 1920, 1080 end, material = function() return {} end,
            rect = function() id = id + 1; calls[#calls + 1] = 'rect'; return id end,
            update_rect = function(_, i, pos) calls[#calls + 1] = 'update ' .. i .. ' ' .. pos[2] end,
            destroy_rect = function(_, i) calls[#calls + 1] = 'destroy ' .. i end,
            text = function() end,
            bitmap_uv = function(_, material, uv00, uv11) calls[#calls + 1] = 'bitmap ' .. material .. ' ' .. uv00[2] .. ' ' .. uv11[2] end}}
    local r = UI.renderer(engine, function() return {font = 'f', material = 'm', atlas = 'a'} end)
    check(r.draw({{bitmap = true, material = A.MATERIAL, uv = {0, 0.1, 0.5, 0.6}, x = 0, y = 0, w = 10, h = 10, color = {255, 255, 255, 255}}}, 'k1'),
        'draw with a bitmap item')
    check(table.concat(calls, '|'):find('bitmap ' .. A.MATERIAL .. ' 0.1 0.6', 1, true), 'bitmap_uv called with the cell uv')
    calls = {}
    r.overlay({{name = 'a', rect = true, x = 0, y = 5, w = 1, h = 1, color = {1, 1, 1, 1}}}, 'o1')
    r.overlay({{name = 'a', rect = true, x = 0, y = 6, w = 1, h = 1, color = {1, 1, 1, 1}}}, 'o2')
    r.overlay({{name = 'a', rect = true, x = 0, y = 6, w = 1, h = 1, color = {1, 1, 1, 1}}}, 'o2')
    r.overlay({}, 'o3')
    local text = table.concat(calls, '|')
    check(text == 'rect|update 1 6|destroy 1', 'overlay: create, update, skip same key, destroy: ' .. text)
    r.draw({}, 'k2')
    calls = {}
    r.overlay({{name = 'a', rect = true, x = 0, y = 7, w = 1, h = 1, color = {1, 1, 1, 1}}}, 'o4')
    check(table.concat(calls, '|') == 'rect', 'new GUI: overlay rects recreated')
    engine.Gui.bitmap_uv = function() error('no bitmap') end
    r.draw({{bitmap = true, material = 'x', uv = {0, 0, 1, 1}, x = 0, y = 0, w = 1, h = 1, color = {1, 1, 1, 1}}}, 'k3')
    check(r.bitmap_error and r.bitmap_error:find('no bitmap'), 'bitmap failure recorded')
end

-- 4. Panel with the atlas, animations and the self-cost row.
local fs = {mkdir = function() return true end, read = function() return nil end, read_head = function() return nil end,
    write = function() return true end, list = function() return {} end}
local m = M.new({base_dir = 'C:/T', platform = fs, globals = _G})
m.start()
local entries = {{id = 'a', name = 'Armor', category = 'RESOURCE', source = 'Arsenal', options = {}, types = {}, enabled = false, file = 'Armor_v1'}}
local library = {scanned = true, sources = {'Arsenal'}, entries = entries, scan = function() end, describe_types = function() return '' end}
local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
    held = function() return false end, wheel = function() return 0 end}
local overlays = {}
local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end,
    overlay = function(items, key) overlays[#overlays + 1] = {items = items, key = key} return true end}
local usable = true
local clock = 0
local cost = {idle = 0.012, open = 0.35, peak = 1.5}
local panel = P.new(m, input, renderer, {library = library, glyphs = G, menu_probe = function() return true end,
    atlas = {cells = A.cells, pieces = A.pieces, material = A.MATERIAL, icons = A.ICONS, usable = function() return usable end},
    anim = Anim.new(), animations_default = true, clock = function() return clock end, self_cost = function() return cost end})

local by_material = {}
for name, piece in pairs(A.pieces) do by_material[piece.material] = name end
local function bitmaps(list)
    local out = {}
    for _, item in ipairs(list) do
        if item.bitmap and not item.uv then
            out[#out + 1] = assert(by_material[item.material], 'unknown piece material')
        elseif item.bitmap then
            for name, uv in pairs(A.cells) do
                if (uv[1] == item.uv[1] or uv[1] == item.uv[3]) and (uv[2] == item.uv[2] or uv[2] == item.uv[4]) then out[#out + 1] = name end
            end
        end
    end
    table.sort(out)
    return table.concat(out, ',')
end
-- Default: pixel glyphs (texture icons are a debug experiment), with a pixel logo.
local list = panel.build(1920, 1080)
local glyph_items, bitmap_items = 0, 0
for _, item in ipairs(list) do
    if item.icon then glyph_items = glyph_items + 1 end
    if item.bitmap then bitmap_items = bitmap_items + 1 end
end
check(glyph_items > 3 and bitmap_items == 0, 'default: pixel glyphs only')
local logo_glyph = false
for _, item in ipairs(list) do if item.icon and item.icon.id:find('^logo:') then logo_glyph = true end end
check(logo_glyph, 'pixel logo before the title')
local slots = {}
for _, item in ipairs(list) do if item.slot then slots[#slots + 1] = item.slot end end
check(table.concat(slots, ',') == 'sel_fill,sel_mark', 'selection slots in the draw order')
m.config.ui.texture_icons = true
list = panel.build(1920, 1080)
local names = bitmaps(list)
check(names:find('logo', 1, true) and names:find('resource', 1, true) and names:find('refresh', 1, true), 'hd2: logo and colour icons from the atlas: ' .. names)
check(not names:find('paper', 1, true), 'hd2: no archive decorations')
local static_sel = false
for _, item in ipairs(list) do if item.rect and item.z == 901 and item.color[1] == 70 then static_sel = true end end
check(not static_sel, 'animated: no static selection rect')
local rows_text = {}
for _, row in ipairs(panel.rows()) do rows_text[#rows_text + 1] = tostring(row.label) .. '=' .. tostring(row.value) end
rows_text = table.concat(rows_text, '|')
check(rows_text:find('Animations=ON', 1, true), 'animations row, on by default here')
check(rows_text:find('MDL frame cost (closed / open / peak)=0.012 / 0.350 / 1.50 ms', 1, true), 'self cost row: ' .. rows_text)

-- Frame: overlay with the selection; the footer carries MDL's cost.
panel.frame()
check(#overlays >= 1, 'overlay sent')
local last = overlays[#overlays]
local sel_found, cover = false, false
for _, it in ipairs(last.items) do
    if it.name == 'sel_fill' then sel_found = true end
    if it.name == 'open_cover' then cover = true end
end
check(sel_found and cover, 'overlay: selection and opening cover')
for _ = 1, 3 do clock = clock + 0.2; panel.frame() end
local before = #overlays
local idle_key = overlays[#overlays].key
clock = clock + 0.1; panel.frame()
check(overlays[#overlays].key == idle_key, 'idle frames keep the same overlay key')
local footer = false
for _, item in ipairs(panel.build(1920, 1080)) do if item.text and item.text:find('MDL 0.35 ms', 1, true) then footer = true end end
check(footer and before > 0, 'footer shows MDL cost')

-- Archive theme: tinted masks and decorations; flips mirror the corners.
m.config.ui.theme = 'archive'
list = panel.build(1920, 1080)
names = bitmaps(list)
check(not names:find('paper', 1, true) and names:find('corner', 1, true) and names:find('rule', 1, true), 'archive decorations (no paper under text): ' .. names)
check(names:find('logo_mask', 1, true) and not names:find('resource,', 1, true), 'archive: tinted masks')
check(names:find('corner_tr', 1, true) and names:find('corner_bl', 1, true) and names:find('corner_br', 1, true),
    'cells mode: pre-mirrored corner images')
check(not table.concat({names}):find('uv', 1, true), 'cells mode')
for _, item in ipairs(list) do if item.bitmap then check(item.uv == nil, 'cells mode: Gui.bitmap items (no uv)') break end end
-- uv mode (debug): atlas cells, mirrored corners by uv swap, Flip V.
m.config.ui.atlas_mode = 'uv'
list = panel.build(1920, 1080)
local corners = {}
for _, item in ipairs(list) do
    if item.bitmap and item.uv[3] < item.uv[1] then corners.flip_x = true end
    if item.bitmap and item.uv[4] < item.uv[2] then corners.flip_y = true end
end
check(corners.flip_x and corners.flip_y, 'uv mode: mirrored corners')
m.config.ui.atlas_flip_v = true
list = panel.build(1920, 1080)
local flipped = 0
for _, item in ipairs(list) do if item.bitmap and item.uv[4] < item.uv[2] then flipped = flipped + 1 end end
check(flipped > 3, 'atlas_flip_v flips every cell')
m.config.ui.atlas_flip_v = nil
m.config.ui.atlas_mode = nil

-- Fallbacks: material not loaded, or bitmaps rejected by the renderer.
usable = false
list = panel.build(1920, 1080)
local grids = 0
for _, item in ipairs(list) do if item.icon then grids = grids + 1 end end
check(bitmaps(list) == '' and grids > 0, 'no atlas: pixel glyphs')
usable = true
renderer.bitmap_error = 'boom'
list = panel.build(1920, 1080)
check(bitmaps(list) == '', 'bitmap failure: pixel glyphs')
renderer.bitmap_error = nil

-- Animations off: static selection again.
m.config.ui.animations = false
m.config.ui.theme = nil
list = panel.build(1920, 1080)
static_sel = false
for _, item in ipairs(list) do if item.rect and item.z == 901 and item.color[1] == 70 then static_sel = true end end
check(static_sel, 'animations off: static selection')

-- Frame cost page: opened from the settings row, one line per part.
cost.parts = {manager = {avg = 0.02, peak = 0.3}, panel = {avg = 0.15, peak = 1.2}, lab = {avg = 0.2, peak = 9}}
panel.page = 'list'
for _, row in ipairs(panel.rows()) do if row.label == 'MDL frame cost (closed / open / peak)' then row.open() end end
check(panel.page == 'cost', 'cost row opens the details page')
local detail = {}
for _, row in ipairs(panel.rows()) do detail[#detail + 1] = tostring(row.label or row.header) .. '=' .. tostring(row.value) end
detail = table.concat(detail, '|')
check(detail:find('Loader core=0.020 / 0.30 ms', 1, true) and detail:find('Live resource mods=0.200 / 9.00 ms', 1, true)
    and not detail:find('Logs=', 1, true), 'parts listed (only measured ones): ' .. detail)
panel.page = 'list'

print('PASS: MDL UI atlas, animations, self cost (' .. checks .. ' checks)')
