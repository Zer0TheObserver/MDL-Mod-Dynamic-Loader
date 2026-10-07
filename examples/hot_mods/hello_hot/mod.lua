-- MDL API 2 example. Copy this folder to
--   %LOCALAPPDATA%\MDL\Helldivers2\Mods\hello_hot\
-- then open the ESC menu and enable "Hello Hot" in the MDL panel.
-- Edit and save this file, then choose "Reload from disk" (or turn on
-- "Auto reload changed files") to see the change without restarting the game.
local ctx = ...                      -- the same ctx is passed to every callback
local util = require('lib/util')     -- resolved inside this mod folder first

local elapsed = 0

return {
    name = 'Hello Hot',
    version = '1.0',
    author = 'example',
    description = 'Logs a heartbeat and shows every option type.',

    options = {
        {key = 'heartbeat', label = 'Heartbeat log', type = 'toggle', default = true},
        {key = 'interval', label = 'Interval (s)', type = 'number', default = 5, min = 1, max = 30, step = 1},
        {key = 'style', label = 'Message style', type = 'choice', default = 'short', choices = {'short', 'long'}},
        {key = 'ping', label = 'Log now', type = 'action'},
    },

    on_enable = function(ctx)
        ctx.log('enabled; settings: interval=' .. tostring(ctx.settings.interval))
        -- Native writes go through ctx.write so disable/reload restores them:
        --   local game = ctx.module('game.dll')
        --   assert(ctx.write(game + 0x123456, '\x90\x90', '\x74\x05'))  -- new bytes, expected original
        -- Anything else that must be undone (GUIs, FFI callbacks) registers a cleanup:
        --   ctx.on_cleanup(function() callback:free() end)
    end,

    on_update = function(ctx, dt)
        if not ctx.settings.heartbeat then return end
        elapsed = elapsed + (dt or 0)
        if elapsed >= ctx.settings.interval then
            elapsed = 0
            ctx.log(util.message(ctx.settings.style))
        end
    end,

    on_setting = function(ctx, key, value)
        ctx.log('setting ' .. key .. ' = ' .. tostring(value))
        elapsed = 0
    end,

    on_action = function(ctx, key)
        if key == 'ping' then ctx.log(util.message('long')) end
    end,

    on_disable = function(ctx)
        ctx.log('disabled')
    end,
}
