-- Library view over synthetic Arsenal and HD2MM installs.
-- Usage: luajit tests/test_mdl_library.lua <src directory>
local source = assert(arg[1])
local json = assert(loadfile(source .. '/mdl_json.lua'))()
local L = assert(loadfile(source .. '/mdl_library.lua'))()
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

local function u32(v) return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) end
local function unhex(h) return (h:gsub('..', function(x) return string.char(tonumber(x, 16)) end)) end
-- Patch header with the given {type_hex, count} list.
local function patch(types)
    local total = 0
    for _, t in ipairs(types) do total = total + t[2] end
    local out = {u32(0xF0000011), u32(#types), u32(total), string.rep('\0', 60)}
    for _, t in ipairs(types) do out[#out + 1] = string.rep('\0', 8) .. unhex(t[1]) .. u32(t[2]) .. string.rep('\0', 12) end
    return table.concat(out)
end
local LUA, UNIT, TEX, MAT = 'e217d12cfa8d4ea1', '3f45a7e90b8da4e0', '329ec6a0c63842cd', 'dfde6a8797b4c0ea'

-- Type table decoding.
local types = L.patch_types(patch({{UNIT, 4}, {TEX, 10}, {MAT, 4}}))
check(types.unit == 4 and types.texture == 10 and types.material == 4, 'type names')
check(L.category(types) == 'RESOURCE', 'model category')
check(L.category(L.patch_types(patch({{LUA, 1}}))) == 'SCRIPT', 'script category')
check(L.category(L.patch_types(patch({{LUA, 1}, {UNIT, 1}}))) == 'MIXED', 'mixed category')
check(L.patch_types('garbage') == nil and L.category(nil) == 'UNKNOWN', 'invalid header')
check(L.describe_types(types) == 'texture 10, material 4, unit 4', 'description ordering')
check(L.patch_types(patch({{'0102030405060708', 3}}))['0102030405060708'] == 3, 'unknown types keep hex')

-- Fake filesystem.
local files = {}
local function put(path, data) files[path] = data end
local platform = {}
function platform.read(path) return files[path] end
function platform.read_head(path, n) return files[path] and files[path]:sub(1, n) end
function platform.list(directory, pattern)
    local out, seen = {}, {}
    local prefix = directory .. '/'
    for path, data in pairs(files) do
        if path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            local head = rest:match('^([^/]+)')
            local ok = not pattern or pattern == '*' or head:match('%.patch_%d+$')
            if ok and not seen[head] then
                seen[head] = true
                out[#out + 1] = {name = head, dir = rest:find('/', 1, true) ~= nil, size = #data, mtime = 0}
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local A = 'C:/Test/hd2arsenal'
put(A .. '/hd2a_data.json', [[{
  "selectedProfile": "default",
  "modsList": {"default": {"label": "Default Profile", "mods": [
    {"uuid": "11111111-0000-0000-0000-000000000001", "path": "C:\\Test\\hd2arsenal\\mods\\Jet_AR1",
     "label": "Jet \u5766\u514b skin", "description": "Model swap.", "iconPath": "C:\\Test\\hd2arsenal\\mods\\Jet_AR1\\icon.png",
     "options": [], "enabled": true, "deployed": true, "changed": false},
    {"uuid": "11111111-0000-0000-0000-000000000002", "path": "C:\\Test\\hd2arsenal\\mods\\Script_AR2",
     "label": "Script addon", "description": null, "iconPath": null,
     "options": [{"name": "Main", "include": ["Addon"], "enabled": true, "iconPath": "C:\\Test\\hd2arsenal\\mods\\Script_AR2\\opt.png"},
                 {"name": "Extra", "include": ["Extra"], "enabled": false, "iconPath": null}],
     "enabled": true, "deployed": false},
    {"uuid": "11111111-0000-0000-0000-000000000003", "path": "C:\\Test\\hd2arsenal\\mods\\Empty_AR3",
     "label": "Empty", "options": [], "enabled": false, "deployed": false}
  ]}}}]])
put(A .. '/mods/Jet_AR1/9ba626afa44a3aa3.patch_0', patch({{UNIT, 4}, {TEX, 10}, {MAT, 4}}))
put(A .. '/mods/Jet_AR1/9ba626afa44a3aa3.patch_0.stream', 'xx')
put(A .. '/mods/Jet_AR1/icon.png', 'png')
put(A .. '/mods/Script_AR2/Addon/9ba626afa44a3aa3.patch_0', patch({{LUA, 1}}))
put(A .. '/mods/Script_AR2/opt.png', 'png')
local M = 'C:/Test/Helldivers2ModManager'
put(M .. '/Mods/Armor/manifest.json', '{"Version":1,"Guid":"AAAA0000-0000-0000-0000-000000000009","Name":"Armor pack","Description":"d","IconPath":"img/icon.png","Options":[{"Name":"Red","Include":["red"],"Image":"red.png"},{"Name":"Blue","Include":["blue"]}]}')
put(M .. '/Mods/Armor/red/abcdefabcdefabcd.patch_0', patch({{TEX, 2}}))
put(M .. '/enabled.json', '[{"Guid":"aaaa0000-0000-0000-0000-000000000009","Enabled":true,"Toggled":[false,true],"Selected":[0,0]}]')
put('D:/Game/data/9ba626afa44a3aa3.patch_0', 'x')
put('D:/Game/data/9ba626afa44a3aa3.patch_1', 'y')
put('D:/Game/data/9ba626afa44a3aa3.patch_1.stream', 'z')

local logged = {}
local lib = L.new({platform = platform, json = json, arsenal_dir = A, hd2mm_dir = M, game_dir = 'D:/Game',
    log = function(line) logged[#logged + 1] = line end})
local entries = lib.scan()
check(#entries == 4, 'all entries found: ' .. #entries)
local jet, script, empty, armor = entries[1], entries[2], entries[3], entries[4]
check(jet.name == 'Jet \229\157\166\229\133\139 skin' and jet.category == 'RESOURCE' and jet.deployed and jet.enabled, 'arsenal model mod')
check(jet.icon == A .. '/mods/Jet_AR1/icon.png', 'icon path normalized')
check(jet.types.texture == 10 and jet.source == 'Arsenal', 'content types')
check(script.category == 'SCRIPT' and script.enabled and not script.deployed, 'script mod enabled but not deployed')
check(script.icon == A .. '/mods/Script_AR2/opt.png' and #script.options == 2 and script.options[2].enabled == false, 'option icon fallback and state')
check(script.description == nil, 'null description')
check(empty.category == 'UNKNOWN' and empty.types == nil, 'mod without archives')
check(armor.source == 'HD2MM' and armor.enabled and armor.icon == M .. '/Mods/Armor/img/icon.png', 'hd2mm manifest')
check(armor.options[1].enabled == false and armor.options[2].enabled == true and armor.category == 'RESOURCE', 'hd2mm toggles')
check(lib.deployed_patch_files == 2, 'deployed patch count ignores sidecars')
check(#lib.sources == 2 and lib.sources[1]:find('Default Profile'), 'sources listed')
check(logged[1]:find('4 entries'), 'scan logged')

-- Newer Arsenal data: a profile entry with only uuid + state; the definition
-- is in modsLibrary (mods added while Arsenal or the game runs).
do
    local B = 'C:/Test2/hd2arsenal'
    put(B .. '/hd2a_data.json', [[{
      "selectedProfile": "default", "librarySystemVersion": 1,
      "modsLibrary": [
        {"uuid": "F7854D5B-D841-49D2-871D-82338C5A8DEF", "path": "C:\\Test2\\hd2arsenal\\mods\\Lua_AR9", "label": "HD2 LUA", "addedAt": "2026-10-03T18:24:41.641Z",
         "description": "", "iconPath": "C:\\Test2\\hd2arsenal\\mods\\Lua_AR9\\icon.png",
         "options": [{"name": "data", "include": ["data"], "enabled": true, "iconPath": null},
                     {"name": "extra", "include": ["extra"], "enabled": true, "iconPath": null}]},
        {"uuid": "22222222-0000-0000-0000-000000000001", "path": "C:\\Test2\\hd2arsenal\\mods\\Old_AR1", "label": "library copy"}
      ],
      "modsList": {"default": {"label": "Default", "mods": [
        {"uuid": "f7854d5b-d841-49d2-871d-82338c5a8def", "enabled": true, "deployed": true, "changed": false,
         "optionsConfig": [{"name": "data", "enabled": true}, {"name": "extra", "enabled": false}]},
        {"uuid": "22222222-0000-0000-0000-000000000001", "path": "C:\\Test2\\hd2arsenal\\mods\\Old_AR1", "label": "Legacy entry",
         "options": [], "enabled": false, "deployed": false},
        {"uuid": "33333333-0000-0000-0000-000000000001", "enabled": true, "deployed": false}
      ]}}}]])
    put(B .. '/mods/Lua_AR9/data/9ba626afa44a3aa3.patch_0', patch({{LUA, 1}}))
    put(B .. '/mods/Old_AR1/9ba626afa44a3aa3.patch_0', patch({{TEX, 1}}))
    local logs2 = {}
    local lib2 = L.new({platform = platform, json = json, arsenal_dir = B, log = function(line) logs2[#logs2 + 1] = line end})
    local list = lib2.scan()
    check(#list == 3, 'three profile entries')
    local lua, old, pending = list[1], list[2], list[3]
    check(lua.name == 'HD2 LUA' and lua.path == B .. '/mods/Lua_AR9' and lua.category == 'SCRIPT', 'definition taken from modsLibrary (case-insensitive uuid)')
    check(lua.deployed and lua.enabled and lua.icon == B .. '/mods/Lua_AR9/icon.png', 'state from the profile, icon from the library')
    check(#lua.options == 2 and lua.options[1].enabled == true and lua.options[2].enabled == false, 'option state from optionsConfig')
    check(old.name == 'Legacy entry' and old.category == 'RESOURCE', 'full legacy entries keep their own fields')
    check(pending.name == '33333333-0000-0000-0000-000000000001' and pending.category == 'UNKNOWN', 'entry without a definition stays unknown')
    check(lua.updated == 1791051881, 'update time from modsLibrary addedAt')
    check(old.updated == nil and old.bytes and old.bytes > 0, 'no addedAt and zero file times: no update time; file size counted')
    check(lua.bytes and lua.bytes > 0, 'patch files in a subfolder counted')
    local text = table.concat(logs2, '\n')
    check(text:find('2 Arsenal mod(s) completed from modsLibrary', 1, true) and text:find('33333333', 1, true), 'merge logged')
end

-- Broken manager data never raises.
local broken = L.new({platform = platform, json = json, arsenal_dir = 'C:/Nope', hd2mm_dir = 'C:/Nope2'})
check(#broken.scan() == 0 and broken.scanned, 'missing managers')
put('C:/Bad/hd2a_data.json', '{"modsList":')
local bad = L.new({platform = platform, json = json, arsenal_dir = 'C:/Bad'})
check(#bad.scan() == 0 and #bad.errors == 1, 'corrupt JSON reported')

-- Startup loaders are recognised and hidden from the list.
do
    local key = 'K'
    check(L.loader_kind({name = 'MDL - Mod Dynamic Loader 1.4.0'}) == 'MDL', 'MDL by name')
    check(L.loader_kind({name = 'x', addon = 'mods/mdl/runtime'}) == 'MDL', 'MDL by runtime entry')
    check(L.loader_kind({name = 'x', guid = '761188B2-C45B-4607-9241-F89CA221C47B'}) == 'MDL', 'MDL by GUID')
    check(L.loader_kind({name = 'Bingus Shared Loader - v18'}) == 'BSL', 'BSL by name')
    check(L.loader_kind({name = 'renamed', guid = '612eaf70-d682-43c7-9efd-16dcc695f977'}) == 'BSL', 'BSL by GUID')
    check(L.loader_kind({name = 'Some other loader', resources = {[key] = 'x'}}, key) == 'LOADER', 'any mod replacing the startup resource')
    check(L.loader_kind({name = 'Jet skin', resources = {other = 'x'}}, key) == nil, 'ordinary mods are kept')
end
print('PASS: MDL library (Arsenal/HD2MM metadata, icons, content types, deployed state) (' .. checks .. ' checks)')
