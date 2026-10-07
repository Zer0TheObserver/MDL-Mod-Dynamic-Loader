-- MDL: view of the mod manager libraries (HD2 Arsenal, HD2MM). Script addons
-- found here can be run live by the manager (kind 'packed').
--
-- Model/asset mods are Stingray patch archives that the engine mounts once at
-- startup; Lua cannot mount or unmount them, so MDL shows them (name, icon,
-- description, options, deployed state, content types) and leaves changes to
-- the manager's Deploy + a game restart. Script addons found here are the same
-- archives the startup coordinator already runs.
local L = {}

-- Stingray type hashes (little-endian bytes as stored in archive type tables).
local TYPES = {
    ['e217d12cfa8d4ea1'] = 'lua', ['3f45a7e90b8da4e0'] = 'unit', ['329ec6a0c63842cd'] = 'texture',
    ['dfde6a8797b4c0ea'] = 'material',
}
L.TYPES = TYPES

local function hex(bytes)
    return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function u32(bytes, offset)
    local a, b, c, d = bytes:byte(offset + 1, offset + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

-- Returns {type_name = resource_count} from a patch archive header, or nil.
function L.patch_types(head)
    if not head or #head < 72 or u32(head, 0) ~= 0xF0000011 then return nil end
    local types = u32(head, 4)
    if types == 0 or types > 256 or #head < 72 + 32 * types then return nil end
    local result = {}
    for i = 0, types - 1 do
        local entry = 72 + 32 * i
        local key = hex(head:sub(entry + 9, entry + 16))
        local name = TYPES[key] or key
        result[name] = (result[name] or 0) + u32(head, entry + 16)
    end
    return result
end

-- Seed-zero MurmurHash64A of a resource name, as the 8 little-endian bytes
-- stored in archive rows (same algorithm as discover.lua).
function L.hasher(ffi, bit)
    local mix = ffi.new('uint64_t', 0xc6a4a793) * ffi.new('uint64_t', 4294967296) + 0x5bd1e995
    local base = ffi.new('uint64_t', 256)
    local function word(bytes)
        local value = ffi.new('uint64_t', 0)
        for i = #bytes, 1, -1 do value = value * base + bytes:byte(i) end
        return value
    end
    return function(name)
        local h = ffi.new('uint64_t', #name) * mix
        local finish = #name - #name % 8
        for i = 1, finish, 8 do
            local k = word(name:sub(i, i + 7)) * mix
            k = bit.bxor(k, bit.rshift(k, 47)) * mix
            h = bit.bxor(h, k) * mix
        end
        if finish < #name then h = bit.bxor(h, word(name:sub(finish + 1))) * mix end
        h = bit.bxor(h, bit.rshift(h, 47)) * mix
        h = bit.bxor(h, bit.rshift(h, 47))
        local bytes = {}
        for i = 1, 8 do
            bytes[i] = string.char(tonumber(h % base))
            h = h / base
        end
        return table.concat(bytes)
    end
end

-- Lua resources of a whole patch archive: {key8 = body}. Bodies are the
-- plaintext or bytecode inside the (length, version 2) envelope.
function L.lua_resources(archive)
    if not archive or #archive < 72 or u32(archive, 0) ~= 0xF0000011 then return nil end
    local types, count = u32(archive, 4), u32(archive, 8)
    local table_start = 72 + 32 * types
    if types == 0 or table_start + 80 * count > #archive then return nil end
    local lua_type = '\226\023\209\044\250\141\078\161'
    local result = {}
    for index = 0, count - 1 do
        local row = table_start + index * 80
        if archive:sub(row + 9, row + 16) == lua_type then
            local offset, length = u32(archive, row + 16) + u32(archive, row + 20) * 4294967296, u32(archive, row + 56)
            if length >= 8 and offset + length <= #archive then
                local body_length, version = u32(archive, offset), u32(archive, offset + 4)
                if version == 2 and body_length <= length - 8 then
                    result[archive:sub(row + 1, row + 8)] = archive:sub(offset + 9, offset + 8 + body_length)
                end
            end
        end
    end
    return result
end

function L.declaration(body)
    return body and body:sub(1, 256):match('^%-%- HD2%-Addon: (mods/[A-Za-z0-9_]+/[A-Za-z0-9_/]+)\r?\n') or nil
end

function L.category(types)
    if not types then return 'UNKNOWN' end
    local lua, other = false, false
    for name in pairs(types) do
        if name == 'lua' then lua = true else other = true end
    end
    if lua and other then return 'MIXED' end
    if lua then return 'SCRIPT' end
    if other then return 'RESOURCE' end
    return 'UNKNOWN'
end

function L.describe_types(types)
    if not types then return 'no patch archive found' end
    local parts = {}
    for name, count in pairs(types) do parts[#parts + 1] = {name, count} end
    table.sort(parts, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
    local text = {}
    for i, part in ipairs(parts) do
        if i > 5 then text[#text + 1] = '...' break end
        text[#text + 1] = part[1] .. ' ' .. part[2]
    end
    return table.concat(text, ', ')
end

-- Startup loaders (this loader and Bingus Shared Loader) are listed by the
-- managers like any mod but can never be switched from inside the game. They
-- are recognised by what they are - a mod that replaces the game's startup
-- resource core/wwise/lua/wwise_flow_callbacks - with GUIDs, the MDL runtime
-- entry and names as fallbacks.
L.STARTUP_RESOURCE = 'core/wwise/lua/wwise_flow_callbacks'
L.LOADER_GUIDS = {['761188b2-c45b-4607-9241-f89ca221c47b'] = 'MDL', ['612eaf70-d682-43c7-9efd-16dcc695f977'] = 'BSL'}
function L.loader_kind(entry, startup_key)
    local name = tostring(entry.name or ''):lower()
    local guid = type(entry.guid) == 'string' and entry.guid:lower() or nil
    if entry.addon == 'mods/mdl/runtime' or guid and L.LOADER_GUIDS[guid] == 'MDL' or name:find('mod dynamic loader', 1, true) then
        return 'MDL'
    end
    if guid and L.LOADER_GUIDS[guid] then return L.LOADER_GUIDS[guid] end
    if name:find('bingus shared loader', 1, true) then return 'BSL' end
    if startup_key and entry.resources and entry.resources[startup_key] then return 'LOADER' end
    return nil
end

-- Name of the file the mod came from, shown under its name: the folder
-- Arsenal / HD2MM unpacked it into, without Arsenal's "_AR<number>" suffix
-- (Arsenal does not record the archive's extension).
function L.file_name(path, source)
    if type(path) ~= 'string' then return nil end
    local base = path:gsub('[/\\]+$', ''):match('([^/\\]+)$')
    if not base or base == '' then return nil end
    if source == 'Arsenal' then base = base:gsub('_AR%d+$', '') end
    return base
end

-- Fingerprint of a script mod's Lua resources (names and bodies). Changes
-- when a new version of the mod is imported; used to reload running addons.
function L.fingerprint(resources)
    if type(resources) ~= 'table' then return nil end
    local keys = {}
    for key in pairs(resources) do keys[#keys + 1] = key end
    if #keys == 0 then return nil end
    table.sort(keys)
    local byte, a, b, total = string.byte, 1, 0, 0
    local function feed(text)
        for i = 1, #text do
            a = (a + byte(text, i)) % 65521
            b = (b + a) % 65521
        end
        total = total + #text
    end
    for _, key in ipairs(keys) do feed(key); feed(resources[key]) end
    return string.format('%d:%d:%08x', #keys, total, b * 65536 + a)
end

-- options = {platform=, json=, log=, arsenal_dir=, hd2mm_dir=, game_dir=, hash=}
-- Days since 1970-01-01 for a civil date (proleptic Gregorian).
local function days_from_civil(y, m, d)
    y = m <= 2 and y - 1 or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end
L.days_from_civil = days_from_civil

-- "2026-10-03T18:24:41.641Z" (UTC; an offset like +02:00 is applied) ->
-- seconds since 1970, or nil.
function L.iso_time(text)
    if type(text) ~= 'string' then return nil end
    local y, mo, d, h, mi, sec, rest = text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)(.*)$')
    if not y then
        y, mo, d = text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
        if not y then return nil end
        h, mi, sec, rest = 0, 0, 0, ''
    end
    local t = days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400 + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(sec) or 0)
    local sign, oh, om = tostring(rest):match('([%+%-])(%d%d):?(%d%d)$')
    if sign then
        local offset = tonumber(oh) * 3600 + tonumber(om) * 60
        t = sign == '+' and t - offset or t + offset
    end
    return t
end

-- Windows FILETIME (100 ns since 1601) -> seconds since 1970; values that
-- are already small pass through; 0 / nil -> nil.
function L.unix_time(value)
    value = tonumber(value)
    if not value or value <= 0 then return nil end
    if value > 1e15 then return math.floor(value / 1e7 - 11644473600) end
    return value
end

-- Seconds since 1970 -> "YYYY-MM-DD HH:MM" in local time (os.date), or UTC
-- computed here when os.date is missing.
function L.format_time(t)
    if not t then return nil end
    if os and os.date then
        local ok, text = pcall(os.date, '%Y-%m-%d %H:%M', math.floor(t))
        if ok and type(text) == 'string' then return text end
    end
    local days = math.floor(t / 86400)
    local seconds = t - days * 86400
    local z = days + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    local y = yoe + era * 400 + (m <= 2 and 1 or 0)
    return string.format('%04d-%02d-%02d %02d:%02d', y, m, d, math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

function L.new(options)
    local platform, json = options.platform, options.json
    local self = {entries = {}, sources = {}, errors = {}}
    -- Body of a Lua resource of `entry` by resource name, or nil.
    self.format_time = L.format_time
    function self.resolve(entry, name)
        if not entry.resources or not options.hash then return nil end
        return entry.resources[options.hash(name)]
    end
    local function log(line) if options.log then pcall(options.log, 'library: ' .. line) end end

    local function normalize(path)
        return path and (tostring(path):gsub('\\', '/')) or nil
    end

    local function read_json(path)
        local text = platform.read(path)
        if not text then return nil end
        local ok, value = pcall(json.decode, text)
        if ok then return value end
        self.errors[#self.errors + 1] = path .. ': ' .. tostring(value)
    end

    -- Merge content types of every patch archive below a mod folder. stats
    -- collects the newest file time and the size of all patch files
    -- (.patch_N, .gpu_resources, .stream).
    local function scan_types(directory, depth, merged, stats)
        merged = merged or {}
        local found = false
        for _, entry in ipairs(platform.list(directory)) do
            if not entry.dir and stats and entry.name:match('^%x+%.patch_%d+') then
                stats.bytes = stats.bytes + (tonumber(entry.size) or 0)
                stats.newest = math.max(stats.newest, tonumber(entry.mtime) or 0)
            end
            if entry.dir then
                if depth < 3 then
                    local _, sub = scan_types(directory .. '/' .. entry.name, depth + 1, merged, stats)
                    found = found or sub
                end
            elseif entry.name:match('^%x+%.patch_%d+$') then
                local head = platform.read_head(directory .. '/' .. entry.name, 72 + 32 * 64)
                local types = L.patch_types(head)
                if types then
                    found = true
                    for name, count in pairs(types) do merged[name] = (merged[name] or 0) + count end
                end
            end
        end
        return merged, found
    end

    -- Collect Lua resources from every patch below a script mod folder and
    -- find its declared addon entry (the name addon discovery would start).
    local function collect_scripts(directory, depth, resources)
        for _, entry in ipairs(platform.list(directory)) do
            if entry.dir then
                if depth < 3 then collect_scripts(directory .. '/' .. entry.name, depth + 1, resources) end
            elseif entry.name:match('^%x+%.patch_%d+$') and (entry.size or 0) <= 16777216 then
                local found = L.lua_resources(platform.read(directory .. '/' .. entry.name, 16777216))
                for key, body in pairs(found or {}) do
                    if resources[key] == nil then resources[key] = body end
                end
            end
        end
        return resources
    end

    local function finish(entry)
        if entry.path then
            local stats = {bytes = 0, newest = 0}
            local types, found = scan_types(entry.path, 0, nil, stats)
            entry.types = found and types or nil
            entry.bytes = stats.bytes > 0 and stats.bytes or nil
            -- Update time: Arsenal's addedAt (set again when a mod is
            -- updated), else the newest patch file.
            entry.updated = entry.updated or L.unix_time(stats.newest)
        end
        entry.category = L.category(entry.types)
        entry.file = L.file_name(entry.path, entry.source)
        if entry.path and entry.types and entry.types.lua and options.hash then
            local ok, resources = pcall(collect_scripts, entry.path, 0, {})
            if ok then
                entry.resources = resources
                entry.stamp = L.fingerprint(resources)
                for key, body in pairs(resources) do
                    local name = L.declaration(body)
                    if name and options.hash(name) == key then entry.addon = name break end
                end
            end
        end
        entry.loader = L.loader_kind(entry, options.hash and options.hash(L.STARTUP_RESOURCE))
        if entry.loader then log('startup loader hidden from the list: ' .. entry.name .. ' (' .. entry.loader .. ')') end
        self.entries[#self.entries + 1] = entry
    end

    -- Arsenal keeps a profile's mods in modsList[profile].mods. Older entries
    -- carry the whole definition; newer ones (Arsenal's mod library, e.g. mods
    -- added while it runs) only hold uuid + state (enabled, deployed,
    -- optionsConfig) and the definition (path, label, options, ...) lives in
    -- data.modsLibrary. Both are merged by uuid.
    local DEFINITION = {'path', 'label', 'description', 'iconPath', 'options'}
    local function arsenal_library(data)
        local by_uuid = {}
        local library = data.modsLibrary
        if type(library) == 'table' then
            for key, mod in pairs(library) do
                if type(mod) == 'table' then
                    local uuid = mod.uuid or (type(key) == 'string' and key or nil)
                    if uuid then by_uuid[tostring(uuid):lower()] = mod end
                end
            end
        end
        return by_uuid
    end
    local function merge_arsenal(mod, by_uuid)
        local definition = mod.uuid and by_uuid[tostring(mod.uuid):lower()]
        if not definition then return mod, false end
        local merged = {}
        for key, value in pairs(definition) do merged[key] = value end
        for key, value in pairs(mod) do merged[key] = value end
        -- Definition fields the profile entry leaves out come from the library.
        for _, key in ipairs(DEFINITION) do
            if mod[key] == nil or mod[key] == json.null then merged[key] = definition[key] end
        end
        -- Option on/off state is kept per profile as optionsConfig {name, enabled}.
        if type(mod.optionsConfig) == 'table' and type(merged.options) == 'table' then
            local state = {}
            for _, item in ipairs(mod.optionsConfig) do
                if type(item) == 'table' and item.name ~= nil then state[tostring(item.name)] = item.enabled == true end
            end
            local options = {}
            for index, option in ipairs(merged.options) do
                if type(option) == 'table' then
                    local copy = {}
                    for key, value in pairs(option) do copy[key] = value end
                    if state[tostring(option.name)] ~= nil then copy.enabled = state[tostring(option.name)] end
                    options[index] = copy
                end
            end
            merged.options = options
        end
        return merged, true
    end

    local function scan_arsenal(root)
        local data = read_json(root .. '/hd2a_data.json')
        if type(data) ~= 'table' or type(data.modsList) ~= 'table' then return false end
        local profile_name = data.selectedProfile or 'default'
        local profile = data.modsList[profile_name]
        if type(profile) ~= 'table' or type(profile.mods) ~= 'table' then return false end
        self.sources[#self.sources + 1] = 'Arsenal (' .. tostring(profile.label or profile_name) .. ')'
        local by_uuid = arsenal_library(data)
        local merged_count = 0
        for index, raw in ipairs(profile.mods) do
            if type(raw) == 'table' then
                local mod, merged = merge_arsenal(raw, by_uuid)
                if merged then merged_count = merged_count + 1 end
                if type(mod.path) ~= 'string' then
                    log('Arsenal mod ' .. tostring(mod.uuid) .. ' has no definition yet (not in modsLibrary)')
                end
                local label = type(mod.label) == 'string' and mod.label ~= '' and mod.label or nil
                local entry = {
                    source = 'Arsenal', order = index,
                    id = 'arsenal:' .. tostring(mod.uuid or index),
                    guid = mod.uuid, name = tostring(label or mod.uuid or '?'),
                    description = type(mod.description) == 'string' and mod.description or nil,
                    icon = normalize(type(mod.iconPath) == 'string' and mod.iconPath or nil),
                    path = normalize(type(mod.path) == 'string' and mod.path or nil),
                    enabled = mod.enabled == true, deployed = mod.deployed == true,
                    changed = mod.changed == true, options = {},
                    updated = L.iso_time(mod.addedAt),
                }
                if type(mod.options) == 'table' then
                    for _, option in ipairs(mod.options) do
                        if type(option) == 'table' then
                            entry.options[#entry.options + 1] = {name = tostring(option.name or '?'), enabled = option.enabled == true,
                                icon = normalize(type(option.iconPath) == 'string' and option.iconPath or nil)}
                            if not entry.icon and entry.options[#entry.options].icon then entry.icon = entry.options[#entry.options].icon end
                        end
                    end
                end
                finish(entry)
            end
        end
        if merged_count > 0 then log(merged_count .. ' Arsenal mod(s) completed from modsLibrary') end
        return true
    end

    local function scan_hd2mm(root)
        local mods_dir = root .. '/Mods'
        local listing = platform.list(mods_dir)
        if #listing == 0 then return false end
        local state = {}
        local enabled = read_json(root .. '/enabled.json')
        if type(enabled) == 'table' then
            for _, item in ipairs(enabled) do
                if type(item) == 'table' and item.Guid then state[tostring(item.Guid):lower()] = item end
            end
        end
        local count = 0
        for _, folder in ipairs(listing) do
            if folder.dir then
                local path = mods_dir .. '/' .. folder.name
                local manifest = read_json(path .. '/manifest.json')
                if type(manifest) == 'table' then
                    count = count + 1
                    local guid = manifest.Guid and tostring(manifest.Guid):lower()
                    local saved = guid and state[guid]
                    local entry = {source = 'HD2MM', order = count, id = 'hd2mm:' .. tostring(guid or folder.name), guid = guid,
                        name = tostring(manifest.Name or folder.name),
                        description = type(manifest.Description) == 'string' and manifest.Description or nil,
                        icon = type(manifest.IconPath) == 'string' and path .. '/' .. normalize(manifest.IconPath) or nil,
                        path = path, enabled = saved and saved.Enabled == true or false, deployed = nil, options = {}}
                    if type(manifest.Options) == 'table' then
                        for index, option in ipairs(manifest.Options) do
                            local name = type(option) == 'table' and option.Name or option
                            local toggled = saved and type(saved.Toggled) == 'table' and saved.Toggled[index]
                            entry.options[#entry.options + 1] = {name = tostring(name),
                                enabled = toggled == nil and true or toggled == true,
                                icon = type(option) == 'table' and type(option.Image) == 'string' and path .. '/' .. normalize(option.Image) or nil}
                            if not entry.icon and entry.options[#entry.options].icon then entry.icon = entry.options[#entry.options].icon end
                        end
                    end
                    finish(entry)
                end
            end
        end
        if count > 0 then self.sources[#self.sources + 1] = 'HD2MM' end
        return count > 0
    end

    -- Deployed patch files in <game>/data, used to confirm what is live.
    local function deployed_patches()
        local game = options.game_dir
        if not game then return nil end
        local count = 0
        for _, entry in ipairs(platform.list(game .. '/data', '*.patch_*')) do
            if entry.name:match('^%x+%.patch_%d+$') then count = count + 1 end
        end
        return count
    end

    -- Cheap check for library changes (a mod imported, updated, removed or
    -- switched in Arsenal / HD2MM): sizes and times of the manager's files.
    function self.source_stamp()
        local parts = {}
        local function add(directory, pattern)
            if not directory then return end
            for _, item in ipairs(platform.list(directory, pattern)) do
                parts[#parts + 1] = item.name .. '=' .. tostring(item.size or 0) .. '@' .. tostring(item.mtime or 0)
            end
        end
        add(options.arsenal_dir, 'hd2a_data.json')
        if options.hd2mm_dir then
            add(options.hd2mm_dir, 'enabled.json')
            add(options.hd2mm_dir .. '/Mods')
        end
        return table.concat(parts, ';')
    end

    function self.scan()
        self.entries, self.sources, self.errors = {}, {}, {}
        local stamped, stamp = pcall(self.source_stamp)
        self.stamp = stamped and stamp or nil
        local ok, reason = pcall(function()
            local arsenal = options.arsenal_dir
            if arsenal then scan_arsenal(arsenal) end
            local hd2mm = options.hd2mm_dir
            if hd2mm then scan_hd2mm(hd2mm) end
            self.deployed_patch_files = deployed_patches()
        end)
        if not ok then self.errors[#self.errors + 1] = tostring(reason) end
        self.scanned = true
        self.revision = (self.revision or 0) + 1
        if options.on_scan then
            local synced, problem = pcall(options.on_scan, self)
            if not synced then self.errors[#self.errors + 1] = 'sync: ' .. tostring(problem) end
        end
        log(#self.entries .. ' entries from ' .. (#self.sources > 0 and table.concat(self.sources, ', ') or 'no manager')
            .. (#self.errors > 0 and ('; errors: ' .. table.concat(self.errors, '; ')) or ''))
        return self.entries
    end

    return self
end

return L
