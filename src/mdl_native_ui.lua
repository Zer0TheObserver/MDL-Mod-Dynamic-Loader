-- MDL: native-looking drawing for the MDL panel.
--
-- The game's body font, its normal material and glyph atlas are located at
-- runtime from the native font initializer, so no build-specific RVA is
-- compiled in. The signature below matched exactly once in every game.dll
-- dump from 2026-06-09 to 2026-09-26 and yields the same offsets Know Your
-- Constellation hard-codes for its build (font +0x262, atlas +0x26c, material
-- table rip-relative at +0x2e). Drawing follows the retained Stingray GUI path
-- proven in that mod.
local M = {}

M.SIGNATURE = '48 89 5C 24 08 48 89 6C 24 10 48 89 74 24 18 48 89 7C 24 20 41 54 41 56 41 57 '
    .. '0F 57 C0 8B C1 0F 57 C9 4C 8D 25 ?? ?? ?? ?? 33 DB 0F 11 05 ?? ?? ?? ?? '
    .. '48 8D 3C C5 00 00 00 00 33 C0 4E 8B 94 27'

local function parse_signature(text)
    local bytes = {}
    for token in text:gmatch('%S+') do
        bytes[#bytes + 1] = token == '??' and -1 or tonumber(token, 16)
    end
    return bytes
end

-- Pure scanner over a byte accessor, used by tests and by the FFI path.
function M.find_all(get, size, signature, limit)
    local pattern = parse_signature(signature)
    local first, count, hits = pattern[1], #pattern, {}
    for i = 0, size - count do
        if get(i) == first then
            local matched = true
            for j = 2, count do
                local want = pattern[j]
                if want >= 0 and get(i + j - 1) ~= want then matched = false break end
            end
            if matched then
                hits[#hits + 1] = i
                if limit and #hits >= limit then break end
            end
        end
    end
    return hits
end

-- Decodes the resource slots from a matched initializer at image offset `at`.
function M.decode(get, at)
    local function u32(offset)
        return get(offset) + get(offset + 1) * 256 + get(offset + 2) * 65536 + get(offset + 3) * 16777216
    end
    local function i32(offset)
        local value = u32(offset)
        if value >= 2147483648 then value = value - 4294967296 end
        return value
    end
    local function marker(offset) -- mov [r12+r8+imm32], rax
        return get(offset) == 0x4B and get(offset + 1) == 0x89 and get(offset + 2) == 0x84 and get(offset + 3) == 0x21
    end
    assert(at + 0x29 + i32(at + 0x25) == 0, 'initializer does not address the image base')
    assert(marker(at + 0x25e) and marker(at + 0x268), 'font table stores not found')
    local font, atlas = u32(at + 0x262), u32(at + 0x26c)
    assert(atlas > font and atlas - font < 0x2000, 'unexpected font/atlas layout')
    local material_table = at + 0x32 + i32(at + 0x2e)
    return {font = font, atlas = atlas, material = material_table + 8}
end

-- Resolves slot RVAs once per session from the loaded game.dll.
function M.resolve_slots(ffi, platform)
    local bit = package.loaded.bit or require('bit')
    local base = assert(platform.module('game.dll'), 'game.dll not loaded')
    local bytes = ffi.cast('const uint8_t *', base)
    local function u32(offset) return tonumber(ffi.cast('const uint32_t *', bytes + offset)[0]) end
    local function u16(offset) return tonumber(ffi.cast('const uint16_t *', bytes + offset)[0]) end
    local pe = u32(0x3c)
    assert(pe > 0 and pe < 4096 and u32(pe) == 0x4550, 'game.dll PE header unavailable')
    local image_size = u32(pe + 24 + 56)
    local sections = u16(pe + 6)
    local optional = u16(pe + 20)
    -- Scan the first executable section only.
    local text_start, text_size
    for i = 0, sections - 1 do
        local header = pe + 24 + optional + 40 * i
        if bit.band(u32(header + 36), 0x20000000) ~= 0 then
            text_size = u32(header + 8)
            text_start = u32(header + 12)
            break
        end
    end
    assert(text_start and text_size > 0 and text_start + text_size <= image_size, 'code section unavailable')
    local code = bytes + text_start
    local hits = M.find_all(function(i) return code[i] end, text_size, M.SIGNATURE, 2)
    assert(#hits == 1, 'font initializer signature matched ' .. #hits .. ' times')
    local slots = M.decode(function(i) return bytes[i] end, text_start + hits[1])
    slots.base, slots.initializer = base, text_start + hits[1]
    return slots
end

-- Reads the live resource hashes. Returns nil until the font system is ready.
function M.read_fonts(platform, slots)
    local function hash(bytes)
        if not bytes or #bytes ~= 8 then return nil end
        local lo = bytes:byte(1) + bytes:byte(2) * 256 + bytes:byte(3) * 65536 + bytes:byte(4) * 16777216
        local hi = bytes:byte(5) + bytes:byte(6) * 256 + bytes:byte(7) * 65536 + bytes:byte(8) * 16777216
        local value = string.format('%08x%08x', hi, lo)
        if value == '0000000000000000' then return nil end
        return value
    end
    local base = slots.base
    local font = hash(platform.mem_read(base + slots.font, 8))
    local atlas = hash(platform.mem_read(base + slots.atlas, 8))
    local pointer = platform.mem_read(base + slots.material, 8)
    if not (font and atlas and pointer) then return nil end
    local lo = pointer:byte(1) + pointer:byte(2) * 256 + pointer:byte(3) * 65536 + pointer:byte(4) * 16777216
    local hi = pointer:byte(5) + pointer:byte(6) * 256 + pointer:byte(7) * 65536 + pointer:byte(8) * 16777216
    if hi == 0 and lo < 0x10000 or hi >= 0x8000 then return nil end
    local material = hash(platform.mem_read(hi * 4294967296 + lo + 24, 8))
    if not material then return nil end
    return {font = font, atlas = atlas, material = material}
end

-- Retained GUI renderer. draw(list) redraws only when the list signature
-- changes; list items are {rect=true,x,y,w,h,z,color} or {text=,x,y,size,z,color}
-- in Stingray screen pixels (origin bottom-left).
function M.renderer(engine, fonts_provider)
    local self = {}
    local App, World, Gui = engine.Application, engine.World, engine.Gui
    local gui, world, signature, font_key
    local generation = 0   -- bumped whenever the GUI is destroyed (overlay ids die with it)
    local overlay_ids, overlay_slots, overlay_key, overlay_gui = {}, {}, nil, nil
    local unchanged = 0
    local function alive(list, wanted)
        for _, item in ipairs(list or {}) do if item == wanted then return true end end
        return false
    end
    local img_gui   -- second GUI for texture images, created after (above) the panel
    function self.clear()
        if gui and world then
            pcall(function() if alive(App.worlds(), world) then World.destroy_gui(world, gui) end end)
            if img_gui then pcall(function() if alive(App.worlds(), world) then World.destroy_gui(world, img_gui) end end) end
        end
        gui, world, signature, img_gui = nil, nil, nil, nil
        unchanged = 0
        generation = generation + 1
    end
    function self.resolution() return Gui.resolution() end
    local function target_world()
        local main, target = App.main_world(), nil
        for _, item in ipairs(App.worlds() or {}) do
            if item ~= main then target = item break end
        end
        return target or main
    end
    local function color(c) return engine.Color(c[1], c[2], c[3], c[4]) end
    local function slot(hash) return engine.IdString64.from_hex(hash .. '00000000') end
    local materials = {}
    local function material_id(hex)
        local id = materials[hex]
        if not id then id = engine.IdString64.from_hex(hex); materials[hex] = id end
        return id
    end

    function self.measure(text, size)
        if not gui or not self.font then return #text * size * 0.5 end
        local lo, hi = Gui.text_extents(gui, text, self.font, size)
        if not (lo and hi) then return #text * size * 0.5 end
        return engine.Vector2.x(hi) - engine.Vector2.x(lo)
    end

    -- Unchanged frames return at once; engine objects (fonts, world list) are
    -- re-validated only every 60 unchanged frames or on a new draw list.
    function self.draw(list, key)
        if gui and signature == key then
            unchanged = unchanged + 1
            if unchanged < 60 then return true end
        end
        unchanged = 0
        local fonts = fonts_provider()
        if not fonts then self.clear() return false, 'font not ready' end
        local target = target_world()
        if not target then self.clear() return false, 'no world' end
        local wanted_font = fonts.font .. '|' .. fonts.material .. '|' .. fonts.atlas
        if gui and (world ~= target or font_key ~= wanted_font or not alive(App.worlds(), world)) then
            self.clear()
        end
        if gui and signature == key then return true end
        self.clear()
        gui = assert(World.create_screen_gui(target, 'scale', 1, 1), 'create_screen_gui failed')
        world, font_key = target, wanted_font
        self.font = engine.IdString64.from_hex(fonts.font)
        local material = engine.IdString64.from_hex(fonts.material)
        -- Mirror the native normal-font material setup.
        local ink = assert(Gui.material(gui, material), 'font material unavailable')
        for _, hash in ipairs({'8035c266', '5e8455fe', '309e7783', '82b803a8'}) do
            engine.Material.set_scalar(ink, slot(hash), 0)
        end
        engine.Material.set_vector2(ink, slot('e13777ce'), engine.Vector2(1, -1))
        engine.Material.set_vector4(ink, slot('7701209e'), engine.Color(0, 0, 0, 0))
        engine.Material.set_texture(ink, slot('88bac99b'), engine.IdString64.from_hex(fonts.atlas))
        overlay_ids, overlay_slots, overlay_key, overlay_gui = {}, {}, nil, generation
        local images = {}
        for _, item in ipairs(list) do
            if item.slot then
                -- Placeholder for an animated rect at this point of the draw
                -- order (the GUI draws in creation order); moved by overlay().
                overlay_ids[item.slot] = Gui.rect(gui, engine.Vector3(0, 0, item.z or 901), engine.Vector2(0, 0), engine.Color(0, 0, 0, 0))
                overlay_slots[item.slot] = true
            elseif item.bitmap then
                images[#images + 1] = item
            elseif item.rect then
                Gui.rect(gui, engine.Vector3(item.x, item.y, item.z or 900),
                    engine.Vector2(item.w, item.h), color(item.color))
            elseif item.icon then
                -- Icon grid: rows run top to bottom; screen y grows upward.
                local grid, cell = item.icon, item.size / math.max(item.icon.w, item.icon.h)
                local ox = item.x + (item.size - grid.w * cell) / 2
                local oy = item.y + (item.size - grid.h * cell) / 2
                for _, run in ipairs(grid.runs) do
                    Gui.rect(gui, engine.Vector3(ox + run[1] * cell, oy + (grid.h - 1 - run[2]) * cell, item.z or 902),
                        engine.Vector2(run[3] * cell + 0.01, cell + 0.01), engine.Color(run[4], run[5], run[6], run[7]))
                end
            elseif item.text and item.text ~= '' then
                Gui.text(gui, item.text, self.font, item.size, material,
                    engine.Vector3(item.x, item.y, item.z or 902), color(item.color))
            end
        end
        -- Texture images go to a second GUI created after the panel's, so
        -- they draw above it (within one GUI they were hidden behind it).
        if #images > 0 and not self.bitmap_error then
            local made, value = pcall(World.create_screen_gui, target, 'scale', 1, 1)
            if made and value then img_gui = value else self.bitmap_error = 'image gui: ' .. tostring(value) end
        end
        for _, item in ipairs(img_gui and images or {}) do
            do
                -- A failure disables bitmaps; the panel then falls back to
                -- pixel glyphs on its next build.
                if not self.bitmap_error then
                    local uv = item.uv
                    local drawn, problem
                    if uv then
                        drawn, problem = pcall(Gui.bitmap_uv, img_gui, material_id(item.material),
                            engine.Vector2(uv[1], uv[2]), engine.Vector2(uv[3], uv[4]),
                            engine.Vector3(item.x, item.y, item.z or 902), engine.Vector2(item.w, item.h), color(item.color))
                    else
                        drawn, problem = pcall(Gui.bitmap, img_gui, material_id(item.material),
                            engine.Vector3(item.x, item.y, item.z or 902), engine.Vector2(item.w, item.h), color(item.color))
                    end
                    if not drawn then self.bitmap_error = tostring(problem) end
                end
            end
        end
        signature = key
        return true
    end

    -- Animated overlay rectangles (mdl_anim): created once per GUI with
    -- Gui.rect, then moved with Gui.update_rect; items that disappear are
    -- destroyed (slot rects are hidden instead). Does nothing while the key
    -- is unchanged.
    function self.overlay(items, key)
        if not gui then return false end
        if overlay_gui ~= generation then overlay_ids, overlay_slots, overlay_key, overlay_gui = {}, {}, nil, generation end
        if key == overlay_key then return true end
        overlay_key = key
        local seen = {}
        for _, item in ipairs(items) do
            seen[item.name] = true
            local pos, size, col = engine.Vector3(item.x, item.y, item.z or 920), engine.Vector2(item.w, item.h), color(item.color)
            local id = overlay_ids[item.name]
            if id then
                Gui.update_rect(gui, id, pos, size, col)
            else
                overlay_ids[item.name] = Gui.rect(gui, pos, size, col)
            end
        end
        for name, id in pairs(overlay_ids) do
            if not seen[name] then
                if overlay_slots[name] then
                    pcall(Gui.update_rect, gui, id, engine.Vector3(0, 0, 901), engine.Vector2(0, 0), engine.Color(0, 0, 0, 0))
                else
                    pcall(Gui.destroy_rect, gui, id)
                    overlay_ids[name] = nil
                end
            end
        end
        return true
    end
    return self
end

return M
