local PLAIN_INDEX, PLAIN_PARTS
-- Resource Lab (debug): PackageLoader decode on bytes from the 2026-09-26
-- helldivers2.exe dump, package monitor over fake memory, home-bundle scan,
-- staging / unstaging in a fake data folder.
-- Usage: luajit tests/test_mdl_reslab.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local R, native_ui, manager_module = module('mdl_reslab'), module('mdl_native_ui'), module('mdl_manager')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- 1. Decode -------------------------------------------------------------------
local image = {}
local function place(rva, hex) for i = 1, #hex, 2 do image[rva + (i - 1) / 2] = tonumber(hex:sub(i, i + 1), 16) end end
place(0x320db0, '488b0d51f46e01488b8900040000e9ad272e00cc')
place(0x603570, '40574881ecc000000083b91832000000488bf90f84db00000048899c24d0000000488bcfe8f7fcffff8b871c3200003b87203200007455488d0c400f1084cf18020000488b8f080200000f11442420488b542420e8b7a400004885c0742e448b')
place(0x60da80, '48895c2408488974241048897c24188bb9800000004533d285ff7440488bb1880000000f1f4000660f1f8400000000004a8b1cd633c0448b4b184585c974154c8b5b204d8b04c3493950107421ffc041')
local function get(i) return image[i] or 0 end
local layout = R.decode_loader(get, 0x320db0)
check(layout.global == 0x1a10208 and layout.loader == 1024 and layout.drain == 0x603570, 'app global, loader offset, queue')
check(layout.set == 0x208 and layout.lookup == 0x60da80, 'package set and lookup')
check(layout.count == 0x80 and layout.array == 0x88 and layout.layer_count == 0x18 and layout.layers == 0x20 and layout.layer_hash == 0x10,
    'set/package/layer offsets')
-- A look-alike accessor (same shape, other target) is rejected.
place(0x500000, '488b0d00000000488b8900040000e9000000' .. '00cc')
check(not pcall(R.decode_loader, get, 0x500000), 'look-alike rejected')
local hits = native_ui.find_all(function(i) return get(0x320000 + i) end, 0x1000, R.LOADER_SIGNATURE, 8)
check(#hits == 1 and 0x320000 + hits[1] == 0x320db0, 'signature found by the scanner')

-- 2. Archive tables -------------------------------------------------------------
local function le(value, bytes)
    local out = {}
    for _ = 1, bytes do out[#out + 1] = string.char(value % 256); value = math.floor(value / 256) end
    return table.concat(out)
end
local function raw8(hex) -- value hex -> stored little-endian bytes
    local out = {}
    for i = 15, 1, -2 do out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16)) end
    return table.concat(out)
end
local UNIT, TEXTURE = 'e0a48d0be9a7453f', 'cd4238c6a0c69e32'
local function archive(rows)
    local types = {[UNIT] = 0, [TEXTURE] = 0}
    for _, row in ipairs(rows) do types[row[1]] = (types[row[1]] or 0) + 1 end
    local type_list = {}
    for t in pairs(types) do type_list[#type_list + 1] = t end
    table.sort(type_list)
    local parts = {le(0xF0000011, 4), le(#type_list, 4), le(#rows, 4), string.rep('\0', 60)}
    for _, t in ipairs(type_list) do parts[#parts + 1] = le(0, 8) .. raw8(t) .. le(types[t], 8) .. le(16, 4) .. le(64, 4) end
    for _, row in ipairs(rows) do parts[#parts + 1] = raw8(row[2]) .. raw8(row[1]) .. string.rep('\0', 48) .. le(row[3] or 0, 4) .. string.rep('\0', 12) end
    return table.concat(parts) .. 'DATA'
end
local mod_archive = archive({{UNIT, '16474112801385b6', 40 * 1048576}, {TEXTURE, '1111111111111111'}, {TEXTURE, '2222222222222222'}, {UNIT, '9999999999999999'}})
local toc = R.parse_toc(mod_archive)
check(toc and toc.count == 4 and toc.entries[1].type == UNIT and toc.entries[1].name == '16474112801385b6', 'table of contents parsed')
check(toc.entries[1].gpu_size == 40 * 1048576 and toc.entries[2].gpu_size == 0, 'GPU sizes from the table rows')
check(R.toc_size(mod_archive:sub(1, 72)) == 72 + 32 * 2 + 80 * 4, 'table size from the header')
check(not R.parse_toc('junk' .. string.rep('\0', 80)), 'non-archive refused')

-- 3. Fake platform: files + memory ------------------------------------------------
local files, memory = {}, {}
local copies, deletes, locked = 0, 0, {}
local platform = {mkdir = function() return true end}
function platform.read(path, limit)
    local data = files[path]
    if not data then return nil end
    return limit and data:sub(1, limit) or data
end
platform.read_head = platform.read
local opened = {}
function platform.open_reader(path)
    if not files[path] then return nil, 2 end
    opened[path] = (opened[path] or 0) + 1
    return {read_at = function(offset, count) return files[path]:sub(offset + 1, offset + count) end,
        size = function() return #files[path] end, close = function() opened[path] = opened[path] - 1 end}
end
function platform.write(path, data) files[path] = data return true end
function platform.list(dir, pattern)
    local out, seen = {}, {}
    local prefix = dir .. '/'
    local glob = pattern and ('^' .. pattern:gsub('%.', '%%.'):gsub('%*', '.*') .. '$')
    for path in pairs(files) do
        if path:sub(1, #prefix) == prefix then
            local rest = path:sub(#prefix + 1)
            local name, deeper = rest:match('^([^/]+)(/?)')
            if name and not seen[name] and (not glob or name:match(glob)) then
                seen[name] = true
                out[#out + 1] = {name = name, dir = deeper == '/', size = deeper == '/' and 0 or #files[path], mtime = 0}
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end
function platform.copy_file(from, to)
    if files[to] or not files[from] then return false, 80 end
    files[to] = files[from]; copies = copies + 1
    return true
end
function platform.delete_file(path)
    if locked[path] then return false, 32 end
    if not files[path] then return false, 2 end
    files[path] = nil; deletes = deletes + 1
    return true
end
function platform.mem_read(address, size)
    local out = {}
    for i = 0, size - 1 do
        local b = memory[address + i]
        if b == nil then return nil end
        out[#out + 1] = string.char(b)
    end
    return table.concat(out)
end
local function put(address, value, size) for i = 0, size - 1 do memory[address + i] = math.floor(value / 256 ^ i) % 256 end end
local function puts(address, text) for i = 1, #text do memory[address + i - 1] = text:byte(i) end memory[address + #text] = 0 end

-- Engine structures: app -> loader -> set -> packages -> layers -> archive -> name.
local BASE, APP, LOADER, SET, ARRAY = 0x7FF700000000, 0x10000000, 0x11000000, 0x12000000, 0x13000000
put(BASE + layout.global, APP, 8)
put(APP + layout.loader, LOADER, 8)
put(LOADER + layout.set, SET, 8)
local next_block = 0x20000000
local function make_package(hash, layer_names)
    local package = next_block; next_block = next_block + 0x10000
    local layers = package + 0x1000
    put(package + 16, tonumber(hash:sub(9), 16), 4); put(package + 20, tonumber(hash:sub(1, 8), 16), 4)
    put(package + layout.layer_count, #layer_names, 4)
    put(package + layout.layers, layers, 8)
    for i, name in ipairs(layer_names) do
        local layer = package + 0x2000 + 0x400 * i
        local archive_object = layer + 0x200
        put(layers + 8 * (i - 1), layer, 8)
        put(layer + 28, 4, 4)
        put(layer + R.LAYER_ARCHIVE, archive_object, 8)
        put(archive_object + R.ARCHIVE_NAME, archive_object + 0x100, 8)
        puts(archive_object + 0x100, name)
    end
    return package
end
local function set_packages(list)
    put(SET + layout.count, #list, 4)
    put(SET + layout.array, ARRAY, 8)
    for i, package in ipairs(list) do put(ARRAY + 8 * (i - 1), package, 8) end
end
local BOOT = R.BOOT_BUNDLE
-- Layer order as in the game: highest patch first, base last.
local boot = make_package(BOOT, {BOOT .. '.patch_1', BOOT .. '.patch_0', BOOT})
local ship = make_package('aaaaaaaaaaaaaaaa', {'aaaaaaaaaaaaaaaa'})
set_packages({boot, ship})

-- LZ4 + DSAR ----------------------------------------------------------------------
local ffi = require('ffi')
-- Greedy LZ4 block compressor (test only): 4-byte hash matches, overlapping allowed.
local function lz4(data)
    local out, seen, i, anchor, n = {}, {}, 1, 1, #data
    local function length(value)
        while value >= 255 do out[#out + 1] = string.char(255); value = value - 255 end
        out[#out + 1] = string.char(value)
    end
    local function sequence(literal_end, offset, match)
        local literal = literal_end - anchor
        local token = (literal >= 15 and 15 or literal) * 16 + (match and (match - 4 >= 15 and 15 or match - 4) or 0)
        out[#out + 1] = string.char(token)
        if literal >= 15 then length(literal - 15) end
        out[#out + 1] = data:sub(anchor, literal_end - 1)
        if match then
            out[#out + 1] = string.char(offset % 256, math.floor(offset / 256))
            if match - 4 >= 15 then length(match - 4 - 15) end
        end
    end
    while i <= n - 12 do
        local key = data:sub(i, i + 3)
        local candidate = seen[key]
        seen[key] = i
        if candidate and i - candidate < 65536 then
            local match = 4
            while i + match <= n - 5 and data:byte(candidate + match) == data:byte(i + match) do match = match + 1 end
            sequence(i, i - candidate, match)
            i = i + match
            anchor = i
        else
            i = i + 1
        end
    end
    sequence(n + 1)
    return table.concat(out)
end
local function lz4_roundtrip(text, need)
    local packed = lz4(text)
    local dst = ffi.new('uint8_t[?]', #text + 1)
    local produced = R.lz4_decode(ffi.cast('const uint8_t *', packed), #packed, dst, #text, need, ffi.copy)
    return produced and ffi.string(dst, produced), #packed
end
do
    local samples = {string.rep('a', 1000), ('abcabcabd'):rep(300) .. 'tail-literals', '', 'short',
        string.rep('0123456789abcdef', 2000) .. string.rep('x', 300)}
    local noise = {}
    for k = 1, 3000 do noise[k] = string.char((k * 7919 + k * k) % 251) end
    samples[#samples + 1] = table.concat(noise) .. table.concat(noise)
    for index, text in ipairs(samples) do
        local back, packed = lz4_roundtrip(text)
        check(back == text, 'LZ4 round trip ' .. index .. ' (' .. #text .. ' -> ' .. packed .. ' bytes)')
    end
    local text = string.rep('0123456789abcdef', 2000)
    local back = lz4_roundtrip(text, 100)
    check(back and #back >= 100 and #back < #text and back == text:sub(1, #back), 'LZ4 decoding stops early at the needed size')
    local dst = ffi.new('uint8_t[16]')
    check(not R.lz4_decode(ffi.cast('const uint8_t *', '\15\1\0'), 3, dst, 16, nil, ffi.copy), 'match before any output refused')
    -- Real 98-byte loose bundle from the 2026-10 install (DSAR, one LZ4 chunk -> 256 bytes).
    local hex = '44534152030001000100000040000000000100000000000050414444494e472a000000000000000040000000000000000001000022000000030254555555555557110000f0000100404d313ec508009f1d426081ab638a69000100c7500000000000'
    files['C:/real/0cf14e223de06a26'] = (hex:gsub('..', function(h) return string.char(tonumber(h, 16)) end))
    local store = assert(R.open_store(platform, ffi, 'C:/real/0cf14e223de06a26'))
    local plain = store.read(0, store.size)
    store.close()
    check(store.dsar and store.size == 256 and #plain == 256 and plain:sub(1, 4) == '\17\0\0\240', 'real DSAR bundle decodes to a bundle table')
    check(R.toc_size(plain) and R.parse_toc(plain), 'its table parses')
end
-- DSAR writer (test only): chunk_size bytes per chunk, LZ4 except every third chunk stored.
local function dsar(text, chunk_size)
    local rows, blobs, count = {}, {}, math.ceil(#text / chunk_size)
    local position = 32 + 32 * count
    for k = 0, count - 1 do
        local piece = text:sub(k * chunk_size + 1, (k + 1) * chunk_size)
        local codec = k % 3 == 2 and 0 or 3
        local blob = codec == 3 and lz4(piece) or piece
        rows[#rows + 1] = le(k * chunk_size, 8) .. le(position, 8) .. le(#piece, 4) .. le(#blob, 4) .. string.char(codec, 2) .. 'TUUUUU'
        blobs[#blobs + 1] = blob
        position = position + #blob
    end
    return 'DSAR\3\0\1\0' .. le(count, 4) .. le(32 + 32 * count, 4) .. le(#text, 8) .. 'PADDING*' .. table.concat(rows) .. table.concat(blobs)
end
do
    local text = ('chunked store contents '):rep(40)
    files['C:/real/store'] = dsar(text, 50)
    local store = R.open_store(platform, ffi, 'C:/real/store')
    check(store.read(0, #text) == text and store.read(45, 20) == text:sub(46, 65) and store.read(900, 500) == text:sub(901),
        'DSAR store: whole, across chunks, clipped at the end')
    store.close()
    files['C:/real/plain'] = 'plain file'
    store = R.open_store(platform, ffi, 'C:/real/plain')
    check(not store.dsar and store.read(6, 4) == 'file', 'plain files read as they are')
    store.close()
end

-- Game data folder: most bundles inside the NxStorage containers
-- (data/bundles.nxa index + data/bundles.NN.nxa parts), a few loose files.
-- The mod's resources live in bundles T1/T2 (containers) and boot (loose).
local GAME, DATA = 'C:/Game', 'C:/Game/data'
local T1, T2, JUNK = 'b1b1b1b1b1b1b1b1', 'b2b2b2b2b2b2b2b2', 'dddddddddddddddd'
-- Builds an index and two parts; every file over 100 bytes is split into two
-- chunks, the first in part 0, the second in part 1.
local function nxa(list)
    table.sort(list, function(a, b) return a[1] < b[1] end)
    local part_names = {'bundles.00.nxa', 'bundles.01.nxa'}
    local parts = {'PART0', 'PART1'}
    local strings, string_at = {}, {}
    local strings_start = 24 + 24 * #list + 4 * #part_names
    local cursor = strings_start
    local function add_string(text)
        string_at[text] = cursor
        strings[#strings + 1] = text .. '\0'
        cursor = cursor + #text + 1
    end
    for _, name in ipairs(part_names) do add_string(name) end
    for _, item in ipairs(list) do add_string('data/' .. item[1]) end
    local chunk_start = cursor
    local rows, chunk_rows = {}, {}
    for _, item in ipairs(list) do
        local data = item[2]
        local pieces = #data > 100 and {{0, data:sub(1, 60)}, {60, data:sub(61)}} or {{0, data}}
        local table_at = chunk_start + 16 * #chunk_rows
        for k, piece in ipairs(pieces) do
            local part = (#pieces == 2 and k == 2) and 2 or 1
            chunk_rows[#chunk_rows + 1] = le(piece[1], 8) .. le(#parts[part], 4) .. '\0\0\0' .. string.char(part - 1)
            parts[part] = parts[part] .. piece[2]
        end
        rows[#rows + 1] = le(#data, 8) .. le(string_at['data/' .. item[1]], 4) .. le(#pieces, 4) .. le(table_at, 8)
    end
    local offsets = {}
    for _, name in ipairs(part_names) do offsets[#offsets + 1] = le(string_at[name], 4) end
    local total = chunk_start + 16 * #chunk_rows
    local index = 'DSAA\1\0\1\0' .. le(total, 4) .. le(#part_names, 4) .. le(#list, 4) .. le(0, 4)
        .. table.concat(rows) .. table.concat(offsets) .. table.concat(strings) .. table.concat(chunk_rows)
    assert(#index == total)
    return index, part_names, parts
end
local T1_DATA = archive({{UNIT, '16474112801385b6'}, {TEXTURE, '1111111111111111'}, {UNIT, '0000000000000001'}})
do
    local index, part_names, parts = nxa({{T1, T1_DATA}, {T2, archive({{TEXTURE, '1111111111111111'}})},
        {T2 .. '.patch_0', archive({})},                 -- a game patch inside the containers: next index is 1
        {T1 .. '.stream', 'STREAMDATA'}, {JUNK, 'not a bundle table'}})
    -- Every game data file is a DSAR container; offsets in the index refer to decompressed data.
    files[DATA .. '/bundles.nxa'] = dsar(index, 64)
    PLAIN_INDEX = index
    for i, name in ipairs(part_names) do files[DATA .. '/' .. name] = dsar(parts[i], 37) end
    PLAIN_PARTS = parts
end
files[DATA .. '/' .. BOOT] = dsar(archive({{TEXTURE, '2222222222222222'}}), 100)
files[DATA .. '/' .. BOOT .. '.patch_0'] = archive({})
files[DATA .. '/' .. T1 .. '.patch_0'] = archive({})          -- someone else's loose patch: next index is 1
files[DATA .. '/cccccccccccccccc'] = dsar(archive({{UNIT, '0000000000000002'}}), 4096)
files[DATA .. '/cccccccccccccccc.stream'] = 'x'
-- Index parser and chunked reads (T1 is split over both parts).
do
    local index = assert(R.parse_nxa(PLAIN_INDEX))
    check(index.count == 5 and #index.parts == 2 and index.parts[2] == 'bundles.01.nxa', 'index header and part names')
    check(index.by_name[T1] and index.by_name[T1].size == #T1_DATA and index.by_name[T1].chunk_count == 2, 'file rows: size, chunks, name without folder')
    local function read_part(part, offset, count) return PLAIN_PARTS[part == 'bundles.00.nxa' and 1 or 2]:sub(offset + 1, offset + count) end
    check(R.nxa_read(index, index.by_name[T1], 0, #T1_DATA, read_part) == T1_DATA, 'whole file read across two parts')
    check(R.nxa_read(index, index.by_name[T1], 50, 20, read_part) == T1_DATA:sub(51, 70), 'read across the chunk boundary')
    check(R.nxa_read(index, index.by_name[T1], 70, 1000, read_part) == T1_DATA:sub(71), 'read clipped at the file end')
    check(not R.parse_nxa('short'), 'short index refused')
    check(not R.parse_nxa(string.rep('\255', 64)), 'implausible header refused')
end
-- The mod in the Arsenal library.
local MOD = 'C:/Arsenal/mods/Armor'
files[MOD .. '/Addon/9ba626afa44a3aa3.patch_0'] = mod_archive
files[MOD .. '/Addon/9ba626afa44a3aa3.patch_0.stream'] = 'STREAM'
files[MOD .. '/Addon/9ba626afa44a3aa3.patch_0.gpu_resources'] = 'GPU'
local entry = {id = 'arsenal:armor', name = 'Armor', path = MOD, category = 'RESOURCE', source = 'Arsenal', options = {}}

local t = 0
local monitor_on = true
local online = {}
local staging_calls = {}
local lab = R.new({platform = platform, clock = function() return t end, base_dir = 'C:/MDL', game_dir = GAME, monitor = function() return monitor_on end,
    serialize = manager_module.serialize, budget = 1, find_all = native_ui.find_all,
    can_get = function(type_hex, name_hex) return online[type_hex .. name_hex] == true end,
    call_set_staging = function(method, factory, size) staging_calls[#staging_calls + 1] = {method, factory, size}; return 0 end})

-- 4. Monitor --------------------------------------------------------------------
lab.step()   -- resolve job fails here (no helldivers2.exe): monitor stays off
check(not lab.resolved() and lab.status:find('unavailable'), 'resolve failure is reported: ' .. tostring(lab.status))
lab.use_layout({base = BASE, global = layout.global, loader = layout.loader, set = layout.set, count = layout.count,
    array = layout.array, layer_count = layout.layer_count, layers = layout.layers, layer_hash = layout.layer_hash})
t = 1; lab.step()
check(lab.status == 'ok' and #lab.packages == 2 and lab.boot and #lab.boot.layers == 3, 'packages read, boot resident with 2 patches')
check(lab.packages[1].layers[2].name == BOOT .. '.patch_0' and lab.packages[1].layers[2].state == 4, 'layer names and state')
check(#lab.events == 0 and lab.log_lines[#lab.log_lines]:find('2 packages loaded at first look'), 'first look logged')
local mission = make_package(T1, {T1 .. '.patch_0', T1})
set_packages({boot, ship, mission})
t = 1.2; lab.step()
check(#lab.events == 0, 'polled every 0.5 s only')
t = 1.6; lab.step()
check(#lab.events == 1 and lab.events[1].kind == 'load' and lab.events[1].text == T1 .. ' +patch 0', 'package load event with its patch layers')
check(lab.loaded_bundles[T1], 'loaded bundle set')
set_packages({boot, ship})
t = 2.2; lab.step()
check(#lab.events == 2 and lab.events[2].kind == 'unload' and lab.events[2].bundle == T1, 'unload event')
check(lab.dump() and lab.log_lines[#lab.log_lines]:find('aaaaaaaaaaaaaaaa'), 'package list dump')

-- 5. Home-bundle scan ---------------------------------------------------------------
local state = lab.state_of(entry)
check(#state.archives == 1 and state.archives[1].rel == 'Addon/9ba626afa44a3aa3.patch_0', 'mod patch file found')
check(lab.scan(entry), 'scan starts')
for _ = 1, 20 do t = t + 0.1; lab.step() end
local scan = state.scan
check(scan.state == 'done' and scan.total == 5, 'index bundles and loose bundles scanned (' .. tostring(scan.total) .. ')')
local lab_log = table.concat(lab.log_lines, '\n')
check(lab_log:find('bundles.nxa (DSAR, ', 1, true) and lab_log:find('5 files (3 bundles, 1 patches, 1 stream/gpu), 2 parts', 1, true), 'index summary logged')
check(lab_log:find('3 in bundles.nxa, 2 loose in data/', 1, true), 'sources logged')
check(lab_log:find('4 ok, 1 unreadable', 1, true) and lab_log:find('unreadable ' .. JUNK, 1, true), 'unreadable table reported')
check(opened[DATA .. '/bundles.00.nxa'] == 0 and opened[DATA .. '/bundles.01.nxa'] == 0, 'part readers closed after the scan')
check(scan.replaced == 2 and scan.boot_only == 1 and scan.new == 1, 'resources classified: 2 replace, 1 boot-only, 1 new')
check(scan.largest and scan.largest.name == '16474112801385b6' and lab_log:find('largest GPU resource: unit 16474112801385b6 40.0 MB', 1, true),
    'largest GPU resource reported')
check(#scan.targets == 2 and scan.targets[1].bundle == T1 and scan.targets[1].hits == 2 and scan.targets[2].bundle == T2,
    'targets exclude boot, sorted by resource count')

-- 6. Staging ---------------------------------------------------------------------
local ok, message = lab.stage(entry)
check(not ok and message:find('new to the game') and copies == 0, 'new resources need a second click')
ok, message = lab.stage(entry, true)
check(ok and copies == 6, 'staged: ' .. tostring(message) .. ' (' .. copies .. ' copies)')
check(files[DATA .. '/' .. T1 .. '.patch_1'] == mod_archive and files[DATA .. '/' .. T1 .. '.patch_1.stream'] == 'STREAM'
    and files[DATA .. '/' .. T1 .. '.patch_1.gpu_resources'] == 'GPU', 'T1 gets the next free index (.patch_1) with stream and gpu files')
check(files[DATA .. '/' .. T2 .. '.patch_1'] == mod_archive and not files[DATA .. '/' .. T2 .. '.patch_0'],
    'T2 gets .patch_1 (its .patch_0 is inside the containers)')
check(not files[DATA .. '/' .. BOOT .. '.patch_2'], 'boot bundle never staged')
check(files['C:/MDL/ResourceLab/staged.lua']:find('armor', 1, true), 'staged record saved')
check(not lab.stage(entry, true), 'no double staging')
-- The staged patch mounts on the next load of T1.
local mission2 = make_package(T1, {T1 .. '.patch_1', T1 .. '.patch_0', T1})
set_packages({boot, ship, mission2})
t = t + 1; lab.step()
local mounted = false
for _, line in ipairs(lab.log_lines) do if line:find(T1 .. '.patch_1 MOUNTED', 1, true) then mounted = true end end
check(mounted, 'monitor reports the staged patch as mounted (bundle name from a patch-first layer list)')
-- Online check 3 s after the mount.
online[UNIT .. '16474112801385b6'] = true
t = t + 1; lab.step(); t = t + 2.5; lab.step()
local online_log = table.concat(lab.log_lines, '\n')
check(online_log:find('online check (' .. T1 .. ' loaded): Armor 1/4 online', 1, true)
    and online_log:find('unit      16474112801385b6  online  (gpu 40.0 MB)', 1, true)
    and online_log:find('texture   1111111111111111  OFFLINE', 1, true), 'per-resource online status logged after the mount')
check(lab.log_online(lab.staged['arsenal:armor'], 'manual'), 'manual online log')
do
    local saved = lab.staged['arsenal:armor'].resources
    lab.staged['arsenal:armor'].resources = nil   -- record written by 1.5.3
    check(lab.log_online(lab.staged['arsenal:armor'], 'manual') and #lab.staged['arsenal:armor'].resources == #saved,
        'resource list rebuilt from the staged copy for older records')
end
-- can_get based online count.
online[UNIT .. '16474112801385b6'] = true; online[TEXTURE .. '1111111111111111'] = true
local status = lab.online(entry)
check(status.online == 2 and status.total == 4, 'online resources counted')
-- A new lab instance (next session) remembers the staged mod.
local lab2 = R.new({platform = platform, clock = function() return t end, base_dir = 'C:/MDL', game_dir = GAME, monitor = function() return monitor_on end,
    serialize = manager_module.serialize, find_all = native_ui.find_all})
check(lab2.staged['arsenal:armor'] and #lab2.staged['arsenal:armor'].files == 2, 'staged record reloaded')
check(lab2.log_lines[1]:find('still staged'), 'reminder about staged files')
do
    local saved = files[DATA .. '/' .. T2 .. '.patch_1']
    files[DATA .. '/' .. T2 .. '.patch_1'] = nil   -- a Deploy removed one copy
    local lab3 = R.new({platform = platform, clock = function() return t end, base_dir = 'C:/MDL', game_dir = GAME, monitor = function() return monitor_on end,
        serialize = manager_module.serialize, find_all = native_ui.find_all})
    local record = lab3.staged['arsenal:armor']
    check(record.missing and table.concat(lab3.log_lines, '\n'):find(T2 .. '.patch_1 is MISSING', 1, true), 'missing staged copy detected at start')
    files[DATA .. '/' .. T2 .. '.patch_1'] = saved
end

-- 6b. DirectStorage staging buffer -------------------------------------------------
do
    check(not lab.staging(), 'staging tools off until the accessor is located')
    local STORAGE, COMMANDS, NXLOADER, IMPL, FACTORY, VTABLE = 0x1b135b0, 0x14000000, 0x14100000, 0x14200000, 0x14300000, 0x14400000
    local DS = 0x7FFA00000000
    put(BASE + STORAGE, COMMANDS, 8); put(COMMANDS + 0xD0, NXLOADER, 8); put(NXLOADER + 48, IMPL, 8)
    put(IMPL + 136, FACTORY, 8); put(IMPL + 336, 0x2000000, 4); memory[IMPL + 152] = 1
    put(FACTORY, VTABLE, 8); put(VTABLE + 8 * 7, DS + 0x1234, 8)
    put(DS + 0x3c, 0x80, 4); put(DS + 0x80 + 24 + 56, 0x100000, 4)
    platform.module = function(name) if name == 'dstorage.dll' then return DS end end
    function platform.mem_write(address, bytes) for i = 1, #bytes do memory[address + i - 1] = bytes:byte(i) end return true end
    lab.use_layout({base = BASE, global = layout.global, loader = layout.loader, set = layout.set, count = layout.count,
        array = layout.array, layer_count = layout.layer_count, layers = layout.layers, layer_hash = layout.layer_hash}, STORAGE)
    local info = lab.staging()
    check(info and info.size == 0x2000000 and info.factory == FACTORY and info.method == DS + 0x1234 and info.ready, 'staging buffer and factory read')
    put(VTABLE + 8 * 7, 0x7FFB00000000, 8)
    local _, why = lab.staging()
    check(not lab.set_staging(64 * 1048576) and tostring(why):find('not recognised'), 'method outside dstorage refused')
    put(VTABLE + 8 * 7, DS + 0x1234, 8)
    local ok_set, text = lab.set_staging(64 * 1048576)
    check(ok_set and #staging_calls == 1 and staging_calls[1][1] == DS + 0x1234 and staging_calls[1][2] == FACTORY
        and staging_calls[1][3] == 64 * 1048576, 'SetStagingBufferSize called on the factory: ' .. tostring(text))
    check(lab.staging().size == 64 * 1048576, 'loader copy of the size updated')
end

-- 7. Unstaging --------------------------------------------------------------------
locked[DATA .. '/' .. T1 .. '.patch_1'] = true
ok, message = lab.unstage('arsenal:armor')
check(not ok and not files[DATA .. '/' .. T2 .. '.patch_1'] and files[DATA .. '/' .. T1 .. '.patch_1'], 'locked file kept, others removed')
check(lab.staged['arsenal:armor'] and #lab.staged['arsenal:armor'].files == 1, 'record keeps only what is left')
locked[DATA .. '/' .. T1 .. '.patch_1'] = nil
files[DATA .. '/' .. T1 .. '.patch_2'] = archive({})
ok = lab.unstage('arsenal:armor')
check(not ok and files[DATA .. '/' .. T1 .. '.patch_1'], 'kept when a later patch exists (numbering)')
files[DATA .. '/' .. T1 .. '.patch_2'] = nil
ok, message = lab.unstage('arsenal:armor')
check(ok and not files[DATA .. '/' .. T1 .. '.patch_1'] and not files[DATA .. '/' .. T1 .. '.patch_1.stream']
    and not lab.staged['arsenal:armor'], 'unstaged completely: ' .. tostring(message))
check(files[DATA .. '/' .. T1 .. '.patch_0'], 'the other tool\'s patch is untouched')


-- 8. Panel pages ------------------------------------------------------------------
do
    local panel_module = module('mdl_panel')
    local mfiles = {}
    local fs = {mkdir = function() return true end, read = function(p) return mfiles[p] end, read_head = function() return nil end,
        write = function(p, d) mfiles[p] = d return true end, list = function() return {} end}
    local m = manager_module.new({base_dir = 'C:/T', platform = fs, globals = _G})
    m.start()
    local library = {scanned = true, sources = {'Arsenal'}, entries = {entry}, scan = function() end, describe_types = function() return '' end}
    local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
        held = function() return false end, wheel = function() return 0 end}
    local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}
    local panel = panel_module.new(m, input, renderer, {library = library, lab = lab, menu_probe = function() return true end})
    local function find(label) for _, row in ipairs(panel.rows()) do if row.label == label then return row end end end
    panel.frame()
    find('Resource Lab (debug)').open()
    check(panel.page == 'lab', 'lab page from the main list')
    local found_monitor = false
    for _, row in ipairs(panel.rows()) do if row.label == 'Loaded packages' and row.value == '3' then found_monitor = true end end
    check(found_monitor, 'lab page shows the monitor')
    panel.frame()
    -- Library detail page -> mod lab page.
    panel.page, panel.target = 'library', entry
    local link = find('Resource Lab (debug)')
    check(link, 'resource mod detail page links its lab page')
    link.open()
    check(panel.page == 'labmod' and panel.target == entry, 'mod lab page')
    find('Find the game bundles that contain these resources').open()
    for _ = 1, 20 do t = t + 0.1; lab.step() end
    local stage = find('Stage into 2 bundle(s)')
    check(stage and stage.value == 'STAGE', 'stage row after the scan')
    stage.open()
    stage = find('Stage into 2 bundle(s)')
    check(stage.value == 'CONFIRM' and panel.flash_text:find('new to the game'), 'first click asks for confirmation')
    stage.open()
    check(lab.staged['arsenal:armor'] and find('Unstage (remove the copies)'), 'second click stages')
    find('Unstage (remove the copies)').open()
    check(not lab.staged['arsenal:armor'], 'unstaged from the page')
    panel.frame()
    check(panel.draw_status == 'visible', 'lab pages draw')
end

-- 9. Live switch (player builds) ------------------------------------------------------
do
    platform.move_file = function(from, to)
        if not files[from] or files[to] then return false, 183 end
        files[to], files[from] = files[from], nil
        return true
    end
    local function live_lab()
        local made = R.new({platform = platform, clock = function() return t end, base_dir = 'C:/MDL', game_dir = GAME, monitor = function() return monitor_on end,
            serialize = manager_module.serialize, budget = 1, find_all = native_ui.find_all, verbose = false,
            experimental = false, auto_reapply = true, log_name = 'MDL-LiveResources.log'})
        made.use_layout({base = BASE, global = layout.global, loader = layout.loader, set = layout.set, count = layout.count,
            array = layout.array, layer_count = layout.layer_count, layers = layout.layers, layer_hash = layout.layer_hash})
        return made
    end
    set_packages({boot, ship})
    check(files['C:/MDL/ResourceLab/scans.lua'] and files['C:/MDL/ResourceLab/scans.lua']:find('arsenal:armor', 1, true), 'scan results cached on disk')
    files['C:/MDL/ResourceLab/scans.lua'] = nil   -- start without a cache
    local live = live_lab()
    t = t + 1; live.step()
    check(live.live_state(entry).state == 'off' and not live.staging(), 'live: off, no DirectStorage tools in player builds')
    local ok, key = live.live_toggle(entry)
    check(ok and key == 'live.scanning' and live.live_state(entry).state == 'scanning', 'live: first switch-on scans')
    for _ = 1, 20 do t = t + 0.1; live.step() end
    local st = live.live_state(entry)
    check(st.state == 'on' and #st.bundles == 2 and st.active == 0, 'live: staged automatically after the scan (new resources included)')
    check(files[DATA .. '/' .. T1 .. '.patch_1'] and files[DATA .. '/' .. T2 .. '.patch_1'], 'live: copies in data/')
    check(not table.concat(live.log_lines, '\n'):find('gpu ', 1, true), 'live: quiet log (no per-resource scan lines)')
    check(files['C:/MDL/Logs/MDL-LiveResources.log'], 'live: own log file')
    -- Second mod into the same bundles; then the first one is switched off: the second moves down.
    local MOD2 = 'C:/Arsenal/mods/Paint'
    files[MOD2 .. '/9ba626afa44a3aa3.patch_0'] = archive({{TEXTURE, '1111111111111111'}})
    local entry2 = {id = 'arsenal:paint', name = 'Paint', path = MOD2, category = 'RESOURCE', source = 'Arsenal', options = {}}
    live.live_toggle(entry2)
    for _ = 1, 20 do t = t + 0.1; live.step() end
    check(live.staged['arsenal:paint'] and files[DATA .. '/' .. T1 .. '.patch_2'] and files[DATA .. '/' .. T2 .. '.patch_2'],
        'live: second mod takes the next numbers')
    ok, key = live.live_toggle(entry)
    check(ok and key == 'live.off' and not live.staged['arsenal:armor'], 'live: switched off')
    check(files[DATA .. '/' .. T1 .. '.patch_1'] == files[MOD2 .. '/9ba626afa44a3aa3.patch_0'] and not files[DATA .. '/' .. T1 .. '.patch_2']
        and live.staged['arsenal:paint'].files[1].index == 1, 'live: later MDL patch renumbered down (no gap)')
    check(files[DATA .. '/' .. T1 .. '.patch_0'], 'live: the foreign patch_0 is untouched')
    -- Switching off while the package is loaded waits for the unload.
    local mission3 = make_package(T1, {T1 .. '.patch_1', T1 .. '.patch_0', T1})
    set_packages({boot, ship, mission3})
    t = t + 1; live.step()
    st = live.live_state(entry2)
    check(st.state == 'on' and st.active == 1, 'live: active in the loaded package')
    ok, key = live.live_toggle(entry2)
    check(ok and key == 'live.off_pending' and live.live_state(entry2).state == 'turning_off' and files[DATA .. '/' .. T1 .. '.patch_1'],
        'live: switch-off while loaded is deferred')
    set_packages({boot, ship})
    t = t + 1; live.step()
    check(not live.staged['arsenal:paint'] and not files[DATA .. '/' .. T1 .. '.patch_1'], 'live: removed after the package unloaded')
    -- Cached scan: switching on again needs no scan.
    local live2 = live_lab()
    check(live2.state_of(entry).scan.cached and live2.state_of(entry).scan.state == 'done', 'live: scan result cached across sessions')
    ok, key = live2.live_toggle(entry)
    check(ok and key == 'live.on' and live2.staged['arsenal:armor'], 'live: immediate switch-on from the cache')
    -- A Deploy removed the copies: re-applied at the next start.
    files[DATA .. '/' .. T1 .. '.patch_1'], files[DATA .. '/' .. T1 .. '.patch_1.gpu_resources'] = nil, nil
    local live3 = live_lab()
    check(files[DATA .. '/' .. T1 .. '.patch_1'] == mod_archive and files[DATA .. '/' .. T1 .. '.patch_1.gpu_resources'] == 'GPU'
        and not live3.staged['arsenal:armor'].missing, 'live: copies re-applied after a Deploy')
    -- Deployed by the manager: the live copies go away.
    entry.deployed = true
    live3.reconcile({entry})
    entry.deployed = nil
    check(not live3.staged['arsenal:armor'] and not files[DATA .. '/' .. T1 .. '.patch_1'], 'live: removed when the manager deploys the mod')
    -- A deployed mod in packages/boot that replaces the same unit wins: reported as a conflict.
    do
        local turret_patch = archive({{UNIT, '16474112801385b6'}, {UNIT, '3333333333333333'}})
        files[DATA .. '/' .. BOOT .. '.patch_1'] = turret_patch
        files['C:/Arsenal/mods/Turret/Addon/9ba626afa44a3aa3.patch_0'] = turret_patch
        local turret = {id = 'arsenal:turret', name = 'Advanced Tank Turret', path = 'C:/Arsenal/mods/Turret', category = 'MIXED',
            source = 'Arsenal', options = {}, deployed = true}
        local okc, keyc = live3.live_toggle(entry, {turret, entry})
        local conflicts = live3.conflicts(entry, {turret, entry})
        check(okc and keyc == 'live.on_conflict' and #conflicts == 1 and conflicts[1].owner == 'Advanced Tank Turret'
            and conflicts[1].count == 1 and conflicts[1].patch == BOOT .. '.patch_1', 'live: conflict with a deployed boot patch found')
        check(table.concat(live3.log_lines, '\n'):find('conflict: Advanced Tank Turret (packages/boot patch_1, deployed at start) also replaces 1 of these resources; its version wins: unit 16474112801385b6', 1, true),
            'live: conflict logged')
        live3.live_toggle(entry, {turret, entry})
        check(not live3.staged['arsenal:armor'], 'live: switched off again')
        files[DATA .. '/' .. BOOT .. '.patch_1'] = nil
    end
    -- A mod whose resources exist only in packages/boot cannot go live.
    local MOD3 = 'C:/Arsenal/mods/BootOnly'
    files[MOD3 .. '/9ba626afa44a3aa3.patch_0'] = archive({{TEXTURE, '2222222222222222'}})
    local entry3 = {id = 'arsenal:bootonly', name = 'BootOnly', path = MOD3, category = 'RESOURCE', source = 'Arsenal', options = {}}
    live3.live_toggle(entry3)
    for _ = 1, 20 do t = t + 0.1; live3.step() end
    st = live3.live_state(entry3)
    check(st.state == 'unavailable' and st.message == 'live.unavailable' and not live3.staged['arsenal:bootonly'], 'live: boot-only mod unavailable')
    -- MIXED mods (1.8.3): script + assets that replace reloadable game assets go live;
    -- the script part is started / stopped through on_live.
    do
        local LUA = 'a14e8dfa2cd117e2'
        local events = {}
        local live4 = R.new({platform = platform, clock = function() return t end, base_dir = 'C:/MDL', game_dir = GAME,
            serialize = manager_module.serialize, budget = 1, find_all = native_ui.find_all, verbose = false,
            experimental = false, auto_reapply = true, log_name = 'MDL-LiveResources.log',
            on_live = function(e, on) events[#events + 1] = e.id .. '=' .. tostring(on) end})
        live4.use_layout({base = BASE, global = layout.global, loader = layout.loader, set = layout.set, count = layout.count,
            array = layout.array, layer_count = layout.layer_count, layers = layout.layers, layer_hash = layout.layer_hash})
        local function mixed(id, rows_list, addon)
            local path = 'C:/Arsenal/mods/' .. id
            for i, rows in ipairs(rows_list) do files[path .. '/9ba626afa44a3aa3.patch_' .. (i - 1)] = archive(rows) end
            return {id = 'arsenal:' .. id, name = id, path = path, category = 'MIXED', source = 'Arsenal', options = {}, addon = addon}
        end
        local good = mixed('MixGood', {{{LUA, 'aaaaaaaaaaaaaaaa'}, {UNIT, '16474112801385b6'}}}, 'mods/test/mixgood')
        check(live4.live_state(good).state == 'off' and not live4.live_state(good).reason and live4.live_state(good).mixed, 'mixed: candidate before the scan')
        local okm, keym = live4.live_toggle(good)
        check(okm and keym == 'live.scanning', 'mixed: switch-on scans')
        for _ = 1, 20 do t = t + 0.1; live4.step() end
        local sm = live4.live_state(good)
        check(sm.state == 'on' and #sm.bundles >= 1 and table.concat(events, ',') == 'arsenal:MixGood=true',
            'mixed: assets staged, script started: ' .. table.concat(events, ','))
        check(live4.state_of(good).scan.scripts == 1 and live4.state_of(good).scan.new == 0, 'mixed: Lua rows are not counted as new assets')
        okm, keym = live4.live_toggle(good)
        check(okm and events[#events] == 'arsenal:MixGood=false' and not live4.staged['arsenal:MixGood'], 'mixed: switch-off stops the script')
        -- Lua part without an addon declaration: launch only, no scan.
        local plain = mixed('MixPlain', {{{LUA, 'bbbbbbbbbbbbbbbb'}, {UNIT, '16474112801385b6'}}}, nil)
        check(live4.live_state(plain).state == 'unavailable' and live4.live_state(plain).reason == 'no_addon', 'mixed: no addon declaration')
        okm, keym = live4.live_toggle(plain)
        check(not okm and keym == 'live.mixed_no_addon' and live4.state_of(plain).scan.state == 'idle', 'mixed: refused without scanning')
        -- New assets (its own textures): launch only after the scan.
        local hud = mixed('MixHud', {{{LUA, 'cccccccccccccccc'}}, {{TEXTURE, 'abababababababab'}}}, 'mods/test/mixhud')
        check(live4.state_of(hud).archive == 2, 'mixed: the asset patch file is the one scanned')
        live4.live_toggle(hud)
        for _ = 1, 20 do t = t + 0.1; live4.step() end
        sm = live4.live_state(hud)
        check(sm.state == 'unavailable' and sm.reason == 'new' and sm.message == 'live.mixed_new' and not live4.staged['arsenal:MixHud'],
            'mixed: new assets stay launch only')
        -- Assets only in packages/boot.
        local boot_mix = mixed('MixBoot', {{{LUA, 'dddddddddddddddd'}, {TEXTURE, '2222222222222222'}}}, 'mods/test/mixboot')
        live4.live_toggle(boot_mix)
        for _ = 1, 20 do t = t + 0.1; live4.step() end
        check(live4.live_state(boot_mix).reason == 'boot_only', 'mixed: boot-only assets stay launch only')
        -- Assets split over two patch files.
        local split = mixed('MixSplit', {{{UNIT, '16474112801385b6'}}, {{TEXTURE, '1111111111111111'}}}, 'mods/test/mixsplit')
        check(live4.live_state(split).reason == 'archives', 'mixed: assets in several patch files')
        check(table.concat(events, ',') == 'arsenal:MixGood=true,arsenal:MixGood=false', 'mixed: no script started for launch-only mods')
    end
    -- Panel (player build: live without lab pages).
    local panel_module = module('mdl_panel')
    local fs = {mkdir = function() return true end, read = function() return nil end, read_head = function() return nil end,
        write = function() return true end, list = function() return {} end}
    local m = manager_module.new({base_dir = 'C:/T', platform = fs, globals = _G})
    m.start()
    entry.types, entry3.types = {}, {}
    local library = {scanned = true, revision = 1, sources = {'Arsenal'}, entries = {entry, entry3}, scan = function() end,
        describe_types = function() return '' end}
    local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
        held = function() return false end, wheel = function() return 0 end}
    local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}
    local panel = panel_module.new(m, input, renderer, {library = library, live = live3, menu_probe = function() return true end})
    local function row(label) for _, r in ipairs(panel.rows()) do if r.label == label then return r end end end
    local function header(text) for _, r in ipairs(panel.rows()) do if r.header == text then return r end end end
    check(header('RESOURCE  -  LIVE ON NEXT LOAD') and not row('Resource Lab (debug)'), 'player panel: live resource group, no lab')
    check(row('Armor').value == 'OFF' and row('BootOnly').value == 'LAUNCH ONLY', 'player panel: OFF and LAUNCH ONLY states')
    row('Armor').adjust()
    check(live3.staged['arsenal:armor'] and panel.flash_text:find('next time the game loads', 1, true), 'player panel: switched on from the list')
    check(row('Armor').value == 'LIVE ON' and row('Armor').tone == 'yellow', 'player panel: LIVE ON, waiting for the next load')
    panel.page, panel.target = 'library', entry
    check(row('Use live (applies on next load)') and row('Game packages: 0 active, 0 to reload, 2 in all'), 'player panel: library page live rows')
    panel.page, panel.target = 'why', 'resource'
    check(header('HOW IT WORKS'), 'player panel: resource explanation page')
    panel.frame()
    check(panel.draw_status == 'visible', 'player panel draws')
    entry.deployed = true
    library.revision = 2
    panel.page = 'list'
    panel.frame()
    check(not live3.staged['arsenal:armor'] and row('Armor').value == 'ON', 'player panel: deployed mod drops its live copies')
    entry.deployed = nil
end

-- Monitor off and nothing staged: the package list is not read.
do
    local lab = R.new({platform = platform, clock = function() return t end, base_dir = 'C:/MDL-idle', game_dir = GAME,
        monitor = function() return monitor_on end, budget = 1, find_all = native_ui.find_all, verbose = false})
    lab.use_layout({base = BASE, global = layout.global, loader = layout.loader, set = layout.set, count = layout.count,
        array = layout.array, layer_count = layout.layer_count, layers = layout.layers, layer_hash = layout.layer_hash})
    monitor_on = false
    local reads = 0
    local real = lab.read_packages
    lab.read_packages = function(...) reads = reads + 1 return real(...) end
    for _ = 1, 5 do t = t + 1.1; lab.step() end
    check(reads == 0 and lab.monitor_idle, 'idle: no package polling')
    monitor_on = true
    t = t + 1.1; lab.step()
    check(reads == 1, 'monitor on: polling again')
    lab.read_packages = real
end
print('PASS: MDL Resource Lab (decode, monitor, scan, staging) (' .. checks .. ' checks)')
