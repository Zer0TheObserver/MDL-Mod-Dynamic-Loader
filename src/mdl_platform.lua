-- MDL platform layer: Windows services for the runtime. All paths are UTF-8
-- strings converted to UTF-16 for the wide Win32 APIs, so non-ASCII user
-- names and mod folders work. Only function prototypes (plus uniquely named
-- MDL_ types) are declared, so repeated cdef calls are harmless.
local platform = {}

local function builtin(name)
    local loaded = package and package.loaded and package.loaded[name]
    if loaded then return loaded end
    return require(name)
end

local declared = false
local function declare(ffi)
    if declared then return end
    declared = true
    ffi.cdef [[
        int MultiByteToWideChar(uint32_t codepage, uint32_t flags, const char *text, int bytes, uint16_t *wide, int chars);
        int WideCharToMultiByte(uint32_t codepage, uint32_t flags, const uint16_t *wide, int chars, char *text, int bytes, const char *def, int *used);
        uint32_t GetEnvironmentVariableW(const uint16_t *name, uint16_t *buffer, uint32_t size);
        int CreateDirectoryW(const uint16_t *path, void *security);
        uint32_t GetLastError(void);
        void *FindFirstFileW(const uint16_t *pattern, void *data);
        int FindNextFileW(void *handle, void *data);
        int FindClose(void *handle);
        void *CreateFileW(const uint16_t *path, uint32_t access, uint32_t share, void *security, uint32_t disposition, uint32_t flags, void *template_file);
        int ReadFile(void *file, void *buffer, uint32_t size, uint32_t *read, void *overlapped);
        int WriteFile(void *file, const void *buffer, uint32_t size, uint32_t *written, void *overlapped);
        int GetFileSizeEx(void *file, int64_t *size);
        int CloseHandle(void *handle);
        int MoveFileExW(const uint16_t *from, const uint16_t *to, uint32_t flags);
        int DeleteFileW(const uint16_t *path);
        int CopyFileW(const uint16_t *from, const uint16_t *to, int fail_if_exists);
        int GetUserDefaultLocaleName(uint16_t *name, int size);
        uint32_t GetModuleFileNameW(void *module, uint16_t *filename, uint32_t size);
        void *GetCurrentProcess(void);
        void *GetModuleHandleA(const char *name);
        int ReadProcessMemory(void *process, const void *address, void *buffer, size_t size, size_t *read);
        int WriteProcessMemory(void *process, void *address, const void *buffer, size_t size, size_t *written);
        int FlushInstructionCache(void *process, const void *address, size_t size);
        int QueryPerformanceCounter(int64_t *count);
        int QueryPerformanceFrequency(int64_t *frequency);
        void *FindFirstChangeNotificationW(const uint16_t *path, int subtree, uint32_t filter);
        int FindNextChangeNotification(void *handle);
        int FindCloseChangeNotification(void *handle);
        uint32_t WaitForSingleObject(void *handle, uint32_t milliseconds);
        typedef struct { uintptr_t Internal; uintptr_t InternalHigh; uint32_t Offset; uint32_t OffsetHigh; void *hEvent; } MDL_OVERLAPPED;
        int WriteFile(void *file, const void *buffer, uint32_t size, uint32_t *written, void *overlapped);
        int GetOverlappedResult(void *file, MDL_OVERLAPPED *overlapped, uint32_t *transferred, int wait);
        int SetFileInformationByHandle(void *file, int info_class, void *info, uint32_t size);
    ]]
end

function platform.new()
    local ffi = builtin('ffi')
    declare(ffi)
    local kernel = ffi.load('kernel32')
    local process = kernel.GetCurrentProcess()
    local invalid = ffi.cast('void *', -1)
    local self = {ffi = ffi}
    local CP_UTF8 = 65001

    local function wide(text)
        text = text:gsub('/', '\\')
        local chars = kernel.MultiByteToWideChar(CP_UTF8, 0, text, #text, nil, 0)
        local buffer = ffi.new('uint16_t[?]', chars + 1)
        if chars > 0 then kernel.MultiByteToWideChar(CP_UTF8, 0, text, #text, buffer, chars) end
        buffer[chars] = 0
        return buffer
    end
    local function narrow(buffer, chars)
        if chars == 0 then return '' end
        local bytes = kernel.WideCharToMultiByte(CP_UTF8, 0, buffer, chars, nil, 0, nil, nil)
        local out = ffi.new('char[?]', bytes)
        kernel.WideCharToMultiByte(CP_UTF8, 0, buffer, chars, out, bytes, nil, nil)
        return ffi.string(out, bytes)
    end
    self.wide, self.narrow = wide, narrow

    local function address_of(address) return ffi.cast('void *', address) end

    function self.getenv(name)
        local buffer = ffi.new('uint16_t[32768]')
        local length = kernel.GetEnvironmentVariableW(wide(name), buffer, 32768)
        if length == 0 or length >= 32768 then return nil end
        return (narrow(buffer, length):gsub('\\', '/'))
    end

    function self.localappdata()
        local base = self.getenv('LOCALAPPDATA')
        assert(base and base ~= '', 'LOCALAPPDATA unavailable')
        return base
    end

    function self.mkdir(path)
        if kernel.CreateDirectoryW(wide(path), nil) ~= 0 then return true end
        return kernel.GetLastError() == 183
    end

    -- %LOCALAPPDATA%/MDL/Helldivers2 (created on demand).
    function self.base_dir()
        local base = self.localappdata()
        for _, part in ipairs({'MDL', 'Helldivers2'}) do
            base = base .. '/' .. part
            self.mkdir(base)
        end
        return base
    end

    -- Game install folder (parent of bin/helldivers2.exe), or nil.
    function self.game_dir()
        local buffer = ffi.new('uint16_t[32768]')
        local length = kernel.GetModuleFileNameW(nil, buffer, 32768)
        if length == 0 or length >= 32768 then return nil end
        local path = narrow(buffer, length):gsub('\\', '/')
        return path:match('^(.*)/[bB][iI][nN]/[^/]+$')
    end

    -- Returns {name=, dir=bool, mtime=number, size=number}, sorted by name.
    function self.list(directory, pattern)
        local data = ffi.new('uint8_t[600]')
        local handle = kernel.FindFirstFileW(wide(directory .. '/' .. (pattern or '*')), data)
        if handle == invalid then return {} end
        local entries = {}
        local ok, reason = pcall(function()
            repeat
                local words = ffi.cast('uint32_t *', data)
                local name_buffer = ffi.cast('uint16_t *', data + 44)
                local chars = 0
                while chars < 260 and name_buffer[chars] ~= 0 do chars = chars + 1 end
                local name = narrow(name_buffer, chars)
                if name ~= '.' and name ~= '..' then
                    entries[#entries + 1] = {
                        name = name,
                        dir = math.floor(tonumber(words[0]) / 16) % 2 == 1,
                        mtime = tonumber(words[6]) * 4294967296 + tonumber(words[5]),
                        size = tonumber(words[7]) * 4294967296 + tonumber(words[8]),
                    }
                end
            until kernel.FindNextFileW(handle, data) == 0
        end)
        kernel.FindClose(handle)
        assert(ok, reason)
        table.sort(entries, function(a, b) return a.name < b.name end)
        return entries
    end

    local GENERIC_READ, GENERIC_WRITE = 0x80000000, 0x40000000
    local function open(path, write)
        local handle = kernel.CreateFileW(wide(path), write and GENERIC_WRITE or GENERIC_READ,
            write and 0 or 7, nil, write and 2 or 3, 0x80, nil)
        if handle == invalid then return nil end
        return handle
    end

    -- Reads a whole file (limit bytes, default 64 MB) or its first `limit` bytes.
    function self.read(path, limit)
        local handle = open(path)
        if not handle then return nil end
        local ok, result = pcall(function()
            local size = ffi.new('int64_t[1]')
            assert(kernel.GetFileSizeEx(handle, size) ~= 0, 'size unavailable')
            local wanted = tonumber(size[0])
            if limit and wanted > limit then wanted = limit end
            assert(wanted <= 67108864, 'file too large')
            if wanted == 0 then return '' end
            local buffer, count = ffi.new('uint8_t[?]', wanted), ffi.new('uint32_t[1]')
            assert(kernel.ReadFile(handle, buffer, wanted, count, nil) ~= 0, 'read failed')
            return ffi.string(buffer, count[0])
        end)
        kernel.CloseHandle(handle)
        if ok then return result end
        return nil
    end

    function self.read_head(path, count) return self.read(path, count) end

    -- Positioned reads from a file kept open: reader.read_at(offset, count)
    -- returns the bytes (possibly fewer at the end) or nil, error code;
    -- reader.close(). Returns nil, error code when the file cannot be opened.
    function self.open_reader(path)
        local handle = open(path)
        if not handle then return nil, tonumber(kernel.GetLastError()) end
        local overlapped, count = ffi.new('MDL_OVERLAPPED'), ffi.new('uint32_t[1]')
        local buffer, capacity = nil, 0
        local reader = {}
        function reader.read_at(offset, size)
            if not handle then return nil, 6 end
            if size <= 0 then return '' end
            if size > 67108864 then return nil, 87 end
            if size > capacity then capacity = math.max(size, 65536); buffer = ffi.new('uint8_t[?]', capacity) end
            overlapped.Internal, overlapped.InternalHigh, overlapped.hEvent = 0, 0, nil
            overlapped.Offset = offset % 4294967296
            overlapped.OffsetHigh = math.floor(offset / 4294967296)
            if kernel.ReadFile(handle, buffer, size, count, overlapped) == 0 then
                return nil, tonumber(kernel.GetLastError())
            end
            return ffi.string(buffer, count[0])
        end
        function reader.size()
            if not handle then return nil end
            local size = ffi.new('int64_t[1]')
            if kernel.GetFileSizeEx(handle, size) == 0 then return nil end
            return tonumber(size[0])
        end
        function reader.close()
            if handle then kernel.CloseHandle(handle); handle = nil end
        end
        return reader
    end

    -- Native copy (never overwrites) and delete; both return true/false, error code.
    function self.copy_file(from, to)
        if kernel.CopyFileW(wide(from), wide(to), 1) ~= 0 then return true end
        return false, tonumber(kernel.GetLastError())
    end
    -- Rename without replacing an existing file.
    function self.move_file(from, to)
        if kernel.MoveFileExW(wide(from), wide(to), 0) ~= 0 then return true end
        return false, tonumber(kernel.GetLastError())
    end
    -- Extra prototypes under MDL's own names (asm labels), so another mod's
    -- declaration of the same Windows / Steam functions can never clash.
    local extra_ok = pcall(ffi.cdef, [[
        uint16_t MDL_GetUserDefaultUILanguage(void) __asm__("GetUserDefaultUILanguage");
        int MDL_LCIDToLocaleName(uint32_t lcid, uint16_t *name, int size, uint32_t flags) __asm__("LCIDToLocaleName");
        void *MDL_GetProcAddress(void *module, const char *name) __asm__("GetProcAddress");
        typedef void *(*MDL_steam_apps_fn)(void);
        typedef const char *(*MDL_steam_language_fn)(void *apps);
    ]])
    -- Windows display language, e.g. "zh-CN", or nil.
    function self.ui_locale()
        if not extra_ok then return nil end
        local ok, value = pcall(function()
            local buffer = ffi.new('uint16_t[86]')
            local length = kernel.MDL_LCIDToLocaleName(kernel.MDL_GetUserDefaultUILanguage(), buffer, 85, 0)
            if length <= 1 then return nil end
            return narrow(buffer, length - 1)
        end)
        return ok and value or nil
    end
    -- Steam's language for this game ("schinese", "english", ...), or nil.
    -- Asked once; steam_api64.dll is already loaded by the game.
    local steam_cached
    function self.steam_language()
        if steam_cached ~= nil then return steam_cached or nil end
        steam_cached = false
        if not extra_ok then return nil end
        local ok, value = pcall(function()
            local steam = kernel.GetModuleHandleA('steam_api64.dll')
            if steam == nil then return nil end
            local apps_fn, language_fn
            for _, name in ipairs({'SteamAPI_SteamApps_v008', 'SteamAPI_SteamApps_v007'}) do
                apps_fn = kernel.MDL_GetProcAddress(steam, name)
                if apps_fn ~= nil then break end
            end
            language_fn = kernel.MDL_GetProcAddress(steam, 'SteamAPI_ISteamApps_GetCurrentGameLanguage')
            if apps_fn == nil or language_fn == nil then return nil end
            local apps = ffi.cast('MDL_steam_apps_fn', apps_fn)()
            if apps == nil then return nil end
            local text = ffi.cast('MDL_steam_language_fn', language_fn)(apps)
            if text == nil then return nil end
            return ffi.string(text)
        end)
        if ok and type(value) == 'string' and value ~= '' then steam_cached = value end
        return steam_cached or nil
    end
    -- Regional format locale, e.g. "zh-CN", or nil.
    function self.locale()
        local ok, value = pcall(function()
            local buffer = ffi.new('uint16_t[86]')
            local length = kernel.GetUserDefaultLocaleName(buffer, 85)
            if length <= 1 then return nil end
            return narrow(buffer, length - 1)
        end)
        return ok and value or nil
    end
    function self.delete_file(path)
        if kernel.DeleteFileW(wide(path)) ~= 0 then return true end
        return false, tonumber(kernel.GetLastError())
    end

    -- Atomic replace so a crash mid-write never truncates the file.
    function self.write(path, data)
        local temporary = path .. '.tmp'
        local handle = open(temporary, true)
        if not handle then return false end
        local count = ffi.new('uint32_t[1]')
        local ok = #data == 0 or kernel.WriteFile(handle, data, #data, count, nil) ~= 0 and count[0] == #data
        kernel.CloseHandle(handle)
        if not ok then kernel.DeleteFileW(wide(temporary)) return false end
        return kernel.MoveFileExW(wide(temporary), wide(path), 1 + 8) ~= 0 -- REPLACE_EXISTING | WRITE_THROUGH
    end

    function self.module(name)
        local handle = kernel.GetModuleHandleA(name)
        if handle == nil then return nil end
        return ffi.cast('uint8_t *', handle)
    end

    function self.mem_read(address, size)
        assert(size > 0 and size <= 1048576, 'Invalid read size')
        local buffer, count = ffi.new('uint8_t[?]', size), ffi.new('size_t[1]')
        if kernel.ReadProcessMemory(process, address_of(address), buffer, size, count) == 0
            or count[0] ~= size then return nil end
        return ffi.string(buffer, size)
    end

    function self.mem_write(address, bytes)
        assert(type(bytes) == 'string' and #bytes > 0 and #bytes <= 65536, 'Invalid write size')
        local count = ffi.new('size_t[1]')
        local target = address_of(address)
        if kernel.WriteProcessMemory(process, target, bytes, #bytes, count) == 0
            or count[0] ~= #bytes then return false end
        kernel.FlushInstructionCache(process, target, #bytes)
        return true
    end

    -- Seconds from the performance counter (sub-microsecond resolution).
    local counter, frequency = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
    kernel.QueryPerformanceFrequency(frequency)
    local scale = 1 / tonumber(frequency[0])
    function self.now()
        kernel.QueryPerformanceCounter(counter)
        return tonumber(counter[0]) * scale
    end

    -- Directory change notification: changed() is a non-blocking check that
    -- is true once after any file name/write change below `directory`.
    function self.watch(directory)
        local handle = kernel.FindFirstChangeNotificationW(wide(directory), 1, 0x1 + 0x2 + 0x10)
        if handle == invalid or handle == nil then return nil end
        local watcher = {}
        function watcher.changed()
            if kernel.WaitForSingleObject(handle, 0) ~= 0 then return false end
            kernel.FindNextChangeNotification(handle)
            return true
        end
        function watcher.close() kernel.FindCloseChangeNotification(handle) end
        return watcher
    end

    -- Log file kept open with overlapped (asynchronous) writes:
    -- write(content, offset, truncate) writes at offset (truncating the file to
    -- offset+#content first when asked) without blocking the frame; busy()
    -- tells whether the previous write is still in flight.
    function self.log_file(path)
        local handle = kernel.CreateFileW(wide(path), 0x40000000, 1 + 2 + 4, nil, 2, 0x80 + 0x40000000, nil)
        if handle == invalid then return nil end
        local file = {}
        local overlapped = ffi.new('MDL_OVERLAPPED')
        local size = ffi.new('int64_t[1]')
        local buffer, in_flight = nil, false
        local count = ffi.new('uint32_t[1]')
        function file.busy()
            if not in_flight then return false end
            if overlapped.Internal == 0x103 then return true end -- STATUS_PENDING
            in_flight = false
            return false
        end
        function file.write(content, offset, truncate)
            if file.busy() then return false end
            offset = offset or 0
            if truncate then
                size[0] = offset + #content
                kernel.SetFileInformationByHandle(handle, 6, size, 8) -- FileEndOfFileInfo
            end
            if #content == 0 then return true end
            buffer = ffi.new('uint8_t[?]', #content)
            ffi.copy(buffer, content, #content)
            ffi.fill(overlapped, ffi.sizeof(overlapped))
            overlapped.Offset = offset % 4294967296
            overlapped.OffsetHigh = math.floor(offset / 4294967296)
            if kernel.WriteFile(handle, buffer, #content, nil, overlapped) ~= 0 then return true end
            if kernel.GetLastError() == 997 then in_flight = true return true end -- ERROR_IO_PENDING
            return false
        end
        function file.wait()
            if in_flight then kernel.GetOverlappedResult(handle, overlapped, count, 1) end
            in_flight = false
        end
        function file.close()
            file.wait()
            kernel.CloseHandle(handle)
        end
        return file
    end

    function self.address_key(address)
        return tonumber(ffi.cast('uintptr_t', address_of(address)))
    end

    return self
end

return platform
