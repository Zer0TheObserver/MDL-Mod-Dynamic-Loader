-- MDL memory estimate per live mod (1.8.4).
--
-- LuaJIT keeps every mod in one shared heap, so there is no exact per-mod
-- number. This walks the objects a mod can reach from its own roots (its
-- environment, captured callbacks, required modules, context, tasks and the
-- globals it created) and adds up an estimate of their size. It stops at
-- anything shared: _G itself, globals the mod did not create (and the values
-- directly inside them, e.g. math.floor or ModOptionsMenu.register_option),
-- other mods' roots and MDL's own functions.
--
-- What it cannot see: memory the engine allocates for the mod (spawned units,
-- GUIs, textures, physics), FFI memory from malloc/VirtualAlloc, and objects
-- the mod shares with other code are counted for every mod holding them.
--
-- Sizes follow LuaJIT 2.1 without GC64 (the game's build): table 40 B +
-- 8 B per array slot + 24 B per hash node (powers of two), string 24 B +
-- length, Lua closure 24 B + 4 B per upvalue, upvalue 24 B, prototype about
-- its string.dump size, cdata 16 B + ffi.sizeof. Coroutines: 1 KB plus what
-- their stacks reach.
--
-- The walk is resumable: step(seconds) does at most that much work, so a big
-- mod is measured over a few frames instead of in one hitch.
local M = {}

M.TABLE, M.SLOT, M.NODE = 40, 8, 24
M.STRING, M.CLOSURE, M.UPVALUE, M.CDATA, M.THREAD, M.PROTO = 24, 24, 24, 16, 1024, 64
M.MAX_OBJECTS = 500000

local function pow2(n)
    local s = 1
    while s < n do s = s * 2 end
    return s
end
M.pow2 = pow2

function M.table_bytes(array, hash)
    return M.TABLE + (array > 0 and pow2(array + 1) * M.SLOT or 0) + (hash > 0 and pow2(hash) * M.NODE or 0)
end

-- "1.23 MB" / "456 KB" / "789 B".
function M.format(bytes)
    if not bytes then return '-' end
    if bytes >= 1048576 then return string.format('%.2f MB', bytes / 1048576) end
    if bytes >= 1024 then return string.format('%.0f KB', bytes / 1024) end
    return string.format('%d B', bytes)
end

-- options:
--   scope(mod) -> {roots = {...}, owned = {global key = true}, stop = {...},
--                  foreign = {'@<other mod id>/', ...}} or nil (not measurable)
--   others(mod) -> list of values that belong to other mods / MDL
--   G           the real globals
--   stop_sources {chunk source = true}: functions from these chunks (MDL's own)
--               are never walked
--   clock, ffi, debug (tests may replace them)
function M.new(options)
    options = options or {}
    local G = options.G or _G
    local clock = options.clock or os.clock
    local dbg = options.debug or debug
    local ffi = options.ffi
    local getinfo, getupvalue, upvalueid, getmetatable_raw = dbg.getinfo, dbg.getupvalue, dbg.upvalueid, dbg.getmetatable
    local getlocal = dbg.getlocal
    local stop_sources = options.stop_sources or {}
    local dump = string.dump
    local self = {revision = 0, results = {}}
    local queue, job = {}, nil

    -- Values shared by everything: _G, every global the mod did not create,
    -- and the values directly inside global tables (library functions).
    local function base_stop(owned)
        local stop = {[G] = true}
        local count = 0
        -- G and the tables its metatable falls back to (sandboxed globals).
        local layers, layer = {}, G
        for _ = 1, 4 do
            if type(layer) ~= 'table' then break end
            layers[#layers + 1] = layer
            stop[layer] = true
            local meta = getmetatable_raw(layer)
            layer = meta and meta.__index
        end
        for _, globals in ipairs(layers) do
            for key, value in next, globals do
                local kind = type(value)
                if not owned[key] and (kind == 'table' or kind == 'function' or kind == 'userdata' or kind == 'thread' or kind == 'cdata') then
                    stop[value] = true
                    if kind == 'table' then
                        for _, inner in next, value do
                            local inner_kind = type(inner)
                            if inner_kind == 'table' or inner_kind == 'function' or inner_kind == 'userdata' then stop[inner] = true end
                            count = count + 1
                            if count > 200000 then return stop end
                        end
                    end
                end
            end
        end
        local string_meta = getmetatable_raw('')
        if string_meta then stop[string_meta] = true end
        return stop
    end

    local function start(mod)
        local scope = options.scope and options.scope(mod)
        if not scope then
            self.results[mod] = {state = 'unavailable', env = mod.env}
            self.revision = self.revision + 1
            return nil
        end
        local stop = base_stop(scope.owned or {})
        for _, value in ipairs(scope.stop or {}) do stop[value] = true end
        for _, value in ipairs(options.others and options.others(mod) or {}) do stop[value] = true end
        local j = {mod = mod, env = mod.env, stop = stop, seen = {}, stack = {}, protos = {}, upvalues = {},
            bytes = 0, objects = 0, counts = {table = 0, ['function'] = 0, string = 0, other = 0},
            foreign = scope.foreign or {}, started = clock(), work = 0}
        for _, root in ipairs(scope.roots or {}) do
            local kind = type(root)
            if root ~= nil and kind ~= 'number' and kind ~= 'boolean' and not j.seen[root] and not stop[root] then
                j.seen[root] = true
                j.stack[#j.stack + 1] = root
            end
        end
        self.results[mod] = {state = 'measuring', env = mod.env, bytes = (self.results[mod] or {}).bytes}
        self.revision = self.revision + 1
        return j
    end

    -- MDL's own chunks and other mods' chunks are not walked.
    local function foreign(source, j)
        source = tostring(source)
        if stop_sources[source] then return true end
        for _, prefix in ipairs(j.foreign) do
            if source:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    local function finish(j, truncated)
        self.results[j.mod] = {state = 'done', env = j.env, bytes = math.floor(j.bytes), objects = j.objects,
            counts = j.counts, truncated = truncated or nil, seconds = j.work, time = clock()}
        self.revision = self.revision + 1
    end

    -- Walks until the stack is empty or `budget` seconds have passed.
    local function walk(j, budget)
        local stack, seen, stop, counts = j.stack, j.seen, j.stop, j.counts
        local started = clock()
        local deadline = started + budget
        local function visit(value)
            if value == nil then return end
            local kind = type(value)
            if kind == 'number' or kind == 'boolean' then return end
            if seen[value] or stop[value] then return end
            seen[value] = true
            stack[#stack + 1] = value
        end
        local n = 0
        while #stack > 0 do
            local value = stack[#stack]
            stack[#stack] = nil
            local kind = type(value)
            j.objects = j.objects + 1
            if kind == 'table' then
                counts.table = counts.table + 1
                local entries, array = 0, 0
                local meta = getmetatable_raw(value)
                if meta and rawget(meta, '__len') then
                    local ok, length = pcall(function() return #value end)
                    array = ok and type(length) == 'number' and length or 0
                else
                    array = #value
                end
                for key, item in next, value do
                    entries = entries + 1
                    visit(key)
                    visit(item)
                end
                local hash = entries - array
                j.bytes = j.bytes + M.table_bytes(array, hash > 0 and hash or 0)
                visit(meta)
            elseif kind == 'function' then
                local info = getinfo(value, 'Su')
                if info and info.what ~= 'C' and foreign(info.source, j) then
                    -- MDL's own function: not this mod's memory.
                    j.objects = j.objects - 1
                else
                    counts['function'] = counts['function'] + 1
                    local ups = info and info.nups or 0
                    j.bytes = j.bytes + M.CLOSURE + 4 * ups
                    if info and info.what ~= 'C' then
                        local key = tostring(info.source) .. ':' .. tostring(info.linedefined) .. ':' .. tostring(info.lastlinedefined)
                        if not j.protos[key] then
                            j.protos[key] = true
                            local ok, text = pcall(dump, value)
                            j.bytes = j.bytes + M.PROTO + (ok and #text or 0)
                        end
                    end
                    for i = 1, ups do
                        local _, item = getupvalue(value, i)
                        local id = upvalueid and info.what ~= 'C' and upvalueid(value, i)
                        if id then
                            if not j.upvalues[id] then
                                j.upvalues[id] = true
                                j.bytes = j.bytes + M.UPVALUE
                                visit(item)
                            end
                        else
                            visit(item)
                        end
                    end
                    if info and info.what ~= 'C' and getfenv then
                        local ok, env = pcall(getfenv, value)
                        if ok then visit(env) end
                    end
                end
            elseif kind == 'string' then
                counts.string = counts.string + 1
                j.bytes = j.bytes + M.STRING + #value
            elseif kind == 'thread' then
                counts.other = counts.other + 1
                j.bytes = j.bytes + M.THREAD
                -- What its suspended stack holds.
                for level = 0, 40 do
                    local info = getinfo(value, level, 'f')
                    if not info then break end
                    visit(info.func)
                    for i = 1, 200 do
                        local name, item = getlocal(value, level, i)
                        if not name then break end
                        visit(item)
                    end
                end
            elseif kind == 'cdata' then
                counts.other = counts.other + 1
                local size = 8
                if ffi then
                    local ok, measured = pcall(ffi.sizeof, value)
                    if ok and type(measured) == 'number' then size = measured end
                end
                j.bytes = j.bytes + M.CDATA + size
            else
                counts.other = counts.other + 1
                j.bytes = j.bytes + 24
            end
            if j.objects >= M.MAX_OBJECTS then
                j.work = j.work + (clock() - started)
                return true, true
            end
            n = n + 1
            if n % 256 == 0 and clock() > deadline then
                j.work = j.work + (clock() - started)
                return false
            end
        end
        j.work = j.work + (clock() - started)
        return true
    end

    -- Queue a measurement (no-op when one is queued or running for it).
    function self.request(mod)
        if job and job.mod == mod then return end
        for _, queued in ipairs(queue) do if queued == mod then return end end
        queue[#queue + 1] = mod
        local result = self.results[mod]
        if not result or result.state ~= 'done' then
            self.results[mod] = {state = 'measuring', env = mod.env, bytes = result and result.bytes}
            self.revision = self.revision + 1
        end
    end

    -- Result for a mod: nil (never measured), or {state = 'measuring' |
    -- 'done' | 'unavailable', bytes, objects, counts, truncated}. A result
    -- from before a reload (other environment) counts as stale.
    function self.result(mod)
        local result = self.results[mod]
        if result and result.env ~= mod.env then return nil, true end
        return result
    end

    function self.busy() return job ~= nil or #queue > 0 end

    -- Does at most `budget` seconds of work (default 1 ms). Returns busy.
    function self.step(budget)
        budget = budget or 0.001
        local deadline = clock() + budget
        while true do
            if not job then
                local mod = table.remove(queue, 1)
                if not mod then return false end
                job = start(mod)
            end
            if job then
                local done, truncated = walk(job, math.max(0, deadline - clock()))
                if done then
                    finish(job, truncated)
                    job = nil
                else
                    return true
                end
            end
            if clock() > deadline then return job ~= nil or #queue > 0 end
        end
    end

    -- Forget everything about a mod (stopped / reloaded).
    function self.forget(mod)
        self.results[mod] = nil
        if job and job.mod == mod then job = nil end
        for i = #queue, 1, -1 do if queue[i] == mod then table.remove(queue, i) end end
        self.revision = self.revision + 1
    end

    return self
end

return M
