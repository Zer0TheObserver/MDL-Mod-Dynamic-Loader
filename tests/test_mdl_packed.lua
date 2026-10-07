-- Library script addons run live from the manager archive (kind 'packed'),
-- and read-only model entries explain themselves when clicked.
-- Usage: luajit tests/test_mdl_packed.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local json, L, mdl_manager, mdl_panel = module('mdl_json'), module('mdl_library'), module('mdl_manager'), module('mdl_panel')
local ffi, bit = require('ffi'), require('bit')
local hash = L.hasher(ffi, bit)
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- Hash matches the archive tooling (scripts/archive.py resource_hash).
local function hex(bytes) return (bytes:reverse():gsub('.', function(c) return string.format('%02X', c:byte()) end)) end
check(hex(hash('core/wwise/lua/wwise_flow_callbacks')) == '7251FDD9BB62480A', 'MurmurHash64A matches archive tooling')

local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local LUA = '\226\023\209\044\250\141\078\161'
local UNIT = '\063\069\167\233\011\141\164\224'
-- Archive with Lua resources {name = body} and optional other typed entries.
local function archive(lua, others)
    local rows, bodies = {}, {}
    local list = {}
    for name, body in pairs(lua) do list[#list + 1] = {hash(name), LUA, body} end
    for _, other in ipairs(others or {}) do list[#list + 1] = {other[1], other[2], other[3]} end
    local types = {}
    for _, item in ipairs(list) do types[item[2]] = (types[item[2]] or 0) + 1 end
    local type_list = {}
    for key, count in pairs(types) do type_list[#type_list + 1] = {key, count} end
    local offset = 72 + 32 * #type_list + 80 * #list
    for index, item in ipairs(list) do
        local resource = u32(#item[3]) .. u32(2) .. item[3]
        rows[#rows + 1] = item[1] .. item[2] .. u32(offset) .. u32(0) .. string.rep('\0', 32) .. u32(#resource) .. string.rep('\0', 20)
        bodies[#bodies + 1] = resource
        offset = offset + #resource
    end
    local header = u32(0xF0000011) .. u32(#type_list) .. u32(#list) .. string.rep('\0', 60)
    local type_rows = {}
    for _, t in ipairs(type_list) do type_rows[#type_rows + 1] = string.rep('\0', 8) .. t[1] .. u32(t[2]) .. string.rep('\0', 12) end
    return header .. table.concat(type_rows) .. table.concat(rows) .. table.concat(bodies)
end

local files = {}
local function put(path, data) files[path] = data end
local platform = {mkdir = function() return true end}
function platform.read(path, limit) local d = files[path]; if d and limit then return d:sub(1, limit) end return d end
function platform.read_head(path, n) return files[path] and files[path]:sub(1, n) end
function platform.write(path, data) files[path] = data return true end
function platform.list(directory)
    local out, seen = {}, {}
    for path, data in pairs(files) do
        local rest = path:sub(1, #directory + 1) == directory .. '/' and path:sub(#directory + 2)
        local head = rest and rest:match('^([^/]+)')
        if head and not seen[head] then
            seen[head] = true
            out[#out + 1] = {name = head, dir = rest:find('/', 1, true) ~= nil, size = #data, mtime = 0}
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local A = 'C:/Test/hd2arsenal'
put(A .. '/hd2a_data.json', [[{"selectedProfile":"default","modsList":{"default":{"label":"Default","mods":[
 {"uuid":"u-script","path":"C:\\Test\\hd2arsenal\\mods\\Tuner_AR1","label":"Tank Tuner","description":"Tunes.","options":[{"name":"Tank Tuner","enabled":true}],"enabled":false,"deployed":false},
 {"uuid":"u-model","path":"C:\\Test\\hd2arsenal\\mods\\Jet_AR2","label":"Jet","options":[],"enabled":false,"deployed":false},
 {"uuid":"u-plain","path":"C:\\Test\\hd2arsenal\\mods\\Plain_AR3","label":"Undeclared","options":[],"enabled":false,"deployed":false},
 {"uuid":"u-running","path":"C:\\Test\\hd2arsenal\\mods\\Run_AR4","label":"Already running","options":[],"enabled":true,"deployed":true},
 {"uuid":"u-svd","path":"C:\\Test\\hd2arsenal\\mods\\Svd_AR5","label":"Svd like","options":[],"enabled":false,"deployed":false},
 {"uuid":"u-idle","path":"C:\\Test\\hd2arsenal\\mods\\Idle_AR6","label":"Idle","options":[],"enabled":false,"deployed":false}
]}}}]])
put(A .. '/mods/Tuner_AR1/Addon/9ba626afa44a3aa3.patch_0', archive({
    ['mods/test/tuner'] = '-- HD2-Addon: mods/test/tuner\nlocal impl = require("mods/test/tuner_impl")\n'
        .. 'if rawget(_G, "TunerGuard") then return end\nrawset(_G, "TunerGuard", true)\n'
        .. 'local previous = update\nupdate = function(dt, ...) Shared.ticks = Shared.ticks + impl.step; if previous then return previous(dt, ...) end end\n'
        .. 'local old = shutdown\nshutdown = function() Shared.restored = Shared.restored + 1 end\n',
    ['mods/test/tuner_impl'] = 'return {step = 1}',
}))
-- Same callback idiom as Solo Vehicle Driver / Tank Clutch Tuner: refuses to
-- start unless `update` is a function, chains previous_update when retired.
put(A .. '/mods/Svd_AR5/Addon/9ba626afa44a3aa3.patch_0', archive({
    ['mods/test/svd'] = '-- HD2-Addon: mods/test/svd\n'
        .. 'if rawget(_G, "SvdGuard") then return end\nrawset(_G, "SvdGuard", {})\n'
        .. 'local previous_update, previous_shutdown = update, shutdown\n'
        .. 'if type(previous_update) ~= "function" then Shared.rejected = true; return end\n'
        .. 'local retired, my_update = false, nil\n'
        .. 'my_update = function(...) if retired then return previous_update(...) end Shared.svd = Shared.svd + 1; return previous_update(...) end\n'
        .. 'update = my_update\n'
        .. 'shutdown = function(...) retired = true; Shared.svd_stopped = true; if update == my_update then update = previous_update end\n'
        .. '  if type(previous_shutdown) == "function" then return previous_shutdown(...) end end\n',
}))
put(A .. '/mods/Idle_AR6/Addon/9ba626afa44a3aa3.patch_0', archive({
    ['mods/test/idle'] = '-- HD2-Addon: mods/test/idle\nreturn\n',
}))
put(A .. '/mods/Jet_AR2/9ba626afa44a3aa3.patch_0', archive({}, {{hash('units/jet'), UNIT, 'unitdata'}}))
put(A .. '/mods/Plain_AR3/9ba626afa44a3aa3.patch_0', archive({['mods/test/plain'] = 'Plain = true'}))
put(A .. '/mods/Run_AR4/9ba626afa44a3aa3.patch_0', archive({['mods/test/run'] = '-- HD2-Addon: mods/test/run\n'}))

-- Archive helpers.
local resources = L.lua_resources(files[A .. '/mods/Tuner_AR1/Addon/9ba626afa44a3aa3.patch_0'])
check(resources[hash('mods/test/tuner_impl')] == 'return {step = 1}', 'lua resources extracted')
check(L.declaration(resources[hash('mods/test/tuner')]) == 'mods/test/tuner', 'declaration parsed')

local G = setmetatable({Shared = {ticks = 0, restored = 0, svd = 0}}, {__index = _G})
G._G = G
G.CowboyBingusModLoader = {modules = {['mods/test/run'] = 'loaded'}}
local BASE = 'C:/TestData/MDL/Helldivers2'
local m = mdl_manager.new({base_dir = BASE, platform = platform, globals = G, boot_control = true})
local library
library = L.new({platform = platform, json = json, arsenal_dir = A, hash = hash, on_scan = function(lib)
    for _, entry in ipairs(lib.entries) do
        if entry.addon and entry.category == 'SCRIPT' then
            local status = G.CowboyBingusModLoader.modules[entry.addon]
            local current = entry
            entry.record = m.register_packed(entry.id, {name = entry.name, description = entry.description}, entry.addon,
                function(name) return lib.resolve(current, name) end, {dir = entry.path, launch = status == 'loaded'})
        end
    end
end})
library.scan()
m.start()
local tuner, jet, plain, running = library.entries[1], library.entries[2], library.entries[3], library.entries[4]
check(tuner.addon == 'mods/test/tuner' and tuner.record and tuner.category == 'SCRIPT', 'script addon found with entry')
check(jet.category == 'RESOURCE' and not jet.record, 'model entry stays read-only')
check(plain.addon == nil and not plain.record, 'undeclared script is not run live')
check(running.record and running.record.status == 'launch', 'addon loaded at launch is marked')
check(not m.enable(running.record) and running.record.error:find('launch'), 'launch addon cannot be started twice')

-- Scripts that require `update` to be a function start (regression: SVD
-- rejected itself with game_update_callback_unavailable in 1.0.1).
local svd = library.entries[5]
check(svd.label == nil and svd.name == 'Svd like' and svd.record, 'svd-style entry registered')
check(m.enable(svd.record) and not G.Shared.rejected and not svd.record.warning, 'svd-style addon accepts stand-in update')
m.frame(0.1); m.frame(0.1)
check(G.Shared.svd == 2, 'svd-style addon ticks once per frame')
check(m.disable(svd.record) and G.Shared.svd_stopped and rawget(G, 'SvdGuard') == nil, 'svd-style shutdown and guard cleanup')
m.frame(0.1)
check(G.Shared.svd == 2, 'svd-style addon stops ticking')
check(m.enable(svd.record) and G.Shared.svd == 2, 'svd-style re-enable')
m.frame(0.1)
check(G.Shared.svd == 3, 'svd-style ticks again after re-enable')
m.disable(svd.record)
local idle = library.entries[6]
check(m.enable(idle.record) and idle.record.warning and idle.record.warning:find('no update callback'), 'idle script flagged')
m.disable(idle.record)

-- Live toggle: runs from the archive, captured update, shutdown restores.
check(m.enable(tuner.record), 'packed addon enables: ' .. tostring(tuner.record.error))
m.frame(0.1); m.frame(0.1)
check(G.Shared.ticks == 2 and rawget(G, 'TunerGuard'), 'addon ticks through MDL dispatcher')
check(m.disable(tuner.record) and G.Shared.restored == 1 and rawget(G, 'TunerGuard') == nil, 'disable calls its shutdown and clears guard')
m.frame(0.1)
check(G.Shared.ticks == 2, 'no ticks after disable')
check(m.enable(tuner.record) and rawget(G, 'TunerGuard'), 're-enable works')
m.frame(0)
local saved = mdl_manager.parse_config(files[BASE .. '/MDL.cfg'])
check(saved.enabled['arsenal:u-script'], 'live state persisted')
-- Rescan keeps the running record; next session restores it.
library.scan()
check(library.entries[1] ~= tuner and library.entries[1].record.status == 'enabled', 'rescan keeps state')
m.shutdown()
check(G.Shared.restored == 2, 'shutdown restores')

-- Panel: row value, click to toggle, flash on read-only rows.
local G2 = setmetatable({Shared = {ticks = 0, restored = 0}, CowboyBingusModLoader = {modules = {}}}, {__index = _G})
G2._G = G2
files[BASE .. '/MDL.cfg'] = nil
local m2 = mdl_manager.new({base_dir = BASE, platform = platform, globals = G2, boot_control = true})
local lib2 = L.new({platform = platform, json = json, arsenal_dir = A, hash = hash, on_scan = function(lib)
    for _, entry in ipairs(lib.entries) do
        if entry.addon and entry.category == 'SCRIPT' then
            local current = entry
            entry.record = m2.register_packed(entry.id, {name = entry.name}, entry.addon, function(n) return lib.resolve(current, n) end, {stamp = entry.stamp})
        end
    end
end})
lib2.scan(); m2.start()
local pressed, cursor, click = {}, nil, nil
local input = {pressed = function(...) for _, n in ipairs({...}) do if pressed[n] then return true end end return false end,
    cursor = function() if cursor then return cursor[1], cursor[2] end end, clicked = function(b) return click == b end,
    wheel = function() return 0 end}
local drawn
local renderer = {resolution = function() return 1920, 1080 end, draw = function(list) drawn = list return true end, clear = function() end}
local panel = mdl_panel.new(m2, input, renderer, {library = lib2})
local function frame(keys, at, button) pressed, cursor, click = keys or {}, at, button; panel.frame(); m2.frame(0.016) end
local function find(text) for _, item in ipairs(drawn or {}) do if item.text == text then return item end end end
frame({esc = true})
local row = find('Tank Tuner')
check(row and find('OFF'), 'library script row shows live state')
frame(nil, {1920 - 90, row.y + 4}, 'left'); frame()
check(lib2.entries[1].record.status == 'enabled' and find('LIVE ON'), 'clicking the state starts it live')
frame(nil, {1920 - 90, row.y + 4}, 'left'); frame()
check(lib2.entries[1].record.status == 'disabled', 'clicking again stops it')
-- Groups: live scripts first, then LAUNCH ONLY groups with a "?".
local order = {}
for _, r in ipairs(panel.rows()) do if r.sub then order[#order + 1] = r.header .. (r.why and '?' or '') end end
check(table.concat(order, '|') == 'SCRIPT  -  LIVE|SCRIPT  -  LAUNCH ONLY?|RESOURCE  -  LAUNCH ONLY?', 'library grouped by type: ' .. table.concat(order, '|'))
local jet_label = find('Jet')
local jet_state
for _, r in ipairs(panel.rows()) do if r.label == 'Jet' then jet_state = r.value end end
check(jet_label and (jet_state == 'ON' or jet_state == 'ON*' or jet_state == 'OFF'), 'launch-only rows show only their state: ' .. tostring(jet_state))
-- Clicking the RESOURCE group's "?" opens the explanation page.
local group = find('RESOURCE  -  LAUNCH ONLY')
frame(nil, {group.x + 40, group.y + 4}, 'left'); frame()
check(panel.page == 'why' and panel.target == 'resource' and find('RESOURCE - LAUNCH ONLY') and find('WHY IT CANNOT START IN GAME')
    and find('HOW TO TURN IT ON') and find('3. Click Deploy.') and find('IN YOUR LIBRARY (1)') and find('Jet'), 'why page: reason, Arsenal steps, members')
local back = find('< Back')
frame(nil, {back.x + 30, back.y + 4}, 'left'); frame()
check(panel.page == 'list', 'Back returns to the list')
local qmarks = 0
local placeholders = 0
for _, item in ipairs(drawn) do
    if item.text == '?' and item.z == 906 then qmarks = qmarks + 1 end
    if item.text == '?' and item.z == 903 then placeholders = placeholders + 1 end
end
check(qmarks == 3, 'header ? plus one per LAUNCH ONLY group (' .. qmarks .. ')')
local iconless = 0
for _, r in ipairs(panel.rows()) do if r.iconic and not r.icon then iconless = iconless + 1 end end
check(iconless > 0 and placeholders == iconless, 'every icon-less mod row gets a ? tile (' .. placeholders .. '/' .. iconless .. ')')
-- All mod rows start at the same x (icon column reserved).
local xs = {}
for _, r in ipairs(panel.rows()) do
    if r.iconic then local item = find(r.label); if item then xs[item.x] = true end end
end
local distinct = 0
for _ in pairs(xs) do distinct = distinct + 1 end
check(distinct == 1, 'mod names aligned')
-- Resource entry: its detail page links to the same explanation.
local jet_row = find('Jet')
frame(nil, {jet_row.x + 30, jet_row.y + 4}, 'left'); frame()
check(panel.page == 'library' and find('Assets load only when the game starts') and find('WHY?'), 'resource page explains itself')
local info = find('Assets load only when the game starts')
frame(nil, {info.x + 30, info.y + 4}, 'left'); frame()
check(panel.page == 'why' and panel.target == 'resource', 'WHY? opens the explanation')
frame(nil, {find('< Back').x + 30, find('< Back').y + 4}, 'left'); frame()
-- Clicking a launch-only row's state explains instead of toggling.
local jet_again = find('Jet')
frame(nil, {1920 - 90, jet_again.y + 4}, 'left'); frame()
local flashed = false
for _, item in ipairs(drawn) do if item.text and item.text:find('Starts only with the game', 1, true) then flashed = true end end
check(flashed, 'clicking a launch-only state shows why')
-- Script page: toggle row inside the detail page.
local t_row = find('Tank Tuner')
frame(nil, {t_row.x + 30, t_row.y + 4}, 'left'); frame()
local live = find('Run live in game')
check(panel.page == 'library' and live, 'script page has live toggle')
frame(nil, {1920 - 90, live.y + 4}, 'left'); frame()
check(lib2.entries[1].record.status == 'enabled', 'detail toggle starts it')


-- File names and new versions ------------------------------------------------
check(L.file_name('C:/x/hd2arsenal/mods/Emote Abilities Test v0.7_AR382765', 'Arsenal') == 'Emote Abilities Test v0.7'
    and L.file_name('C:\\M\\Mods\\Some Mod\\', 'HD2MM') == 'Some Mod' and L.file_name(nil) == nil, 'file names')
check(tuner.file == 'Tuner' and library.entries[2].file == 'Jet', 'entries carry their file name')
do
    panel.page = 'list'
    local rows_text = {}
    for _, r in ipairs(panel.rows()) do if r.file then rows_text[#rows_text + 1] = r.label .. '<' .. r.file end end
    check(table.concat(rows_text, '|'):find('Tank Tuner<Tuner', 1, true), 'list rows carry the file name: ' .. table.concat(rows_text, '|'))
    local list = panel.build(1920, 1080)
    local name_y, file_y
    for _, item in ipairs(list) do
        if item.text == 'Tank Tuner' then name_y = item.y end
        if item.text == 'Tuner' then file_y = item.y end
    end
    check(name_y and file_y and file_y < name_y, 'file name drawn under the mod name')
end
check(L.fingerprint({a = 'x'}) ~= L.fingerprint({a = 'y'}) and L.fingerprint({}) == nil, 'fingerprint follows the code')

-- An updated Arsenal import (same uuid, new folder, new code) reloads the
-- running addon when auto reload is on, and is only marked otherwise.
do
    local DATA = A .. '/hd2a_data.json'
    local original = files[DATA]
    local record = lib2.entries[1].record
    check(record.status == 'enabled' and record.loaded_stamp, 'running addon remembers its version')
        local function step()
        for _ = 1, 3 do m2.frame(0.016) end
        local now = G2.Shared.ticks
        m2.frame(0.016)
        return G2.Shared.ticks - now
    end
    check(step() == 1, 'old version adds 1 per frame')
    put(A .. '/mods/Tuner_AR9/Addon/9ba626afa44a3aa3.patch_0', archive({
        ['mods/test/tuner'] = files[A .. '/mods/Tuner_AR1/Addon/9ba626afa44a3aa3.patch_0'] and
            '-- HD2-Addon: mods/test/tuner\nlocal impl = require("mods/test/tuner_impl")\n'
            .. 'local previous = update\nupdate = function(dt, ...) Shared.ticks = Shared.ticks + impl.step; if previous then return previous(dt, ...) end end\n'
            .. 'shutdown = function() Shared.restored = Shared.restored + 1 end\n',
        ['mods/test/tuner_impl'] = 'return {step = 10}',
    }))
    files[DATA] = original:gsub('Tuner_AR1', 'Tuner_AR9')
    -- Auto reload off: marked, still the old code.
    m2.config.ui.auto_reload = false
    lib2.scan()
    local updated = lib2.entries[1].record
    check(updated == record and record.outdated and record.status == 'enabled', 'new version marked when auto reload is off')
    check(step() == 1, 'still the old code')
    -- Auto reload on: the next scan reloads it from the new folder.
    m2.config.ui.auto_reload = true
    lib2.scan()
    check(step() == 10 and not record.outdated and record.status == 'enabled', 'auto reload runs the new version')
    check(record.loaded_stamp == lib2.entries[1].stamp, 'new version remembered')
    lib2.scan()
    check(step() == 10, 'unchanged library: no further reload')
    files[DATA] = original
end

-- MIXED mods with the live switch (1.8.3): group title, Use live row, script
-- part row, and the launch-only reason on the mod page.
do
    local states = {}
    local toggled = {}
    local live = {revision = 0, staged = {}, live_state = function(entry) return states[entry.id] end,
        live_toggle = function(entry) toggled[#toggled + 1] = entry.id return true, 'live.scanning' end,
        conflicts = function() return {} end, reconcile = function() end}
    local turret = {id = 'arsenal:att', name = 'ATT', category = 'MIXED', source = 'Arsenal', options = {}, types = {}, addon = 'mods/x/att',
        record = {status = 'disabled', id = 'arsenal:att'}}
    local hud = {id = 'arsenal:hud', name = 'HUD', category = 'MIXED', source = 'Arsenal', options = {}, types = {}}
    states['arsenal:att'] = {state = 'off', mixed = true}
    states['arsenal:hud'] = {state = 'unavailable', reason = 'new', new = 2, mixed = true}
    local lib = {scanned = true, sources = {'Arsenal'}, entries = {turret, hud}, scan = function() end, describe_types = function() return '' end}
    local p2 = mdl_panel.new(m2, input, renderer, {library = lib, live = live})
    local labels = {}
    for _, r in ipairs(p2.rows()) do labels[#labels + 1] = tostring(r.label or r.header) .. '=' .. tostring(r.value) end
    labels = table.concat(labels, '|')
    check(labels:find('MIXED  -  SCRIPT NOW, ASSETS NEXT LOAD', 1, true) and labels:find('ATT=OFF', 1, true) and labels:find('HUD=LAUNCH ONLY', 1, true),
        'mixed group with live states: ' .. labels)
    for _, r in ipairs(p2.rows()) do if r.label == 'ATT' then r.adjust() end end
    check(toggled[1] == 'arsenal:att', 'state click toggles the mixed mod live')
    p2.page, p2.target = 'library', turret
    local page = {}
    for _, r in ipairs(p2.rows()) do page[#page + 1] = tostring(r.label) .. '=' .. tostring(r.value) end
    page = table.concat(page, '|')
    check(page:find('Use live (applies on next load)', 1, true) and page:find('Script part=', 1, true), 'mixed page: live row and script part: ' .. page)
    p2.page, p2.target = 'library', hud
    page = {}
    for _, r in ipairs(p2.rows()) do page[#page + 1] = tostring(r.label) end
    page = table.concat(page, '|')
    check(page:find('Launch only: 2 asset(s) are new to the game', 1, true), 'mixed page: launch-only reason: ' .. page)
end

print('PASS: MDL live library addons, launch detection, read-only explanations (' .. checks .. ' checks)')
