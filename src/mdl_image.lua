-- MDL: mod icons. Decodes PNG/JPG/BMP/GIF with GDI+ (flat C API) into a small
-- pixel grid and converts it to horizontal colour runs that the Stingray GUI
-- draws as rectangles, so manager icons (manifest IconPath / option Image) can
-- be shown without creating engine textures. Decoding is queued and runs at
-- most one image per frame.
local I = {}

-- Pure: ARGB pixel rows -> {w=,h=,runs={{x,y,len,a,r,g,b}}}, merging equal
-- colours after quantizing to 5 bits per channel and dropping near-transparent
-- pixels.
function I.runs(width, height, pixel, step)
    local runs = {}
    step = step or 8
    local function q(v) return math.floor(v / step) * step + math.floor(step / 2) end
    for y = 0, height - 1 do
        local x = 0
        while x < width do
            local argb = pixel(x, y)
            local a = math.floor(argb / 16777216) % 256
            if a < 40 then
                x = x + 1
            else
                local r, g, b = q(math.floor(argb / 65536) % 256), q(math.floor(argb / 256) % 256), q(argb % 256)
                local qa = a >= 250 and 255 or q(a)
                local start = x
                x = x + 1
                while x < width do
                    local next_argb = pixel(x, y)
                    local na = math.floor(next_argb / 16777216) % 256
                    local nqa = na >= 250 and 255 or q(na)
                    if na < 40 or nqa ~= qa or q(math.floor(next_argb / 65536) % 256) ~= r
                        or q(math.floor(next_argb / 256) % 256) ~= g or q(next_argb % 256) ~= b then break end
                    x = x + 1
                end
                runs[#runs + 1] = {start, y, x - start, qa, r, g, b}
            end
        end
    end
    return {w = width, h = height, runs = runs}
end

local declared = false
local function gdiplus(ffi)
    if not declared then
        declared = true
        ffi.cdef [[
            typedef struct { uint32_t version; void *debug_callback; int suppress_thread; int suppress_codecs; } MDL_GdiplusStartupInput;
            int GdiplusStartup(uintptr_t *token, const MDL_GdiplusStartupInput *input, void *output);
            int GdipLoadImageFromFile(const uint16_t *filename, void **image);
            int GdipGetImageWidth(void *image, uint32_t *width);
            int GdipGetImageHeight(void *image, uint32_t *height);
            int GdipGetImageThumbnail(void *image, uint32_t width, uint32_t height, void **thumb, void *callback, void *data);
            int GdipBitmapGetPixel(void *bitmap, int x, int y, uint32_t *color);
            int GdipDisposeImage(void *image);
        ]]
    end
    return ffi.load('gdiplus')
end

-- options = {ffi=, platform=, log=}
function I.new(options)
    local ffi, platform = options.ffi, options.platform
    local self = {cache = {}, queue = {}, queued = {}, done = 0}
    local gdi, token, broken
    local serial = 0

    local function start()
        if gdi or broken then return gdi end
        local ok, reason = pcall(function()
            gdi = gdiplus(ffi)
            local handle = ffi.new('uintptr_t[1]')
            local input = ffi.new('MDL_GdiplusStartupInput')
            input.version = 1
            assert(gdi.GdiplusStartup(handle, input, nil) == 0, 'GdiplusStartup failed')
            token = handle[0]
        end)
        if not ok then
            broken, gdi = tostring(reason), nil
            if options.log then pcall(options.log, 'icons unavailable: ' .. broken) end
        end
        return gdi
    end

    local function decode(path, size)
        local lib = assert(start(), 'GDI+ unavailable')
        local image, thumb = ffi.new('void *[1]'), ffi.new('void *[1]')
        assert(lib.GdipLoadImageFromFile(platform.wide(path), image) == 0, 'cannot load ' .. path)
        local ok, result = pcall(function()
            local w, h = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
            lib.GdipGetImageWidth(image[0], w)
            lib.GdipGetImageHeight(image[0], h)
            local iw, ih = tonumber(w[0]), tonumber(h[0])
            assert(iw > 0 and ih > 0, 'empty image')
            local tw, th = size, size
            if iw > ih then th = math.max(1, math.floor(size * ih / iw + 0.5)) else tw = math.max(1, math.floor(size * iw / ih + 0.5)) end
            assert(lib.GdipGetImageThumbnail(image[0], tw, th, thumb, nil, nil) == 0, 'thumbnail failed')
            local color = ffi.new('uint32_t[1]')
            local grid = I.runs(tw, th, function(x, y)
                if lib.GdipBitmapGetPixel(thumb[0], x, y, color) ~= 0 then return 0 end
                return tonumber(color[0])
            end, size <= 24 and 16 or 8)
            return grid
        end)
        if thumb[0] ~= nil then lib.GdipDisposeImage(thumb[0]) end
        lib.GdipDisposeImage(image[0])
        if not ok then error(result, 0) end
        return result
    end

    -- Returns the decoded grid, false when it failed, or nil while pending.
    function self.get(path, size)
        if not path then return false end
        local key = path .. '|' .. size
        local cached = self.cache[key]
        if cached ~= nil then return cached end
        if not self.queued[key] then
            self.queued[key] = true
            self.queue[#self.queue + 1] = {key = key, path = path, size = size}
        end
        return nil
    end

    -- Decode one queued image; returns true when something changed.
    function self.step()
        local job = table.remove(self.queue, 1)
        if not job then return false end
        local ok, grid = pcall(decode, job.path, job.size)
        if ok then
            serial = serial + 1
            grid.id = serial
            self.cache[job.key] = grid
        else
            self.cache[job.key] = false
            if options.log then pcall(options.log, 'icon failed: ' .. tostring(grid)) end
        end
        self.queued[job.key] = nil
        self.done = self.done + 1
        return true
    end

    return self
end

return I
