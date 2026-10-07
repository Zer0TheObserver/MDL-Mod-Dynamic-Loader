-- Texture probe (debug): one variant at a time, crash bookkeeping across
-- starts, guarded variants, draw-before-material order, slot ids, cleanup.
-- Usage: luajit tests/test_mdl_probe.lua <src directory>
local source = assert(arg[1])
local P = assert(loadfile(source .. '/mdl_probe.lua'))()
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

local function fake(loaded)
    local calls, counts = {}, {created = 0, destroyed = 0}
    local engine = {}
    engine.IdString64 = {from_hex = function(hex) return {hex = hex} end}
    engine.Vector3 = function(x, y, z) return {x, y, z} end
    engine.Vector2 = function(x, y) return {x, y} end
    engine.Color = function(a, r, g, b) return {a, r, g, b} end
    local world = {}
    engine.Application = {main_world = function() return world end, worlds = function() return {world} end,
        can_get = function(kind, name)
            if type(name) == 'table' and type(kind) == 'table' then
                local k = ({cd4238c6a0c69e32 = 'texture', eac0b497876adedf = 'material'})[kind.hex]
                return loaded[k .. ':' .. name.hex] == true
            end
            return nil
        end}
    engine.World = {create_screen_gui = function() counts.created = counts.created + 1 return {n = counts.created} end,
        destroy_gui = function() counts.destroyed = counts.destroyed + 1 end}
    engine.Gui = {resolution = function() return 1920, 1080 end, rect = function() end,
        text = function(gui, text) calls[#calls + 1] = 'text ' .. text end,
        material = function(gui, material)
            calls[#calls + 1] = 'material ' .. (material.hex or material)
            return {gui = gui.n, material = material.hex or material}
        end,
        bitmap = function(gui, material, pos, size, color)
            calls[#calls + 1] = 'bitmap ' .. (type(material) == 'string' and material or material.hex) .. ' ' .. size[1]
        end,
        bitmap_uv = function(gui, material, uv00, uv11)
            calls[#calls + 1] = 'bitmap_uv ' .. material.hex .. ' ' .. uv00[1] .. ',' .. uv00[2] .. '-' .. uv11[1] .. ',' .. uv11[2]
        end}
    engine.Material = {set_texture = function(instance, slot, texture)
        calls[#calls + 1] = 'set ' .. instance.material .. ' ' .. slot.hex .. ' ' .. texture.hex
    end}
    return engine, calls, counts
end
local fonts = function() return {font = 'f0', material = 'f1', atlas = 'f2'} end
local files = {}
local platform = {read = function(path) return files[path] end, write = function(path, data) files[path] = data return true end}
local STATE = 'C:/L/MDL-probe-state-4.txt'
local GAME = {['material:' .. P.PERF_HUD] = true, ['material:' .. P.PERF_DEBUG] = true}
local A = assert(loadfile(source .. '/mdl_atlas.lua'))()
local ALL = {['material:' .. A.MATERIAL] = true, ['material:' .. A.pieces.logo.material] = true,['material:' .. P.PERF_HUD] = true, ['material:' .. P.PERF_DEBUG] = true, ['texture:' .. P.PROBE] = true,
    ['material:' .. P.PROBE] = true, ['material:' .. P.PROBE2] = true}
local function run_all(probe) for _ = 1, #P.VARIANTS * (P.SETTLE + 2) do probe.draw() end end

-- State file helpers.
check(P.parse_state('G=ok\r\nU1=running\nbad line\n').U1 == 'running', 'state parse')
check(P.encode_state({U1 = 'crashed', G = 'ok'}) == 'G=ok\nU1=crashed\n', 'state encode in variant order')
local keys = {}
for _, v in ipairs(P.VARIANTS) do keys[#keys + 1] = v.key end
check(table.concat(keys, ',') == 'G,U1,U2,U3,P1,P2,P3', 'variant order: ' .. table.concat(keys, ','))

-- 1. Nothing loaded: everything skipped, no draw calls.
local logs, flushes = {}, 0
local engine, calls = fake(GAME)
local probe = P.new({engine = engine, fonts = fonts, log = function(l) logs[#logs + 1] = l end,
    flush = function() flushes = flushes + 1 end, platform = platform, state_path = STATE, atlas = A})
run_all(probe)
for _, key in ipairs(keys) do check(probe.results[key]:find('^skipped'), key .. ' skipped: ' .. tostring(probe.results[key])) end
local any = false
for _, c in ipairs(calls) do if c:sub(1, 6) == 'bitmap' then any = true end end
check(not any, 'no bitmaps')
check(table.concat(logs, '\n'):find('can_get atlas=false piece=false', 1, true), 'atlas can_get logged')

-- 2. All loaded: one variant at a time, the right calls.
files[STATE] = nil
engine, calls = fake(ALL)
probe = P.new({engine = engine, fonts = fonts, platform = platform, state_path = STATE, atlas = A})
probe.draw()
check(files[STATE] == 'G=running\n', 'G marked running first')
run_all(probe)
for _, key in ipairs(keys) do check(probe.results[key]:find('^ok:'), key .. ' ok: ' .. tostring(probe.results[key])) end
local text = table.concat(calls, '\n')
check(text:find('bitmap mdl/textures/probe2 140', 1, true), 'G reference')
check(text:find('bitmap ' .. A.MATERIAL .. ' 140', 1, true), 'U1: atlas with Gui.bitmap')
check(text:find('bitmap_uv ' .. A.MATERIAL .. ' 0,0-1,1', 1, true), 'U2: whole atlas uv')
local logo = A.cells.logo
check(text:find(string.format('bitmap_uv %s %s,%s-%s,%s', A.MATERIAL, logo[1], logo[2], logo[3], logo[4]), 1, true), 'U3: logo cell uv')
check(text:find('bitmap ' .. A.pieces.logo.material .. ' 140', 1, true) and text:find('bitmap ' .. A.pieces.logo.material .. ' 28', 1, true),
    'P1/P2: logo piece large and small')
check(text:find('bitmap ' .. A.pieces.logo_mask.material, 1, true), 'P3: tinted mask')
check(files[STATE]:find('P3=ok', 1, true), 'all survived')

-- 3. Crash recorded at the next start, crashed variant skipped.
files[STATE] = 'G=ok\nU1=ok\nU2=running\n'
logs = {}
engine, calls = fake(ALL)
probe = P.new({engine = engine, fonts = fonts, log = function(l) logs[#logs + 1] = l end, platform = platform, state_path = STATE, atlas = A})
check(probe.state.U2 == 'crashed' and table.concat(logs, '\n'):find('U2: CRASHED', 1, true), 'crash recorded')
run_all(probe)
check(probe.results.U2 == 'CRASHED last time - skipped' and probe.results.U3:find('^ok:'), 'skip and continue')

-- 4. Closing mid-variant is not a crash.
files[STATE] = nil
engine = fake(ALL)
probe = P.new({engine = engine, fonts = fonts, platform = platform, state_path = STATE, atlas = A})
probe.draw()
probe.clear()
check(files[STATE] == '\n' and not probe.active(), 'cleared: not a crash')

-- 5. Layout stays on screen.
for _, size in ipairs({{1280, 720}, {1920, 1080}, {3840, 2160}}) do
    local g = P.layout(size[1], size[2])
    local last = g.boxes[#g.boxes]
    check(last.x + last.size < size[1] and g.panel.y > 0 and g.boxes[1].y + g.size < size[2], 'layout fits ' .. size[1])
end

print('PASS: MDL texture probe (' .. checks .. ' checks)')
