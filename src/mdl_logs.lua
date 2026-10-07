-- MDL: coalesced asynchronous mod logs.
--
-- Many addons rewrite small status logs through CowboyBingusModLoader.open_log
-- (open -> write -> close), some every few seconds, some on every state change.
-- Each open/truncate/close is synchronous file-system work on the game thread
-- (and a scan target for antivirus software). MDL returns an in-memory file
-- instead; close() hands the content to this writer, which keeps one handle per
-- log, writes at most every `interval` seconds per file (latest content wins)
-- with overlapped I/O, and flushes everything synchronously on shutdown.
-- Files, names and final contents are unchanged for the mods and the player.
local M = {}

-- Two usage patterns are supported with bounded memory:
--   rewrite: open_log -> write... -> close, repeated (status files); every
--            open starts a new generation that replaces the file, and only the
--            latest generation is written (coalescing);
--   stream:  open_log once, then write + flush for the whole session (event
--            logs, e.g. Mod Options Menu); each flush appends its new text.
-- options = {platform=, directory=, clock=, interval=0.5}
function M.new(options)
    local platform = options.platform
    local interval = options.interval or 0.5
    local clock = options.clock or os.clock
    local self = {files = {}, writes = 0, coalesced = 0, fallbacks = 0}
    local logs = self

    local function entry(name)
        local file = self.files[name]
        if not file then
            file = {name = name, last = -math.huge, offset = 0, chunks = {}, contents = ''}
            self.files[name] = file
        end
        return file
    end

    -- Writes pending chunks (after an optional truncate). Returns true when
    -- nothing is left pending.
    local function start(file, now)
        if #file.chunks == 0 and not file.truncate then return true end
        if file.handle == nil then
            file.handle = platform.log_file and platform.log_file(options.directory .. '/' .. file.name) or false
        end
        if file.handle and file.handle.busy() then return false end
        local text = table.concat(file.chunks)
        if file.truncate then file.offset, file.contents = 0, '' end
        local written = false
        if file.handle then
            written = file.handle.write(text, file.offset, file.truncate)
            if not written then
                file.handle.close()
                file.handle = false
            end
        end
        if not written then
            -- Synchronous fallback rewrites the whole file from our copy.
            self.fallbacks = self.fallbacks + 1
            platform.write(options.directory .. '/' .. file.name, file.contents .. text)
        end
        file.contents = (file.contents .. text):sub(-65536) -- only for the fallback path
        file.offset = file.offset + #text
        file.chunks, file.truncate, file.last = {}, false, now
        self.writes = self.writes + 1
        return true
    end

    local function due(file)
        local now = clock()
        if now - file.last >= interval then start(file, now) end
    end

    -- A new generation of a file (open_log called again): replaces content.
    function self.begin(name)
        local file = entry(name)
        if #file.chunks > 0 or file.truncate then self.coalesced = self.coalesced + 1 end
        file.chunks, file.truncate = {}, true
        return file
    end

    function self.append(name, text, generation)
        local file = self.files[name]
        if not file or file.generation ~= generation then return end -- superseded
        if text ~= '' then file.chunks[#file.chunks + 1] = text end
        due(file)
    end

    -- Legacy single-call form: replace the whole file with content.
    function self.submit(name, content)
        local file = self.begin(name)
        file.generation = (file.generation or 0) + 1
        self.append(name, content, file.generation)
    end

    -- Call once per frame: writes due files (cheap when nothing is pending).
    function self.pump()
        local now
        for _, file in pairs(self.files) do
            if #file.chunks > 0 or file.truncate then
                now = now or clock()
                if now - file.last >= interval then start(file, now) end
            end
        end
    end

    function self.flush()
        for _, file in pairs(self.files) do
            if file.handle then file.handle.wait() end
            if #file.chunks > 0 or file.truncate then start(file, clock()) end
            if file.handle then file.handle.wait() end
        end
    end

    function self.close()
        self.flush()
        for _, file in pairs(self.files) do
            if file.handle then file.handle.close() end
            file.handle = nil
        end
    end

    -- Drop-in for CowboyBingusModLoader.open_log(name): same name rules,
    -- returns a write-only file object. Text reaches the writer on flush()
    -- and close(), so memory stays bounded for long-lived logs.
    function self.open_log(name)
        if type(name) ~= 'string' or not name:match('^[%w_-]+%.log$') then return nil end
        local record = logs.begin(name)
        record.generation = (record.generation or 0) + 1
        local generation = record.generation
        local parts, closed = {}, false
        local file = {}
        local function hand_over()
            if #parts == 0 then return end
            local ok, text = pcall(table.concat, parts)
            parts = {}
            if ok then logs.append(name, text, generation) end
        end
        function file:write(...)
            if closed then return nil, 'closed' end
            for i = 1, select('#', ...) do
                local value = select(i, ...)
                parts[#parts + 1] = type(value) == 'number' and tostring(value) or value
            end
            if #parts > 256 then hand_over() end
            return self
        end
        function file:flush() hand_over() return self end
        function file:setvbuf() return true end
        function file:seek() return 0 end
        function file:close()
            if not closed then
                closed = true
                hand_over()
                local record_now = logs.files[name]
                if record_now and record_now.generation == generation then
                    -- empty file on close still truncates
                    local now = clock()
                    if now - record_now.last >= interval then start(record_now, now) end
                end
            end
            return true
        end
        return file
    end
    return self
end

return M
