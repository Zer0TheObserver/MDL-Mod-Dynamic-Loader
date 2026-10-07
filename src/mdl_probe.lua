-- MDL texture probe (debug builds only). Answers one question in game: can
-- a Lua mod show its own picture through a MIX texture, i.e. does
-- Gui.bitmap draw a material and does Material.set_texture swap in a texture
-- shipped by a mod package? The probe texture comes from the separate
-- "MDL Texture Probe" package (mdl/textures/probe: 256x256 R8G8B8A8, plus a
-- material of the same name cloned from the performance HUD gui material).
--
-- Each variant draws into its own screen gui (one material instance per
-- gui), so a set_texture on one never leaks into another:
--   A   core/performance_hud/gui as is               (white: this material has no texture table)
--   E   font material, atlas slot 88bac99b -> probe  (1.7.3: probe shown, monochrome)
--   F   core/performance_hud/debug as is             (has a texture table, slot 3aa8b87e)
--   G   mdl/textures/probe2: debug layout -> probe   (probe package 1.1.0)
--   H   debug material, set_texture 3aa8b87e -> probe
--   D   mdl/textures/probe: perf_hud/gui layout      (1.7.3: white)
-- Dropped: A2/B (set_texture on perf_hud/gui crashed the game), C.
--
-- Crash safe (1.7.2; 1.7.3 draws before Gui.material): variants run one at a time, each in its own frame.
-- Before a variant runs, "<key>=running" is written to the state file and
-- the MDL log is flushed; it is marked survived only after it has been on
-- screen for SETTLE frames. A variant still "running" at the next start
-- crashed the game: it is marked CRASHED and never run again (delete the
-- state file to retry). Variants that need the probe texture are skipped
-- unless the engine reports it loaded.
local P = {}

P.PROBE = 'e82c57bcec17b92f'        -- murmur64('mdl/textures/probe')
P.PERF_HUD = '495bf47a4c60ca4d'     -- murmur64('core/performance_hud/gui')
P.PERF_DEBUG = 'ccf39a02b444fa01'   -- murmur64('core/performance_hud/debug')
P.PROBE2 = '494775f495ebf195'       -- murmur64('mdl/textures/probe2'), probe package 1.1.0
P.SETTLE = 90                       -- frames on screen before a variant counts as survived
-- 1.7.4 run (results so far: A white; A2/B crashed in set_texture on
-- perf_hud/gui, whose material has no texture table; D white for the same
-- reason; E showed the probe through the font shader, monochrome):
-- 1.8.1 run: why MDL's UI images (1.8.0: atlas + Gui.bitmap_uv) drew
-- nothing in the panel. G is the proven reference.
P.VARIANTS = {
    {key = 'G', label = 'G probe2 (ref)', material = 'probe2', needs = 'material2'},
    {key = 'U1', label = 'U1 atlas bitmap', material = 'atlas', needs = 'atlas'},
    {key = 'U2', label = 'U2 atlas uv 0-1', material = 'atlas', needs = 'atlas', uv = {0, 0, 1, 1}},
    {key = 'U3', label = 'U3 atlas uv logo', material = 'atlas', needs = 'atlas', cell = 'logo'},
    {key = 'P1', label = 'P1 piece logo', material = 'piece', piece = 'logo', needs = 'piece'},
    {key = 'P2', label = 'P2 logo 28px', material = 'piece', piece = 'logo', needs = 'piece', scale = 0.2},
    {key = 'P3', label = 'P3 mask tinted', material = 'piece', piece = 'logo_mask', needs = 'piece', tint = {255, 240, 96, 80}},
}

-- Pure layout: square positions for a screen size (origin bottom-left).
function P.layout(width, height)
    local s = math.max(0.5, math.min(width / 1920, height / 1080))
    local size, gap = math.floor(140 * s), math.floor(22 * s)
    local x0, y0 = math.floor(40 * s), math.floor(height - 230 * s - size)
    local boxes = {}
    for i = 1, #P.VARIANTS do
        boxes[i] = {x = x0 + (i - 1) * (size + gap), y = y0, size = size}
    end
    return {s = s, size = size, boxes = boxes, label = math.floor(16 * s),
        panel = {x = x0 - 12 * s, y = y0 - 70 * s, w = #P.VARIANTS * (size + gap) - gap + 24 * s, h = size + 120 * s}}
end

-- State file: one "key=value" per line.
function P.parse_state(text)
    local state = {}
    for line in tostring(text or ''):gmatch('[^\r\n]+') do
        local key, value = line:match('^([%w]+)=(.*)$')
        if key then state[key] = value end
    end
    return state
end
function P.encode_state(state)
    local lines = {}
    for _, variant in ipairs(P.VARIANTS) do
        if state[variant.key] then lines[#lines + 1] = variant.key .. '=' .. state[variant.key] end
    end
    return table.concat(lines, '\n') .. '\n'
end

-- options = {engine=, fonts=function() -> {font=,material=,atlas=}, log=,
--            flush=function() (synchronous log write), platform=, state_path=}
function P.new(options)
    local engine = options.engine
    local App, World, Gui = engine.Application, engine.World, engine.Gui
    local log = options.log or function() end
    local flush = options.flush or function() end
    local platform, state_path = options.platform, options.state_path
    local atlas = options.atlas   -- mdl_atlas (UI images), for the U/P variants
    local self = {results = {}, loaded = {}}
    local guis, world, built_for = {}, nil, nil
    local ran, in_flight, dirty, geometry, checked = {}, nil, true, nil, false

    -- Crash bookkeeping across starts.
    local state = {}
    if platform and state_path then
        local ok, text = pcall(platform.read, state_path)
        state = P.parse_state(ok and text or '')
    end
    local function save()
        if platform and state_path then pcall(platform.write, state_path, P.encode_state(state)) end
    end
    local crashed = {}
    for key, value in pairs(state) do
        if value == 'running' then
            state[key] = 'crashed'
            log('texture probe ' .. key .. ': CRASHED the game last time (it was still running); it will not run again')
        end
        if state[key] == 'crashed' then crashed[key] = true end
    end
    save()
    self.state = state

    local function id(hex) return engine.IdString64.from_hex(hex) end
    local function slot(hash) return engine.IdString64.from_hex(hash .. '00000000') end
    local function short(value) return (tostring(value):gsub('%s+', ' '):sub(1, 60)) end

    -- can_get(type id, name id) as the Resource Lab uses it (proven in game),
    -- then with plain strings; nil when neither form answers.
    local TYPES = {texture = 'cd4238c6a0c69e32', material = 'eac0b497876adedf'}
    local function can_get(kind, name, hex)
        if not App or type(App.can_get) ~= 'function' then return nil, 'Application.can_get missing' end
        local ok, value = pcall(App.can_get, id(TYPES[kind]), id(hex))
        if ok and value ~= nil then return value == true, 'by id' end
        local ok2, value2 = pcall(App.can_get, kind, name)
        if ok2 and value2 ~= nil then return value2 == true, 'by name' end
        return nil, short(ok and 'nil' or value) .. ' / ' .. short(ok2 and 'nil' or value2)
    end

    local function target_world()
        local main, target = App.main_world(), nil
        for _, item in ipairs(App.worlds() or {}) do
            if item ~= main then target = item break end
        end
        return target or main
    end
    local function alive(wanted)
        for _, item in ipairs(App.worlds() or {}) do if item == wanted then return true end end
        return false
    end

    function self.clear()
        if world and alive(world) then
            for _, gui in pairs(guis) do pcall(World.destroy_gui, world, gui) end
        end
        -- A variant taken off screen before it settled is run again next time.
        if in_flight and state[in_flight.key] == 'running' then
            state[in_flight.key] = nil
            save()
        end
        guis, world, built_for, in_flight, ran, dirty = {}, nil, nil, nil, {}, true
    end
    function self.active() return built_for ~= nil end

    local function material_of(variant, fonts)
        if variant.material == 'perf' then return 'core/performance_hud/gui', id(P.PERF_HUD) end
        if variant.material == 'probe' then return 'mdl/textures/probe', id(P.PROBE) end
        if variant.material == 'debug' then return 'core/performance_hud/debug', id(P.PERF_DEBUG) end
        if variant.material == 'probe2' then return 'mdl/textures/probe2', id(P.PROBE2) end
        if variant.material == 'atlas' then return nil, atlas and atlas.MATERIAL and id(atlas.MATERIAL) or nil end
        if variant.material == 'piece' then
            local piece = atlas and atlas.pieces and atlas.pieces[variant.piece]
            return nil, piece and id(piece.material) or nil
        end
        return nil, fonts and id(fonts.material) or nil
    end

    -- Order matters: a gui knows a material only after something was drawn
    -- with it. 1.7.2 called Gui.material first and the game crashed inside
    -- that call (A2, game data only), so the bitmap is drawn first and the
    -- texture is set on the instance it created. Each step is logged and
    -- flushed before it runs, so a crash names the step.
    local function run(variant, gui, fonts, box)
        local name, hashed = material_of(variant, fonts)
        if not hashed then return 'skipped: font not ready' end
        local function step(text) log('texture probe ' .. variant.key .. ': ' .. text) flush() end
        local edge = box.size * (variant.scale or 1)
        local pos, size = engine.Vector3(box.x, box.y, 950), engine.Vector2(edge, edge)
        local white = variant.tint and engine.Color(variant.tint[1], variant.tint[2], variant.tint[3], variant.tint[4])
            or engine.Color(255, 255, 255, 255)
        local uv = variant.uv or (variant.cell and atlas and atlas.cells and atlas.cells[variant.cell])
        if uv then
            step('Gui.bitmap_uv ' .. string.format('%.3f,%.3f-%.3f,%.3f', uv[1], uv[2], uv[3], uv[4]))
            local ok, err = pcall(Gui.bitmap_uv, gui, hashed, engine.Vector2(uv[1], uv[2]), engine.Vector2(uv[3], uv[4]), pos, size, white)
            return ok and 'ok: bitmap_uv' or ('bitmap_uv failed: ' .. short(err))
        end
        local drawn, first_error, how
        for _, material in ipairs(name and {name, hashed} or {hashed}) do
            how = type(material) == 'string' and 'name' or 'id'
            step('Gui.bitmap (' .. how .. ')')
            local ok, err = pcall(Gui.bitmap, gui, material, pos, size, white)
            if ok then drawn = material break end
            first_error = first_error or err
        end
        if not drawn then return 'bitmap failed: ' .. short(first_error) end
        if variant.slot then
            local texture = variant.texture == 'atlas' and fonts and id(fonts.atlas) or id(P.PROBE)
            step('Gui.material')
            local got, instance = pcall(Gui.material, gui, hashed)
            if not (got and instance) and name then got, instance = pcall(Gui.material, gui, name) end
            if not (got and instance) then return 'Gui.material failed: ' .. short(instance) end
            step('Material.set_texture ' .. variant.slot)
            local set, why = pcall(engine.Material.set_texture, instance, slot(variant.slot), texture)
            if not set then return 'set_texture failed: ' .. short(why) end
        end
        return 'ok: bitmap(' .. how .. ')' .. (variant.slot and ' + texture' or '')
    end

    local function skip_reason(variant, fonts)
        if crashed[variant.key] then return 'CRASHED last time - skipped' end
        if variant.material == 'perf' and self.loaded.perf == false then return 'skipped: perf_hud not loaded' end
        if variant.needs == 'texture' and not self.loaded.texture then return 'skipped: probe texture not loaded' end
        if variant.needs == 'material' and not self.loaded.material then return 'skipped: probe material not loaded' end
        if variant.needs == 'material2' and not self.loaded.material2 then return 'skipped: probe2 needs package 1.1.0' end
        if variant.needs == 'atlas' and not self.loaded.atlas then return 'skipped: atlas not loaded' end
        if variant.needs == 'piece' and not self.loaded.piece then return 'skipped: UI images not loaded' end
        if variant.material == 'debug' and self.loaded.debug == false then return 'skipped: perf debug not loaded' end
        if (variant.material == 'font' or variant.texture == 'atlas') and not fonts then return 'skipped: font not ready' end
        return nil
    end

    -- Backdrop and labels (rebuilt when a result changes).
    local function draw_labels(fonts)
        if guis.back then pcall(World.destroy_gui, world, guis.back) end
        local g = geometry
        local back = World.create_screen_gui(world, 'scale', 1, 1)
        guis.back = back
        Gui.rect(back, engine.Vector3(g.panel.x, g.panel.y, 940), engine.Vector2(g.panel.w, g.panel.h), engine.Color(230, 12, 14, 18))
        for _, box in ipairs(g.boxes) do
            local cell = box.size / 6
            for cy = 0, 5 do
                for cx = 0, 5 do
                    if (cx + cy) % 2 == 0 then
                        Gui.rect(back, engine.Vector3(box.x + cx * cell, box.y + cy * cell, 945), engine.Vector2(cell, cell),
                            engine.Color(255, 60, 64, 72))
                    end
                end
            end
        end
        if not fonts then return end
        -- Font material set up like the panel renderer (else glyphs are blocks).
        pcall(function()
            local ink = Gui.material(back, id(fonts.material))
            for _, hash in ipairs({'8035c266', '5e8455fe', '309e7783', '82b803a8'}) do
                engine.Material.set_scalar(ink, slot(hash), 0)
            end
            engine.Material.set_vector2(ink, slot('e13777ce'), engine.Vector2(1, -1))
            engine.Material.set_vector4(ink, slot('7701209e'), engine.Color(0, 0, 0, 0))
            engine.Material.set_texture(ink, slot('88bac99b'), id(fonts.atlas))
        end)
        local font, ink = id(fonts.font), id(fonts.material)
        for i, box in ipairs(g.boxes) do
            local variant = P.VARIANTS[i]
            local result = self.results[variant.key] or (in_flight and in_flight.key == variant.key and 'running') or 'waiting'
            local colour = result:sub(1, 3) == 'ok:' and engine.Color(255, 150, 222, 120)
                or (result == 'waiting' or result == 'running') and engine.Color(255, 160, 160, 160)
                or engine.Color(255, 255, 140, 100)
            pcall(Gui.text, back, variant.label, font, g.label, ink, engine.Vector3(box.x, box.y - 26 * g.s, 955), engine.Color(255, 230, 230, 230))
            pcall(Gui.text, back, result:sub(1, 24), font, g.label * 0.8, ink, engine.Vector3(box.x, box.y - 50 * g.s, 955), colour)
        end
        local head = self.loaded.texture and 'MDL TEXTURE PROBE  (probe package loaded, one variant at a time)'
            or 'MDL TEXTURE PROBE  (probe package NOT loaded: import MDL-Texture-Probe in Arsenal, Deploy, restart)'
        pcall(Gui.text, back, head, font, g.label, ink, engine.Vector3(g.panel.x + 12 * g.s, g.panel.y + g.panel.h - 30 * g.s, 955),
            engine.Color(255, 255, 213, 0))
    end

    -- Called every frame while the probe is shown.
    function self.draw()
        local width, height = Gui.resolution()
        if not width then return false, 'no resolution' end
        local target = target_world()
        local key = tostring(target) .. ':' .. width .. 'x' .. height
        if built_for ~= key or not alive(world) then
            self.clear()
            world, built_for = target, key
            geometry = P.layout(width, height)
            if not checked then
                checked = true
                local texture, how_t = can_get('texture', 'mdl/textures/probe', P.PROBE)
                local material, how_m = can_get('material', 'mdl/textures/probe', P.PROBE)
                local perf, how_p = can_get('material', 'core/performance_hud/gui', P.PERF_HUD)
                local material2 = can_get('material', 'mdl/textures/probe2', P.PROBE2)
                local debug = can_get('material', 'core/performance_hud/debug', P.PERF_DEBUG)
                local has_atlas = atlas and atlas.MATERIAL and can_get('material', nil, atlas.MATERIAL)
                local has_piece = atlas and atlas.pieces and can_get('material', nil, atlas.pieces.logo.material)
                self.loaded = {texture = texture == true, material = material == true, perf = perf,
                    material2 = material2 == true, debug = debug, atlas = has_atlas == true, piece = has_piece == true}
                log('texture probe: can_get atlas=' .. tostring(has_atlas) .. ' piece=' .. tostring(has_piece))
                log('texture probe: can_get probe2=' .. tostring(material2) .. ' perf_debug=' .. tostring(debug))
                log(string.format('texture probe: can_get texture=%s (%s) material=%s (%s) perf_hud=%s (%s)',
                    tostring(texture), tostring(how_t), tostring(material), tostring(how_m), tostring(perf), tostring(how_p)))
            end
        end
        local fonts = options.fonts and options.fonts() or nil
        if in_flight then
            in_flight.frames = in_flight.frames + 1
            if in_flight.frames >= in_flight.settle then
                local done = in_flight.key
                state[done] = 'ok'
                save()
                log('texture probe ' .. done .. ': survived ' .. in_flight.settle .. ' frames on screen')
                in_flight = nil
            end
        else
            for i, variant in ipairs(P.VARIANTS) do
                if not ran[variant.key] then
                    ran[variant.key] = true
                    dirty = true
                    local why = skip_reason(variant, fonts)
                    if why then
                        self.results[variant.key] = why
                        log('texture probe ' .. variant.label .. ': ' .. why)
                    else
                        local settle = state[variant.key] == 'ok' and 1 or P.SETTLE
                        state[variant.key] = 'running'
                        save()
                        log('texture probe ' .. variant.label .. ': running')
                        flush()
                        local gui = World.create_screen_gui(world, 'scale', 1, 1)
                        guis[variant.key] = gui
                        local ok, value = pcall(run, variant, gui, fonts, geometry.boxes[i])
                        local result = ok and value or ('error: ' .. short(value))
                        self.results[variant.key] = result
                        log('texture probe ' .. variant.label .. ': ' .. tostring(result))
                        flush()
                        in_flight = {key = variant.key, frames = 0, settle = settle}
                    end
                    break
                end
            end
        end
        if dirty then
            dirty = false
            draw_labels(fonts)
        end
        return true
    end
    return self
end

return P
