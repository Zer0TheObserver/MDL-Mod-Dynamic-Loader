-- MDL Resource Lab (debug builds only): route A experiment for live resource
-- mods.
--
-- Engine facts this relies on (helldivers2.exe, static analysis of the
-- 2026-06-09 .. 2026-09-26 dumps; see analysis_archive_20260930_native_resource_loading):
--   * A resource package is built by the engine's PackageLoader when it is
--     loaded. Only then does it enumerate "<bundle>.patch_0", ".patch_1", ...
--     in the data folder (stopping at the first missing index). A package that
--     is unloaded and loaded again picks up patch files added meanwhile.
--   * Mod managers deploy into 9ba626afa44a3aa3 = murmur64("packages/boot"),
--     which is loaded once at start and never unloaded.
-- So the lab (1) watches which packages the engine loads/unloads and which
-- patch layers they mounted, (2) finds the game bundles that contain a mod's
-- resources, and (3) on request copies the mod's patch as the next patch of
-- those bundles, so the next load of such a package mounts it - no restart.
--
-- Install layout: almost every bundle is stored inside data/bundles.NN.nxa,
-- indexed by data/bundles.nxa (NxStorage aggregate archive). Every game data
-- file (index, parts, loose bundles) is a DSAR container of LZ4 chunks; mod
-- patch files are plain and the engine reads both. The engine's
-- file lookup tries the aggregate index first and falls back to loose files
-- in data/, so a loose data/<bundle>.patch_N is found for a bundle stored in
-- the containers, as long as the index has no file of that name.
--
-- Memory access is read-only. File writes only happen on an explicit Stage
-- (copies into the game's data folder) and Unstage (deletes exactly the files
-- recorded when staging).
local R = {}

R.BOOT_BUNDLE = '9ba626afa44a3aa3'
-- mov rcx,[rip+app]; mov rcx,[rcx+LOADER]; jmp drain_queue   (22 look-alikes:
-- the real one is the one whose target reads the package set, see decode)
R.LOADER_SIGNATURE = '48 8B 0D ?? ?? ?? ?? 48 8B 89 ?? ?? 00 00 E9 ?? ?? ?? ?? CC'
-- drain_queue: mov rcx,[rdi+SET]; movups [rsp+20h],xmm0; mov rdx,[rsp+20h]; call lookup
R.DRAIN_LOOKUP = '48 8B 8F ?? ?? 00 00 0F 11 44 24 20 48 8B 54 24 20 E8'
R.LOOKUP_HEAD = '48 89 5C 24 08 48 89 74 24 10 48 89 7C 24 18 8B B9 ?? ?? ?? ?? 45 33 D2 85 FF 74 ?? 48 8B B1 ?? ?? ?? ??'
R.LOOKUP_TAIL = '4A 8B 1C D6 33 C0 44 8B 4B ?? 45 85 C9 74 ?? 4C 8B 5B ?? 4D 8B 04 C3 49 39 50 ??'
-- mov rax,[rip+file_commands]; mov rax,[rax+0xD0]; ret; int3; xor edx,edx; jmp
-- (unique in the 2026-06-09 .. 09-26 dumps). file_commands +0xD0 -> NxStorage
-- loader, +48 -> ArchiveLoaderImpl: +136 IDStorageFactory*, +152 DirectStorage
-- initialised, +336 staging buffer size (default 32 MiB, 0x73ec80; the game
-- passes no size, 0x7ab60). A DirectStorage request larger than the staging
-- buffer fails.
R.STORAGE_SIGNATURE = '48 8B 05 ?? ?? ?? ?? 48 8B 80 D0 00 00 00 C3 CC 33 D2 E9'
R.STORAGE_LOADER, R.LOADER_IMPL, R.DS_FACTORY, R.DS_READY, R.DS_STAGING = 0xD0, 48, 136, 152, 336
R.SET_STAGING_SLOT = 7   -- IDStorageFactory vtable: QI, AddRef, Release, CreateQueue, OpenFile, CreateStatusArray, SetDebugFlags, SetStagingBufferSize
R.PACKAGE_HASH = 16      -- package object + 16: package name hash
R.LAYER_STATE = 28       -- layer + 28: state (u32)
R.LAYER_ARCHIVE = 184    -- layer + 184: archive object (fallback: scanned)
R.ARCHIVE_NAME = 48      -- archive + 48: char *file name ("%016llx[.patch_%i]")

local function u32(get, offset)
    return get(offset) + get(offset + 1) * 256 + get(offset + 2) * 65536 + get(offset + 3) * 16777216
end
local function i32(get, offset)
    local value = u32(get, offset)
    if value >= 2147483648 then value = value - 4294967296 end
    return value
end
local function matches(get, at, signature)
    local i = 0
    for token in signature:gmatch('%S+') do
        if token ~= '??' and get(at + i) ~= tonumber(token, 16) then return false end
        i = i + 1
    end
    return true
end
R.matches = matches

-- Decodes a LOADER_SIGNATURE match into the PackageLoader layout; errors when
-- the match is one of the look-alikes or the structures changed.
function R.decode_loader(get, at)
    assert(matches(get, at, R.LOADER_SIGNATURE), 'not a loader accessor')
    local layout = {global = at + 7 + i32(get, at + 3), loader = u32(get, at + 10), drain = at + 19 + i32(get, at + 15)}
    local call
    for i = 0, 0x90 do
        if matches(get, layout.drain + i, R.DRAIN_LOOKUP) then call = layout.drain + i break end
    end
    assert(call, 'jump target is not the package queue')
    layout.set = u32(get, call + 3)
    layout.lookup = call + 22 + i32(get, call + 18)
    assert(matches(get, layout.lookup, R.LOOKUP_HEAD), 'package lookup changed')
    layout.count = u32(get, layout.lookup + 17)
    layout.array = u32(get, layout.lookup + 31)
    local tail
    for i = 0x20, 0x60 do
        if matches(get, layout.lookup + i, R.LOOKUP_TAIL) then tail = layout.lookup + i break end
    end
    assert(tail, 'package lookup layout changed')
    layout.layer_count = get(tail + 9)
    layout.layers = get(tail + 18)
    layout.layer_hash = get(tail + 26)
    assert(layout.set < 0x10000 and layout.count < 0x1000 and layout.array < 0x1000 and layout.loader < 0x10000,
        'implausible PackageLoader offsets')
    return layout
end

-- Archive table of contents (patch or bundle): {types = n, entries = {{key=16 raw bytes (name8..type8),
-- name=hex, type=hex}}} or nil, why. Hex strings are the 64-bit values, as IdString64.from_hex wants them.
local function value_hex(raw)
    local out = {}
    for i = #raw, 1, -1 do out[#out + 1] = string.format('%02x', raw:byte(i)) end
    return table.concat(out)
end
R.value_hex = value_hex
function R.toc_size(head)
    if not head or #head < 72 then return nil, 'short header' end
    local get = function(i) return head:byte(i + 1) end
    if u32(get, 0) ~= 0xF0000011 then return nil, 'not an archive' end
    local types, count = u32(get, 4), u32(get, 8)
    if types > 4096 or count > 4000000 then return nil, 'implausible table' end
    return 72 + 32 * types + 80 * count, types, count
end
function R.parse_toc(data)
    local size, types, count = R.toc_size(data)
    if not size then return nil, types end
    if #data < size then return nil, 'table truncated' end
    local entries = {}
    local start = 72 + 32 * types
    for index = 0, count - 1 do
        local row = start + 80 * index
        local key = data:sub(row + 1, row + 16)
        local get = function(i) return data:byte(row + i + 1) end
        entries[#entries + 1] = {key = key, name = value_hex(key:sub(1, 8)), type = value_hex(key:sub(9, 16)),
            size = u32(get, 56), stream_size = u32(get, 60), gpu_size = u32(get, 64)}
    end
    return {types = types, count = count, entries = entries}
end

local TYPE_NAMES = {
    ['a14e8dfa2cd117e2'] = 'lua', ['e0a48d0be9a7453f'] = 'unit', ['cd4238c6a0c69e32'] = 'texture',
    ['eac0b497876adedf'] = 'material', ['18dead01056b72e9'] = 'bones', ['931e336d7646cc26'] = 'animation',
    ['a486d4045106165c'] = 'state_machine', ['fe73c7dcff8a7ca5'] = 'shading_environment',
    ['5f7203c8f280dab8'] = 'physics', ['ad9c6d9ed1e5e77a'] = 'package', ['a8193123526fad64'] = 'particles',
    ['c4f0f4be7fb0c8d6'] = 'geometry_group', ['535a7bd3e650d799'] = 'wwise_bank', ['504b55235d21440e'] = 'wwise_stream',
    ['0d972bab10b40fd3'] = 'strings', ['9efe0a916aae7880'] = 'font', ['2a690fd348fe9ac5'] = 'level',
    ['9831ca893b0d087d'] = 'entity', ['ab2f78e885f513c6'] = 'prefab', ['e985c5f61c169997'] = 'speedtree',
    ['27862fe24795319c'] = 'render_config', ['1d59bd6687db6b33'] = 'ragdoll_profile', ['d7014a50477953e0'] = 'cloth',
}
R.TYPE_NAMES = TYPE_NAMES
local function type_name(hex) return TYPE_NAMES[hex] or hex end

local function is_bundle_name(name) return #name == 16 and not name:find('[^0-9a-f]') end
R.is_bundle_name = is_bundle_name

-- NxStorage aggregate index (data/bundles.nxa decompressed, "DSAA"), from
-- AggregateArchiveLoader (exe 0x73c6f0 open, 0x73bc90 name lookup, 0x73b760 read):
--   header 24 bytes ("DSAA", u16 1, u16 1, ...): +8 u32 index size, +12 u32 part count, +16 u32 file count
--   +24 files[count], 24 bytes each, sorted by name (strcmp):
--       +0 u64 size, +8 u32 name offset, +12 u32 chunk count, +16 u64 chunk table offset
--   then u32 part name offsets[parts] ("bundles.00.nxa", ...); names are
--   relative to the folder holding bundles.nxa. Offsets are from the index start.
--   chunk 16 bytes: +0 u64 offset in the file, +8 u32 offset in the part,
--       +15 u8 part number; a chunk runs to the next chunk's offset (the last to the size).
local function le32(data, at)
    local a, b, c, d = data:byte(at + 1, at + 4)
    return a + b * 256 + c * 65536 + d * 16777216
end
local function le64(data, at) return le32(data, at) + le32(data, at + 4) * 4294967296 end
local function cstring(data, at)
    local stop = data:find('\0', at + 1, true)
    return stop and data:sub(at + 1, stop - 1) or nil
end
-- DSAR container (every game data file since the NxStorage layout: bundles.nxa,
-- bundles.NN.nxa and the loose bundles; mod patch files are plain):
--   header 32 bytes: "DSAR", u16 3, u16 1, +8 u32 chunk count, +12 u32 header end,
--       +16 u64 decompressed size, "PADDING*"
--   chunks 32 bytes: +0 u64 offset in the decompressed data, +8 u64 offset in the file,
--       +16 u32 decompressed size, +20 u32 stored size, +24 u8 codec (0 stored, 3 LZ4 block)
-- All offsets in the aggregate index refer to decompressed data.

-- LZ4 block decoder on FFI buffers. Stops once `need` bytes are out.
-- Returns the number of bytes produced, or nil, why.
function R.lz4_decode(src, src_length, dst, dst_length, need, copy, yield)
    local i, o, steps = 0, 0, 0
    need = need or dst_length
    while i < src_length do
        local token = src[i]; i = i + 1
        local literal = math.floor(token / 16)
        if literal == 15 then
            repeat
                local b = src[i]; i = i + 1; literal = literal + b
            until b ~= 255 or i >= src_length
        end
        if i + literal > src_length or o + literal > dst_length then return nil, 'literal overrun' end
        copy(dst + o, src + i, literal)
        o, i = o + literal, i + literal
        if i >= src_length or o >= need then break end
        local offset = src[i] + src[i + 1] * 256; i = i + 2
        if offset == 0 or offset > o then return nil, 'bad match offset' end
        local match = token % 16
        if match == 15 then
            repeat
                local b = src[i]; i = i + 1; match = match + b
            until b ~= 255 or i >= src_length
        end
        match = match + 4
        if o + match > dst_length then return nil, 'match overrun' end
        local from = o - offset
        if offset >= match then
            copy(dst + o, dst + from, match)
        else
            for k = 0, match - 1 do dst[o + k] = dst[from + k] end
        end
        o = o + match
        if o >= need then break end
        steps = steps + 1
        if yield and steps % 4096 == 0 then yield() end
    end
    return o
end

-- Opens a game data file and returns a store with store.size and
-- store.read(offset, count) over its decompressed contents (plain files are
-- read as they are), store.dsar, store.close(); or nil, why.
function R.open_store(platform, ffi, path, yield)
    local reader, code = platform.open_reader(path)
    if not reader then return nil, 'open error ' .. tostring(code) end
    local head = reader.read_at(0, 32) or ''
    local store = {dsar = head:sub(1, 4) == 'DSAR'}
    function store.close() reader.close() end
    if not store.dsar then
        store.size = reader.size and reader.size() or math.huge
        function store.read(offset, count) return reader.read_at(offset, count) end
        return store
    end
    if #head < 32 then reader.close(); return nil, 'short DSAR header' end
    local count = le32(head, 8)
    local table_bytes = reader.read_at(32, 32 * count)
    if not table_bytes or #table_bytes < 32 * count then reader.close(); return nil, 'short DSAR chunk table' end
    store.size = le64(head, 16)
    local starts, places, sizes, stored, codecs = {}, {}, {}, {}, {}
    for k = 0, count - 1 do
        local at = 32 * k
        starts[k + 1] = le64(table_bytes, at)
        places[k + 1] = le64(table_bytes, at + 8)
        sizes[k + 1] = le32(table_bytes, at + 16)
        stored[k + 1] = le32(table_bytes, at + 20)
        codecs[k + 1] = table_bytes:byte(at + 25)
    end
    store.chunks = count
    local cached_chunk, cached_text = nil, ''
    local buffer, buffer_size = nil, 0
    -- Decompressed prefix of chunk k with at least `need` bytes.
    local function chunk_text(k, need)
        if cached_chunk == k and #cached_text >= need then return cached_text end
        local raw, why = reader.read_at(places[k], stored[k])
        if not raw or #raw < stored[k] then return nil, 'read error ' .. tostring(why) end
        local text
        if codecs[k] == 0 then
            text = raw
        elseif codecs[k] == 3 then
            if sizes[k] > buffer_size then buffer_size = math.max(sizes[k], 262144); buffer = ffi.new('uint8_t[?]', buffer_size) end
            local source = ffi.cast('const uint8_t *', raw)
            local produced, decode_why = R.lz4_decode(source, #raw, buffer, sizes[k], need, ffi.copy, yield)
            if not produced then return nil, decode_why end
            if produced < need then return nil, 'chunk decoded short' end
            text = ffi.string(buffer, produced)
        else
            return nil, 'unknown codec ' .. tostring(codecs[k])
        end
        cached_chunk, cached_text = k, text
        return text
    end
    function store.read(offset, count)
        local stop = math.min(offset + count, store.size)
        if stop <= offset then return '' end
        local low, high, k = 1, #starts, 0
        while low <= high do
            local mid = math.floor((low + high) / 2)
            if starts[mid] <= offset then k = mid; low = mid + 1 else high = mid - 1 end
        end
        if k == 0 then return nil, 'offset before the first chunk' end
        local out, position = {}, offset
        while position < stop do
            if not starts[k] or starts[k] > position then return nil, 'gap in the chunk table' end
            local chunk_stop = math.min(stop, starts[k] + sizes[k])
            local text, why = chunk_text(k, chunk_stop - starts[k])
            if not text then return nil, why end
            out[#out + 1] = text:sub(position - starts[k] + 1, chunk_stop - starts[k])
            position, k = chunk_stop, k + 1
        end
        return table.concat(out)
    end
    return store
end

-- yield (optional) is called now and then on large indexes.
function R.parse_nxa(data, yield)
    if not data or #data < 24 then return nil, 'short index' end
    local size, parts, count = le32(data, 8), le32(data, 12), le32(data, 16)
    if size > #data or parts == 0 or parts > 4096 or 24 + 24 * count + 4 * parts > #data then
        return nil, string.format('implausible header (size %d of %d, %d parts, %d files)', size, #data, parts, count)
    end
    local index = {data = data, count = count, parts = {}, files = {}, by_name = {},
        head = (data:sub(1, 8):gsub('.', function(c) return string.format('%02x', c:byte()) end))}
    local part_table = 24 + 24 * count
    for i = 0, parts - 1 do
        local name = cstring(data, le32(data, part_table + 4 * i))
        if not name or name == '' then return nil, 'bad part name ' .. i end
        index.parts[i + 1] = name
    end
    for i = 0, count - 1 do
        local at = 24 + 24 * i
        local name = cstring(data, le32(data, at + 8))
        if not name then return nil, 'bad file name at ' .. i end
        name = name:match('[^/\\]+$') or name
        local file = {name = name, size = le64(data, at), chunk_count = le32(data, at + 12), chunk_table = le64(data, at + 16)}
        if file.chunk_table + 16 * file.chunk_count > #data then return nil, 'chunk table outside the index: ' .. name end
        index.files[i + 1] = file
        index.by_name[name] = file
        if yield and i % 4096 == 4095 then yield() end
    end
    return index
end
function R.nxa_chunks(index, file)
    if file.chunks then return file.chunks end
    local data, chunks = index.data, {}
    for j = 0, file.chunk_count - 1 do
        local at = file.chunk_table + 16 * j
        chunks[j + 1] = {offset = le64(data, at), physical = le32(data, at + 8), part = data:byte(at + 16),
            flags = data:byte(at + 13) + data:byte(at + 14) * 256 + data:byte(at + 15) * 65536}
    end
    file.chunks = chunks
    return chunks
end
-- read_part(part_name, offset, count) -> bytes or nil, why.
function R.nxa_read(index, file, offset, count, read_part)
    local chunks = R.nxa_chunks(index, file)
    if offset + count > file.size then count = file.size - offset end
    if count <= 0 then return '' end
    local low, high, j = 1, #chunks, 0
    while low <= high do
        local mid = math.floor((low + high) / 2)
        if chunks[mid].offset <= offset then j = mid; low = mid + 1 else high = mid - 1 end
    end
    if j == 0 then return nil, 'no chunk at ' .. offset end
    local out, position, left = {}, offset, count
    while left > 0 do
        local chunk = chunks[j]
        if not chunk then return nil, 'past the last chunk' end
        local stop = chunks[j + 1] and chunks[j + 1].offset or file.size
        local take = math.min(left, stop - position)
        if take <= 0 then return nil, 'empty chunk ' .. j end
        local part = index.parts[chunk.part + 1]
        if not part then return nil, 'unknown part ' .. chunk.part end
        local bytes, why = read_part(part, chunk.physical + position - chunk.offset, take)
        if not bytes or #bytes < take then return nil, 'read failed in ' .. part .. ' (' .. tostring(why) .. ')' end
        out[#out + 1] = bytes
        position, left, j = position + take, left - take, j + 1
    end
    return table.concat(out)
end
local function patch_index(name, bundle)
    local index = name:match('^' .. bundle .. '%.patch_(%d+)$')
    return index and tonumber(index)
end

-- options = {platform=, ffi=, find_all=, clock=, log=, base_dir=, game_dir=, serialize=, can_get=fn(type_hex, name_hex),
--            write_log=fn(text) (optional), budget=seconds}
function R.new(options)
    local platform, clock = options.platform, options.clock or os.clock
    local budget = options.budget or 0.002
    -- verbose (debug lab): every package load/unload and per-resource scan
    -- lines go to the log. experimental (debug lab): DirectStorage tools.
    local verbose = options.verbose ~= false
    local experimental = options.experimental ~= false
    -- A home-bundle scan reads thousands of bundle tables from the containers;
    -- it gets a larger slice of each frame while it runs.
    local scan_budget = options.scan_budget or math.max(budget, 0.006)
    local self = {revision = 0, events = {}, packages = {}, loaded_bundles = {}, status = 'starting',
        entries = {}, staged = {}, log_lines = {}}
    local data_dir = options.game_dir and (options.game_dir .. '/data') or nil
    self.data_dir = data_dir
    -- Bundles are in the NxStorage containers (data/bundles.nxa index) plus a
    -- few loose files in data/. Staged patches are loose files in data/.
    local nxa, nxa_stamp     -- parsed index (loaded by the first scan) and its size/time
    local lab_dir = options.base_dir .. '/ResourceLab'
    platform.mkdir(lab_dir)
    local staged_path = lab_dir .. '/staged.lua'
    local log_dirty, log_written = false, -1

    local function log(line)
        line = tostring(line)
        self.log_lines[#self.log_lines + 1] = os.date('%H:%M:%S ') .. line
        if #self.log_lines > 3000 then table.remove(self.log_lines, 1) end
        log_dirty = true
        if options.log then pcall(options.log, line) end
    end
    self.log = log
    local function bump() self.revision = self.revision + 1 end

    local function flush_log(force)
        local now = clock()
        if not log_dirty or not force and now - log_written < 1 then return end
        log_dirty, log_written = false, now
        local text = (verbose and 'MDL Resource Lab (debug)\n' or 'MDL live resource mods\n') .. table.concat(self.log_lines, '\n') .. '\n'
        if options.write_log then pcall(options.write_log, text)
        else pcall(platform.write, options.base_dir .. '/Logs/' .. (options.log_name or 'MDL-ResourceLab.log'), text) end
    end
    self.flush_log = flush_log

    -- Staged records ------------------------------------------------------
    local function load_staged()
        local text = platform.read(staged_path)
        if not text or text == '' then return {} end
        local chunk = loadstring(text, '=staged.lua')
        if not chunk then return {} end
        setfenv(chunk, {})
        local ok, value = pcall(chunk)
        return ok and type(value) == 'table' and value or {}
    end
    local function save_staged()
        if options.serialize then
            platform.write(staged_path, 'return ' .. options.serialize(self.staged) .. '\n')
        end
    end
    self.staged = load_staged()
    do
        local count = 0
        for _ in pairs(self.staged) do count = count + 1 end
        if count > 0 then log(count .. ' mod(s) still staged in the game data folder from an earlier session') end
        -- A mod manager Deploy rewrites data/ and can delete the copies. With
        -- auto_reapply they are copied again from the mod (same patch number,
        -- when that number is still free); otherwise they are reported.
        for _, record in pairs(self.staged) do
            for _, file in ipairs(record.files or {}) do
                if file.paths and file.paths[1] and platform.read_head(file.paths[1], 1) == nil then
                    local restored = false
                    if options.auto_reapply and record.archive_path and platform.read_head(record.archive_path, 1) ~= nil then
                        restored = true
                        for k, suffix in ipairs({'', '.stream', '.gpu_resources'}) do
                            local to = file.paths[k]
                            if to and platform.read_head(to, 1) == nil then
                                local from = record.archive_path .. suffix
                                local ok
                                if suffix == '' or platform.read_head(from, 1) ~= nil then ok = platform.copy_file(from, to)
                                else ok = platform.write(to, '') end
                                if not ok then restored = false end
                            end
                        end
                        if restored then
                            log('re-applied ' .. (record.name or '?') .. ' -> ' .. file.bundle .. '.patch_' .. file.index .. ' (removed by a Deploy)')
                        end
                    end
                    if not restored then
                        file.missing, record.missing = true, true
                        log('staged ' .. (record.name or '?') .. ': ' .. file.bundle .. '.patch_' .. file.index
                            .. ' is MISSING (removed by a Deploy?); unstage and stage again')
                    end
                end
            end
        end
    end

    -- Package monitor -------------------------------------------------------
    local layout, problem
    local storage_global    -- exe RVA of the NxStorage file-command manager pointer
    local pending_checks = {}   -- {time=, bundle=} online checks after a staged package loads
    local function mem_u32(address)
        local raw = platform.mem_read(address, 4)
        if not raw then return nil end
        return raw:byte(1) + raw:byte(2) * 256 + raw:byte(3) * 65536 + raw:byte(4) * 16777216
    end
    local function mem_ptr(address)
        local raw = platform.mem_read(address, 8)
        if not raw then return nil end
        local lo = raw:byte(1) + raw:byte(2) * 256 + raw:byte(3) * 65536 + raw:byte(4) * 16777216
        local hi = raw:byte(5) + raw:byte(6) * 256 + raw:byte(7) * 65536 + raw:byte(8) * 16777216
        if hi == 0 and lo < 0x10000 or hi >= 0x8000 then return nil end
        return hi * 4294967296 + lo
    end
    local function mem_name(pointer)
        if not pointer then return nil end
        -- 16 hex digits, then byte by byte up to the terminator (the buffer
        -- may end right before an unreadable page).
        local text = platform.mem_read(pointer, 16)
        if not text then return nil end
        local terminated = false
        for i = 16, 40 do
            local c = platform.mem_read(pointer + i, 1)
            if not c then return nil end
            if c == '\0' then terminated = true break end
            text = text .. c
        end
        local name = terminated and text or nil
        if name and (is_bundle_name(name:sub(1, 16)) and (#name == 16 or name:sub(17):match('^%.patch_%d+$'))) then return name end
        return nil
    end
    local archive_offset = R.LAYER_ARCHIVE
    local function layer_name(layer)
        local name = mem_name(mem_ptr((mem_ptr(layer + archive_offset) or 0) + R.ARCHIVE_NAME))
        if name then return name end
        for k = 0, 25 do
            local candidate = mem_ptr(layer + 8 * k)
            if candidate then
                name = mem_name(mem_ptr(candidate + R.ARCHIVE_NAME))
                if name then
                    if archive_offset ~= 8 * k then log('layer archive offset is +' .. 8 * k) end
                    archive_offset = 8 * k
                    return name
                end
            end
        end
        return nil
    end

    local known = {}   -- package pointer -> record
    function self.read_packages(refresh_states)
        local app = mem_ptr(layout.base + layout.global)
        local loader = app and mem_ptr(app + layout.loader)
        local set = loader and mem_ptr(loader + layout.set)
        if not set then return nil, 'package loader not ready' end
        local count = mem_u32(set + layout.count)
        local array = mem_ptr(set + layout.array)
        if not count or count > 8192 then return nil, 'implausible package count' end
        if count == 0 then return {} end
        if not array then return nil, 'package array unreadable' end
        local raw = platform.mem_read(array, 8 * count)
        if not raw then return nil, 'package array unreadable' end
        local list = {}
        for i = 0, count - 1 do
            local lo = raw:byte(8 * i + 1) + raw:byte(8 * i + 2) * 256 + raw:byte(8 * i + 3) * 65536 + raw:byte(8 * i + 4) * 16777216
            local hi = raw:byte(8 * i + 5) + raw:byte(8 * i + 6) * 256 + raw:byte(8 * i + 7) * 65536 + raw:byte(8 * i + 8) * 16777216
            local package = hi * 4294967296 + lo
            local layers_n = mem_u32(package + layout.layer_count) or 0
            local record = known[package]
            if not record or record.layer_count ~= layers_n then
                local hash_raw = platform.mem_read(package + R.PACKAGE_HASH, 8)
                record = {pointer = package, hash = hash_raw and value_hex(hash_raw) or '?', layer_count = layers_n, layers = {}}
                local layers = mem_ptr(package + layout.layers)
                for j = 0, math.min(layers_n, 64) - 1 do
                    local layer = layers and mem_ptr(layers + 8 * j)
                    record.layers[#record.layers + 1] = {name = layer and layer_name(layer) or '?', state = layer and mem_u32(layer + R.LAYER_STATE)}
                end
                -- Patch layers come first ([1] = highest patch, last = base).
                local first = record.layers[1] and record.layers[1].name
                record.bundle = first and first:gsub('%.patch_%d+$', '') or record.hash
                known[package] = record
            elseif refresh_states then
                local layers = mem_ptr(package + layout.layers)
                for j, entry in ipairs(record.layers) do
                    local layer = layers and mem_ptr(layers + 8 * (j - 1))
                    entry.state = layer and mem_u32(layer + R.LAYER_STATE)
                end
            end
            list[#list + 1] = record
        end
        return list
    end

    local function describe(record)
        local patches = {}
        for _, layer in ipairs(record.layers) do
            local index = layer.name and layer.name:match('%.patch_(%d+)$')
            if index then patches[#patches + 1] = index end
        end
        local name = record.hash == record.bundle and record.hash or (record.hash .. ' -> ' .. record.bundle)
        return name .. (#patches > 0 and (' +patch ' .. table.concat(patches, ',')) or '')
    end

    local previous
    local function poll()
        local list, why = self.read_packages()
        if not list then
            if self.status ~= why then self.status = why; log('monitor: ' .. why); bump() end
            return
        end
        self.status = 'ok'
        local now, bundles = {}, {}
        for _, record in ipairs(list) do
            now[record.pointer] = record
            bundles[record.bundle] = true
            if record.hash == R.BOOT_BUNDLE or record.bundle == R.BOOT_BUNDLE then self.boot = record end
        end
        if previous then
            for pointer, record in pairs(now) do
                if not previous[pointer] then
                    local event = {kind = 'load', text = describe(record), time = os.date('%H:%M:%S'), bundle = record.bundle}
                    table.insert(self.events, event)
                    if verbose then log('LOAD   ' .. event.text) end
                    for _, staged in pairs(self.staged) do
                        for _, file in ipairs(staged.files or {}) do
                            if file.bundle == record.bundle then
                                local mounted = false
                                for _, layer in ipairs(record.layers) do
                                    if layer.name == file.bundle .. '.patch_' .. file.index then mounted = true end
                                end
                                log(string.format('%sstaged %s: %s.patch_%d %s', verbose and '  ' or 'package loaded, ', staged.name or '?',
                                    file.bundle, file.index, mounted and 'MOUNTED' or 'NOT mounted'))
                                if mounted then
                                    pending_checks[#pending_checks + 1] = {time = clock() + 3, staged = staged, bundle = file.bundle}
                                    pending_checks[#pending_checks + 1] = {time = clock() + 15, staged = staged, bundle = file.bundle}
                                end
                            end
                        end
                    end
                end
            end
            for pointer, record in pairs(previous) do
                if not now[pointer] then
                    local event = {kind = 'unload', text = describe(record), time = os.date('%H:%M:%S'), bundle = record.bundle}
                    table.insert(self.events, event)
                    if verbose then log('UNLOAD ' .. event.text) end
                    known[pointer] = nil
                end
            end
            while #self.events > 200 do table.remove(self.events, 1) end
        else
            log(string.format('monitor: %d packages loaded at first look', #list))
        end
        previous, self.packages, self.loaded_bundles = now, list, bundles
        local t = clock()
        for i = #pending_checks, 1, -1 do
            local check = pending_checks[i]
            if t >= check.time then
                table.remove(pending_checks, i)
                if bundles[check.bundle] then self.log_online(check.staged, check.bundle .. ' loaded') end
            end
        end
        -- Live mods switched off while their package was loaded: remove the
        -- copies once none of their packages is loaded.
        for id, record in pairs(self.staged) do
            if record.pending_remove then
                local busy = false
                for _, file in ipairs(record.files or {}) do if bundles[file.bundle] then busy = true end end
                if not busy then self.unstage(id) end
            end
        end
        bump()
    end

    function self.dump()
        if not layout then return false, 'monitor not running' end
        self.packages = self.read_packages(true) or self.packages
        log('--- package list (' .. #self.packages .. ') ---')
        for _, record in ipairs(self.packages) do
            local states = {}
            for _, layer in ipairs(record.layers) do states[#states + 1] = tostring(layer.name) .. '#' .. tostring(layer.state) end
            log('  ' .. record.hash .. '  ' .. table.concat(states, ' '))
        end
        flush_log(true)
        return true, #self.packages .. ' packages written to MDL-ResourceLab.log'
    end

    -- Background jobs (resolve, scans) share one coroutine queue and a
    -- per-frame time budget.
    local jobs = {}
    local function spawn(fn, name)
        jobs[#jobs + 1] = {co = coroutine.create(fn), name = name}
    end
    local deadline = 0
    local function over() return clock() > deadline end
    local function pause() if over() then coroutine.yield() end end

    -- Resolve the PackageLoader in helldivers2.exe (chunked signature scan).
    local function resolve_job()
        local ffi = options.ffi
        local base = platform.module('helldivers2.exe')
        assert(base, 'helldivers2.exe not loaded')
        local bytes = ffi.cast('const uint8_t *', base)
        local function get(i) return bytes[i] end
        local pe = u32(get, 0x3c)
        local sections, optional = get(pe + 6) + get(pe + 7) * 256, get(pe + 20) + get(pe + 21) * 256
        local text_start, text_size
        for i = 0, sections - 1 do
            local header = pe + 24 + optional + 40 * i
            if math.floor(u32(get, header + 36) / 0x20000000) % 2 == 1 then
                text_size, text_start = u32(get, header + 8), u32(get, header + 12)
                break
            end
        end
        assert(text_start, 'code section unavailable')
        local chunk, found, valid, storage_hits = 0x40000, {}, {}, {}
        local offset = 0
        while offset < text_size do
            local size = math.min(chunk + 32, text_size - offset)
            local start = text_start + offset
            local function at(i) return bytes[start + i] end
            for _, hit in ipairs(options.find_all(at, size, R.LOADER_SIGNATURE, 64)) do
                if hit < chunk or offset + chunk >= text_size then found[start + hit] = true end
            end
            for _, hit in ipairs(experimental and options.find_all(at, size, R.STORAGE_SIGNATURE, 8) or {}) do
                if hit < chunk or offset + chunk >= text_size then storage_hits[#storage_hits + 1] = start + hit end
            end
            offset = offset + chunk
            coroutine.yield()
        end
        for at in pairs(found) do
            local ok, value = pcall(R.decode_loader, get, at)
            if ok then valid[#valid + 1] = value end
        end
        assert(#valid == 1, 'PackageLoader accessor matched ' .. #valid .. ' times')
        layout = valid[1]
        layout.base = tonumber(ffi.cast('uintptr_t', base))
        if not experimental then
            -- DirectStorage tools are debug-only.
        elseif #storage_hits == 1 then
            local at = storage_hits[1]
            storage_global = at + 7 + i32(get, at + 3)
            log(string.format('NxStorage file commands: exe +0x%x', storage_global))
        else
            log('NxStorage accessor matched ' .. #storage_hits .. ' times; staging buffer tools off')
        end
        log(string.format('PackageLoader: app +0x%x, loader +%d, set +0x%x (count +0x%x, array +0x%x), package layers +0x%x/+0x%x',
            layout.global, layout.loader, layout.set, layout.count, layout.array, layout.layer_count, layout.layers))
    end
    -- Tests inject the layout directly.
    function self.use_layout(value, storage) layout = value; storage_global = storage end

    -- DirectStorage staging buffer (experiment) ------------------------------
    local function module_range(name)
        local base = platform.module(name)
        if base == nil then return nil end
        if type(base) ~= 'number' then base = tonumber(options.ffi.cast('uintptr_t', base)) end
        local pe = mem_u32(base + 0x3c)
        local size = pe and mem_u32(base + pe + 24 + 56)
        if not size then return nil end
        return base, base + size
    end
    local function inside(address, name)
        local low, high = module_range(name)
        return low and address >= low and address < high
    end
    -- {size=, impl=, factory=, method=, ready=} or nil, why.
    function self.staging()
        if not experimental then return nil, 'not in this build' end
        if not layout or not storage_global then return nil, 'not located' end
        local commands = mem_ptr(layout.base + storage_global)
        local loader = commands and mem_ptr(commands + R.STORAGE_LOADER)
        local impl = loader and mem_ptr(loader + R.LOADER_IMPL)
        if not impl then return nil, 'NxStorage loader not ready' end
        local size = mem_u32(impl + R.DS_STAGING)
        local factory = mem_ptr(impl + R.DS_FACTORY)
        local ready = platform.mem_read(impl + R.DS_READY, 1)
        if not size or size < 0x100000 or size > 0x40000000 then return nil, 'implausible staging size' end
        if not factory then return {size = size, impl = impl}, 'DirectStorage not in use (fallback reads)' end
        local vtable = mem_ptr(factory)
        local method = vtable and mem_ptr(vtable + 8 * R.SET_STAGING_SLOT)
        if not method or not (inside(method, 'dstorage.dll') or inside(method, 'dstoragecore.dll')) then
            return {size = size, impl = impl}, 'DirectStorage factory not recognised'
        end
        return {size = size, impl = impl, factory = factory, method = method, ready = ready and ready:byte() ~= 0}
    end
    function self.set_staging(bytes)
        local info, why = self.staging()
        if not info or not info.method then return false, 'Staging buffer not adjustable: ' .. tostring(why) end
        local call = options.call_set_staging or function(method, factory, size)
            local ffi = options.ffi
            local fn = ffi.cast('int32_t (*)(void *, uint32_t)', ffi.cast('uintptr_t', method))
            return fn(ffi.cast('void *', ffi.cast('uintptr_t', factory)), size)
        end
        local ok, hr = pcall(call, info.method, info.factory, bytes)
        if not ok or not hr or hr < 0 then
            log(string.format('SetStagingBufferSize(%d MB) failed: %s', bytes / 1048576, tostring(hr)))
            return false, 'DirectStorage refused the new size (see the lab log).'
        end
        local raw = string.char(bytes % 256, math.floor(bytes / 256) % 256, math.floor(bytes / 65536) % 256, math.floor(bytes / 16777216) % 256)
        platform.mem_write(info.impl + R.DS_STAGING, raw)
        log(string.format('DirectStorage staging buffer: %d MB -> %d MB (until the game restarts)', info.size / 1048576, bytes / 1048576))
        flush_log(true)
        bump()
        return true, 'Staging buffer set to ' .. math.floor(bytes / 1048576) .. ' MB until the game restarts. Reload the package (new mission) to test.'
    end

    -- Mod archives and home-bundle scan ------------------------------------
    local function archives_of(entry)
        local list = {}
        local function walk(dir, depth)
            for _, item in ipairs(platform.list(dir)) do
                if item.dir then
                    if depth < 3 then walk(dir .. '/' .. item.name, depth + 1) end
                elseif item.name:match('^%x+%.patch_%d+$') then
                    list[#list + 1] = {path = dir .. '/' .. item.name, name = item.name, size = item.size,
                        rel = (dir .. '/' .. item.name):sub(#entry.path + 2)}
                end
            end
        end
        if entry.path then walk(entry.path, 0) end
        table.sort(list, function(a, b) return a.rel < b.rel end)
        return list
    end

    -- Scan results are cached per mod (ResourceLab/scans.lua) and reused while
    -- the mod's patch file and the game's bundles.nxa are unchanged.
    local cache_path = lab_dir .. '/scans.lua'
    local cache = (function()
        local text = platform.read(cache_path)
        local chunk = text and text ~= '' and loadstring(text, '=scans.lua')
        if not chunk then return {} end
        setfenv(chunk, {})
        local ok, value = pcall(chunk)
        return ok and type(value) == 'table' and value or {}
    end)()
    local function save_cache()
        if options.serialize then platform.write(cache_path, 'return ' .. options.serialize(cache) .. '\n') end
    end
    local function file_stamp(dir, name)
        for _, item in ipairs(platform.list(dir, name)) do
            if item.name == name then return item.size .. ':' .. item.mtime end
        end
    end
    local function archive_stamp(archive)
        local dir, name = archive.path:match('^(.*)/([^/]+)$')
        local game = data_dir and file_stamp(data_dir, 'bundles.nxa') or 'none'
        local own = dir and file_stamp(dir, name)
        return own and (own .. '|' .. game) or nil
    end

    local function get_ffi()
        if options.ffi then return options.ffi end
        local ok, value = pcall(require, 'ffi')
        return ok and value or nil
    end
    -- Table of contents of an archive file, plain or DSAR.
    local function mod_toc(archive)
        local store, why = R.open_store(platform, get_ffi(), archive.path)
        if not store then return nil, why end
        local head = store.read(0, 72)
        local size
        size, why = R.toc_size(head)
        local toc
        if size then toc, why = R.parse_toc(store.read(0, size)) end
        store.close()
        return toc, why
    end

    -- MIXED mods (script + assets), 1.8.3: they can go live when their Lua
    -- part declares an addon (MDL runs it at once) and every asset replaces a
    -- game resource in a package that reloads (staged like a resource mod).
    -- plan = {archive = index of the one patch file with assets} or
    -- {reason = 'no_addon' | 'no_assets' | 'archives'}; after the scan,
    -- mixed_block() adds 'new' / 'boot_only'.
    local LUA_HEX = 'a14e8dfa2cd117e2'
    function self.mixed_plan(entry, state)
        if entry.category ~= 'MIXED' then return nil end
        if state.mixed then return state.mixed end
        local plan, assets_in = {}, {}
        for index, archive in ipairs(state.archives) do
            local toc = mod_toc(archive)
            local assets = 0
            for _, item in ipairs(toc and toc.entries or {}) do if item.type ~= LUA_HEX then assets = assets + 1 end end
            if assets > 0 then assets_in[#assets_in + 1] = index end
        end
        if #assets_in == 1 then plan.archive = assets_in[1] end
        if not entry.addon then plan.reason = 'no_addon'
        elseif #assets_in == 0 then plan.reason = 'no_assets'
        elseif #assets_in > 1 then plan.reason = 'archives' end
        state.mixed = plan
        return plan
    end
    -- Blocking reason for a MIXED mod once its scan is done (nil = can go live).
    local function mixed_block(entry, state)
        local plan = self.mixed_plan(entry, state)
        if not plan then return nil end
        if plan.reason then return plan.reason end
        local scan = state.scan
        if scan.state ~= 'done' then return nil end
        if (scan.new or 0) > 0 then return 'new' end
        if (scan.boot_only or 0) > 0 then return 'boot_only' end
        if #(scan.targets or {}) == 0 then return 'new' end
        return nil
    end
    self.mixed_block = function(entry) return mixed_block(entry, state_of(entry)) end
    local function notify(entry, on)
        if options.on_live and entry.category == 'MIXED' then pcall(options.on_live, entry, on) end
    end

    local function state_of(entry)
        local state = self.entries[entry.id]
        if state and #state.archives == 0 and entry.path then
            state.archives = archives_of(entry)   -- files added since (e.g. a finished download)
        end
        if not state then
            state = {archives = archives_of(entry), archive = 1, scan = {state = 'idle'}}
            self.entries[entry.id] = state
            state.live_archive = 1
            local plan = self.mixed_plan(entry, state)
            if plan and plan.archive then state.archive, state.live_archive = plan.archive, plan.archive end
            local archive = state.archives[state.live_archive]
            local saved = archive and cache[entry.id]
            if saved and saved.path == archive.path and saved.stamp == archive_stamp(archive) then
                local entries = {}
                for _, item in ipairs(saved.resources or {}) do
                    entries[#entries + 1] = {type = item.type, name = item.name, gpu_size = item.gpu or 0}
                end
                local largest
                for _, item in ipairs(entries) do if not largest or item.gpu_size > largest.gpu_size then largest = item end end
                state.scan = {state = 'done', cached = true, toc = {entries = entries}, targets = saved.targets or {},
                    replaced = saved.replaced or 0, boot_only = saved.boot_only or 0, new = saved.new or 0, largest = largest,
                    done = 1, total = 1}
            end
        end
        return state
    end
    self.state_of = state_of

    function self.cycle_archive(entry)
        local state = state_of(entry)
        if #state.archives < 2 then return false, 'This mod has one patch file.' end
        state.archive = state.archive % #state.archives + 1
        state.scan = {state = 'idle'}
        bump()
        return true, 'Patch file ' .. state.archive .. '/' .. #state.archives .. ': ' .. state.archives[state.archive].rel
    end


    -- Game bundle sources: the aggregate index (cached while its size/time
    -- stay the same) plus loose bundles in data/ that the index lacks.
    local function load_index()
        local stamp
        for _, item in ipairs(platform.list(data_dir, 'bundles.nxa')) do
            if item.name == 'bundles.nxa' then stamp = item.size .. ':' .. item.mtime end
        end
        if not stamp then nxa, nxa_stamp = nil, nil; return nil, 'no data/bundles.nxa' end
        if nxa and nxa_stamp == stamp then return nxa end
        local store, why = R.open_store(platform, get_ffi(), data_dir .. '/bundles.nxa', pause)
        if not store then return nil, 'bundles.nxa: ' .. tostring(why) end
        local data
        data, why = store.read(0, store.size)
        store.close()
        if not data then return nil, 'bundles.nxa: ' .. tostring(why) end
        local index
        index, why = R.parse_nxa(data, pause)
        if not index then return nil, why end
        index.container = store.dsar and ('DSAR, ' .. store.chunks .. ' chunks, ' .. #data .. ' bytes') or 'plain'
        nxa, nxa_stamp = index, stamp
        local bundles, patches, streams = 0, 0, 0
        for _, file in ipairs(index.files) do
            if is_bundle_name(file.name) then bundles = bundles + 1
            elseif file.name:find('%.patch_%d+$') then patches = patches + 1
            elseif file.name:find('%.stream$') or file.name:find('%.gpu_resources$') then streams = streams + 1 end
        end
        log(string.format('bundles.nxa (%s): %d files (%d bundles, %d patches, %d stream/gpu), %d parts (%s .. %s), head %s',
            index.container, index.count, bundles, patches, streams, #index.parts, index.parts[1], index.parts[#index.parts], index.head))
        return index
    end
    self.load_index = load_index

    -- Is a file of this name visible to the engine (index or loose data/)?
    local function engine_has(name)
        if nxa and nxa.by_name[name] then return 'index' end
        if platform.read_head(data_dir .. '/' .. name, 1) ~= nil then return 'loose' end
        return nil
    end

    function self.scan(entry)
        local state = state_of(entry)
        if state.scan.state == 'running' then return false, 'Already scanning.' end
        local archive = state.archives[state.archive]
        if not archive then return false, 'No patch file found in this mod.' end
        if not data_dir then return false, 'Game folder unknown.' end
        local toc, why = mod_toc(archive)
        if not toc then return false, 'Cannot read ' .. archive.rel .. ': ' .. tostring(why) end
        local scan = {state = 'running', done = 0, total = 0, toc = toc, homes = {}, bundles = {}}
        state.scan = scan
        local wanted = {}
        for index, item in ipairs(toc.entries) do wanted[item.key] = index; scan.homes[index] = {} end
        log(string.format('scan %s (%s): %d resources', entry.name, archive.rel, #toc.entries))
        spawn(function()
            local index, index_why = load_index()
            if not index then log('aggregate index unavailable (' .. tostring(index_why) .. '); loose bundles only') end
            local sources, stores, open_failed = {}, {}, {}
            local ffi = get_ffi()
            local function read_part(part, offset, count)
                local store = stores[part]
                if not store then
                    if open_failed[part] then return nil, open_failed[part] end
                    local why
                    store, why = R.open_store(platform, ffi, data_dir .. '/' .. part, pause)
                    if not store then
                        open_failed[part] = tostring(why)
                        log('cannot open ' .. part .. ' (' .. tostring(why) .. ')')
                        return nil, open_failed[part]
                    end
                    stores[part] = store
                end
                return store.read(offset, count)
            end
            local in_index, loose = 0, 0
            if index then
                for _, file in ipairs(index.files) do
                    if is_bundle_name(file.name) then
                        sources[#sources + 1] = {name = file.name, size = file.size, read = function(offset, count)
                            return R.nxa_read(index, file, offset, count, read_part)
                        end}
                        in_index = in_index + 1
                    end
                end
            end
            for _, item in ipairs(platform.list(data_dir)) do
                if not item.dir and is_bundle_name(item.name) and not (index and index.by_name[item.name]) then
                    local name = item.name
                    sources[#sources + 1] = {name = name, size = item.size, loose = true, read = function(offset, count)
                        return read_part(name, offset, count)
                    end}
                    loose = loose + 1
                end
            end
            scan.total = #sources
            log(string.format('bundles to scan: %d in bundles.nxa, %d loose in data/', in_index, loose))
            local good, bad, bad_examples, rows_total = 0, 0, {}, 0
            local function reject(name, reason)
                bad = bad + 1
                if #bad_examples < 5 then bad_examples[#bad_examples + 1] = name .. ': ' .. tostring(reason) end
            end
            for _, source in ipairs(sources) do
                local first = 8192
                local head, read_why = source.read(0, first)
                local size, toc_why = R.toc_size(head)
                if not head then reject(source.name, read_why)
                elseif not size then reject(source.name, toc_why .. ' (' .. value_hex(head:sub(1, 4)) .. ')')
                elseif size > 64 * 1048576 then reject(source.name, 'table too large')
                else
                    local body = head
                    if #body < size then body = source.read(0, size) end
                    if not body or #body < size then reject(source.name, 'table truncated')
                    else
                        good = good + 1
                        local types, count = le32(body, 4), le32(body, 8)
                        rows_total = rows_total + count
                        local start = 72 + 32 * types
                        local hits = 0
                        for row_index = 0, count - 1 do
                            local row = start + 80 * row_index
                            local hit = wanted[body:sub(row + 1, row + 16)]
                            if hit then
                                local list = scan.homes[hit]
                                list[#list + 1] = source.name
                                hits = hits + 1
                            end
                            if row_index % 4096 == 4095 then pause() end
                        end
                        if hits > 0 then scan.bundles[source.name] = hits end
                    end
                end
                scan.done = scan.done + 1
                pause()
            end
            for _, store in pairs(stores) do store.close() end
            log(string.format('tables read: %d ok, %d unreadable, %d resource rows', good, bad, rows_total))
            for _, line in ipairs(bad_examples) do log('  unreadable ' .. line) end
            -- Summary: replaced (in a bundle other than boot), boot-only, new.
            local replaced, boot_only, fresh, scripts = 0, 0, 0, 0
            for index_, homes in ipairs(scan.homes) do
                local other = false
                -- Lua rows of a MIXED mod are the script part (run by MDL), not assets.
                if toc.entries[index_].type == LUA_HEX then scripts = scripts + 1; homes = {false} end
                for _, bundle in ipairs(homes) do if bundle ~= R.BOOT_BUNDLE then other = true end end
                if homes[1] == false then -- script
                elseif other then replaced = replaced + 1
                elseif #homes > 0 then boot_only = boot_only + 1
                else fresh = fresh + 1; scan.first_new = scan.first_new or index_ end
            end
            scan.replaced, scan.boot_only, scan.new, scan.scripts = replaced, boot_only, fresh, scripts
            local largest
            for _, item in ipairs(toc.entries) do
                if not largest or (item.gpu_size or 0) > largest.gpu_size then largest = item end
            end
            scan.largest = largest
            local targets = {}
            for bundle, hits in pairs(scan.bundles) do
                if bundle ~= R.BOOT_BUNDLE then targets[#targets + 1] = {bundle = bundle, hits = hits} end
            end
            table.sort(targets, function(a, b) if a.hits ~= b.hits then return a.hits > b.hits end return a.bundle < b.bundle end)
            scan.targets = targets
            scan.state = 'done'
            local archive_now = state.archives[state.archive]
            local stamp = archive_now and archive_stamp(archive_now)
            if stamp and state.archive == (state.live_archive or 1) then
                local resources = {}
                for _, item in ipairs(toc.entries) do resources[#resources + 1] = {type = item.type, name = item.name, gpu = item.gpu_size} end
                cache[entry.id] = {path = archive_now.path, stamp = stamp, targets = targets, replaced = replaced,
                    boot_only = boot_only, new = fresh, resources = resources}
                save_cache()
            end
            log(string.format('scan done: %d scanned bundles; %d resources replace game resources, %d exist only in packages/boot, %d are new; %d target bundles',
                scan.total, replaced, boot_only, fresh, #targets))
            for i = 1, math.min(#targets, 40) do
                log(string.format('  %s  %d resource(s)%s', targets[i].bundle, targets[i].hits,
                    self.loaded_bundles[targets[i].bundle] and '  (loaded now)' or ''))
            end
            local staging = self.staging and self.staging()
            if largest and largest.gpu_size > 0 then
                log(string.format('largest GPU resource: %s %s %.1f MB; DirectStorage staging buffer %s', type_name(largest.type),
                    largest.name, largest.gpu_size / 1048576, staging and string.format('%d MB', staging.size / 1048576) or 'unknown'))
            end
            for i, item in ipairs(verbose and toc.entries or {}) do
                local homes = scan.homes[i]
                log(string.format('  %-9s %s  gpu %6.1f MB  in %s', type_name(item.type), item.name, (item.gpu_size or 0) / 1048576,
                    #homes == 0 and 'no game bundle (new)' or table.concat(homes, ' ', 1, math.min(#homes, 6))
                        .. (#homes > 6 and (' +' .. (#homes - 6)) or '')))
            end
            flush_log(true)
            if state.auto_stage then
                state.auto_stage = nil
                local block = mixed_block(entry, state)
                if block then
                    state.live_message = 'live.mixed_' .. block
                    log(string.format('%s stays launch only: %s', entry.name, block))
                elseif #targets > 0 then
                    local ok, message = self.stage(entry, true)
                    state.live_message = ok and 'live.on' or 'live.failed'
                    if not ok then log('live switch-on failed: ' .. tostring(message)) end
                    if ok then
                        notify(entry, true)
                        log_conflicts(entry, state.auto_entries)
                        if #self.conflicts(entry, state.auto_entries) > 0 then state.live_message = 'live.on_conflict' end
                    end
                    state.auto_entries = nil
                else
                    state.live_message = 'live.unavailable'
                end
            end
            bump()
        end, 'scan')
        bump()
        return true, 'Scanning the game bundles...'
    end

    -- Staging ---------------------------------------------------------------
    -- Next free patch number; the engine stops at the first missing number and
    -- sees index files and loose files alike.
    local function next_index(bundle)
        local used, highest = {}, -1
        for _, item in ipairs(platform.list(data_dir, bundle .. '.patch_*')) do
            local index = patch_index(item.name, bundle)
            if index then used[index] = true; if index > highest then highest = index end end
        end
        if nxa then
            for index = 0, 63 do
                if nxa.by_name[bundle .. '.patch_' .. index] then
                    used[index] = true; if index > highest then highest = index end
                end
            end
        end
        local index = 0
        while used[index] do index = index + 1 end
        return index, highest > index
    end
    R.next_index = next_index

    function self.stage(entry, confirm)
        local state = state_of(entry)
        local scan = state.scan
        if scan.state ~= 'done' then return false, 'Find home bundles first.' end
        if self.staged[entry.id] then return false, 'Already staged; unstage first.' end
        if #scan.targets == 0 then return false, 'No game bundle contains these resources (nothing to stage).' end
        if scan.new > 0 and not confirm then
            state.confirm = true
            bump()
            return false, scan.new .. ' resource(s) are new to the game. They may not load through another package and '
                .. 'a model that needs them can crash. Click Stage again to stage anyway.'
        end
        local archive = state.archives[state.archive]
        local record = {name = entry.name, archive = archive.rel, archive_path = archive.path, files = {},
            time = os.date('%Y-%m-%d %H:%M:%S'), resources = {}}
        for _, item in ipairs(scan.toc.entries) do
            record.resources[#record.resources + 1] = {type = item.type, name = item.name, gpu = item.gpu_size}
        end
        local function rollback()
            for _, file in ipairs(record.files) do
                for _, path in ipairs(file.paths) do platform.delete_file(path) end
            end
        end
        for _, target in ipairs(scan.targets) do
            local index, gap = next_index(target.bundle)
            if gap then log('warning: ' .. target.bundle .. ' has a gap in its patch numbers; using .patch_' .. index) end
            local destination = data_dir .. '/' .. target.bundle .. '.patch_' .. index
            local file = {bundle = target.bundle, index = index, paths = {}}
            for _, suffix in ipairs({'', '.stream', '.gpu_resources'}) do
                local from, to = archive.path .. suffix, destination .. suffix
                local ok, code
                if suffix == '' or platform.read_head(from, 1) ~= nil then
                    ok, code = platform.copy_file(from, to)
                else
                    ok = platform.write(to, '')
                end
                if not ok then
                    rollback()
                    for _, path in ipairs(file.paths) do platform.delete_file(path) end
                    log('stage failed at ' .. to .. ' (error ' .. tostring(code) .. '); rolled back')
                    return false, 'Copy failed (' .. tostring(code) .. '); nothing staged. See the lab log.'
                end
                file.paths[#file.paths + 1] = to
            end
            record.files[#record.files + 1] = file
            log(string.format('staged %s -> %s.patch_%d%s', archive.rel, target.bundle, index,
                self.loaded_bundles[target.bundle] and ' (package loaded now: mounts on its next load)' or ''))
        end
        self.staged[entry.id] = record
        state.confirm = nil
        save_staged()
        flush_log(true)
        bump()
        return true, 'Staged into ' .. #record.files .. ' bundle(s). They mount the next time the game loads those packages.'
    end

    local function owner_of(bundle, index, except)
        for _, record in pairs(self.staged) do
            for _, file in ipairs(record.files or {}) do
                if file ~= except and file.bundle == bundle and file.index == index then return record, file end
            end
        end
    end
    -- Removes a staged mod's copies. The engine stops at the first missing
    -- patch number, so later patches of the same bundle that MDL staged for
    -- other mods are moved down one number; a later patch from another tool
    -- keeps ours in place.
    function self.unstage(entry_id)
        local record = self.staged[entry_id]
        if not record then return false, 'Not staged.' end
        local kept = {}
        for _, file in ipairs(record.files) do
            local chain, foreign = {}, nil
            local j = file.index + 1
            while true do
                local name = file.bundle .. '.patch_' .. j
                local where = engine_has(name)
                if not where then break end
                local owner_record, owner_file = owner_of(file.bundle, j, file)
                if where ~= 'loose' or not owner_file then foreign = name break end
                chain[#chain + 1] = {record = owner_record, file = owner_file}
                j = j + 1
            end
            if foreign then
                kept[#kept + 1] = file
                log('unstage: kept ' .. file.bundle .. '.patch_' .. file.index .. ' (' .. foreign .. ' from another tool follows it)')
            else
                local failed
                for i = #file.paths, 1, -1 do
                    local ok, code = platform.delete_file(file.paths[i])
                    if not ok and platform.read_head(file.paths[i], 1) ~= nil then failed = code end
                end
                if failed then
                    kept[#kept + 1] = file
                    log('unstage: ' .. file.bundle .. '.patch_' .. file.index .. ' in use (error ' .. tostring(failed) .. '); retry after the package unloads or after a restart')
                else
                    log('unstaged ' .. file.bundle .. '.patch_' .. file.index)
                    for _, link in ipairs(chain) do
                        local moved = {}
                        local to_index = link.file.index - 1
                        local suffixes = {'', '.stream', '.gpu_resources'}
                        for k, path in ipairs(link.file.paths) do
                            local target = data_dir .. '/' .. link.file.bundle .. '.patch_' .. to_index .. (suffixes[k] or '')
                            local ok, code = platform.move_file(path, target)
                            if not ok then log('renumber failed: ' .. path .. ' (error ' .. tostring(code) .. ')') end
                            moved[k] = ok and target or path
                        end
                        link.file.paths, link.file.index = moved, to_index
                        log(string.format('renumbered %s: %s.patch_%d -> .patch_%d', link.record.name or '?', link.file.bundle, to_index + 1, to_index))
                    end
                end
            end
        end
        if #kept == 0 then self.staged[entry_id] = nil else record.files = kept; record.pending_remove = nil end
        save_staged()
        flush_log(true)
        bump()
        if #kept == 0 then return true, 'Unstaged; all copies removed from the game data folder.' end
        return false, #kept .. ' file set(s) kept (in use or followed by another patch). See the lab log.'
    end

    -- Conflicts with mods deployed into packages/boot ----------------------------
    -- packages/boot is loaded at start, so its version of a resource comes online
    -- first and wins over a live copy of the same resource.
    local boot_cache = {}   -- file name -> {stamp=, keys=, size=, index=, owner=}
    local function raw_of(hex)
        local out = {}
        for i = 15, 1, -2 do out[#out + 1] = string.char(tonumber(hex:sub(i, i + 1), 16)) end
        return table.concat(out)
    end
    local function boot_patches()
        local list = {}
        if not data_dir then return list end
        for _, item in ipairs(platform.list(data_dir, R.BOOT_BUNDLE .. '.patch_*')) do
            local index = patch_index(item.name, R.BOOT_BUNDLE)
            if index then
                local stamp = tostring(item.size) .. ':' .. tostring(item.mtime)
                local cached = boot_cache[item.name]
                if not cached or cached.stamp ~= stamp then
                    local toc = mod_toc({path = data_dir .. '/' .. item.name})
                    local keys = {}
                    for _, resource in ipairs(toc and toc.entries or {}) do keys[resource.key] = true end
                    cached = {stamp = stamp, keys = keys, size = item.size, index = index, name = item.name}
                    boot_cache[item.name] = cached
                end
                list[#list + 1] = cached
            end
        end
        table.sort(list, function(a, b) return a.index < b.index end)
        return list
    end
    -- Library mod that deployed a boot patch (same size and first 4 KB).
    local function owner_name(patch, entries, except)
        if patch.owner ~= nil then return patch.owner or nil end
        patch.owner = false
        local head = platform.read_head(data_dir .. '/' .. patch.name, 4096)
        for _, other in ipairs(entries or {}) do
            if other.id ~= except and other.path and (other.deployed or other.enabled) then
                for _, archive in ipairs(archives_of(other)) do
                    if archive.size == patch.size and platform.read_head(archive.path, 4096) == head then
                        patch.owner = other.name or other.id
                        return patch.owner
                    end
                end
            end
        end
        return nil
    end
    -- {{owner=, patch=, count=, resources={hex...}}} for the mod's resources that
    -- a deployed (boot) patch also provides.
    function self.conflicts(entry, entries)
        local state = state_of(entry)
        local toc = state.scan.state == 'done' and state.scan.toc
        if not toc then return {} end
        local result = {}
        for _, patch in ipairs(boot_patches()) do
            local hits = {}
            for _, resource in ipairs(toc.entries) do
                local key = resource.key or raw_of(resource.name) .. raw_of(resource.type)
                if patch.keys[key] then hits[#hits + 1] = type_name(resource.type) .. ' ' .. resource.name end
            end
            if #hits > 0 then
                result[#result + 1] = {owner = owner_name(patch, entries, entry.id), patch = patch.name, count = #hits, resources = hits}
            end
        end
        return result
    end
    local function log_conflicts(entry, entries)
        for _, conflict in ipairs(self.conflicts(entry, entries)) do
            log(string.format('conflict: %s (packages/boot %s, deployed at start) also replaces %d of these resources; its version wins: %s',
                conflict.owner or 'a deployed mod', conflict.patch:match('patch_%d+$') or conflict.patch, conflict.count,
                table.concat(conflict.resources, ', ')))
        end
    end
    self.log_conflicts = log_conflicts

    -- Live switch (player builds) -----------------------------------------------
    -- State of a library resource mod: off | scanning | on | turning_off |
    -- unavailable | missing, with progress and per-bundle status.
    local function mounted_in(bundle, index)
        for _, package in ipairs(self.packages or {}) do
            if package.bundle == bundle then
                for _, layer in ipairs(package.layers or {}) do
                    if layer.name == bundle .. '.patch_' .. index then return true end
                end
                return false
            end
        end
        return false
    end
    function self.live_state(entry)
        local record = self.staged[entry.id]
        local state = state_of(entry)
        local scan = state.scan
        local result = {new = scan.new, targets = scan.targets and #scan.targets or 0, message = state.live_message}
        if record then
            result.state = record.pending_remove and 'turning_off' or record.missing and 'missing' or 'on'
            result.bundles, result.active, result.waiting = {}, 0, 0
            for _, file in ipairs(record.files or {}) do
                local loaded = self.loaded_bundles[file.bundle] == true
                local mounted = loaded and mounted_in(file.bundle, file.index)
                result.bundles[#result.bundles + 1] = {bundle = file.bundle, index = file.index, loaded = loaded, mounted = mounted,
                    missing = file.missing}
                if mounted then result.active = result.active + 1 elseif loaded then result.waiting = result.waiting + 1 end
            end
            return result
        end
        if scan.state == 'running' then
            result.state, result.progress = 'scanning', scan.done / math.max(1, scan.total)
        elseif scan.state == 'done' and #scan.targets == 0 then
            result.state = 'unavailable'
        else
            result.state = 'off'
        end
        if #state.archives == 0 then result.state = 'unavailable'; result.no_archive = true end
        local block = mixed_block(entry, state)
        if block then
            result.state, result.reason = 'unavailable', block
            result.boot_only, result.new = scan.boot_only, scan.new
        end
        result.mixed = entry.category == 'MIXED' or nil
        return result
    end
    -- Returns ok, message key (live.*) for the panel.
    function self.live_toggle(entry, entries)
        local state = state_of(entry)
        local record = self.staged[entry.id]
        state.live_message = nil
        if record then
            if record.pending_remove then
                record.pending_remove = nil
                save_staged(); bump()
                notify(entry, true)
                return true, 'live.on'
            end
            notify(entry, false)
            local busy = false
            for _, file in ipairs(record.files or {}) do if self.loaded_bundles[file.bundle] then busy = true end end
            if busy then
                record.pending_remove = true
                save_staged(); bump()
                log('live off requested for ' .. (record.name or '?') .. '; copies are removed when its packages unload')
                return true, 'live.off_pending'
            end
            local ok = self.unstage(entry.id)
            return ok, ok and 'live.off' or 'live.off_kept'
        end
        if #state.archives == 0 then return false, 'live.no_archive' end
        if state.scan.state == 'running' then return false, 'live.scanning' end
        local block = mixed_block(entry, state)
        if block then return false, 'live.mixed_' .. block end
        if state.scan.state == 'done' and state.archive == (state.live_archive or 1) then
            if #state.scan.targets == 0 then return false, 'live.unavailable' end
            local ok, message = self.stage(entry, true)
            if not ok then log('live switch-on failed: ' .. tostring(message)) return false, 'live.failed' end
            notify(entry, true)
            log_conflicts(entry, entries)
            if #self.conflicts(entry, entries) > 0 then return true, 'live.on_conflict' end
            for _, target in ipairs(state.scan.targets) do
                if self.loaded_bundles[target.bundle] then return true, 'live.on_reload' end
            end
            return true, 'live.on'
        end
        state.archive = state.live_archive or 1
        local ok, message = self.scan(entry)
        if not ok then log('live scan failed: ' .. tostring(message)) return false, 'live.failed' end
        state.auto_stage = true
        state.auto_entries = entries
        return true, 'live.scanning'
    end
    -- A mod deployed by the mod manager is loaded from packages/boot; MDL's
    -- copies for it are removed (deployed(entry) -> true).
    function self.reconcile(entries)
        for _, entry in ipairs(entries or {}) do
            local record = self.staged[entry.id]
            if record and entry.deployed and not record.pending_remove then
                log((record.name or '?') .. ' is deployed by ' .. tostring(entry.source) .. '; removing the live copies')
                self.live_toggle(entry)
            end
        end
    end

    -- Logs can_get for every resource of a staged mod.
    function self.log_online(record, why)
        if record and not record.resources and record.files and record.files[1] and record.files[1].paths then
            -- Staged by 1.5.3 or earlier: read the list back from the staged copy.
            local toc = mod_toc({path = record.files[1].paths[1]})
            if toc then
                record.resources = {}
                for _, item in ipairs(toc.entries) do
                    record.resources[#record.resources + 1] = {type = item.type, name = item.name, gpu = item.gpu_size}
                end
                save_staged()
            end
        end
        if not options.can_get or not record or not record.resources then return false, 'Nothing to check.' end
        local lines, online = {}, 0
        for _, item in ipairs(record.resources) do
            local ok, value = pcall(options.can_get, item.type, item.name)
            local yes = ok and value and true or false
            if yes then online = online + 1 end
            lines[#lines + 1] = string.format('    %-9s %s  %s%s', type_name(item.type), item.name, yes and 'online' or 'OFFLINE',
                (item.gpu or 0) > 0 and string.format('  (gpu %.1f MB)', item.gpu / 1048576) or '')
        end
        log(string.format('online check (%s): %s %d/%d online', why or 'manual', record.name or '?', online, #record.resources))
        for _, line in ipairs(lines) do log(line) end
        flush_log(true)
        return true, online .. '/' .. #record.resources .. ' online; details in the lab log.'
    end

    -- How many of the mod's resources are online right now (can_get).
    function self.online(entry)
        local state = state_of(entry)
        local toc = state.scan.toc
        if not toc or not options.can_get then return nil end
        local now = clock()
        if state.online and now - state.online.time < 2 then return state.online end
        local online, total = 0, 0
        for _, item in ipairs(toc.entries) do
            total = total + 1
            local ok, value = pcall(options.can_get, item.type, item.name)
            if ok and value then online = online + 1 end
        end
        state.online = {time = now, online = online, total = total}
        return state.online
    end

    -- Frame step --------------------------------------------------------------
    local next_poll = 0
    spawn(resolve_job, 'resolve')
    function self.step()
        local now = clock()
        local scanning = false
        for _, job in ipairs(jobs) do if job.name == 'scan' then scanning = true end end
        deadline = now + (scanning and scan_budget or budget)
        local i = 1
        while i <= #jobs and not over() do
            local job = jobs[i]
            local ok, why = coroutine.resume(job.co)
            if not ok then
                if job.name == 'resolve' then problem = tostring(why); self.status = 'unavailable: ' .. problem end
                log(job.name .. ' failed: ' .. tostring(why))
                table.remove(jobs, i)
                bump()
            elseif coroutine.status(job.co) == 'dead' then
                table.remove(jobs, i)
                bump()
            else
                i = i + 1
            end
        end
        -- Package monitor: polled only while something needs it (a staged
        -- live mod, a pending online check) or when the debug monitor is on
        -- (options.monitor()). Idle player builds read no package list.
        if layout and now >= next_poll then
            local always = options.monitor and options.monitor() == true
            if always or #pending_checks > 0 then
                next_poll = now + 0.5
                poll()
            elseif next(self.staged) ~= nil then
                next_poll = now + 2
                poll()
            else
                next_poll = now + 1
                self.monitor_idle = true
            end
        end
        flush_log(false)
    end
    function self.resolved() return layout ~= nil, problem end
    -- Debug settings: package load/unload lines in the lab log.
    function self.set_verbose(on) verbose = on == true end
    function self.verbose() return verbose end

    return self
end

return R
