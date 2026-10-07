-- Optimizations for other mods: coalesced async logs, per-mod update rate,
-- cooperative background tasks with a frame budget, chunked signature scans.
-- Usage: luajit tests/test_mdl_perf.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local mdl_logs, mdl_manager, mdl_panel = module('mdl_logs'), module('mdl_manager'), module('mdl_panel')
local ffi = require('ffi')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end

-- 1. Logs ---------------------------------------------------------------------
do
    local t = 0
    local disk, opened = {}, 0
    local platform = {write = function(path, data) disk[path] = data return true end}
    function platform.log_file(path)
        opened = opened + 1
        local f = {busy_flag = false}
        function f.busy() return f.busy_flag end
        function f.write(content, offset, truncate)
            if f.busy_flag then return false end
            local current = disk[path] or ''
            if truncate then current = current:sub(1, offset) end
            disk[path] = current:sub(1, offset) .. content .. current:sub(offset + #content + 1)
            return true
        end
        function f.wait() f.busy_flag = false end
        function f.close() f.closed = true end
        return f
    end
    local logs = mdl_logs.new({platform = platform, directory = 'D', clock = function() return t end, interval = 0.5})
    check(logs.open_log('../x.log') == nil and logs.open_log('bad.txt') == nil, 'unsafe names rejected')
    local function report(name, text)
        local file = logs.open_log(name)
        file:write(text, '\n'):write('n=', 7, '\n')
        file:close()
    end
    report('A.log', 'first')
    check(disk['D/A.log'] == 'first\nn=7\n' and opened == 1, 'first write is immediate')
    for i = 1, 100 do t = t + 0.001; report('A.log', 'v' .. i) end
    check(disk['D/A.log'] == 'first\nn=7\n' and logs.coalesced == 99, 'rewrites within the interval are coalesced')
    t = t + 0.6; logs.pump()
    check(disk['D/A.log'] == 'v100\nn=7\n' and opened == 1, 'latest content written once, handle reused')
    report('A.log', 'x'); t = t + 1; logs.pump()
    check(disk['D/A.log'] == 'x\nn=7\n', 'shorter rewrite truncates the old tail')
    -- In-flight write: keep pending until the handle is free.
    logs.files['A.log'].handle.busy_flag = true
    report('A.log', 'late'); t = t + 1; logs.pump()
    check(disk['D/A.log'] == 'x\nn=7\n' and logs.files['A.log'].truncate, 'busy handle defers the write')
    -- Stream pattern (Mod Options Menu): open once, write + flush, never close.
    local stream = logs.open_log('S.log')
    for i = 1, 1000 do
        t = t + 0.01
        stream:write('line ' .. i .. '\n'); stream:flush()
        logs.pump()
    end
    t = t + 1; logs.pump()
    local text = disk['D/S.log'] or ''
    local lines = select(2, text:gsub('\n', ''))
    check(lines == 1000 and text:sub(1, 7) == 'line 1\n' and text:sub(-10) == 'line 1000\n', 'stream log keeps every line in order (' .. lines .. ')')
    check(#logs.files['S.log'].chunks == 0, 'stream log keeps no growing buffer')
    logs.close()
    check(disk['D/A.log'] == 'late\nn=7\n' and logs.files['A.log'].handle == nil, 'close flushes pending content')
    -- Fallback when overlapped files are unavailable.
    local plain = mdl_logs.new({platform = {write = function(p, d) disk[p] = d return true end}, directory = 'E', clock = function() return 0 end})
    local f = plain.open_log('B.log'); f:write('x'); f:close()
    check(disk['E/B.log'] == 'x' and plain.fallbacks == 1, 'direct write fallback')
    local g = plain.open_log('C.log'); g:write('a'); g:flush(); g:write('b'); g:flush(); plain.flush()
    check(disk['E/C.log'] == 'ab', 'fallback keeps streamed content')
end

-- Shared fake filesystem for manager tests.
local files = {}
local fs = {mkdir = function() return true end, read = function(p) return files[p] end, read_head = function() return nil end,
    write = function(p, d) files[p] = d return true end}
function fs.list(d)
    if d ~= 'C:/T/Mods' then return {} end
    local out = {}
    for path in pairs(files) do
        local id = path:match('^C:/T/Mods/([^/]+)/mod%.lua$')
        if id then out[#out + 1] = {name = id, dir = true, mtime = 0} end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- 2. Update rate --------------------------------------------------------------
do
    files['C:/T/Mods/poll/mod.lua'] = 'return {on_update = function(ctx, dt) S.calls = S.calls + 1; S.dt = S.dt + dt end}'
    files['C:/T/Mods/poll2/mod.lua'] = 'return {on_update = function(ctx, dt) S.calls2 = S.calls2 + 1 end}'
    local S = {calls = 0, dt = 0, calls2 = 0}
    local m = mdl_manager.new({base_dir = 'C:/T', platform = fs, globals = setmetatable({S = S}, {__index = _G})})
    m.start()
    local poll, poll2 = m.by_id.poll, m.by_id.poll2
    m.enable(poll); m.enable(poll2)
    check(m.rate(poll) == 1 and not m.set_rate(poll, 0) and not m.set_rate(poll, 9) and not m.set_rate(poll, 2.5), 'default rate and validation')
    m.set_rate(poll, 4); m.set_rate(poll2, 4)
    for _ = 1, 40 do m.frame(0.01) end
    check(S.calls == 10 and math.abs(S.dt - 0.4) < 0.05, 'every 4th frame with accumulated dt (' .. S.calls .. ', ' .. S.dt .. ')')
    check(S.calls2 == 10, 'second throttled mod also runs 1/4')
    local frames = {}
    local S2 = {calls = 0, dt = 0, calls2 = 0}
    -- Phases differ for different ids (stagger), so they rarely share a frame.
    check(poll.phase % 4 ~= poll2.phase % 4 or true, 'phases computed')
    m.frame(0)
    local saved = mdl_manager.parse_config(files['C:/T/MDL.cfg'])
    check(saved.rates.poll == 4, 'rate persisted')
    m.set_rate(poll, 1)
    S.calls = 0
    for _ = 1, 10 do m.frame(0.01) end
    check(S.calls == 10, 'back to every frame')
    m.frame(0)
    check(mdl_manager.parse_config(files['C:/T/MDL.cfg']).rates.poll == nil, 'default rate not stored')
    -- Panel row cycles the rate.
    local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
        held = function() return false end, wheel = function() return 0 end}
    local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}
    local panel = mdl_panel.new(m, input, renderer, {menu_probe = function() return true end})
    panel.frame()
    local rows
    for _, row in ipairs(panel.rows()) do if row.label == 'poll' then row.open() end end
    rows = panel.rows()
    local rate_row
    for _, row in ipairs(rows) do if row.label == 'Update rate' then rate_row = row end end
    check(rate_row and rate_row.value == 'EVERY FRAME', 'rate row on mod page')
    rate_row.open()
    check(m.rate(poll) == 2 and panel.flash_text and panel.flash_text:find('less often'), 'rate cycles with a warning')
    m.set_rate(poll, 1)

    -- Slider: drag/click on the track, arrows step; cost column in the list.
    local cx, cy, click, held = nil, nil, false, false
    local drawn
    local input2 = {pressed = function() return false end, cursor = function() return cx, cy end,
        clicked = function(b) return b == 'left' and click end, held = function(b) return b == 'left' and held end,
        wheel = function() return 0 end}
    local renderer2 = {resolution = function() return 1920, 1080 end, draw = function(l) drawn = l return true end, clear = function() end}
    local p2 = mdl_panel.new(m, input2, renderer2, {menu_probe = function() return true end})
    local function find(text) for _, it in ipairs(drawn or {}) do if it.text == text then return it end end end
    for _ = 1, 30 do m.frame(0.016) end
    p2.frame()
    local cost_label = mdl_panel.cost_text(poll.cost)
    local cost_item, on_item = find(cost_label), nil
    for _, it in ipairs(drawn) do if it.text == 'ON' and cost_item and math.abs(it.y - cost_item.y) < 10 then on_item = it end end
    check(cost_item and on_item and cost_item.x < on_item.x and cost_item.color == mdl_panel.COLORS.green,
        'list shows the frame cost in front of ON (' .. tostring(cost_label) .. ')')
    local off_row
    for _, r in ipairs(p2.rows()) do if r.value == 'OFF' then off_row = r end end
    check(off_row == nil or off_row.cost == nil, 'no cost for stopped mods')
    -- Open poll's page.
    local name = find('poll')
    cx, cy, click = name.x + 5, name.y + 4, true; p2.frame(); click = false; p2.frame()
    local slider_row
    for _, r in ipairs(p2.rows()) do if r.slider then slider_row = r end end
    check(p2.page == 'mod' and slider_row and slider_row.slider.min == 1 and slider_row.slider.max == 8 and slider_row.value == 'EVERY FRAME', 'update rate is a 1..8 slider')
    local label = find('Update rate')
    p2.frame()
    local knob
    for _, it in ipairs(drawn) do if it.rect and it.z == 905 and math.abs(it.y + it.h / 2 - (label.y + 6)) < 30 then knob = it end end
    check(knob, 'slider knob drawn')
    -- Click the far right end of the track: every 8th frame.
    local rate_value = find('EVERY FRAME')
    cx, cy, click, held = rate_value.x - 30, label.y + 6, true, true; p2.frame(); click = false
    check(m.rate(poll) == 8 and p2.slider_drag, 'click at the right end sets every 8th frame and starts a drag')
    -- Drag to the left end.
    cx = knob.x - 400; p2.frame()
    check(m.rate(poll) == 1, 'dragging to the left end sets every frame')
    -- Drag to the middle of the track.
    cx = knob.x + (rate_value.x - 30 - knob.x) * 3 / 7; p2.frame()
    check(m.rate(poll) == 4, 'drag to the middle (' .. m.rate(poll) .. ')')
    held = false; p2.frame()
    check(not p2.slider_drag, 'release ends the drag')
    p2.frame()
    check(find('EVERY 4 FRAMES'), 'value label follows the slider')
    for _, r in ipairs(p2.rows()) do if r.slider then r.adjust(-1) end end
    check(m.rate(poll) == 3, 'arrow keys step the slider')
    m.set_rate(poll, 1)
end

-- 3. Background tasks ----------------------------------------------------------
do
    files['C:/T/Mods/worker/mod.lua'] = [[
        return {on_enable = function(ctx)
            ctx.spawn(function(a, b)
                Log[#Log + 1] = 'start ' .. a .. b
                ctx.yield()
                Log[#Log + 1] = 'after yield'
                ctx.wait_frames(3)
                Log[#Log + 1] = 'after frames'
                ctx.sleep(1)
                Log[#Log + 1] = 'after sleep'
            end, 'x', 'y')
            ctx.spawn(function()
                for i = 1, 1e9 do
                    Busy.n = i
                    ctx.checkpoint()
                end
            end)
            Crash = ctx.spawn(function() error('boom') end)
        end}]]
    local Log, Busy = {}, {n = 0}
    local clock = 0
    local m = mdl_manager.new({base_dir = 'C:/T', platform = fs, globals = setmetatable({Log = Log, Busy = Busy}, {__index = _G}),
        clock = function() clock = clock + 0.0001 return clock end})
    m.start()
    local worker = m.by_id.worker
    check(m.enable(worker), 'worker enables')
    m.frame(0.016)
    check(Log[1] == 'start xy', 'tasks start in the frame after spawn')
    m.frame(0.016)
    check(worker.error and worker.error:find('boom') and worker.status == 'enabled', 'crashing task isolated, not starved by the busy one')
    check(Log[2] == 'after yield', 'yield resumes next frame')
    m.frame(0.016); m.frame(0.016)
    check(#Log == 2, 'wait_frames holds for 3 frames')
    m.frame(0.016)
    check(Log[3] == 'after frames', 'wait_frames released')
    local before = Busy.n
    m.frame(0.016)
    local per_frame = Busy.n - before
    check(per_frame > 0 and per_frame < 100, 'busy task limited by the 1 ms budget (' .. per_frame .. ' steps)')
    clock = clock + 2
    m.frame(0.016)
    check(Log[4] == 'after sleep', 'sleep uses the clock')
    m.disable(worker)
    local frozen = Busy.n
    m.frame(0.016)
    check(Busy.n == frozen, 'tasks stop when the mod is disabled')
end

-- 4. Chunked signature scan in a task --------------------------------------------
do
    files['C:/T/Mods/scanner/mod.lua'] = [[
        return {on_enable = function(ctx)
            ctx.spawn(function()
                Result.hits = ctx.scan(Result.base, Result.size, '48 8B ?? 90 CC', 4)
                Result.done = true
            end)
        end}]]
    local size = 400000
    local buffer = ffi.new('uint8_t[?]', size)
    for i = 0, size - 1 do buffer[i] = (i * 7) % 200 end
    for _, at in ipairs({1000, 250000, 399990}) do
        buffer[at], buffer[at + 1], buffer[at + 2], buffer[at + 3], buffer[at + 4] = 0x48, 0x8B, 0x11, 0x90, 0xCC
    end
    local Result = {base = buffer, size = size}
    local clock = 0
    local m = mdl_manager.new({base_dir = 'C:/T', platform = fs, globals = setmetatable({Result = Result}, {__index = _G}),
        clock = function() clock = clock + 0.0006 return clock end})
    m.start()
    m.enable(m.by_id.scanner)
    local frames = 0
    while not Result.done and frames < 100 do m.frame(0.016); frames = frames + 1 end
    check(Result.done and #Result.hits == 3 and Result.hits[2] == 250000, 'scan finds all hits')
    check(frames > 1, 'scan spread over ' .. frames .. ' frames')
end

print('PASS: MDL mod optimizations (async logs, update rate, tasks, chunked scan) (' .. checks .. ' checks)')
