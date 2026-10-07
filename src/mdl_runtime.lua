-- MDL runtime entry (resource mods/mdl/runtime). The build prepends the MDL
-- modules as local closures (mdl_platform, mdl_json, mdl_manager, mdl_library,
-- mdl_image, mdl_native_ui, mdl_menu, mdl_nativetab, mdl_panel). Started either by the MDL startup
-- coordinator or, when Bingus Shared Loader owns startup, by its declared-addon
-- discovery. A global guard keeps it to one instance per session.
local existing = rawget(_G, 'MDL')
if existing then return existing end
local MDL = {name = 'MDL', title = 'Mod Dynamic Loader', version = MDL_VERSION, api = 2, status = 'starting'}
rawset(_G, 'MDL', MDL)

local lines, dirty, written = {}, false, -1
local function log(line)
    line = tostring(line)
    print('[MDL] ' .. line)
    lines[#lines + 1] = os.date('%H:%M:%S ') .. line
    if #lines > 300 then table.remove(lines, 1) end
    dirty = true
end
MDL.log = log

local ok, reason = pcall(function()
    local platform = mdl_platform.new()
    local base = platform.base_dir()
    local log_dir = base .. '/Logs'
    platform.mkdir(log_dir)
    function MDL.write_log(force)
        local now = os.clock()
        if not dirty or not force and now - written < 1 then return end
        dirty, written = false, now
        pcall(platform.write, log_dir .. '/MDL.log', 'MDL ' .. tostring(MDL.version) .. ' (API 2)\n' .. table.concat(lines, '\n') .. '\n')
    end

    local loader = rawget(_G, 'CowboyBingusModLoader')
    local host = loader and (loader.provider == 'MDL' and 'MDL' or 'Bingus Shared Loader') or 'none'
    MDL.host, MDL.base_dir = host, base
    log('starting; startup host: ' .. host .. '; folder ' .. base)

    local manager = mdl_manager.new({base_dir = base, platform = platform, globals = _G, log = log, clock = platform.now,
        track_engine_default = MDL_DEBUG == true,
        boot_control = host == 'MDL', skip_boot = {['mods/mdl/runtime'] = true}})
    MDL.manager = manager
    -- Asynchronous, coalesced addon logs behind the shared open_log API.
    if loader and type(loader.open_log) == 'function' and manager.config.ui.async_logs ~= false then
        local ok_logs, problem = pcall(function()
            local directory = loader.log_directory
            if type(directory) ~= 'string' then
                directory = platform.localappdata()
                for _, part in ipairs({'CowboyBingus', 'Helldivers2', 'Logs'}) do
                    directory = directory .. '/' .. part
                    platform.mkdir(directory)
                end
            end
            local logs = mdl_logs.new({platform = platform, directory = directory, clock = platform.now, interval = 0.5})
            MDL.logs = logs
            loader.open_log_direct = loader.open_log_direct or loader.open_log
            loader.open_log = logs.open_log
        end)
        if not ok_logs then log('async logs unavailable: ' .. tostring(problem)) end
    end

    if loader then manager.sync_boot(loader.modules) end

    -- Library script addons with an HD2-Addon entry can run live from the
    -- manager archive (no Deploy); ones already loaded at launch are marked.
    local localappdata = platform.localappdata()
    local ui = manager.config.ui
    local library
    local function sync_library()
        for _, entry in ipairs(library.entries) do
            -- SCRIPT addons run live; MIXED ones too (their assets go through the
            -- live resource switch, which starts and stops the script).
            if entry.addon and (entry.category == 'SCRIPT' or entry.category == 'MIXED') and entry.addon ~= 'mods/mdl/runtime' then
                local status = loader and loader.modules and loader.modules[entry.addon]
                local current = entry
                entry.record = manager.register_packed(entry.id,
                    {name = entry.name, description = entry.description, author = entry.source},
                    entry.addon, function(name) return library.resolve(current, name) end,
                    {dir = entry.path, icon = entry.icon, launch = status == 'loaded' or status == 'loading', stamp = entry.stamp})
            end
        end
    end
    library = mdl_library.new({platform = platform, json = mdl_json, log = log, game_dir = platform.game_dir(),
        hash = mdl_library.hasher(require('ffi'), require('bit')), on_scan = sync_library,
        arsenal_dir = type(ui.arsenal_dir) == 'string' and ui.arsenal_dir or localappdata .. '/hd2arsenal',
        hd2mm_dir = type(ui.hd2mm_dir) == 'string' and ui.hd2mm_dir or localappdata .. '/Helldivers2ModManager'})
    MDL.library = library
    -- The library is scanned at startup only when a library addon must be
    -- restored; otherwise the first time the panel opens.
    local restore = false
    for id, on in pairs(manager.config.enabled) do
        if on and (id:sub(1, 8) == 'arsenal:' or id:sub(1, 6) == 'hd2mm:') then restore = true break end
    end
    if restore then
        local scanned, scan_problem = pcall(library.scan)
        if not scanned then log('library scan failed: ' .. tostring(scan_problem)) end
    end
    -- Library addons are restored on the first frame, after the coordinator
    -- reported which addons it loaded at launch (MDL starts before them).
    manager.start({defer_packed = true})

    local panel
    if stingray and stingray.Gui and stingray.World then
        local ffi = require('ffi')
        local images = mdl_image.new({ffi = ffi, platform = platform, log = log})
        local slots, slot_error, fonts, next_try = nil, nil, nil, 0
        local function provider()
            if fonts then return fonts end
            if type(ui.font) == 'string' and type(ui.material) == 'string' and type(ui.atlas) == 'string' then
                fonts = {font = ui.font, material = ui.material, atlas = ui.atlas}
                return fonts
            end
            local now = os.clock()
            if now < next_try then return nil end
            next_try = now + 1
            if not slots and not slot_error then
                local found, value = pcall(mdl_native_ui.resolve_slots, ffi, platform)
                if found then
                    slots = value
                    log(string.format('native font slots: font +0x%x atlas +0x%x material +0x%x', slots.font, slots.atlas, slots.material))
                else
                    slot_error = tostring(value)
                    log('native font lookup failed: ' .. slot_error)
                end
            end
            if slots then fonts = mdl_native_ui.read_fonts(platform, slots) end
            return fonts
        end
        local renderer = mdl_native_ui.renderer(stingray, provider)
        local input = mdl_panel.stingray_input(stingray, function() return ui.cursor_origin == 'top' and 'top' or 'bottom' end)
        -- Localisation (Languages\<code>.json; English base in mdl_panel).
        local i18n
        if mdl_i18n then
            local made, value = pcall(mdl_i18n.new, {platform = platform, json = mdl_json, dir = base .. '/Languages',
                base = mdl_panel.STRINGS, builtin = mdl_lang, code = ui.language,
                -- Automatic language: the game's Text Language (when a CowboyBingus
                -- menu mod has read it into _G.BingusTranslations), else Steam's
                -- language for the game, else the Windows display language.
                auto = function()
                    local shared = rawget(_G, 'BingusTranslations')
                    local game = type(shared) == 'table' and shared.game_language
                    if type(game) == 'string' and game ~= '' then return game, 'game' end
                    local steam = platform.steam_language and platform.steam_language()
                    if steam then return mdl_i18n.STEAM[steam] or steam, 'steam' end
                    local windows = platform.ui_locale and platform.ui_locale()
                    if windows then return windows, 'windows' end
                end,
                locale = platform.locale and platform.locale(),
                log = log})
            if made then
                i18n = value; MDL.i18n = i18n
                log('language: ' .. i18n.code .. (i18n.auto and (' (automatic, ' .. tostring(i18n.auto_source) .. ': '
                    .. tostring(i18n.auto_locale) .. ')') or ''))
            else log('localisation unavailable: ' .. tostring(value)) end
        end
        -- Live resource mods (mdl_reslab). Debug builds also get the Resource
        -- Lab pages, the full package log and the DirectStorage experiments.
        -- ui.live_resources = false turns the live switch off.
        local lab
        local debug_build = MDL_DEBUG == true
        if mdl_reslab and (debug_build or ui.live_resources ~= false) then
            local App, Id = stingray.Application, stingray.IdString64
            local made, value = pcall(mdl_reslab.new, {platform = platform, ffi = ffi, find_all = mdl_native_ui.find_all,
                clock = platform.now, base_dir = base, game_dir = platform.game_dir(), serialize = mdl_manager.serialize,
                verbose = debug_build and ui.debug_verbose ~= false, experimental = debug_build, auto_reapply = true,
                monitor = function() return debug_build and ui.debug_monitor ~= false end,
                -- MIXED mods: start / stop the script part with the assets.
                on_live = function(entry, on)
                    local record = entry.record
                    if not record then return end
                    if on and record.status ~= 'enabled' and record.status ~= 'launch' then
                        log(entry.name .. ': script started live (assets on their next load)')
                        manager.request('enable', record)
                    elseif not on and record.status == 'enabled' then
                        log(entry.name .. ': script stopped')
                        manager.request('disable', record)
                    end
                end,
                log_name = debug_build and 'MDL-ResourceLab.log' or 'MDL-LiveResources.log',
                log = function(line) log((debug_build and 'lab: ' or 'live: ') .. line) end,
                can_get = App and App.can_get and Id and Id.from_hex and function(type_hex, name_hex)
                    return App.can_get(Id.from_hex(type_hex), Id.from_hex(name_hex))
                end})
            if made then lab = value; MDL.lab = lab else log('resource lab unavailable: ' .. tostring(value)) end
        end
        -- Debug: texture probe (Settings > Texture probe), see mdl_probe.
        local probe
        if debug_build and mdl_probe then
            local made, value = pcall(mdl_probe.new, {engine = stingray, fonts = provider, log = log,
                flush = function() MDL.write_log(true) end, platform = platform, state_path = log_dir .. '/MDL-probe-state-4.txt',
                atlas = mdl_atlas})
            if made then probe = value; MDL.probe = probe else log('texture probe unavailable: ' .. tostring(value)) end
        end
        -- UI atlas shipped in MDL's own patch (texture + GUI material). The
        -- panel uses it once the engine reports the material loaded.
        local atlas
        if mdl_atlas and stingray.Application and stingray.IdString64 then
            local App, Id = stingray.Application, stingray.IdString64
            local known, next_check = {}, {}
            -- The packed atlas (uv mode) exists in debug builds only.
            atlas = {cells = mdl_atlas.cells, pieces = mdl_atlas.pieces, icons = mdl_atlas.ICONS,
                material = debug_build and mdl_atlas.MATERIAL or nil}
            function atlas.usable(mode)
                mode = mode or 'cells'
                if known[mode] then return true end
                local t = platform.now and platform.now() or os.clock()
                if t < (next_check[mode] or 0) then return false end
                next_check[mode] = t + 5
                local hex = mode == 'uv' and mdl_atlas.MATERIAL or mdl_atlas.pieces.logo.material
                local ok, value = pcall(App.can_get, Id.from_hex('eac0b497876adedf'), Id.from_hex(hex))
                known[mode] = ok and value == true
                if known[mode] then log('ui images (' .. mode .. '): material online')
                elseif not atlas['reported_' .. mode] then
                    atlas['reported_' .. mode] = true
                    log('ui images (' .. mode .. '): material not loaded (' .. tostring(ok and value or 'can_get failed') .. '); pixel glyphs used')
                end
                return known[mode]
            end
        end
        -- Per-mod Lua memory estimate (mdl_memory), measured in slices while
        -- the panel shows a mod page or the cost page.
        local memory
        if mdl_memory then
            local made, value = pcall(mdl_memory.new, {G = _G, ffi = ffi, clock = platform.now,
                scope = manager.memory_scope,
                stop_sources = manager.own_source and {[manager.own_source] = true} or nil})
            if made then memory = value; MDL.memory = memory else log('memory estimate unavailable: ' .. tostring(value)) end
        end
        panel = mdl_panel.new(manager, input, renderer, {library = library, images = images, host = host,
            memory = memory, heap_kb = function() return collectgarbage('count') end, debug_build = debug_build,
            atlas = atlas, anim = mdl_anim and mdl_anim.new() or nil, animations_default = debug_build,
            clock = platform.now, log = log, self_cost = function() return MDL.cost end,
            lab = debug_build and lab or nil, live = lab, i18n = i18n, glyphs = mdl_glyphs, probe = probe,
            menu_probe = function()
                local probe = MDL.menu_probe
                if type(probe) ~= 'function' then return nil end
                local probed, value = pcall(probe)
                if probed and value ~= nil then return value == true end
            end,
            tab_state = function() return MDL.tab_state end,
            context_serial = function() return MDL.context_serial or 0 end})
        MDL.panel = panel

        -- Native ESC-menu state from the game's MenuSystem; falls back to
        -- counting ESC presses (reset on level/cutscene world changes).
        if ui.native_menu ~= false then
            local found, layout = pcall(mdl_menu.resolve, ffi, platform, mdl_native_ui.find_all)
            if found then
                local names = mdl_menu.read_names(platform, layout)
                local screens = type(ui.menu_screens) == 'table' and ui.menu_screens or {'InGame'}
                local native = mdl_menu.probe(platform, layout, names, screens)
                -- Native "MDL Settings" tab in the ESC menu (independent implementation,
                -- see mdl_nativetab). ui.native_tab = false keeps the floating panel.
                local tabs
                if ui.native_tab ~= false then
                    local resolved, tab_layout = pcall(mdl_nativetab.resolve, ffi, platform, mdl_native_ui.find_all)
                    -- Tab title: ui.tab_text (default "MDL Settings"); ui.tab_label may
                    -- name a localized string id instead.
                    local label = tonumber(ui.tab_label)
                    local text = not label and (type(ui.tab_text) == 'string' and ui.tab_text ~= '' and ui.tab_text
                        or i18n and i18n.t('tab.title') or mdl_nativetab.DEFAULT_TEXT) or nil
                    if resolved and text and not tab_layout.set_arg then
                        resolved, tab_layout = false, 'custom tab text unavailable: ' .. tostring(tab_layout.arg_problem)
                    end
                    if resolved then
                        tabs = mdl_nativetab.new({platform = platform, layout = tab_layout, menu = layout, ffi = ffi, log = log,
                            label = label, text = text,
                            -- Mod Options Menu keeps the 4th tab; MDL becomes the 5th.
                            after_other = function() return rawget(_G, 'ModOptionsMenu') ~= nil end,
                            set_arg = text and mdl_nativetab.native_arg(ffi, tab_layout),
                            call = mdl_nativetab.native_call(ffi, tab_layout)})
                        MDL.native_tab = tabs
                        log(string.format('native tab: bar +%d, count +%d, labels +%d, text +%d, set_labels +0x%x, set_arg +0x%x, labels 0x%x 0x%x 0x%x',
                            tab_layout.bar, tab_layout.count, tab_layout.labels, tab_layout.text, tab_layout.set_labels,
                            tab_layout.set_arg or 0, tab_layout.expected[0], tab_layout.expected[1], tab_layout.expected[2]))
                    else
                        log('native tab unavailable (' .. tostring(tab_layout) .. '); using the floating panel')
                    end
                end
                local last_name, last_tab, mom_checked
                MDL.menu_probe = function()
                    local open, name = native()
                    if name ~= last_name then
                        last_name = name
                        log('menu screen: ' .. tostring(name) .. (open and ' (panel shown)' or ''))
                    end
                    MDL.tab_state = nil
                    -- Mod Options Menu adds its own native 4th tab (MODS) and, up to
                    -- 1.1, accepts only exactly 4 tabs: MDL takes tab 5 and shows
                    -- MOM a 4-tab bar while MOM's own update runs. A MOM that
                    -- declares extra_tabs = true needs no help.
                    local mom = tabs and not tabs.disabled and rawget(_G, 'ModOptionsMenu')
                    if mom ~= nil and mom ~= false and not mom_checked then
                        mom_checked = true
                        local version = type(mom) == 'table' and tostring(mom.version) or '?'
                        if type(mom) == 'table' and mom.extra_tabs == true then
                            log('native tab: Mod Options Menu ' .. version .. ' accepts extra tabs; MDL is tab 5')
                        else
                            local called, done, why = pcall(mdl_nativetab.shim_mom, _G, tabs, log)
                            if not called or done ~= true then
                                tabs.disabled = 'Mod Options Menu present (' .. tostring(called and why or done) .. ')'
                                log('native tab: ' .. tabs.disabled .. '; using the floating panel')
                            else
                                log('native tab: Mod Options Menu ' .. version .. ' found; MDL is tab 5')
                            end
                        end
                    end
                    if open and tabs and not tabs.disabled then
                        local stepped, info = pcall(tabs.step)
                        if not stepped then
                            tabs.disabled = tostring(info)
                            log('native tab disabled: ' .. tabs.disabled)
                        elseif info then
                            MDL.tab_state = info
                            local now = info.active and 'MDL' or tostring(info.current)
                            if now ~= last_tab then
                                last_tab = now
                                log(string.format('native tab: selected %s (panel %d, %d tabs)', now, info.panel, info.count))
                            end
                        end
                    end
                    return open
                end
                log(string.format('native menu state: MenuSystem +0x%x, open byte +%d, %d screen types, showing on %s',
                    layout.global, layout.open, #names + 1, table.concat(screens, ', ')))
            else
                log('native menu state unavailable (' .. tostring(layout) .. '); using ESC presses')
            end
        end
    else
        log('Stingray GUI unavailable; panel disabled')
    end

    local failures, synced = 0, false
    local previous_update = update
    local application = stingray and stingray.Application
    local main_world
    -- Library changes on disk (a mod imported or updated in Arsenal / HD2MM
    -- while the game runs) trigger a rescan once the manager's files have
    -- been stable for one check. Checked every 2 s while auto reload is on or
    -- the panel is open; a rescan reloads live addons whose code changed.
    local library_check, library_pending = 0, nil
    local function watch_library()
        if not (library and library.scanned) then return end
        if not (ui.auto_reload or (panel and panel.visible)) then return end
        local t = platform.now and platform.now() or os.clock()
        if t < library_check then return end
        library_check = t + 2
        local ok, stamp = pcall(library.source_stamp)
        if not ok or stamp == library.stamp then library_pending = nil return end
        if library_pending ~= stamp then library_pending = stamp return end
        library_pending = nil
        log('library changed on disk, rescanning')
        local scanned, problem = pcall(library.scan)
        if not scanned then log('library rescan failed: ' .. tostring(problem)) end
    end
    -- MDL's own time per frame (everything in `after` except the mods'
    -- updates and tasks): smoothed averages with the menu closed / open and
    -- a slowly decaying peak. Shown in Settings and the main page footer.
    local clock = platform.now or os.clock
    local cost = {idle = 0, open = 0, peak = 0, parts = {}}
    MDL.cost = cost
    -- Per-part averages and decaying peaks (Settings > MDL frame cost).
    local function part(name, started, extra)
        local spent = (clock() - started) * 1000 - (extra or 0)
        if spent < 0 then spent = 0 end
        local p = cost.parts[name]
        if not p then p = {avg = spent, peak = spent}; cost.parts[name] = p end
        p.avg = p.avg * 0.97 + spent * 0.03
        p.peak = math.max(spent, p.peak * 0.995)
    end
    local function account(started)
        local own = (clock() - started) * 1000 - (manager.frame_mods_ms or 0)
        if own < 0 then own = 0 end
        local key = panel and panel.visible and 'open' or 'idle'
        cost[key] = cost[key] * 0.97 + own * 0.03
        cost.peak = math.max(own, cost.peak * 0.995)
        cost.last = own
    end
    local function after(dt, ...)
        local started = clock()
        -- Level loads and cutscenes replace the main world; the ESC fallback
        -- uses this to drop a panel that the game closed behind our back.
        if application and not MDL.menu_probe then
            local got, world = pcall(application.main_world)
            if got and world ~= main_world then
                main_world = world
                MDL.context_serial = (MDL.context_serial or 0) + 1
            end
        end
        if not synced then
            synced = true
            if loader then pcall(manager.sync_boot, loader.modules) end
            local restored, restore_problem = pcall(manager.restore_packed)
            if not restored then log('library addon restore failed: ' .. tostring(restore_problem)) end
        end
        local t0 = clock()
        local watched, watch_problem = pcall(watch_library)
        if not watched then log('library watch failed: ' .. tostring(watch_problem)) end
        part('watch', t0)
        t0 = clock()
        local frame_ok, why = pcall(manager.frame, dt)
        if not frame_ok then log('frame failed: ' .. tostring(why)) end
        part('manager', t0, manager.frame_mods_ms)
        t0 = clock()
        if panel then
            local drawn, problem = pcall(panel.frame)
            if not drawn then
                failures = failures + 1
                log('panel failed: ' .. tostring(problem))
                if failures >= 10 then
                    pcall(panel.hide)
                    panel, MDL.panel = nil, nil
                    log('panel disabled after repeated failures')
                end
            end
        end
        part('panel', t0)
        t0 = clock()
        local probe = MDL.probe
        if probe then
            if panel and panel.visible and manager.config.ui.texture_probe then
                local drew, problem = pcall(probe.draw)
                if not drew then
                    log('texture probe failed: ' .. tostring(problem))
                    pcall(probe.clear)
                    MDL.probe = nil
                end
            elseif probe.active() then
                pcall(probe.clear)
            end
        end
        if MDL.probe then part('probe', t0) end
        t0 = clock()
        if MDL.lab then
            local stepped, problem = pcall(MDL.lab.step)
            if not stepped then
                log('lab failed: ' .. tostring(problem))
                MDL.lab.failures = (MDL.lab.failures or 0) + 1
                if MDL.lab.failures >= 10 then MDL.lab = nil end
            end
        end
        part('lab', t0)
        t0 = clock()
        if MDL.logs then MDL.logs.pump() end
        MDL.write_log(false)
        part('log', t0)
        account(started)
        return ...
    end
    -- Re-entry guard: a nested call while a frame is running (from inside a
    -- mod's update) is ignored instead of running the whole frame again.
    local in_frame = false
    local function run(dt, ...)
        if previous_update then return after(dt, previous_update(dt, ...)) end
        return after(dt)
    end
    local function finish(ok, ...)
        in_frame = false
        if not ok then error((...), 0) end
        return ...
    end
    update = function(dt, ...)
        if in_frame then
            pcall(manager.reentered)
            return
        end
        in_frame = true
        return finish(pcall(run, dt, ...))
    end
    local previous_shutdown = shutdown
    shutdown = function(...)
        pcall(manager.shutdown)
        if MDL.logs then pcall(MDL.logs.close) end
        if panel then pcall(panel.hide) end
        MDL.write_log(true)
        if previous_shutdown then return previous_shutdown(...) end
    end
    MDL.status = 'ready'
    log('ready: ' .. #manager.mods .. ' mods known')
    MDL.write_log(true)
end)

if not ok then
    MDL.status, MDL.error = 'failed', tostring(reason)
    log('startup failed: ' .. tostring(reason))
    if MDL.write_log then pcall(MDL.write_log, true) end
end
return MDL
