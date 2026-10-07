-- MDL API example: background initialization without a frame hitch.
-- Scans game.dll for a signature in a background task (spread over frames
-- within MDL's task budget), then polls a value at 10 Hz with ctx.sleep.
local ffi = require('ffi')

return {
    name = 'Async Scan Example',
    version = '1.0',
    description = 'Finds a code signature in the background, then polls without blocking frames.',

    on_enable = function(ctx)
        ctx.spawn(function()
            local game = ctx.module('game.dll')
            if not game then ctx.log('game.dll not loaded') return end
            -- Code only: BaseOfCode / SizeOfCode from the PE optional header.
            local pe = ffi.cast('const int32_t *', game + 0x3c)[0]
            local code_size = tonumber(ffi.cast('const uint32_t *', game + pe + 24 + 4)[0])
            local code_base = tonumber(ffi.cast('const uint32_t *', game + pe + 24 + 20)[0])
            local started = os.clock()
            -- Example pattern: MenuSystem pop_screen.
            local hits = ctx.scan(game + code_base, code_size, '40 53 48 83 EC 20 48 8B 1D ?? ?? ?? ?? 8B 03 3B C2', 2)
            ctx.log(string.format('scan finished: %d hit(s) in %.1f s of background time', #hits, os.clock() - started))
            while true do
                -- poll something cheap here, 10 times per second
                ctx.sleep(0.1)
            end
        end)
    end,
}
