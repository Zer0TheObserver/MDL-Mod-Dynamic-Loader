-- MDL runtime mod manager (MDL API 2).
--
-- Loose mods live in <LOCALAPPDATA>/MDL/Helldivers2/Mods/<id>/mod.lua
-- and can be enabled, disabled and reloaded while the game runs. The manager
-- owns one frame dispatcher, so disabling a mod never breaks another mod's
-- update chain. Native writes made through ctx.write are restored in reverse
-- order on disable. Deployed (boot) addons keep their one-way startup and can
-- only be switched off for the next launch.
local M = {API = 2}

local function traceback(message)
    return debug and debug.traceback and debug.traceback(tostring(message), 2) or tostring(message)
end

-- Serializes plain configuration data into a Lua literal ("return {...}").
local function serialize(value, indent)
    indent = indent or ''
    local kind = type(value)
    if kind == 'string' then return string.format('%q', value) end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return '0' end
        return string.format('%.17g', value)
    end
    if kind == 'boolean' then return tostring(value) end
    if kind ~= 'table' then return 'nil' end
    local keys = {}
    for key in pairs(value) do
        if type(key) == 'string' or type(key) == 'number' then keys[#keys + 1] = key end
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then return a < b end
        return type(a) == 'number'
    end)
    local inner, lines = indent .. '  ', {}
    for _, key in ipairs(keys) do
        local text = serialize(value[key], inner)
        if text ~= 'nil' then
            local label = type(key) == 'string' and key:match('^[%a_][%w_]*$') and key
                or '[' .. serialize(key) .. ']'
            lines[#lines + 1] = inner .. label .. ' = ' .. text
        end
    end
    if #lines == 0 then return '{}' end
    return '{\n' .. table.concat(lines, ',\n') .. '\n' .. indent .. '}'
end
M.serialize = serialize

local function parse_config(text)
    if not text or text == '' then return nil end
    local chunk = loadstring(text, '=MDL.cfg')
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, value = pcall(chunk)
    if ok and type(value) == 'table' then return value end
end
M.parse_config = parse_config

local function valid_id(name)
    return type(name) == 'string' and #name <= 64 and name:match('^[%w_%-]+$') ~= nil
end
M.valid_id = valid_id

-- Windows FILETIME (100 ns since 1601) to seconds since 1970; small values
-- (already seconds, e.g. tests) pass through; 0 / nil -> nil.
function M.unix_time(value)
    value = tonumber(value)
    if not value or value <= 0 then return nil end
    if value > 1e15 then return math.floor(value / 1e7 - 11644473600) end
    return value
end

local function clamp(value, low, high)
    if low and value < low then return low end
    if high and value > high then return high end
    return value
end

-- options = {base_dir=, platform=, globals=_G, log=function(line), boot_control=bool, skip_boot={name=true}}
function M.new(options)
    local G = options.globals or _G
    local platform = assert(options.platform, 'platform required')
    -- High-resolution clock (seconds); os.clock is only ms-accurate on Windows.
    local now = options.clock or os.clock
    -- Heap size in KB for the per-mod allocation rate (false = off).
    local gc_count = options.gc_count
    if gc_count == nil then gc_count = collectgarbage end
    local base = options.base_dir
    local mods_dir = base .. '/Mods'
    local config_path = base .. '/MDL.cfg'
    local self = {
        mods = {},        -- ordered records
        by_id = {},
        queue = {},
        log_lines = {},
        frame_count = 0,
        rescan_every = 2,
        rescan_elapsed = 0,
    }
    platform.mkdir(mods_dir)

    -- Bumped on every visible change so the panel can skip redrawing.
    self.revision = 0
    local function log(line)
        self.revision = self.revision + 1
        line = tostring(line)
        self.log_lines[#self.log_lines + 1] = line
        if #self.log_lines > 200 then table.remove(self.log_lines, 1) end
        if options.log then pcall(options.log, line) end
    end
    self.log = log

    -- Configuration -------------------------------------------------------
    local config = parse_config(platform.read(config_path)) or {}
    config.version = 1
    config.enabled = type(config.enabled) == 'table' and config.enabled or {}
    config.settings = type(config.settings) == 'table' and config.settings or {}
    config.boot_disabled = type(config.boot_disabled) == 'table' and config.boot_disabled or {}
    config.ui = type(config.ui) == 'table' and config.ui or {}
    config.order = type(config.order) == 'table' and config.order or {}
    self.config = config

    local dirty = false
    function self.save() dirty = true; self.revision = self.revision + 1 end
    local function flush()
        if not dirty then return end
        dirty = false
        if not platform.write(config_path, 'return ' .. serialize(config) .. '\n') then
            log('config: write failed')
        end
    end
    self.flush = flush

    -- Mod records ---------------------------------------------------------
    local function record(id, kind)
        local mod = self.by_id[id]
        if mod then return mod end
        mod = {id = id, kind = kind, status = 'disabled', errors = 0, info = {name = id}}
        self.by_id[id] = mod
        self.mods[#self.mods + 1] = mod
        return mod
    end

    local function mod_files_mtime(directory, depth)
        local newest = 0
        for _, entry in ipairs(platform.list(directory)) do
            if entry.dir then
                if depth < 3 then newest = math.max(newest, mod_files_mtime(directory .. '/' .. entry.name, depth + 1)) end
            elseif entry.name:match('%.lua$') then
                newest = math.max(newest, entry.mtime or 0)
            end
        end
        return newest
    end

    function self.scan()
        local seen = {}
        for _, entry in ipairs(platform.list(mods_dir)) do
            if entry.dir and valid_id(entry.name) and platform.read(mods_dir .. '/' .. entry.name .. '/mod.lua') then
                local mod = record(entry.name, 'loose')
                mod.dir = mods_dir .. '/' .. entry.name
                mod.missing = nil
                local icon = mod.dir .. '/icon.png'
                mod.icon = platform.read_head and platform.read_head(icon, 4) and icon or nil
                -- Newest .lua file, for "sort by update time" (seconds since 1970).
                local listed, newest = pcall(mod_files_mtime, mod.dir, 0)
                mod.updated = listed and M.unix_time(newest) or nil
                seen[entry.name] = true
            end
        end
        for _, mod in ipairs(self.mods) do
            if mod.kind == 'loose' and not seen[mod.id] then mod.missing = true end
        end
    end

    -- Mirrors the startup coordinator's module table (MDL or BSL host).
    function self.sync_boot(modules)
        if type(modules) ~= 'table' then return end
        for name, status in pairs(modules) do
            if type(name) == 'string' and not (options.skip_boot and options.skip_boot[name]) then
                local mod = self.by_id[name]
                if not mod then self.register_boot(name, tostring(status))
                elseif mod.kind == 'boot' and mod.boot_status ~= status and mod.status ~= 'restart' then
                    self.register_boot(name, tostring(status))
                end
            end
        end
    end

    -- Boot addons registered by the startup coordinator.
    function self.register_boot(name, status)
        self.revision = self.revision + 1
        local mod = record(name, 'boot')
        mod.boot_status = status
        mod.info.name = (name:match('([^/]+)$') or name):gsub('_', ' ')
        if status == 'loaded' or status == 'loading' then mod.status = 'enabled'
        elseif status == 'disabled by user' then mod.status = 'disabled'
        elseif status == 'not installed' then mod.status = 'missing'
        else mod.status = 'error'; mod.error = status end
        self.settle_launch(name)
    end

    -- Library records of an addon that the game loaded at launch (deployed by
    -- Arsenal / HD2MM) show as such and cannot be started a second time. MDL
    -- starts before the other addons, so this is settled when the
    -- coordinator reports them (first frame), not at the first library scan.
    -- A live copy MDL started earlier is left running but flagged: stopping
    -- it would run its shutdown, which can undo hooks the launch copy shares.
    function self.settle_launch(name)
        local boot = self.by_id[name]
        local loaded = boot and boot.kind == 'boot' and (boot.boot_status == 'loaded' or boot.boot_status == 'loading')
        for _, mod in ipairs(self.mods) do
            if mod.kind == 'packed' and mod.main == name then
                if loaded then
                    mod.launch = true
                    if mod.status == 'enabled' then
                        mod.double = true
                        log(mod.id .. ': also loaded at launch by the mod manager: two copies run. Stop the live copy and restart the game')
                    else
                        mod.status = 'launch'
                    end
                elseif mod.launch then
                    mod.launch = nil
                    if mod.status == 'launch' then mod.status = 'disabled' end
                end
                self.revision = self.revision + 1
            end
        end
    end

    -- Library script addons (kind 'packed') run from their manager archive.
    -- resolve(name) returns a Lua resource body (source or bytecode) or nil.
    function self.register_packed(id, info, main, resolve, extra)
        self.revision = self.revision + 1
        local mod = record(id, 'packed')
        mod.info, mod.base_info = info, info
        mod.main, mod.resolve, mod.dir = main, resolve, extra and extra.dir
        mod.icon = extra and extra.icon
        -- Loaded at launch: the coordinator says so (extra.launch), or the
        -- boot record of the same addon is running.
        local boot = self.by_id[main]
        local boot_loaded = boot and boot.kind == 'boot' and (boot.boot_status == 'loaded' or boot.boot_status == 'loading')
        mod.launch = (extra and extra.launch or boot_loaded) and true or nil
        if mod.launch and mod.status ~= 'enabled' then mod.status = 'launch' end
        if not mod.launch and mod.status == 'launch' then mod.status = 'disabled' end
        -- A new version imported into the library while the addon runs live:
        -- reload it from the new files (auto reload on), else mark it.
        mod.stamp = extra and extra.stamp or nil
        if mod.status == 'enabled' and mod.stamp and mod.loaded_stamp and mod.stamp ~= mod.loaded_stamp then
            if config.ui.auto_reload then
                if not mod.reload_queued then
                    mod.reload_queued = true
                    log(id .. ': new version in the library, reloading')
                    self.request('reload', mod)
                end
            elseif not mod.outdated then
                mod.outdated = true
                log(id .. ': new version in the library (reload it to use it)')
            end
        else
            mod.outdated = nil
        end
        return mod
    end

    local function live(mod) return mod.kind == 'loose' or mod.kind == 'packed' end
    self.is_live = live

    -- Memory estimate (mdl_memory): what belongs to a running live mod, and
    -- what belongs to others (other mods' roots, MDL's own records).
    local function add(list, value) if value ~= nil then list[#list + 1] = value end end
    self.own_source = debug and debug.getinfo and debug.getinfo(1, 'S').source or nil
    function self.memory_scope(mod)
        if not live(mod) or mod.status ~= 'enabled' or not mod.env then return nil end
        local roots = {}
        add(roots, mod.env); add(roots, mod.legacy); add(roots, mod.package); add(roots, mod.def); add(roots, mod.ctx)
        for _, task in ipairs(mod.tasks or {}) do add(roots, task.co) end
        for _, cleanup in ipairs(mod.cleanups or {}) do add(roots, cleanup) end
        for name in pairs(mod.globals or {}) do add(roots, rawget(G, name)) end
        local stop, foreign = {mod, self, config, self.mods, self.by_id}, {}
        for _, other in ipairs(self.mods) do
            if other ~= mod then
                add(stop, other); add(stop, other.env); add(stop, other.legacy); add(stop, other.package)
                add(stop, other.def); add(stop, other.ctx)
                for name in pairs(other.globals or {}) do add(stop, rawget(G, name)) end
                foreign[#foreign + 1] = '@' .. other.id .. '/'
            end
        end
        return {roots = roots, owned = mod.globals or {}, stop = stop, foreign = foreign}
    end

    -- Sandboxed environment -----------------------------------------------
    local function load_file(mod, relative)
        local source
        if mod.kind == 'packed' then
            source = mod.resolve(relative)
            if not source then return nil, 'missing resource ' .. relative end
        else
            source = platform.read(mod.dir .. '/' .. relative)
            if not source then return nil, 'missing ' .. relative end
        end
        if source:sub(1, 3) == '\239\187\191' then source = source:sub(4) end
        local chunk, reason = loadstring(source, '@' .. mod.id .. '/' .. relative)
        if not chunk then return nil, reason end
        setfenv(chunk, mod.env)
        return chunk
    end

    -- Scripts written for the game chain read `update`/`shutdown` to wrap
    -- them and often refuse to start when they are not functions. They get
    -- no-op stand-ins instead of the real game callbacks, so the loader's own
    -- dispatcher never runs the game's update twice.
    local function stand_in() end
    -- The game callbacks a script may read or replace. Every way a script can
    -- reach them - a plain global, _G.update, rawget(_G, 'update'),
    -- rawset(_G, 'update', f) - goes through the capture; the real ones
    -- contain the loader itself, and calling them from a live update would
    -- run the whole frame again (Advanced Tank Camera did rawget(_G, 'update')).
    local CALLBACKS = {update = true, shutdown = true, init = true}
    M.CALLBACKS = CALLBACKS

    -- Engine objects and native memory a live mod creates (1.8.5). A mod
    -- that runs in MDL's environment sees its own views of `stingray`,
    -- `World` and `require('ffi')`: the same functions, except that the
    -- creating / destroying ones below also note what they made. Nothing
    -- else changes; values are looked up once and cached in the view.
    -- Off with ui.track_engine = false (applies the next time a mod starts).
    local function tracking()
        local value = config.ui.track_engine
        if value == nil then return options.track_engine_default == true end
        return value == true
    end
    self.tracking = tracking
    local function new_tracker()
        return {units = setmetatable({}, {__mode = 'k'}), guis = {}, particles = {}, lines = {},
            native = {}, native_bytes = 0, native_blocks = 0}
    end
    local function add_returned(fn, set)
        return function(...)
            local a, b, c, d = fn(...)
            if a ~= nil then set[a] = true end
            return a, b, c, d
        end
    end
    local function remove_argument(fn, set)
        return function(world, target, ...)
            if target ~= nil then set[target] = nil end
            return fn(world, target, ...)
        end
    end
    M.TRACKED_WORLD = {spawn_unit = 'units', destroy_unit = 'units', create_screen_gui = 'guis', create_world_gui = 'guis',
        destroy_gui = 'guis', create_particles = 'particles', destroy_particles = 'particles',
        create_line_object = 'lines', destroy_line_object = 'lines'}
    -- Views are full copies (pairs over them works like over the real
    -- tables), with __index for keys the engine adds later.
    local function copy_view(real, convert)
        local view = {}
        for key, value in pairs(real) do view[key] = convert(key, value) end
        return setmetatable(view, {__index = function(t, key)
            local value = real[key]
            if value ~= nil then value = convert(key, value); rawset(t, key, value) end
            return value
        end})
    end
    local function world_view(real, track)
        return copy_view(real, function(key, value)
            local set = M.TRACKED_WORLD[key]
            if set and type(value) == 'function' then
                return (key:match('^destroy') and remove_argument or add_returned)(value, track[set])
            end
            return value
        end)
    end
    local function engine_view(real, track)
        local world = type(real.World) == 'table' and world_view(real.World, track) or nil
        return copy_view(real, function(key, value)
            if key == 'World' and world then return world end
            return value
        end), world
    end
    -- Native blocks by address; sizes from the allocation call.
    local function native_view(ffi, track)
        local okay = pcall(ffi.typeof, 'uintptr_t')
        if not okay then return nil end
        local function key_of(pointer) return tonumber(ffi.cast('uintptr_t', pointer)) end
        local function note(pointer, size)
            if pointer == nil then return end
            local key = key_of(pointer)
            local old = track.native[key]
            size = tonumber(size) or 0
            if old then
                if size > old then track.native_bytes = track.native_bytes + size - old; track.native[key] = size end
            else
                track.native[key] = size
                track.native_bytes = track.native_bytes + size
                track.native_blocks = track.native_blocks + 1
            end
        end
        local function forget(pointer)
            if pointer == nil then return end
            local key = key_of(pointer)
            local old = track.native[key]
            if old then
                track.native[key] = nil
                track.native_bytes = track.native_bytes - old
                track.native_blocks = track.native_blocks - 1
            end
        end
        local WRAP = {
            VirtualAlloc = function(fn) return function(address, size, kind, protect)
                local pointer = fn(address, size, kind, protect)
                note(pointer, size)
                return pointer
            end end,
            VirtualFree = function(fn) return function(address, size, kind)
                local result = fn(address, size, kind)
                if tonumber(kind) == 0x8000 then forget(address) end
                return result
            end end,
            malloc = function(fn) return function(size) local pointer = fn(size); note(pointer, size); return pointer end end,
            calloc = function(fn) return function(count, size)
                local pointer = fn(count, size)
                note(pointer, (tonumber(count) or 0) * (tonumber(size) or 0))
                return pointer
            end end,
            free = function(fn) return function(pointer) forget(pointer); return fn(pointer) end end,
            HeapAlloc = function(fn) return function(heap, flags, size)
                local pointer = fn(heap, flags, size)
                note(pointer, size)
                return pointer
            end end,
            HeapFree = function(fn) return function(heap, flags, pointer)
                local result = fn(heap, flags, pointer)
                forget(pointer)
                return result
            end end,
        }
        local C = ffi.C
        local c_view = setmetatable({}, {__index = function(view, key)
            local value = C[key]
            if WRAP[key] then value = WRAP[key](value) end
            rawset(view, key, value)
            return value
        end})
        return copy_view(ffi, function(key, value)
            if key == 'C' then return c_view end
            return value
        end)
    end
    -- What a stopped / running mod still has: live units (checked with
    -- Unit.alive when the engine offers it), GUIs, effects, native memory.
    function self.engine_counts(mod)
        local track = mod.engine
        if not track then return nil end
        local units = 0
        local engine = rawget(G, 'stingray')
        local alive = engine and engine.Unit and engine.Unit.alive
        for unit in pairs(track.units) do
            local ok, is_alive = true, true
            if alive then ok, is_alive = pcall(alive, unit) end
            if ok and is_alive then units = units + 1 else track.units[unit] = nil end
        end
        local function count(set) local n = 0 for _ in pairs(set) do n = n + 1 end return n end
        return {units = units, guis = count(track.guis), particles = count(track.particles), lines = count(track.lines),
            native_bytes = track.native_bytes, native_blocks = track.native_blocks}
    end
    local function make_env(mod)
        local captured = {}
        mod.legacy, mod.globals, mod.package = captured, {}, {}
        -- Tracking views (see above): stingray / World / ffi of this mod.
        local views = {}
        mod.engine = nil
        if tracking() then
            local track = new_tracker()
            mod.engine = track
            local real = rawget(G, 'stingray')
            if type(real) == 'table' then
                local view, world = engine_view(real, track)
                views.stingray = view
                if world and rawget(G, 'World') == real.World then views.World = world end
            end
            local has_ffi, ffi = pcall(G.require, 'ffi')
            if has_ffi and type(ffi) == 'table' then
                local made, view = pcall(native_view, ffi, track)
                if made and view then views.ffi = view end
            end
        end
        local function callback(key)
            if key == 'init' then return captured.init end
            return captured[key] or stand_in
        end
        -- _G for the script: reads/writes the real globals (shared state
        -- between mods keeps working) except the callbacks above.
        local global_view = setmetatable({}, {
            __index = function(_, key)
                if CALLBACKS[key] then return callback(key) end
                if views[key] then return views[key] end
                return G[key]
            end,
            __newindex = function(_, key, value)
                if CALLBACKS[key] then captured[key] = value return end
                mod.globals[key] = true
                G[key] = value
            end,
        })
        local env = {}
        setmetatable(env, {
            __index = function(_, key)
                if CALLBACKS[key] then return callback(key) end
                if key == '_G' then return global_view end
                if views[key] then return views[key] end
                return G[key]
            end,
            __newindex = function(t, key, value)
                if key == 'update' or key == 'shutdown' then captured[key] = value
                else rawset(t, key, value) end
            end,
        })
        env.rawget = function(t, key)
            if t == global_view or t == G then
                if CALLBACKS[key] then return callback(key) end
                if views[key] then return views[key] end
                return rawget(G, key)
            end
            return rawget(t, key)
        end
        env.rawset = function(t, key, value)
            if t == global_view or t == G then
                if CALLBACKS[key] then captured[key] = value return t end
                mod.globals[key] = true
                rawset(G, key, value)
                return t
            end
            return rawset(t, key, value)
        end
        env.require = function(name)
            local cached = mod.package[name]
            if cached ~= nil then return cached end
            if mod.kind == 'packed' and type(name) == 'string' and mod.resolve(name) then
                local chunk = assert(load_file(mod, name))
                local result = chunk(name)
                if result == nil then result = true end
                mod.package[name] = result
                return result
            end
            if mod.kind == 'loose' and type(name) == 'string' and name:match('^[%w_%-%./]+$') and not name:find('..', 1, true) then
                local relative = name:gsub('%.lua$', ''):gsub('%.', '/') .. '.lua'
                if platform.read(mod.dir .. '/' .. relative) then
                    local chunk = assert(load_file(mod, relative))
                    local result = chunk(name)
                    if result == nil then result = true end
                    mod.package[name] = result
                    return result
                end
            end
            if name == 'ffi' and views.ffi then return views.ffi end
            return G.require(name)
        end
        mod.env = env
        return env
    end

    -- Per-mod context (hot API 2) -------------------------------------------
    local function make_ctx(mod)
        local ctx = {id = mod.id, dir = mod.dir, api = M.API, mdl = rawget(G, 'MDL'), loader = G.CowboyBingusModLoader}
        mod.cleanups, mod.patches = {}, {}
        config.settings[mod.id] = config.settings[mod.id] or {}
        ctx.settings = config.settings[mod.id]
        function ctx.log(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
            log('[' .. mod.id .. '] ' .. table.concat(parts, ' '))
        end
        function ctx.set(key, value)
            ctx.settings[key] = value
            self.save()
        end
        function ctx.on_cleanup(fn)
            assert(type(fn) == 'function', 'cleanup must be a function')
            mod.cleanups[#mod.cleanups + 1] = fn
        end
        function ctx.global(name, value)
            mod.globals[name] = true
            rawset(G, name, value)
            return value
        end
        -- Idempotent ffi.cdef: structs that already exist are skipped, so a
        -- reloaded mod can repeat its declarations.
        function ctx.cdef(declarations)
            local ffi = G.require('ffi')
            local ok, reason = pcall(ffi.cdef, declarations)
            if ok then return true end
            if not tostring(reason):find('redefine', 1, true) then error(reason, 2) end
            local depth, start = 0, 1
            for i = 1, #declarations do
                local c = declarations:sub(i, i)
                if c == '{' then depth = depth + 1
                elseif c == '}' then depth = depth - 1
                elseif c == ';' and depth == 0 then
                    local piece = declarations:sub(start, i)
                    start = i + 1
                    if piece:find('%S') then
                        local single_ok, single_reason = pcall(ffi.cdef, piece)
                        if not single_ok and not tostring(single_reason):find('redefine', 1, true) then
                            error(single_reason, 2)
                        end
                    end
                end
            end
            return true
        end
        function ctx.module(name) return platform.module(name) end
        function ctx.read(address, size) return platform.mem_read(address, size) end
        -- Transactional write: remembers the original bytes and restores them
        -- on disable if the location still holds what this mod wrote.
        function ctx.write(address, bytes, expected)
            local original = platform.mem_read(address, #bytes)
            if not original then return false, 'read failed' end
            if expected and original ~= expected then return false, 'unexpected original bytes' end
            if original == bytes then return true end
            if not platform.mem_write(address, bytes) then return false, 'write failed' end
            if platform.mem_read(address, #bytes) ~= bytes then
                platform.mem_write(address, original)
                return false, 'verification failed'
            end
            local key = platform.address_key and platform.address_key(address) or address
            local first
            for _, patch in ipairs(mod.patches) do
                if patch.key == key and #patch.original == #bytes then first = patch break end
            end
            if first then first.written = bytes
            else mod.patches[#mod.patches + 1] = {address = address, key = key, original = original, written = bytes} end
            return true
        end
        -- Cooperative background tasks (coroutines). The loader resumes them
        -- after the frame's updates within a shared time budget, so long work
        -- (scans, parsing, retries) is spread over frames instead of blocking
        -- one. Lua cannot be preempted: tasks must call ctx.yield(),
        -- ctx.checkpoint(), ctx.sleep() or ctx.wait_frames() regularly.
        mod.tasks = {}
        function ctx.spawn(fn, ...)
            assert(type(fn) == 'function', 'spawn expects a function')
            local args, count = {...}, select('#', ...)
            local task = {co = coroutine.create(function() return fn(unpack(args, 1, count)) end), wake = 0, frames = 0}
            mod.tasks[#mod.tasks + 1] = task
            function task.cancel() task.dead = true end
            function task.done() return task.dead == true end
            return task
        end
        function ctx.yield() coroutine.yield() end
        function ctx.sleep(seconds) coroutine.yield('sleep', seconds) end
        function ctx.wait_frames(frames) coroutine.yield('frames', frames) end
        -- Yields only when this frame's task budget is used up; cheap enough
        -- to call inside tight loops.
        function ctx.checkpoint()
            if now() > (self.task_deadline or 0) then coroutine.yield() end
        end
        -- Signature scan over [base, base+size) inside a task, yielding at
        -- checkpoints. Pattern: "48 8B ?? ..." Returns offsets (numbers).
        function ctx.scan(base, size, signature, limit)
            assert(coroutine.running(), 'ctx.scan must run inside ctx.spawn')
            local ffi = G.require('ffi')
            local bytes = ffi.cast('const uint8_t *', base)
            local pattern = {}
            for token in signature:gmatch('%S+') do pattern[#pattern + 1] = token == '??' and -1 or tonumber(token, 16) end
            local first, count, hits = pattern[1], #pattern, {}
            for i = 0, size - count do
                if bytes[i] == first then
                    local matched = true
                    for j = 2, count do
                        local want = pattern[j]
                        if want >= 0 and bytes[i + j - 1] ~= want then matched = false break end
                    end
                    if matched then
                        hits[#hits + 1] = i
                        if limit and #hits >= limit then return hits end
                    end
                end
                if i % 65536 == 0 then ctx.checkpoint() end
            end
            return hits
        end

        function ctx.restore(address)
            local key = platform.address_key and platform.address_key(address) or address
            for i = #mod.patches, 1, -1 do
                local patch = mod.patches[i]
                if patch.key == key then
                    table.remove(mod.patches, i)
                    return platform.mem_write(patch.address, patch.original)
                end
            end
            return false
        end
        mod.ctx = ctx
        return ctx
    end

    local function option_value(mod, option)
        local value = mod.ctx and mod.ctx.settings[option.key]
        if value == nil then value = option.default end
        return value
    end
    self.option_value = option_value

    local function apply_defaults(mod)
        local def = mod.def
        if type(def) ~= 'table' or type(def.options) ~= 'table' then return end
        for _, option in ipairs(def.options) do
            if type(option) == 'table' and option.key ~= nil and mod.ctx.settings[option.key] == nil
                and option.default ~= nil then
                mod.ctx.settings[option.key] = option.default
            end
        end
    end

    -- Lifecycle -------------------------------------------------------------
    local function teardown(mod)
        local problems = {}
        if type(mod.def) == 'table' and type(mod.def.on_disable) == 'function' then
            local ok, reason = xpcall(function() mod.def.on_disable(mod.ctx) end, traceback)
            if not ok then problems[#problems + 1] = 'on_disable: ' .. tostring(reason) end
        end
        if type(mod.legacy) == 'table' and type(mod.legacy.shutdown) == 'function' and mod.legacy.shutdown ~= stand_in then
            local ok, reason = xpcall(mod.legacy.shutdown, traceback)
            if not ok then problems[#problems + 1] = 'shutdown: ' .. tostring(reason) end
        end
        for i = #(mod.cleanups or {}), 1, -1 do
            local ok, reason = xpcall(mod.cleanups[i], traceback)
            if not ok then problems[#problems + 1] = 'cleanup: ' .. tostring(reason) end
        end
        for i = #(mod.patches or {}), 1, -1 do
            local patch = mod.patches[i]
            local current = platform.mem_read(patch.address, #patch.written)
            if current == patch.written then
                if not platform.mem_write(patch.address, patch.original) then
                    problems[#problems + 1] = 'restore failed at ' .. tostring(patch.key)
                end
            else
                problems[#problems + 1] = 'restore skipped (bytes changed by others) at ' .. tostring(patch.key)
            end
        end
        mod.tasks = nil
        for name in pairs(mod.globals or {}) do rawset(G, name, nil) end
        mod.def, mod.env, mod.ctx, mod.legacy = nil, nil, nil, nil
        mod.cleanups, mod.patches, mod.globals, mod.package = nil, nil, nil, nil
        return problems
    end

    local function enable_loose(mod)
        if mod.missing then return false, 'mod folder missing' end
        make_env(mod)
        local ctx = make_ctx(mod)
        local ok, result = xpcall(function()
            local chunk = assert(load_file(mod, mod.kind == 'packed' and mod.main or 'mod.lua'))
            return chunk(ctx)
        end, traceback)
        if ok and type(result) == 'table' then
            mod.def = result
            mod.info = {
                name = type(result.name) == 'string' and result.name or mod.id,
                version = result.version and tostring(result.version) or nil,
                author = type(result.author) == 'string' and result.author or nil,
                description = type(result.description) == 'string' and result.description or nil,
            }
            if mod.kind == 'loose' and type(result.icon) == 'string' and result.icon:match('^[%w_%-%./]+$') and not result.icon:find('..', 1, true) then
                mod.icon = mod.dir .. '/' .. result.icon
            end
            apply_defaults(mod)
            if type(result.on_enable) == 'function' then
                ok, result = xpcall(function() return result.on_enable(ctx) end, traceback)
            end
        elseif ok then
            mod.def = {}
            mod.info = mod.base_info or {name = mod.id, description = 'legacy script (update/shutdown captured)'}
            if type(mod.legacy.update) ~= 'function' and type(mod.legacy.shutdown) ~= 'function' then
                -- Running but idle: typically the script rejected itself (see its own log).
                mod.warning = 'Started but installed no update callback; it may have stopped itself - check its own log'
                log(mod.id .. ': ' .. mod.warning)
            end
        end
        if not ok then
            teardown(mod)
            return false, result
        end
        return true
    end

    function self.enable(mod)
        if mod.status == 'enabled' then return true end
        if mod.status == 'launch' then
            mod.error = 'Already running: deployed by the manager and loaded at launch'
            return false, mod.error
        end
        if mod.kind == 'boot' then
            config.boot_disabled[mod.id] = nil
            self.save()
            if mod.boot_status == 'loaded' then mod.status = 'enabled' return true end
            local application = G.stingray and G.stingray.Application
            local ok, reason = pcall(function()
                assert(application and application.can_get('lua', mod.id), 'resource not deployed')
                return G.require(mod.id)
            end)
            mod.boot_status = ok and 'loaded' or 'load failed: ' .. tostring(reason)
            mod.status, mod.error = ok and 'enabled' or 'error', not ok and tostring(reason) or nil
            local shared = G.CowboyBingusModLoader
            if shared and shared.modules then shared.modules[mod.id] = mod.boot_status end
            log(mod.id .. ': ' .. mod.boot_status)
            return ok, reason
        end
        mod.errors, mod.error, mod.warning, mod.cost, mod.peak, mod.alloc, mod.double = 0, nil, nil, nil, nil, nil, nil
        local ok, reason = enable_loose(mod)
        if ok then
            mod.status = 'enabled'
            mod.loaded_mtime = mod.kind == 'loose' and mod_files_mtime(mod.dir, 0) or nil
            mod.loaded_stamp, mod.outdated = mod.stamp, nil
            config.enabled[mod.id] = true
            log(mod.id .. ': enabled')
        else
            mod.status, mod.error = 'error', tostring(reason)
            log(mod.id .. ': enable failed: ' .. mod.error)
        end
        self.save()
        return ok, reason
    end

    function self.disable(mod, keep_config)
        if mod.kind == 'boot' and not options.boot_control then
            mod.error = 'Startup is managed by Bingus Shared Loader; deploy MDL as the startup loader to switch addons off'
            return false
        end
        if mod.kind == 'boot' then
            -- Deployed addons patch the game chain themselves; they cannot be
            -- unloaded safely, so the choice applies from the next launch.
            config.boot_disabled[mod.id] = true
            self.save()
            if mod.status == 'enabled' then mod.status = 'restart' end
            log(mod.id .. ': disabled from next launch')
            return true
        end
        if mod.status == 'launch' then return false end
        if mod.status ~= 'enabled' then
            if not keep_config then config.enabled[mod.id] = nil; self.save() end
            mod.status = mod.status == 'error' and 'error' or 'disabled'
            return true
        end
        local problems = teardown(mod)
        mod.status = mod.launch and 'launch' or 'disabled'
        mod.double = nil
        if #problems > 0 then
            mod.error = table.concat(problems, '; ')
            log(mod.id .. ': disabled with problems: ' .. mod.error)
        else
            log(mod.id .. ': disabled')
        end
        if not keep_config then config.enabled[mod.id] = nil end
        self.save()
        return #problems == 0
    end

    function self.reload(mod)
        mod.reload_queued = nil
        if mod.kind == 'boot' then return false, 'boot addons cannot be reloaded' end
        local was_enabled = mod.status == 'enabled' or mod.status == 'error'
        self.disable(mod, true)
        mod.status = 'disabled'
        if was_enabled or config.enabled[mod.id] then return self.enable(mod) end
        return true
    end

    function self.toggle(mod)
        if mod.status == 'enabled' then return self.disable(mod) end
        if mod.kind == 'boot' and mod.status == 'restart' then
            config.boot_disabled[mod.id] = nil
            mod.status = 'enabled'
            self.save()
            return true
        end
        return self.enable(mod)
    end

    function self.set_option(mod, option, value)
        if not mod.ctx then
            config.settings[mod.id] = config.settings[mod.id] or {}
            config.settings[mod.id][option.key] = value
            self.save()
            return
        end
        mod.ctx.settings[option.key] = value
        self.save()
        if type(mod.def.on_setting) == 'function' then
            local ok, reason = xpcall(function() mod.def.on_setting(mod.ctx, option.key, value) end, traceback)
            if not ok then mod.error = tostring(reason); log(mod.id .. ': on_setting failed: ' .. mod.error) end
        end
    end

    function self.action(mod, option)
        if mod.ctx and type(mod.def.on_action) == 'function' then
            local ok, reason = xpcall(function() mod.def.on_action(mod.ctx, option.key) end, traceback)
            if not ok then mod.error = tostring(reason); log(mod.id .. ': on_action failed: ' .. mod.error) end
        end
    end

    -- UI and external callers queue work; it runs at the start of a frame.
    function self.request(kind, mod, a, b)
        self.queue[#self.queue + 1] = {kind = kind, mod = mod, a = a, b = b}
    end

    local function run_queue()
        local queue = self.queue
        if #queue == 0 then return end
        self.queue = {}
        for _, item in ipairs(queue) do
            local handler = self[item.kind]
            if handler then
                local ok, reason = xpcall(function() return handler(item.mod, item.a, item.b) end, traceback)
                if not ok then log('request ' .. item.kind .. ' failed: ' .. tostring(reason)) end
            end
        end
    end

    -- Frame dispatch ----------------------------------------------------------
    local MAX_ERRORS = 5
    local function fail(mod, reason)
        mod.errors = mod.errors + 1
        mod.error = tostring(reason)
        if mod.errors >= MAX_ERRORS then
            log(mod.id .. ': auto-disabled after repeated errors: ' .. mod.error)
            local last = mod.error
            self.disable(mod)
            mod.error = last
            mod.status = 'error'
        end
    end

    -- High-resolution clock (seconds) for per-mod frame cost; os.clock is
    -- only millisecond-accurate on Windows.
    -- Optional per-mod update rate (1 = every frame, 2/4/8 = every Nth frame,
    -- dt accumulated). Phases are staggered so throttled mods do not all run
    -- on the same frame.
    config.rates = type(config.rates) == 'table' and config.rates or {}
    local RATES = {1, 2, 3, 4, 5, 6, 7, 8}   -- run every Nth frame
    self.RATES = RATES
    self.MAX_RATE = RATES[#RATES]
    local function phase_of(id)
        local h = 0
        for i = 1, #id do h = (h * 31 + id:byte(i)) % 65521 end
        return h
    end
    function self.rate(mod) return tonumber(config.rates[mod.id]) or 1 end
    function self.set_rate(mod, rate)
        local valid = false
        for _, value in ipairs(RATES) do if value == rate then valid = true end end
        if not valid then return false end
        config.rates[mod.id] = rate ~= 1 and rate or nil
        mod.skipped_dt = 0
        self.revision = (self.revision or 0) + 1
        self.save()
        return true
    end

    self.task_budget = 1.0 -- ms per frame for all background tasks
    -- Round-robin over mods (rotating start) and over each mod's tasks; a
    -- task that used up the budget goes to the back of its queue so the
    -- others are not starved.
    local function run_tasks()
        local any = false
        for _, mod in ipairs(self.mods) do
            if mod.tasks and #mod.tasks > 0 and mod.status == 'enabled' then any = true break end
        end
        if not any then return end
        local budget = (tonumber(config.ui.task_budget_ms) or self.task_budget) / 1000
        local started = now()
        self.task_deadline = started + budget
        local clock_now = started
        local count = #self.mods
        if count == 0 then return end
        local first = self.frame_count % count
        for step = 0, count - 1 do
            local mod = self.mods[(first + step) % count + 1]
            local tasks = mod.status == 'enabled' and mod.tasks
            if tasks and #tasks > 0 then
                local i = 1
                while i <= #tasks do
                    local task = tasks[i]
                    local runnable = not task.dead and clock_now >= task.wake and task.frames <= 0
                    if task.frames > 0 then task.frames = task.frames - 1 end
                    if runnable then
                        local ok, kind, value = coroutine.resume(task.co)
                        if not ok then
                            task.dead = true
                            mod.error = 'task: ' .. tostring(kind)
                            log(mod.id .. ': background task failed: ' .. tostring(kind))
                        elseif coroutine.status(task.co) == 'dead' then
                            task.dead = true
                        elseif kind == 'sleep' then
                            task.wake = clock_now + (tonumber(value) or 0)
                        elseif kind == 'frames' then
                            task.frames = math.max(0, (tonumber(value) or 1) - 1)
                        end
                        clock_now = now()
                    end
                    if task.dead then
                        table.remove(tasks, i)
                    elseif runnable and clock_now > self.task_deadline then
                        table.remove(tasks, i)
                        tasks[#tasks + 1] = task
                        return
                    else
                        i = i + 1
                    end
                    if clock_now > self.task_deadline then return end
                end
            end
        end
    end

    -- Called by the runtime when the game's update was entered again while a
    -- frame is running (a live script got hold of the real update and called it).
    function self.reentered()
        local mod = self.current
        if mod and not mod.reentry_noted then
            mod.reentry_noted = true
            mod.warning = 're-entered the game update from its own update; the extra call was ignored'
            log(mod.id .. ': ' .. mod.warning)
        end
    end

    function self.frame(dt)
        self.frame_dt = dt
        self.frame_count = self.frame_count + 1
        -- Time spent inside mods this frame (updates and their tasks), so
        -- the runtime can report MDL's own cost without it.
        local mods_ms = 0
        if #self.queue > 0 then run_queue() end
        for _, mod in ipairs(self.mods) do
            local rate = mod.status == 'enabled' and config.rates[mod.id]
            local skip = false
            if rate and rate > 1 and live(mod) then
                mod.skipped_dt = (mod.skipped_dt or 0) + (dt or 0)
                mod.phase = mod.phase or phase_of(mod.id)
                if (self.frame_count + mod.phase) % rate ~= 0 then skip = true
                else dt, mod.skipped_dt = mod.skipped_dt, 0 end
            end
            if not skip and mod.status == 'enabled' and live(mod) then
                self.current = mod
                local heap_before = gc_count and gc_count('count')
                local started = now()
                local def, legacy = mod.def, mod.legacy
                if def and type(def.on_update) == 'function' then
                    local ok, reason = xpcall(def.on_update, traceback, mod.ctx, dt)
                    if not ok then fail(mod, reason) end
                end
                if mod.status == 'enabled' and legacy and type(legacy.update) == 'function' and legacy.update ~= stand_in then
                    local ok, reason = xpcall(legacy.update, traceback, dt)
                    if not ok then fail(mod, reason) end
                end
                self.current = nil
                local spent = (now() - started) * 1000
                mods_ms = mods_ms + spent
                mod.cost = mod.cost and (mod.cost * 0.95 + spent * 0.05) or spent
                if not mod.peak or spent > mod.peak then mod.peak = spent end
                -- Lua allocation rate (KB/s) of the update: heap growth across
                -- the call. A frame where the collector ran inside the call
                -- (the heap shrank) is left out, so this leans low.
                if heap_before then
                    local grown = gc_count('count') - heap_before
                    if grown >= 0 and (dt or 0) > 0 then
                        local rate = grown / dt
                        mod.alloc = mod.alloc and (mod.alloc * 0.95 + rate * 0.05) or rate
                    end
                end
            end
            dt = self.frame_dt
        end
        local tasks_started = now()
        run_tasks()
        mods_ms = mods_ms + (now() - tasks_started) * 1000
        self.frame_mods_ms = mods_ms
        if config.ui.auto_reload then
            self.rescan_elapsed = self.rescan_elapsed + (dt or 0)
            -- A directory change notification (when the platform offers one)
            -- is checked 4x per second and costs nothing until files change;
            -- without it the folder is polled every 2 s.
            local due = false
            if self.watcher == nil then self.watcher = platform.watch and platform.watch(mods_dir) or false end
            if self.watcher then
                if self.rescan_elapsed >= 0.25 then
                    self.rescan_elapsed = 0
                    due = self.watcher.changed()
                end
            elseif self.rescan_elapsed >= self.rescan_every then
                self.rescan_elapsed = 0
                due = true
            end
            if due then
                self.scan()
                for _, mod in ipairs(self.mods) do
                    if mod.kind == 'loose' and mod.status == 'enabled' and not mod.missing then
                        local mtime = mod_files_mtime(mod.dir, 0)
                        if mod.loaded_mtime and mtime > mod.loaded_mtime then
                            log(mod.id .. ': files changed, reloading')
                            self.reload(mod)
                        end
                    end
                end
            end
        end
        flush()
    end

    function self.shutdown()
        if self.watcher then pcall(self.watcher.close); self.watcher = nil end
        for i = #self.mods, 1, -1 do
            local mod = self.mods[i]
            if live(mod) and mod.status == 'enabled' then
                if type(mod.def) == 'table' and type(mod.def.on_shutdown) == 'function' then
                    pcall(mod.def.on_shutdown, mod.ctx)
                end
                self.disable(mod, true)
            end
        end
        flush()
    end

    -- Startup: enable remembered loose mods in folder order.
    -- start_options.defer_packed: library addons are restored later with
    -- restore_packed(), once the coordinator has said which addons it loaded
    -- at launch (those must not be started a second time).
    function self.start(start_options)
        self.scan()
        local defer = start_options and start_options.defer_packed
        for _, mod in ipairs(self.mods) do
            if live(mod) and config.enabled[mod.id] and mod.status ~= 'enabled' and mod.status ~= 'launch'
                and not (defer and mod.kind == 'packed') then
                self.enable(mod)
            end
        end
        self.packed_deferred = defer or nil
        flush()
    end
    function self.restore_packed()
        if not self.packed_deferred then return end
        self.packed_deferred = nil
        for _, mod in ipairs(self.mods) do
            if mod.kind == 'packed' and config.enabled[mod.id] and mod.status ~= 'enabled' and mod.status ~= 'launch' then
                self.enable(mod)
            end
        end
    end

    return self
end

return M
