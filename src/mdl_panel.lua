-- MDL panel: opens together with the ESC menu and shows
--   LIVE LUA MODS   loose mods, enable/disable/reload and their options
--   SCRIPT ADDONS   deployed script addons started at launch
--   MOD LIBRARY     Arsenal / HD2MM library (model and script mods), with icons
-- Controller logic is engine-free; engine access is limited to the injected
-- input table and renderer.
local P = {}

local COLORS = {
    yellow = {255, 255, 213, 0}, border = {255, 255, 185, 0}, back = {214, 8, 10, 14},
    band = {255, 20, 24, 32}, hover = {70, 255, 213, 0}, select = {255, 255, 213, 0},
    text = {255, 222, 226, 232}, dim = {255, 150, 158, 168}, faint = {255, 96, 102, 110},
    red = {255, 255, 96, 72}, green = {255, 150, 222, 120}, blue = {255, 120, 190, 255},
    iconback = {255, 28, 32, 40},
}
P.COLORS = COLORS
-- Themes: the default Helldivers yellow-on-dark, and "archive", a paper-like
-- beige theme (dark ink, inverted selection rows, square bullets, a faint
-- ruled background). Colours are {a, r, g, b}.
local ARCHIVE = {
    yellow = {255, 70, 66, 56}, border = {255, 78, 74, 63}, back = {238, 208, 203, 182},
    band = {255, 192, 186, 163}, hover = {40, 70, 66, 56}, select = {255, 70, 66, 56},
    text = {255, 70, 66, 56}, dim = {255, 112, 106, 91}, faint = {255, 150, 144, 125},
    red = {255, 156, 58, 46}, green = {255, 74, 104, 64}, blue = {255, 58, 86, 116},
    iconback = {255, 184, 177, 154}, select_fill = {255, 82, 78, 67}, select_text = {255, 214, 208, 186},
    rule = {28, 70, 66, 56},
}
P.THEMES = {
    hd2 = {colors = COLORS, invert = false, bullets = false, rules = false, colour_icons = true},
    archive = {colors = ARCHIVE, invert = true, bullets = true, rules = true, decor = true, blink = true},
}
P.THEME_ORDER = {'hd2', 'archive'}

-- Author ID shown at the bottom of the main page (screenshot attribution).
local OWNER_ID = '174513429'
local R_BOOT = '9ba626afa44a3aa3'
P.OWNER_ID = OWNER_ID

-- English base text of every user-facing string (localisation keys; see
-- mdl_i18n). Language files override them key by key.
local STRINGS = {
    ['title.main'] = 'MOD DYNAMIC LOADER', ['title.help'] = 'HELP',
    ['state.on'] = 'ON', ['state.off'] = 'OFF', ['state.error'] = 'ERROR', ['state.restart'] = 'OFF NEXT LAUNCH',
    ['state.missing'] = 'NOT INSTALLED', ['state.on_pending'] = 'ON*', ['state.at_launch'] = 'AT LAUNCH', ['state.idle'] = 'IDLE',
    ['state.live_on'] = 'LIVE ON', ['state.run'] = 'RUN', ['state.why'] = 'WHY?', ['state.deployed'] = 'DEPLOYED',
    ['state.enabled_not_deployed'] = 'ENABLED, NOT DEPLOYED', ['state.scanning'] = 'SCANNING {percent}%',
    ['state.turning_off'] = 'OFF AFTER UNLOAD', ['state.launch_only'] = 'LAUNCH ONLY', ['state.copies_missing'] = 'COPIES MISSING',
    ['rate.every_frame'] = 'EVERY FRAME', ['rate.every_n'] = 'EVERY {n} FRAMES',
    ['category.SCRIPT'] = 'SCRIPT', ['category.MIXED'] = 'MIXED', ['category.RESOURCE'] = 'RESOURCE', ['category.UNKNOWN'] = 'UNKNOWN',
    ['group.live'] = 'SCRIPT  -  LIVE', ['group.script'] = 'SCRIPT  -  LAUNCH ONLY', ['group.mixed'] = 'MIXED  -  LAUNCH ONLY',
    ['group.resource'] = 'RESOURCE  -  LAUNCH ONLY', ['group.resource_live'] = 'RESOURCE  -  LIVE ON NEXT LOAD', ['group.unknown'] = 'UNKNOWN',
    ['header.live_mods'] = 'LIVE LUA MODS', ['header.addons'] = 'SCRIPT ADDONS (LOADED AT LAUNCH)', ['header.library'] = 'MOD LIBRARY',
    ['header.options'] = 'OPTIONS', ['header.why'] = 'WHY IT CANNOT START IN GAME', ['header.how'] = 'HOW TO TURN IT ON',
    ['header.in_library'] = 'IN YOUR LIBRARY ({count})', ['header.live_resource'] = 'LIVE (NO RESTART)', ['header.how_live'] = 'HOW IT WORKS',
    ['note.put_mods'] = 'Put mods in %LOCALAPPDATA%\\MDL\\Helldivers2\\Mods', ['note.or_library'] = '...or the Arsenal library (script addons, below)',
    ['note.scanning'] = 'Scanning...', ['note.no_other'] = 'No other mods in the library', ['note.no_library'] = 'No Arsenal or HD2MM library found',
    ['note.on_star'] = 'ON* = enabled in the manager but not deployed yet.',
    ['row.back'] = '< Back', ['row.rescan'] = 'Rescan mods and library', ['row.auto_reload'] = 'Auto reload changed Lua files',
    ['header.self_cost'] = 'MDL ITSELF, MS PER FRAME', ['header.cost_parts'] = 'BY PART (AVERAGE / PEAK)',
    ['title.cost'] = 'MDL FRAME COST',
    ['cost.closed'] = 'Menu closed (average)', ['cost.open'] = 'Menu open (average)', ['cost.peak'] = 'Recent peak',
    ['cost.manager'] = 'Loader core', ['cost.manager_hint'] = 'Scheduling the mods, their task queue and the auto reload checks (the mods\' own time is not included).',
    ['cost.panel'] = 'This panel', ['cost.panel_hint'] = 'Menu detection and drawing this panel (rebuilt about once a second while open).',
    ['cost.lab'] = 'Live resource mods', ['cost.lab_hint'] = 'Package monitor and staging work of the live resource switch; idle when no live resource mod is on.',
    ['cost.watch'] = 'Library watch', ['cost.watch_hint'] = 'Checks for mods added or updated in Arsenal / HD2MM every 2 s while auto reload is on or the panel is open.',
    ['cost.log'] = 'Logs', ['cost.log_hint'] = 'Writing MDL.log (at most once a second) and the addon log queue.',
    ['cost.probe'] = 'Texture probe (debug)', ['cost.probe_hint'] = 'Debug texture probe; nothing while it is off.',
    ['note.cost_parts'] = 'Short spikes (a panel rebuild, a log write) raise the peak; the averages are what the game feels.',
    ['row.animations'] = 'Animations', ['row.self_cost'] = 'MDL frame cost (closed / open / peak)',
    ['flash.self_cost'] = 'Time MDL itself takes per frame, without the mods\' updates: average with the menu closed, with it open, and the recent peak.',
    ['footer.self_cost'] = 'MDL {ms} ms',
    ['help.animations'] = 'Panel animations: the panel unfolds when it opens, the selection glides between rows, and the Archive theme has a blinking cursor. They cost a few GUI updates per frame while something moves.',
    ['help.self_cost'] = 'MDL frame cost: what MDL itself spends per frame (menu closed / open / peak), without the mods. Also in the footer of the main page.',
    ['state.launched_by'] = 'ON VIA {source}', ['state.twice'] = 'RUNNING TWICE',
    ['help.twice'] = 'Loaded at launch by the mod manager and also started live by MDL: stop the live copy and restart the game.',
    ['row.engine'] = 'Engine objects it made', ['engine.counts'] = '{units} units, {guis} GUIs, {effects} effects',
    ['engine.short'] = '{n} obj',
    ['flash.engine'] = 'Units, GUIs, particles and line objects this mod created and has not destroyed (counted while it runs; units the game removed are not counted).',
    ['row.native'] = 'Native memory (FFI)',
    ['flash.native'] = 'Memory it took with VirtualAlloc / HeapAlloc / malloc through ffi.C and has not freed (number of blocks in brackets). ffi.new memory is part of the Lua estimate.',
    ['row.left_behind'] = 'Left behind after stopping',
    ['flash.left_behind'] = 'This mod stopped without destroying these. They stay until the level unloads (units, GUIs) or the game closes (native memory).',
    ['row.track_engine'] = 'Track engine objects and native memory',
    ['flash.track_engine'] = 'Applies the next time a live mod starts. Mods see the same engine functions; the create/destroy ones also count what they made.',
    ['help.track_engine'] = 'Counts the units, GUIs, effects and native memory (VirtualAlloc / malloc through ffi.C) each live mod creates, and shows what a stopped mod left behind. Applies when a mod starts.',
    ['sort.order'] = 'SORT: LOAD ORDER', ['sort.name'] = 'SORT: A-Z', ['sort.time'] = 'SORT: NEWEST',
    ['flash.sort_order'] = 'Sorted in load order (as in the manager).', ['flash.sort_name'] = 'Sorted by name, A to Z.',
    ['flash.sort_time'] = 'Sorted by update time, newest first; the time is shown under each mod.',
    ['note.no_time'] = 'no time',
    ['row.updated'] = 'Updated', ['flash.updated'] = 'When the mod was added or last updated in Arsenal; for HD2MM, the newest patch file.',
    ['row.files_size'] = 'Files on disk', ['flash.files_size'] = 'Size of its patch files (.patch, .gpu_resources, .stream) on disk, not the memory it uses in game.',
    ['row.memory'] = 'Lua memory (estimate)', ['state.measuring'] = 'MEASURING',
    ['flash.memory'] = 'Estimate of the Lua objects this mod holds (tables, strings, functions). Engine memory it causes (units, textures, GUIs) and FFI allocations are not included.',
    ['row.alloc'] = 'Lua allocation', ['flash.alloc'] = 'Lua memory its update allocates per second; the collector frees it again. High values mean more garbage collection work.',
    ['header.memory'] = 'RUNNING MODS: MEMORY / ALLOCATION', ['memory.heap'] = 'Lua heap, whole game',
    ['flash.heap'] = 'All Lua memory in the game right now: the game\'s own scripts, the loaders and every mod.',
    ['note.no_running'] = 'No live mod is running.', ['row.measure_all'] = 'Measure again',
    ['note.memory'] = 'Lua objects only, estimated. Click for details.',
    ['lang.auto'] = 'Auto ({name})',
    ['flash.language_auto'] = 'Language: automatic, now {name}. Follows the game\'s language (Steam / game setting, else Windows); English when MDL has no such language.',
    ['help.fold_t'] = 'Folding',
    ['help.fold'] = 'Click [-] before a section title (or a title without ?) to fold it, [+] to open it again. A folded title shows how many mods it holds. Script addons (loaded at launch) start folded. Saved in MDL.cfg.',
    ['help.sort_t'] = 'Sorting',
    ['help.sort'] = 'Each section has a SORT switch on its title: load order, A-Z, or newest update first. Right click steps back. Saved in MDL.cfg.',
    ['help.memory_t'] = 'Memory',
    ['help.memory'] = 'A running mod\'s page shows its Lua memory (an estimate of the objects it holds, measured in 1 ms slices), its allocation rate, the engine objects it made and its native memory. All of them: MDL frame cost page.',
    ['row.theme'] = 'Theme', ['theme.hd2'] = 'Helldivers', ['theme.archive'] = 'Archive',
    ['help.theme'] = 'Helldivers: yellow on dark. Archive: paper beige with dark ink, inverted selection and ruled lines. Saved in MDL.cfg.',
    ['row.language'] = 'Language', ['row.update_rate'] = 'Update rate', ['row.load_at_launch'] = 'Load at launch', ['row.state'] = 'State',
    ['row.frame_cost'] = 'Frame cost (avg / peak)', ['row.reload_disk'] = 'Reload from disk', ['row.run_live'] = 'Run live in game',
    ['row.reload_library'] = 'Reload from library', ['row.in_source'] = 'In {source}', ['row.type'] = 'Type', ['row.manager'] = 'Manager',
    ['row.content'] = 'Content: {types}', ['row.use_live'] = 'Use live (applies on next load)',
    ['row.live_packages'] = 'Game packages: {active} active, {waiting} to reload, {total} in all',
    ['row.live_new'] = 'Adds {count} new resource(s) of its own', ['row.live_scan'] = 'Looking for the game packages it changes: {percent}%',
    ['reason.script'] = 'No HD2-Addon entry: starts only with the game', ['reason.unknown'] = 'No patch archive found',
    ['reason.resource'] = 'Assets load only when the game starts', ['reason.boot_only'] = 'Changes assets loaded once at game start',
    ['flash.launch_only'] = 'Starts only with the game: enable it in Arsenal, Deploy, restart. Click ? next to its group for details.',
    ['flash.rate_hint'] = 'Runs the update less often (dt is accumulated). Only for mods that poll; mods that must write every frame can misbehave.',
    ['flash.already_at_launch'] = 'Already loaded at launch (deployed). Turn it off in the manager.',
    ['flash.library_live'] = 'Script addons in MOD LIBRARY can be started live: click their OFF state.',
    ['flash.frame_cost_mod'] = 'Time this mod spends in its update each frame (measured by the loader).',
    ['flash.frame_cost_addon'] = 'Time this addon spends in its update each frame (measured by the loader).',
    ['flash.options_in_manager'] = 'Options are chosen in {source} (Deploy, then restart).',
    ['flash.read_only'] = 'Read-only information.',
    ['flash.language'] = 'Language: {name}. The ESC tab title changes at the next start.',
    ['live.scanning'] = 'Finding the game packages this mod changes (once per mod, a few seconds)...',
    ['live.on'] = 'On. It applies the next time the game loads these assets (next mission or back to the ship).',
    ['live.on_reload'] = 'On. These assets are loaded right now: leave and come back (mission or ship) to see the mod.',
    ['live.off'] = 'Off. The game uses its own assets the next time it loads them.',
    ['live.off_pending'] = 'Turning off: MDL removes its copies when the game unloads these assets (end of mission).',
    ['live.off_kept'] = 'Some copies are still in use; MDL removes them later or at the next start.',
    ['live.unavailable'] = 'This mod only changes assets the game loads once at start: enable it in {source}, Deploy, restart.',
    ['live.failed'] = 'Could not switch it on. See Logs\\MDL-LiveResources.log.',
    ['live.no_archive'] = 'No patch file found in this mod.',
    ['live.deployed'] = 'Deployed by {source}: it already loads at start. Turn it off there to use it live.',
    ['live.enabled'] = 'Enabled in {source}: the next Deploy loads it at start. Disable it there to use it live.',
    ['live.missing'] = 'A Deploy removed MDL\'s copies and they could not be restored. Switch it off and on again.',
    ['live.on_conflict'] = 'On, but {mod} (deployed in Arsenal) replaces {count} of the same assets and loads first: those parts keep its look. Disable it in Arsenal to see this mod in full.',
    ['live.unknown_mod'] = 'a deployed mod',
    ['row.live_conflict'] = 'Conflict: {mod} also replaces {count} of these assets (its version wins)',
    ['flash.live_conflict'] = '{mod} is deployed in Arsenal and loads at start, so its version of the shared assets is used. Disable it there (Deploy) to see this mod in full.',
    ['live.state_waiting'] = 'Applies when the game next loads these assets.',
    ['live.state_active'] = 'Active now.',
    ['live.state_reload'] = 'Loaded without it: leave and come back to apply.',
    ['footer.help'] = 'Click ? or < Back to return.',
    ['footer.why'] = 'These mods are switched in Arsenal (or HD2MM): Deploy, then restart the game.',
    ['footer.back'] = 'Click < Back to return.',
    ['footer.library_live'] = 'Runs from the library, no Deploy needed.',
    ['footer.outdated'] = 'A newer version is in the library: reload it, or turn on auto reload.',
    ['footer.resource_live'] = 'Live: no Deploy, no restart. Applies when the game next loads these assets.',
    ['footer.change_in'] = 'Change in {source} + Deploy, then restart.',
    ['footer.by'] = 'by {author}', ['footer.launch_addon'] = 'launch addon: applies next launch', ['footer.live_mod'] = 'live Lua mod',
    ['footer.summary'] = '{enabled} of {total} live Lua mods on  |  live mods {ms} ms/frame',
    ['footer.hint'] = 'Click a row to open it, click its state to toggle.',
    ['footer.hint2'] = 'Wheel scrolls. ON* = enabled in manager, not deployed.',
    ['help.h_types'] = 'MOD TYPES', ['help.h_states'] = 'STATES', ['help.h_deploy'] = 'ARSENAL DEPLOY', ['help.h_performance'] = 'PERFORMANCE',
    ['help.h_live_mods'] = 'LIVE LUA MODS',
    ['help.script'] = 'Lua code only. If it has an "-- HD2-Addon:" entry it can run live from your library: click OFF to start it, LIVE ON to stop it. No Deploy, no restart.',
    ['help.mixed'] = 'Assets plus Lua. Live when its Lua is an addon and its assets reload with game packages; else it starts with the game.',
    ['help.resource'] = 'Models, textures, sounds, materials and other assets. The game loads them once when it starts, so they cannot be switched on or off in game.',
    ['help.resource_live'] = 'Models, textures, sounds, materials and other assets. Click OFF to use one live: MDL places it next to the game files it changes and the game picks it up the next time it loads them (next mission or back to the ship). Mods that change assets loaded once at start show LAUNCH ONLY.',
    ['help.launch_only_t'] = 'LAUNCH ONLY',
    ['help.launch_only'] = 'Groups marked LAUNCH ONLY cannot start in game. Click the ? next to the group for the reason and the Arsenal steps.',
    ['help.unknown'] = 'No patch archive was found in the mod folder.',
    ['help.on'] = 'Enabled and deployed by Arsenal; active this session.',
    ['help.on_pending'] = 'Enabled in Arsenal but not deployed yet: Deploy, then restart the game.',
    ['help.off'] = 'Not enabled (library) or not running (script).',
    ['help.live_on'] = 'Started by this loader from the library or the Mods folder (scripts), or placed for the next load (resource mods).',
    ['help.at_launch'] = 'Deployed by Arsenal / HD2MM and started with the game (shown as ON VIA Arsenal); MDL does not start it a second time.',
    ['help.idle'] = 'Started but stopped itself right away; check that mod\'s own log.',
    ['help.error'] = 'Failed to start or crashed repeatedly; open the mod to read the reason.',
    ['help.deploy_t'] = 'What Deploy does',
    ['help.deploy'] = 'Arsenal copies the enabled mods into the game\'s data folder as patch files. The game reads those files only while it starts.',
    ['help.resource_mods_t'] = 'Resource mods',
    ['help.resource_mods'] = 'Close the game, enable or disable them in Arsenal, Deploy, then start the game again.',
    ['help.resource_mods_live'] = 'Use them live here, or enable them in Arsenal and Deploy to load them at every start. Not both: a Deploy removes MDL\'s copies (MDL restores them at the next start).',
    ['help.script_addons_t'] = 'Script addons',
    ['help.script_addons'] = 'Try them live here first. To load one every launch without clicking, enable it in Arsenal and Deploy; it then shows AT LAUNCH.',
    ['help.this_loader_t'] = 'This loader',
    ['help.this_loader'] = 'Keep it enabled in Arsenal. It works alone or next to Bingus Shared Loader in any order.',
    ['help.frame_cost_t'] = 'Frame cost',
    ['help.frame_cost'] = 'Average time a running mod spends per frame, shown in front of its state (green < 0.25 ms, yellow < 1 ms, red above). Its page also shows the peak.',
    ['help.update_rate_t'] = 'Update rate',
    ['help.update_rate'] = 'Slider on a mod\'s page: run it every frame up to every 8th frame. Good for mods that only poll; mods that must write every frame can misbehave.',
    ['help.logs_t'] = 'Logs',
    ['help.logs'] = 'Mod log files are written in the background at most twice per second; the final content is unchanged.',
    ['help.folder_t'] = 'Folder',
    ['help.folder'] = '%LOCALAPPDATA%\\MDL\\Helldivers2\\Mods\\<name>\\mod.lua (optional icon.png). Loaded, stopped and reloaded in game.',
    ['help.language_t'] = 'Language',
    ['help.language'] = 'Auto (default) follows the game\'s language: its Text Language setting when a menu mod has read it, else Steam\'s language, else Windows. Chinese shows Chinese; a language MDL has no file for shows English. Or pick one in the Language row. Texts come from %LOCALAPPDATA%\\MDL\\Helldivers2\\Languages\\<code>.json; copy en.json to add a language.',
    ['how.1'] = '1. Close the game.', ['how.2'] = '2. In Arsenal (or HD2MM) enable the mod and choose its options.',
    ['how.3'] = '3. Click Deploy.', ['how.4'] = '4. Start the game. The mod shows ON here.',
    ['why.script.title'] = 'SCRIPT - LAUNCH ONLY',
    ['why.script.1'] = 'This script has no "-- HD2-Addon:" line, so this loader cannot tell which resource starts it and cannot run it from the library.',
    ['why.script.2'] = 'It still works when deployed: the game or the startup loader runs it at launch.',
    ['why.script.3'] = 'Mod authors: make "-- HD2-Addon: mods/<author>/<name>" the first line of the script to make it live.',
    ['why.mixed_live.title'] = 'MIXED - SCRIPT NOW, ASSETS ON NEXT LOAD',
    ['why.mixed_live.1'] = 'A mixed mod (Lua + assets) can be switched on live when its Lua part is an addon (it declares HD2-Addon) and every asset replaces a game asset in a package the game reloads (a mission, the ship, a vehicle). MDL starts the script at once and stages the assets; they apply the next time those packages load.',
    ['why.mixed_live.2'] = 'It stays launch only when the Lua part is not an addon, when it adds new assets the game does not have (its own HUD textures, for example), when some assets exist only in the startup package, or when its assets are split over several patch files. The mod\'s page says which.',
    ['why.mixed_live.3'] = 'Switching it off stops the script at once; the asset copies are removed when their packages unload. Use one way per mod: live here, or deployed in your mod manager.',
    ['group.mixed_live'] = 'MIXED  -  SCRIPT NOW, ASSETS NEXT LOAD',
    ['row.mixed_script'] = 'Script part',
    ['reason.mixed'] = 'Click Use live to check whether it can run live (scans the game bundles once).',
    ['reason.mixed_no_addon'] = 'Launch only: the Lua part is not an addon (no HD2-Addon declaration).',
    ['reason.mixed_new'] = 'Launch only: {count} asset(s) are new to the game and load only at start.',
    ['reason.mixed_boot_only'] = 'Launch only: {count} asset(s) exist only in the startup package.',
    ['reason.mixed_archives'] = 'Launch only: its assets are split over several patch files.',
    ['reason.mixed_no_assets'] = 'Launch only: no assets found in its patch files.',
    ['live.mixed_no_addon'] = 'Launch only: its Lua part is not an addon. Turn it on in {source} and restart.',
    ['live.mixed_new'] = 'Launch only: it adds assets the game does not have. Turn it on in {source} and restart.',
    ['live.mixed_boot_only'] = 'Launch only: some assets exist only in the startup package. Turn it on in {source} and restart.',
    ['live.mixed_archives'] = 'Launch only: its assets are split over several patch files. Turn it on in {source} and restart.',
    ['live.mixed_no_assets'] = 'Launch only: no assets found. Turn it on in {source} and restart.',
    ['why.mixed.title'] = 'MIXED - LAUNCH ONLY',
    ['why.mixed.1'] = 'Mixed mods bring assets (models, textures, sounds) together with Lua. The game reads asset archives from its data folder only while it starts, and the Lua part expects those assets.',
    ['why.mixed.2'] = 'So the whole mod starts with the game; nothing can load or unload it while the game runs.',
    ['why.resource.title'] = 'RESOURCE - LAUNCH ONLY',
    ['why.resource.1'] = 'Resource mods replace models, textures, sounds, materials and other assets. The game reads asset archives from its data folder only while it starts.',
    ['why.resource.2'] = 'Nothing can add or remove them while the game runs, so they cannot be switched here.',
    ['why.resource_live.title'] = 'RESOURCE - LIVE ON NEXT LOAD',
    ['why.resource_live.1'] = 'The game loads most assets in packages, for example when a mission starts, and reads mod files for a package each time it loads it.',
    ['why.resource_live.2'] = 'Click OFF on a resource mod: MDL finds the packages that hold the assets it replaces (once per mod, a few seconds) and places the mod next to them. It shows up the next time the game loads them: next mission, or back to the ship. Nothing restarts.',
    ['why.resource_live.3'] = 'Mods that change assets the game loads once at start show LAUNCH ONLY: use Arsenal for those.',
    ['why.resource_live.4'] = 'Use a mod either live or through Arsenal, not both. An Arsenal Deploy removes MDL\'s copies; MDL puts them back at the next start.',
    ['why.unknown.title'] = 'UNKNOWN',
    ['why.unknown.1'] = 'No patch archive was found in this mod folder. The download may be incomplete, or the manager installs it in a way this loader cannot read.',
    ['why.unknown.2'] = 'Reinstall it in Arsenal, or check its page for install steps.',
    ['tab.title'] = 'MDL Settings',
}
P.STRINGS = STRINGS
local function english(key, vars)
    local text = STRINGS[key] or key
    if vars then text = text:gsub('{([%w_]+)}', function(name) return vars[name] ~= nil and tostring(vars[name]) or '{' .. name .. '}' end) end
    return text
end

local STATUS = {
    enabled = {'state.on', 'green'}, disabled = {'state.off', 'dim'}, error = {'state.error', 'red'},
    restart = {'state.restart', 'yellow'}, missing = {'state.missing', 'dim'},
}

-- UTF-8 aware; CJK and other multi-byte glyphs count as two columns.
local function columns(text)
    local width, i, n = 0, 1, #text
    while i <= n do
        local c = text:byte(i)
        local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
        width = width + (len >= 3 and 2 or 1)
        i = i + len
    end
    return width
end
P.columns = columns

local function short(text, limit)
    text = tostring(text or ''):gsub('[\r\n\t]+', ' ')
    if columns(text) <= limit then return text end
    local width, i, n = 0, 1, #text
    while i <= n do
        local c = text:byte(i)
        local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
        local w = len >= 3 and 2 or 1
        if width + w > limit - 3 then return text:sub(1, i - 1) .. '...' end
        width = width + w
        i = i + len
    end
    return text
end
P.short = short

-- Greedy wrap into at most `max_lines` lines of `limit` columns.
local function wrap(text, limit, max_lines)
    text = tostring(text or ''):gsub('[\r\n\t]+', ' ')
    local lines, current, width = {}, {}, 0
    local last_space
    local i, n = 1, #text
    while i <= n do
        local c = text:byte(i)
        local len = c < 0x80 and 1 or c >= 0xF0 and 4 or c >= 0xE0 and 3 or c >= 0xC0 and 2 or 1
        local ch = text:sub(i, i + len - 1)
        local w = len >= 3 and 2 or 1
        if width + w > limit then
            local line = table.concat(current)
            local carry = ''
            if last_space and last_space > #line * 0.5 then
                carry = line:sub(last_space + 1)
                line = line:sub(1, last_space - 1)
            end
            lines[#lines + 1] = line
            if #lines >= max_lines then
                lines[#lines] = short(lines[#lines] .. ' ' .. carry .. text:sub(i), limit)
                return lines
            end
            current, width, last_space = {carry}, columns(carry), nil
        end
        if ch == ' ' then last_space = #table.concat(current) + 1 end
        current[#current + 1] = ch
        width = width + w
        i = i + len
    end
    if #current > 0 then lines[#lines + 1] = table.concat(current) end
    return lines
end
P.wrap = wrap

local function format_number(value)
    if value == math.floor(value) then return tostring(value) end
    return string.format('%.2f', value)
end

-- Input adapter over stingray.Keyboard / stingray.Mouse; every lookup is
-- guarded so a renamed button only disables that control.
function P.stingray_input(engine, origin)
    local K, Mo = engine.Keyboard, engine.Mouse
    local ids = {}
    local function key_id(names)
        local cache_key = table.concat(names, '|')
        if ids[cache_key] == nil then
            ids[cache_key] = false
            for _, name in ipairs(names) do
                local ok, id = pcall(K.button_id, name)
                if ok and id then ids[cache_key] = id break end
            end
        end
        return ids[cache_key]
    end
    local input = {}
    function input.pressed(...)
        local id = K and key_id({...})
        if not id then return false end
        local ok, value = pcall(K.pressed, id)
        return ok and value == true
    end
    local function mouse_id(kind, name)
        local key = kind .. name
        if ids[key] == nil then
            local ok, id = pcall(kind == 'axis' and Mo.axis_id or Mo.button_id, name)
            ids[key] = ok and id or false
        end
        return ids[key]
    end
    function input.cursor(height)
        if not Mo then return nil end
        local id = mouse_id('axis', 'cursor')
        if not id then return nil end
        local ok, v = pcall(Mo.axis, id)
        if not ok or not v then return nil end
        local x, y = engine.Vector3.x(v), engine.Vector3.y(v)
        if origin() == 'top' then y = height - y end
        return x, y
    end
    function input.clicked(button)
        if not Mo then return false end
        local id = mouse_id('button', button)
        if not id then return false end
        local ok, value = pcall(Mo.pressed, id)
        return ok and value == true
    end
    function input.held(button)
        if not Mo then return false end
        local id = mouse_id('button', button)
        if not id then return false end
        local ok, value = pcall(Mo.button, id)
        return ok and type(value) == 'number' and value > 0.5
    end
    function input.wheel()
        if not Mo then return 0 end
        local id = mouse_id('axis', 'wheel')
        if not id then return 0 end
        local ok, v = pcall(Mo.axis, id)
        if not ok or not v then return 0 end
        return engine.Vector3.y(v)
    end
    return input
end

-- options = {library=, images=, host=, menu_probe=, tab_state=, width=, right=, top=}
function P.new(manager, input, renderer, options)
    options = options or {}
    local ui = manager.config.ui
    -- Localised text: options.i18n (mdl_i18n) or the English base.
    local i18n = options.i18n
    local function L(key, vars)
        if i18n then return i18n.t(key, vars) end
        return english(key, vars)
    end
    -- Live resource mods (mdl_reslab live switch), when compiled in.
    local live = options.live
    local glyphs = options.glyphs
    local self_anim_error = nil
    -- MDL UI atlas (texture + GUI material shipped in MDL's own patch, 1.8.0):
    -- options.atlas = {cells=, material=, usable=function()}. Used when the
    -- engine has it and the renderer has not rejected bitmaps.
    local atlas = options.atlas
    -- 'cells' (default): one texture + material per image, Gui.bitmap (the
    -- route proven by texture probe G). 'uv' (debug): the packed atlas with
    -- Gui.bitmap_uv (drew nothing in game in 1.8.0).
    local function atlas_mode()
        if ui.atlas_mode == 'uv' and atlas and atlas.material then return 'uv' end
        return 'cells'
    end
    local function atlas_ok()
        return atlas ~= nil and (atlas.pieces ~= nil or atlas.cells ~= nil)
            and (atlas.usable == nil or atlas.usable(atlas_mode()) == true) and not renderer.bitmap_error
    end
    -- Animations (mdl_anim): ui.animations, default options.animations_default.
    local anim = options.anim
    local function animating()
        if not anim or self_anim_error then return false end
        if ui.animations == nil then return options.animations_default == true end
        return ui.animations == true
    end
    local function theme() return P.THEMES[ui.theme] or P.THEMES.hd2 end
    local library, images = options.library, options.images
    local self = {visible = false, esc_open = false, page = 'list', cursor = 1, scroll = 0}
    local rows, geometry
    -- Text wrap widths are written for the 600 px floating panel and scaled
    -- with the current panel width / font size.
    local col_scale = 1
    local function cols(n) return math.max(16, math.floor(n * col_scale)) end

    local function flag(name, default)
        local value = ui[name]
        if value == nil then return default end
        return value == true
    end
    local function toggle_ui(name, default)
        ui[name] = not flag(name, default)
        manager.save()
    end
    local function icon(path, size)
        if not images or not path then return nil end
        return images.get(path, size)
    end
    local page_serial = 0
    local function go(page, target)
        self.page, self.target, self.cursor, self.scroll = page, target, 1, 0
        page_serial = page_serial + 1
    end
    self.go_for_test = go
    self.geometry = function() return geometry end
    -- Library groups, in display order. `why` groups have an explanation page.
    local GROUPS = {
        {key = 'live', title = 'group.live'},
        {key = 'script', title = 'group.script', why = true},
        {key = 'mixed', title = live and 'group.mixed_live' or 'group.mixed', why = true},
        {key = 'resource', title = live and 'group.resource_live' or 'group.resource', why = true},
        {key = 'unknown', title = 'group.unknown', why = true},
    }
    P.GROUPS = GROUPS
    -- Built-in glyph per group, drawn when a mod has no icon of its own.
    local GLYPH = {live = 'script', script = 'script', mixed = 'mixed', resource = 'resource', unknown = 'unknown'}
    local function group_of(entry)
        if entry.category == 'MIXED' then return 'mixed' end
        if entry.record then return 'live' end
        if entry.category == 'SCRIPT' then return 'script' end
        if entry.category == 'MIXED' then return 'mixed' end
        if entry.category == 'RESOURCE' then return 'resource' end
        return 'unknown'
    end
    -- Library entry that declares this addon name (launch addons get their
    -- manager name from it).
    local function library_entry_of(addon)
        for _, entry in ipairs(library and library.entries or {}) do
            if entry.addon == addon then return entry end
        end
    end
    -- "YYYY-MM-DD HH:MM" (local time) for update times (seconds since 1970).
    local function format_time(t)
        local format = options.format_time or (library and library.format_time)
        if format then return format(t) end
        local ok, text = pcall(os.date, '%Y-%m-%d %H:%M', math.floor(t))
        return ok and text or tostring(t)
    end
    -- Folding per list section (ui.collapsed[section] = true / false). The
    -- launch addon section starts folded; the others start open.
    local FOLDED_BY_DEFAULT = {addons = true}
    local function folded(section)
        local value = nil
        if type(ui.collapsed) == 'table' then value = ui.collapsed[section] end
        if value == nil then return FOLDED_BY_DEFAULT[section] == true end
        return value == true
    end
    self.folded = folded
    local function toggle_fold(section)
        if type(ui.collapsed) ~= 'table' then ui.collapsed = {} end
        local value = not folded(section)
        -- Stored only when it differs from the default.
        if value == (FOLDED_BY_DEFAULT[section] == true) then ui.collapsed[section] = nil else ui.collapsed[section] = value end
        if next(ui.collapsed) == nil then ui.collapsed = nil end
        manager.save()
    end
    self.toggle_fold = toggle_fold
    -- Drops the rows of folded sections. A folded top section hides its
    -- groups too; a folded header shows how many mods it holds.
    local function apply_folds(rows_in)
        local counts, owner_top, owner_sub = {}, nil, nil
        for i, row in ipairs(rows_in) do
            if row.separator then owner_top, owner_sub = nil, nil
            elseif row.header and not row.sub then owner_top, owner_sub = row.fold and i or nil, nil
            elseif row.header and row.sub then owner_sub = row.fold and i or nil
            elseif not row.note then
                if owner_top then counts[owner_top] = (counts[owner_top] or 0) + 1 end
                if owner_sub then counts[owner_sub] = (counts[owner_sub] or 0) + 1 end
            end
        end
        local out, hide_top, hide_sub = {}, false, false
        for i, row in ipairs(rows_in) do
            if row.separator then
                hide_top, hide_sub = false, false
                out[#out + 1] = row
            elseif row.header and not row.sub then
                hide_sub = false
                hide_top = row.fold ~= nil and folded(row.fold)
                if row.fold then row.collapsed, row.members = hide_top, counts[i] or 0 end
                out[#out + 1] = row
            elseif row.header and row.sub then
                if not hide_top then
                    hide_sub = row.fold ~= nil and folded(row.fold)
                    if row.fold then row.collapsed = hide_sub end
                    out[#out + 1] = row
                end
            elseif not (hide_top or hide_sub) then
                out[#out + 1] = row
            end
        end
        return out
    end

    -- Sorting per list section (ui.sort[section] = 'name' | 'time'; absent =
    -- load / library order). 'time' puts the newest update first.
    local SORT_ORDER = {'order', 'name', 'time'}
    local SORT_FLASH = {order = 'flash.sort_order', name = 'flash.sort_name', time = 'flash.sort_time'}
    local SORT_LABEL = {order = 'sort.order', name = 'sort.name', time = 'sort.time'}
    P.SORT_ORDER = SORT_ORDER
    local function sort_mode(section)
        local mode = type(ui.sort) == 'table' and ui.sort[section]
        if mode == 'name' or mode == 'time' then return mode end
        return 'order'
    end
    self.sort_mode = sort_mode
    local function cycle_sort(section)
        local at = 1
        for i, mode in ipairs(SORT_ORDER) do if mode == sort_mode(section) then at = i end end
        local mode = SORT_ORDER[at % #SORT_ORDER + 1]
        if type(ui.sort) ~= 'table' then ui.sort = {} end
        ui.sort[section] = mode ~= 'order' and mode or nil
        if next(ui.sort) == nil then ui.sort = nil end
        manager.save()
        if self.flash then self.flash(L(SORT_FLASH[mode])) end
    end
    self.cycle_sort = cycle_sort
    -- Stable sort of `list` by the section's mode. name_of / time_of read an
    -- item; items without a time go last, in their old order.
    local function sorted(list, section, name_of, time_of)
        local mode = sort_mode(section)
        if mode == 'order' or #list < 2 then return list end
        local keyed = {}
        for i, item in ipairs(list) do
            keyed[i] = {item = item, i = i, name = mode == 'name' and string.lower(tostring(name_of(item) or '')) or nil,
                time = mode == 'time' and time_of(item) or nil}
        end
        table.sort(keyed, function(a, b)
            if mode == 'name' then
                if a.name ~= b.name then return a.name < b.name end
            else
                local ta, tb = a.time or -1, b.time or -1
                if ta ~= tb then return ta > tb end
            end
            return a.i < b.i
        end)
        local result = {}
        for i, k in ipairs(keyed) do result[i] = k.item end
        return result
    end
    P.sorted_for_test = sorted
    -- The file line under a row, plus the update time when sorted by time.
    local function file_line(file, section, time)
        if sort_mode(section) ~= 'time' then return file end
        local stamp = time and format_time(time) or L('note.no_time')
        if file and file ~= '' then return file .. '   ' .. stamp end
        return stamp
    end

    local function launch_state(entry)
        if entry.deployed then return L('state.on'), 'green' end
        if entry.enabled then return L('state.on_pending'), 'yellow' end
        return L('state.off'), 'dim'
    end
    local function status_of(mod)
        local status = STATUS[mod.status]
        if status then return L(status[1]), status[2] end
        return string.upper(tostring(mod.status)), 'dim'
    end
    local function flash(text)
        self.flash_text, self.flash_until = text, os.clock() + 4
    end
    self.flash = flash
    local function live_state(record)
        if record.status == 'launch' then
            -- Deployed by Arsenal / HD2MM and loaded with the game.
            local source = record.info and record.info.author
            if source == 'Arsenal' or source == 'HD2MM' then return L('state.launched_by', {source = source}), 'green' end
            return L('state.at_launch'), 'green'
        end
        if record.status == 'enabled' and record.double then return L('state.twice'), 'red' end
        if record.status == 'enabled' and record.warning then return L('state.idle'), 'yellow' end
        if record.status == 'enabled' then return L('state.live_on'), 'green' end
        if record.status == 'error' then return L('state.error'), 'red' end
        return L('state.off'), 'dim'
    end
    -- Live resource mods: state label of a library resource mod.
    -- MIXED mods that stay launch only, by reason (mdl_reslab mixed_block).
    local MIXED_FLASH = {no_addon = 'live.mixed_no_addon', new = 'live.mixed_new', boot_only = 'live.mixed_boot_only',
        archives = 'live.mixed_archives', no_assets = 'live.mixed_no_assets'}
    local MIXED_REASON = {no_addon = 'reason.mixed_no_addon', new = 'reason.mixed_new', boot_only = 'reason.mixed_boot_only',
        archives = 'reason.mixed_archives', no_assets = 'reason.mixed_no_assets'}
    local function resource_live(entry)
        if not live or (entry.category ~= 'RESOURCE' and entry.category ~= 'MIXED') then return nil end
        local ok, state = pcall(live.live_state, entry)
        return ok and state or nil
    end
    local function resource_value(entry, state)
        if entry.deployed then return L('state.on'), 'green' end
        if state.state == 'on' then
            return L('state.live_on'), state.active and state.active > 0 and 'green' or 'yellow'
        elseif state.state == 'scanning' then
            return L('state.scanning', {percent = math.floor(100 * (state.progress or 0))}), 'yellow'
        elseif state.state == 'turning_off' then return L('state.turning_off'), 'yellow'
        elseif state.state == 'missing' then return L('state.copies_missing'), 'red'
        elseif state.state == 'unavailable' then return L('state.launch_only'), 'dim' end
        if entry.enabled then return L('state.on_pending'), 'yellow' end
        return L('state.off'), 'dim'
    end
    local function toggle_resource(entry)
        if entry.deployed and not (live.staged and live.staged[entry.id]) then
            flash(L('live.deployed', {source = entry.source})) return
        end
        local state = live.live_state(entry)
        if entry.enabled and state.state == 'off' then flash(L('live.enabled', {source = entry.source})) return end
        if state.state == 'unavailable' then
            if state.reason then flash(L(MIXED_FLASH[state.reason] or 'live.unavailable', {source = entry.source})) return end
            flash(L(state.no_archive and 'live.no_archive' or 'live.unavailable', {source = entry.source})) return
        end
        local _, key = live.live_toggle(entry, library and library.entries)
        if key == 'live.on_conflict' then
            local conflict = (live.conflicts(entry, library and library.entries) or {})[1]
            flash(L(key, {mod = conflict and conflict.owner or L('live.unknown_mod'), count = conflict and conflict.count or 0}))
        elseif key then flash(L(key, {source = entry.source})) end
    end
    -- Frame cost (average ms spent in the mod's update per frame).
    local function cost_text(cost) return cost < 0.01 and '<0.01 ms' or string.format('%.2f ms', cost) end
    local function cost_tone(cost) return cost > 1 and 'red' or cost > 0.25 and 'yellow' or 'green' end
    P.cost_text = cost_text
    local function running_cost(mod) return mod.status == 'enabled' and mod.cost or nil end
    -- Memory (mdl_memory estimate) and Lua allocation rate of a running mod.
    local memory = options.memory
    local function format_bytes(bytes)
        if bytes >= 1048576 then return string.format('%.2f MB', bytes / 1048576) end
        if bytes >= 1024 then return string.format('%.0f KB', bytes / 1024) end
        return string.format('%d B', bytes)
    end
    P.format_bytes = format_bytes
    local function alloc_text(rate)
        if rate < 1 then return '<1 KB/s' end
        if rate >= 1024 then return string.format('%.1f MB/s', rate / 1024) end
        return string.format('%.0f KB/s', rate)
    end
    P.alloc_text = alloc_text
    local function alloc_tone(rate) return rate > 1024 and 'red' or rate > 128 and 'yellow' or 'green' end
    -- Text and tone of a mod's memory estimate; queues a measurement when
    -- there is none (or it is from before a reload).
    local function memory_value(mod)
        if not memory or not manager.is_live(mod) or mod.status ~= 'enabled' then return nil end
        local result, stale = memory.result(mod)
        if not result or stale then
            memory.request(mod)
            result = memory.result(mod)
        end
        if not result then return nil end
        if result.state == 'done' then
            return '~' .. format_bytes(result.bytes) .. (result.truncated and '+' or ''), 'text'
        elseif result.state == 'measuring' then
            return result.bytes and ('~' .. format_bytes(result.bytes) .. ' ...') or L('state.measuring'), 'yellow'
        end
        return '-', 'dim'
    end
    -- Engine objects / native memory the mod made (manager tracking views).
    local function engine_counts(mod)
        if not manager.engine_counts then return nil end
        local ok, counts = pcall(manager.engine_counts, mod)
        return ok and counts or nil
    end
    local function engine_text(c)
        return L('engine.counts', {units = c.units, guis = c.guis, effects = c.particles + c.lines})
    end
    local function engine_total(c) return c.units + c.guis + c.particles + c.lines end
    local function memory_rows(mod, result)
        local counts = engine_counts(mod)
        if mod.status ~= 'enabled' then
            -- Stopped: what it left behind (a mod that forgot to clean up).
            if counts and (engine_total(counts) > 0 or counts.native_bytes > 0) then
                local text = engine_text(counts)
                if counts.native_bytes > 0 then text = text .. ', ' .. format_bytes(counts.native_bytes) end
                result[#result + 1] = {label = L('row.left_behind'), value = text, tone = 'red', note = true,
                    flash = L('flash.left_behind')}
            end
            return
        end
        if counts then
            result[#result + 1] = {label = L('row.engine'), value = engine_text(counts), tone = 'text', note = true,
                flash = L('flash.engine')}
            result[#result + 1] = {label = L('row.native'), value = format_bytes(counts.native_bytes)
                .. (counts.native_blocks > 0 and (' (' .. counts.native_blocks .. ')') or ''), tone = 'text', note = true,
                flash = L('flash.native')}
        end
        local value, tone = memory_value(mod)
        if value then
            result[#result + 1] = {label = L('row.memory'), value = value, tone = tone,
                open = function() memory.request(mod); flash(L('flash.memory')) end,
                adjust = function() memory.request(mod) end}
        end
        if mod.alloc then
            result[#result + 1] = {label = L('row.alloc'), value = alloc_text(mod.alloc), tone = alloc_tone(mod.alloc), note = true,
                flash = L('flash.alloc')}
        end
    end
    local function rate_label(rate) return rate == 1 and L('rate.every_frame') or L('rate.every_n', {n = rate}) end
    P.rate_label = function(rate) return rate == 1 and english('rate.every_frame') or english('rate.every_n', {n = rate}) end
    -- Update rate as a slider: every frame (left) .. every 8th frame (right).
    -- Drag or click the track; left/right (keyboard) or click the name step it.
    local function rate_row(mod)
        local rate = manager.rate(mod)
        local low, high = manager.RATES[1], manager.RATES[#manager.RATES]
        local function set(value)
            value = math.max(low, math.min(high, math.floor(value + 0.5)))
            if value ~= manager.rate(mod) then
                manager.set_rate(mod, value)
                flash(L('flash.rate_hint'))
            end
        end
        local function step(direction) set(rate + (direction or 1)) end
        return {label = L('row.update_rate'), value = rate_label(rate), tone = rate == 1 and 'text' or 'yellow',
            slider = {min = low, max = high, value = rate, set = set},
            open = function() set(rate < high and rate + 1 or low) end, adjust = step}
    end

    local function toggle_live(record)
        if record.status == 'launch' then
            flash(L('flash.already_at_launch'))
            return
        end
        manager.request('toggle', record)
    end

    -- Row model -------------------------------------------------------------
    local function list_rows()
        local result = {}
        result[#result + 1] = {header = L('header.live_mods'), sort = 'loose', fold = 'loose'}
        local loose = 0
        local loose_mods = {}
        for _, mod in ipairs(manager.mods) do if mod.kind == 'loose' then loose_mods[#loose_mods + 1] = mod end end
        loose_mods = sorted(loose_mods, 'loose', function(mod) return mod.info and mod.info.name or mod.id end,
            function(mod) return mod.updated end)
        for _, mod in ipairs(loose_mods) do
            do
                loose = loose + 1
                local value, tone = status_of(mod)
                result[#result + 1] = {label = mod.info and mod.info.name or mod.id, value = value, tone = tone,
                    file = file_line(mod.info and mod.info.name and mod.info.name ~= mod.id and mod.id or nil, 'loose', mod.updated),
                    icon = mod.icon, iconic = true, glyph = 'script', detail = mod.info and mod.info.description, cost_state = true, cost = running_cost(mod),
                    open = function() go('mod', mod) end,
                    adjust = function() manager.request('toggle', mod) end}
            end
        end
        if loose == 0 then
            result[#result + 1] = {label = L('note.put_mods'), tone = 'dim', note = true}
            result[#result + 1] = {label = L('note.or_library'), tone = 'dim', note = true, flash = L('flash.library_live')}
        end
        local addons = {}
        for _, mod in ipairs(manager.mods) do
            if mod.kind == 'boot' and mod.status ~= 'missing' and mod.id ~= 'mods/mdl/runtime' then addons[#addons + 1] = mod end
        end
        if #addons > 0 then
            result[#result + 1] = {header = L('header.addons'), sort = 'addons', fold = 'addons'}
            -- Launch addons have no files of their own here; their library
            -- entry (same addon name) gives the update time.
            -- Their library entry (same addon name) gives the name shown in
            -- the manager, the file name and the update time.
            local addon_entry = {}
            for _, entry in ipairs(library and library.entries or {}) do
                if entry.addon and not addon_entry[entry.addon] then addon_entry[entry.addon] = entry end
            end
            local function addon_name(mod)
                local entry = addon_entry[mod.id]
                return entry and entry.name or mod.info and mod.info.name or mod.id
            end
            addons = sorted(addons, 'addons', addon_name,
                function(mod) return addon_entry[mod.id] and addon_entry[mod.id].updated end)
            for _, mod in ipairs(addons) do
                local value, tone = status_of(mod)
                local entry = addon_entry[mod.id]
                result[#result + 1] = {label = addon_name(mod), value = value, tone = tone,
                    file = entry and file_line(entry.file, 'addons', entry.updated) or file_line(nil, 'addons', nil),
                    icon = entry and entry.icon,
                    detail = mod.id, iconic = true, glyph = 'script', cost_state = true, open = function() go('mod', mod) end,
                    adjust = function() manager.request('toggle', mod) end}
            end
        end
        if library then
            -- MDL and Bingus Shared Loader are never switched from in here.
            local entries = {}
            for _, entry in ipairs(library.entries or {}) do
                if not entry.loader then entries[#entries + 1] = entry end
            end
            result[#result + 1] = {header = L('header.library') .. (library.sources and #library.sources > 0 and (' - ' .. table.concat(library.sources, ', ')) or ''),
                fold = 'library'}
            -- Grouped by type; groups that cannot start in game carry a "?"
            -- that opens the explanation page (why + how to use Arsenal).
            local grouped = {}
            for _, entry in ipairs(entries) do
                local key = group_of(entry)
                grouped[key] = grouped[key] or {}
                table.insert(grouped[key], entry)
            end
            for _, group in ipairs(GROUPS) do
                local members = grouped[group.key]
                if members then
                    result[#result + 1] = {header = L(group.title), sub = true, count = #members, why = group.why and group.key, sort = group.key,
                        fold = 'group_' .. group.key}
                    members = sorted(members, group.key, function(entry) return entry.name end, function(entry) return entry.updated end)
                    for _, entry in ipairs(members) do
                        local file = file_line(entry.file, group.key, entry.updated)
                        local record = entry.category ~= 'MIXED' and entry.record
                        if record then
                            local value, tone = live_state(record)
                            result[#result + 1] = {label = entry.name, value = value, tone = tone, icon = entry.icon, detail = entry.description,
                                file = file,
                                iconic = true, glyph = 'script', cost_state = true, cost = running_cost(record),
                                open = function() go('library', entry) end, adjust = function() toggle_live(record) end}
                        else
                            local resource = resource_live(entry)
                            if resource then
                                local state, tone = resource_value(entry, resource)
                                result[#result + 1] = {label = entry.name, value = state, tone = tone, detail = entry.description,
                                    file = file, icon = entry.icon, iconic = true, glyph = GLYPH[group.key], cost_state = true, open = function() go('library', entry) end,
                                    adjust = function() toggle_resource(entry) end}
                            else
                                local state, tone = launch_state(entry)
                                result[#result + 1] = {label = entry.name, value = state, tone = tone, detail = entry.description,
                                    file = file, icon = entry.icon, iconic = true, glyph = GLYPH[group.key], cost_state = true, open = function() go('library', entry) end,
                                    adjust = function() flash(L('flash.launch_only')) end}
                            end
                        end
                    end
                end
            end
            if #entries == 0 then
                local any = library.entries and #library.entries > 0
                result[#result + 1] = {label = L(not library.scanned and 'note.scanning' or any and 'note.no_other' or 'note.no_library'),
                    tone = 'dim', note = true}
            end
        end
        result = apply_folds(result)
        result[#result + 1] = {separator = true}
        result[#result + 1] = {label = L('row.rescan'), value = '', tone = 'dim', glyph = 'refresh',
            open = function() manager.request('scan'); if library then self.rescan_library = true end end}
        result[#result + 1] = {label = L('row.auto_reload'), value = L(flag('auto_reload', false) and 'state.on' or 'state.off'),
            tone = 'blue', glyph = 'bolt', open = function() toggle_ui('auto_reload', false) end,
            adjust = function() toggle_ui('auto_reload', false) end}
        if i18n then
            -- Automatic (follows the game, English when no file matches), then
            -- each language. Automatic is stored as no choice (ui.language nil).
            local function pick(direction)
                local code = i18n.next(direction)
                ui.language = code ~= 'auto' and code or nil
                manager.save()
                if code == 'auto' then flash(L('flash.language_auto', {name = i18n.name()}))
                else flash(L('flash.language', {name = i18n.name(code)})) end
            end
            local auto = i18n.auto
            result[#result + 1] = {label = L('row.language'), value = auto and L('lang.auto', {name = i18n.name()}) or i18n.name(),
                tone = 'blue', glyph = 'globe',
                open = function() pick(1) end, adjust = function(direction) pick(direction or 1) end}
        end
        local function next_theme(direction)
            local order, at = P.THEME_ORDER, 1
            for i, key in ipairs(order) do if key == (P.THEMES[ui.theme] and ui.theme or 'hd2') then at = i end end
            ui.theme = order[(at - 1 + (direction or 1)) % #order + 1]
            manager.save()
        end
        result[#result + 1] = {label = L('row.theme'), value = L('theme.' .. (P.THEMES[ui.theme] and ui.theme or 'hd2')), tone = 'blue',
            glyph = 'palette', open = function() next_theme(1) end, adjust = function(direction) next_theme(direction or 1) end}
        if anim then
            local on = animating()
            local function flip()
                ui.animations = not animating()
                manager.save()
            end
            result[#result + 1] = {label = L('row.animations'), value = L(on and 'state.on' or 'state.off'), tone = 'blue',
                glyph = 'bolt', open = flip, adjust = flip}
        end
        if manager.tracking then
            local on = manager.tracking()
            local function flip_tracking()
                ui.track_engine = not manager.tracking()
                manager.save()
                flash(L('flash.track_engine'))
            end
            result[#result + 1] = {label = L('row.track_engine'), value = L(on and 'state.on' or 'state.off'), tone = 'blue',
                glyph = 'gear', open = flip_tracking, adjust = flip_tracking}
        end
        if options.self_cost then
            -- MDL's own time per frame (everything MDL does except the mods'
            -- update calls): average with the menu closed / open, and peak.
            local cost = options.self_cost()
            if cost then
                result[#result + 1] = {label = L('row.self_cost'), value = string.format('%.3f / %.3f / %.2f ms',
                    cost.idle or 0, cost.open or 0, cost.peak or 0), tone = cost_tone(math.max(cost.idle or 0, (cost.open or 0) / 4)),
                    glyph = 'gear', open = function() go('cost') end}
            end
        end
        if options.lab then
            result[#result + 1] = {label = 'Resource Lab (debug)', value = 'OPEN', tone = 'yellow', glyph = 'lab', open = function() go('lab') end}
        end
        if options.probe then
            -- Debug: draws the texture probe squares while the panel is open.
            local on = ui.texture_probe == true
            local function flip() toggle_ui('texture_probe', false) end
            result[#result + 1] = {label = 'Texture probe (debug)', value = on and 'ON' or 'OFF', tone = on and 'green' or 'dim',
                glyph = 'lab', open = flip, adjust = flip}
        end
        if options.lab then
            -- Debug extras that cost time; each can be switched off.
            local monitor = ui.debug_monitor ~= false
            local function flip_monitor() ui.debug_monitor = not (ui.debug_monitor ~= false); manager.save() end
            result[#result + 1] = {label = 'Package monitor (debug)', value = monitor and 'ON' or 'OFF', tone = monitor and 'green' or 'dim',
                glyph = 'lab', open = flip_monitor, adjust = flip_monitor}
            local verbose = ui.debug_verbose ~= false
            local function flip_verbose()
                ui.debug_verbose = not (ui.debug_verbose ~= false)
                if options.lab.set_verbose then options.lab.set_verbose(ui.debug_verbose) end
                manager.save()
            end
            result[#result + 1] = {label = 'Verbose lab log (debug)', value = verbose and 'ON' or 'OFF', tone = verbose and 'green' or 'dim',
                glyph = 'lab', open = flip_verbose, adjust = flip_verbose}
        end
        if options.lab and atlas then
            local on = ui.texture_icons == true
            local function flip() ui.texture_icons = not on or nil; renderer.bitmap_error = nil; manager.save() end
            result[#result + 1] = {label = 'Texture icons (debug, experimental)', value = on and 'ON' or 'OFF', tone = on and 'green' or 'dim',
                glyph = 'palette', open = flip, adjust = flip}
            result[#result + 1] = {label = 'UI atlas (debug)', value = atlas_ok() and 'OK' or 'OFF', tone = atlas_ok() and 'green' or 'red',
                glyph = 'palette', open = function() go('atlas') end}
        end
        return result
    end

    -- MDL frame cost by part (average / recent peak, ms per frame).
    local COST_PARTS = {'manager', 'panel', 'lab', 'watch', 'log', 'probe'}
    local function cost_rows()
        local result = {{label = L('row.back'), value = '', tone = 'dim', open = function() go('list') end}}
        local cost = options.self_cost and options.self_cost() or {}
        result[#result + 1] = {header = L('header.self_cost')}
        result[#result + 1] = {label = L('cost.closed'), value = string.format('%.3f ms', cost.idle or 0), tone = cost_tone(cost.idle or 0), note = true}
        result[#result + 1] = {label = L('cost.open'), value = string.format('%.3f ms', cost.open or 0), tone = cost_tone((cost.open or 0) / 4), note = true}
        result[#result + 1] = {label = L('cost.peak'), value = string.format('%.2f ms', cost.peak or 0), tone = cost_tone((cost.peak or 0) / 4), note = true}
        result[#result + 1] = {header = L('header.cost_parts')}
        for _, name in ipairs(COST_PARTS) do
            local p = cost.parts and cost.parts[name]
            if p then
                result[#result + 1] = {label = L('cost.' .. name), value = string.format('%.3f / %.2f ms', p.avg, p.peak),
                    tone = cost_tone(p.avg), note = true, flash = L('cost.' .. name .. '_hint')}
            end
        end
        result[#result + 1] = {label = L('note.cost_parts'), tone = 'dim', note = true}
        -- Memory of the running live mods (estimate) and their allocation rate.
        result[#result + 1] = {header = L('header.memory')}
        local heap = options.heap_kb and options.heap_kb()
        if heap then
            result[#result + 1] = {label = L('memory.heap'), value = format_bytes(heap * 1024), tone = 'text', note = true,
                flash = L('flash.heap')}
        end
        local running = {}
        for _, mod in ipairs(manager.mods) do
            if manager.is_live(mod) and mod.status == 'enabled' then running[#running + 1] = mod end
        end
        for _, mod in ipairs(running) do
            local value, tone = memory_value(mod)
            local parts = {}
            if value then parts[#parts + 1] = value end
            if mod.alloc then parts[#parts + 1] = alloc_text(mod.alloc) end
            local counts = engine_counts(mod)
            if counts and counts.native_bytes > 0 then parts[#parts + 1] = 'FFI ' .. format_bytes(counts.native_bytes) end
            if counts and engine_total(counts) > 0 then parts[#parts + 1] = L('engine.short', {n = engine_total(counts)}) end
            result[#result + 1] = {label = mod.info and mod.info.name or mod.id, value = table.concat(parts, '  '),
                tone = tone or 'text', glyph = 'script', open = function() go('mod', mod) end}
        end
        if #running == 0 then
            result[#result + 1] = {label = L('note.no_running'), tone = 'dim', note = true}
        elseif memory then
            result[#result + 1] = {label = L('row.measure_all'), value = '', tone = 'dim', glyph = 'refresh',
                open = function() for _, mod in ipairs(running) do memory.request(mod) end end}
        end
        result[#result + 1] = {label = L('note.memory'), tone = 'dim', note = true, flash = L('flash.memory')}
        return result
    end

    -- Debug: every atlas cell, its tinted mask, and the orientation cell.
    local function atlas_rows()
        local result = {{label = L('row.back'), value = '', tone = 'dim', open = function() go('list') end}}
        local state = not atlas and 'not compiled in' or renderer.bitmap_error and ('bitmap failed: ' .. tostring(renderer.bitmap_error))
            or (atlas.usable and not atlas.usable(atlas_mode())) and 'material not loaded (can_get false)' or 'OK'
        result[#result + 1] = {label = 'UI images: ' .. atlas_mode(), value = state:sub(1, 22), tone = state == 'OK' and 'green' or 'red', note = true,
            flash = state}
        local function switch()
            ui.atlas_mode = atlas_mode() == 'cells' and atlas.material and 'uv' or nil
            renderer.bitmap_error = nil
            manager.save()
        end
        result[#result + 1] = {label = 'Mode (cells = Gui.bitmap, uv = atlas + bitmap_uv)', value = atlas_mode(), tone = 'blue',
            open = switch, adjust = switch}
        local function flip() ui.atlas_flip_v = not ui.atlas_flip_v or nil; manager.save() end
        result[#result + 1] = {label = 'Flip V (if the arrow points down)', value = ui.atlas_flip_v and 'ON' or 'OFF', tone = 'blue', open = flip, adjust = flip}
        result[#result + 1] = {label = 'orient: arrow up, red mark top-left', atlas_cell = 'orient', note = true}
        result[#result + 1] = {header = 'ICONS (colour / mask tinted)'}
        for _, name in ipairs(atlas and atlas.icons or {}) do
            result[#result + 1] = {label = name, value = 'colour', atlas_cell = name, note = true}
            result[#result + 1] = {label = name .. '_mask', value = 'mask', atlas_cell = name .. '_mask', atlas_tint = 'yellow', note = true}
        end
        result[#result + 1] = {header = 'DECORATIONS'}
        for _, name in ipairs({'paper', 'corner', 'corner_tr', 'corner_bl', 'corner_br', 'rule', 'scan', 'grain'}) do
            result[#result + 1] = {label = name, atlas_cell = name, note = true}
        end
        return result
    end

    local function mod_rows(mod)
        local result = {{label = L('row.back'), value = '', tone = 'dim', open = function() go('list') end}}
        local value, tone = status_of(mod)
        result[#result + 1] = {label = L(mod.kind == 'boot' and 'row.load_at_launch' or 'row.state'), value = value, tone = tone,
            open = function() manager.request('toggle', mod) end,
            adjust = function() manager.request('toggle', mod) end}
        if mod.status == 'enabled' and mod.cost then
            result[#result + 1] = {label = L('row.frame_cost'), value = string.format('%.3f / %.2f ms', mod.cost, mod.peak or 0),
                tone = cost_tone(mod.cost), note = true, flash = L('flash.frame_cost_mod')}
        end
        memory_rows(mod, result)
        if mod.kind ~= 'boot' then result[#result + 1] = rate_row(mod) end
        if mod.kind == 'loose' then
            result[#result + 1] = {label = L('row.reload_disk'), value = '', tone = 'dim',
                open = function() manager.request('reload', mod) end}
        end
        local def = mod.def
        if type(def) == 'table' and type(def.options) == 'table' then
            result[#result + 1] = {header = L('header.options')}
            for _, option in ipairs(def.options) do
                if type(option) == 'table' and option.key ~= nil then
                    local kind = option.type or 'toggle'
                    local value = manager.option_value(mod, option)
                    local row = {label = option.label or tostring(option.key), tone = 'yellow', option = option}
                    if kind == 'toggle' then
                        row.value = L(value and 'state.on' or 'state.off')
                        row.open = function() manager.request('set_option', mod, option, not value) end
                        row.adjust = row.open
                    elseif kind == 'number' then
                        local step = option.step or 1
                        row.value = format_number(tonumber(value) or 0)
                        row.adjust = function(direction)
                            local next_value = (tonumber(value) or 0) + step * (direction or 1)
                            if option.min and next_value < option.min then next_value = option.min end
                            if option.max and next_value > option.max then next_value = option.max end
                            manager.request('set_option', mod, option, next_value)
                        end
                        row.open = function() row.adjust(1) end
                    elseif kind == 'choice' and type(option.choices) == 'table' and #option.choices > 0 then
                        local index = 1
                        for i, choice in ipairs(option.choices) do if choice == value then index = i end end
                        row.value = tostring(option.choices[index])
                        row.adjust = function(direction)
                            local count = #option.choices
                            manager.request('set_option', mod, option, option.choices[(index - 1 + (direction or 1)) % count + 1])
                        end
                        row.open = function() row.adjust(1) end
                    elseif kind == 'action' then
                        row.value = L('state.run')
                        row.open = function() manager.request('action', mod, option) end
                    else
                        row.value = tostring(value)
                    end
                    result[#result + 1] = row
                end
            end
        end
        return result
    end

    local function library_rows(entry)
        local result = {{label = L('row.back'), value = '', tone = 'dim', open = function() go('list') end}}
        local mixed = entry.category == 'MIXED'
        local record = not mixed and entry.record
        local resource = not record and resource_live(entry)
        if record then
            local value, tone = live_state(record)
            result[#result + 1] = {label = L('row.run_live'), value = value, tone = tone,
                open = function() toggle_live(record) end, adjust = function() toggle_live(record) end}
            if record.status == 'enabled' and record.cost then
                result[#result + 1] = {label = L('row.frame_cost'), value = string.format('%.3f / %.2f ms', record.cost, record.peak or 0),
                    tone = cost_tone(record.cost), note = true, flash = L('flash.frame_cost_addon')}
            end
            memory_rows(record, result)
            result[#result + 1] = rate_row(record)
            if record.status == 'enabled' then
                result[#result + 1] = {label = L('row.reload_library'), value = '', tone = 'dim',
                    open = function() self.rescan_library = true; manager.request('reload', record) end}
            end
        elseif resource and resource.state ~= 'unavailable' then
            result[#result + 1] = {header = L('header.live_resource')}
            local value, tone = resource_value(entry, resource)
            result[#result + 1] = {label = L('row.use_live'), value = value, tone = tone,
                open = function() toggle_resource(entry) end, adjust = function() toggle_resource(entry) end}
            if mixed and entry.record then
                -- The script part, started and stopped with the assets.
                local script_value, script_tone = live_state(entry.record)
                result[#result + 1] = {label = L('row.mixed_script'), value = script_value, tone = script_tone, note = true, quiet = true}
                if entry.record.status == 'enabled' and entry.record.cost then
                    result[#result + 1] = {label = L('row.frame_cost'), value = string.format('%.3f / %.2f ms', entry.record.cost, entry.record.peak or 0),
                        tone = cost_tone(entry.record.cost), note = true, flash = L('flash.frame_cost_addon')}
                end
                memory_rows(entry.record, result)
            end
            if resource.state == 'scanning' then
                result[#result + 1] = {label = L('row.live_scan', {percent = math.floor(100 * (resource.progress or 0))}), color = 'dim', note = true, quiet = true}
            end
            if resource.bundles then
                result[#result + 1] = {label = L('row.live_packages', {active = resource.active, waiting = resource.waiting, total = #resource.bundles}),
                    color = 'text', note = true, quiet = true}
                local key = resource.active > 0 and 'live.state_active' or resource.waiting > 0 and 'live.state_reload' or 'live.state_waiting'
                if resource.state == 'turning_off' then key = 'live.off_pending' elseif resource.state == 'missing' then key = 'live.missing' end
                result[#result + 1] = {label = L(key), color = resource.state == 'missing' and 'red' or 'dim', note = true, quiet = true}
            end
            if (resource.new or 0) > 0 then
                result[#result + 1] = {label = L('row.live_new', {count = resource.new}), color = 'dim', note = true, quiet = true}
            end
            local ok, conflicts = pcall(live.conflicts, entry, library and library.entries)
            for _, conflict in ipairs(ok and conflicts or {}) do
                result[#result + 1] = {label = L('row.live_conflict', {mod = conflict.owner or L('live.unknown_mod'), count = conflict.count}),
                    color = 'red', note = true, flash = L('flash.live_conflict', {mod = conflict.owner or L('live.unknown_mod')})}
            end
            result[#result + 1] = {label = L('header.how_live'), value = L('state.why'), tone = 'yellow',
                open = function() go('why', mixed and 'mixed' or 'resource') end}
        else
            local key = group_of(entry)
            local reason = L(key == 'script' and 'reason.script' or key == 'unknown' and 'reason.unknown'
                or resource and resource.reason and MIXED_REASON[resource.reason]
                or mixed and 'reason.mixed' or resource and 'reason.boot_only' or 'reason.resource',
                {count = resource and (resource.reason == 'boot_only' and resource.boot_only or resource.new) or 0})
            result[#result + 1] = {label = reason, value = L('state.why'), tone = 'yellow', open = function() go('why', key) end}
        end
        if options.lab and not record and (entry.category == 'RESOURCE' or entry.category == 'MIXED') then
            result[#result + 1] = {label = 'Resource Lab (debug)', value = 'OPEN', tone = 'yellow', open = function() go('labmod', entry) end}
        end
        local state, tone = L('state.off'), 'dim'
        if entry.deployed then state, tone = L('state.deployed'), 'green'
        elseif entry.enabled then state, tone = L('state.enabled_not_deployed'), 'yellow' end
        result[#result + 1] = {label = L('row.in_source', {source = entry.source}), value = state, tone = tone, note = true}
        result[#result + 1] = {label = L('row.type'), value = L('category.' .. tostring(entry.category)), tone = 'text', note = true}
        result[#result + 1] = {label = L('row.manager'), value = entry.source, tone = 'text', note = true}
        if entry.updated then
            result[#result + 1] = {label = L('row.updated'), value = format_time(entry.updated), tone = 'text', note = true,
                flash = L('flash.updated')}
        end
        if entry.bytes then
            result[#result + 1] = {label = L('row.files_size'), value = format_bytes(entry.bytes), tone = 'text', note = true,
                flash = L('flash.files_size')}
        end
        result[#result + 1] = {label = L('row.content', {types = library and library.describe_types and library.describe_types(entry.types) or ''}), tone = 'dim', note = true}
        if #entry.options > 0 then
            result[#result + 1] = {header = L('header.options')}
            for _, option in ipairs(entry.options) do
                result[#result + 1] = {label = option.name, value = L(option.enabled and 'state.on' or 'state.off'),
                    tone = option.enabled and 'green' or 'dim', icon = option.icon, iconic = true, glyph = 'square', note = true,
                    flash = L('flash.options_in_manager', {source = entry.source})}
            end
        end
        return result
    end

    -- Help page: what the library types and states mean, and how Arsenal
    -- deployment relates to what can change in game.
    local HELP = {
        {'help.h_types'},
        {'category.SCRIPT', 'help.script'},
        {'category.MIXED', 'help.mixed'},
        {'category.RESOURCE', 'help.resource', 'help.resource_live'},
        {'help.launch_only_t', 'help.launch_only'},
        {'category.UNKNOWN', 'help.unknown'},
        {'help.h_states'},
        {'state.on', 'help.on'},
        {'state.on_pending', 'help.on_pending'},
        {'state.off', 'help.off'},
        {'state.live_on', 'help.live_on'},
        {'state.at_launch', 'help.at_launch'},
        {'state.idle', 'help.idle'},
        {'state.twice', 'help.twice'},
        {'state.error', 'help.error'},
        {'help.h_deploy'},
        {'help.deploy_t', 'help.deploy'},
        {'help.resource_mods_t', 'help.resource_mods', 'help.resource_mods_live'},
        {'help.script_addons_t', 'help.script_addons'},
        {'help.this_loader_t', 'help.this_loader'},
        {'help.h_performance'},
        {'help.frame_cost_t', 'help.frame_cost'},
        {'help.update_rate_t', 'help.update_rate'},
        {'help.logs_t', 'help.logs'},
        {'help.memory_t', 'help.memory'},
        {'row.track_engine', 'help.track_engine'},
        {'help.h_live_mods'},
        {'help.folder_t', 'help.folder'},
        {'help.sort_t', 'help.sort'},
        {'help.fold_t', 'help.fold'},
        {'row.language', 'help.language'},
        {'row.theme', 'help.theme'},
        {'row.animations', 'help.animations'},
        {'row.self_cost', 'help.self_cost'},
    }
    local function help_rows()
        local result = {{label = L('row.back'), value = '', tone = 'dim', open = function() go('list') end}}
        for _, item in ipairs(HELP) do
            if not item[2] then
                result[#result + 1] = {header = L(item[1])}
            else
                result[#result + 1] = {label = L(item[1]), color = 'yellow', note = true, quiet = true}
                for _, line in ipairs(wrap(L(live and item[3] or item[2]), cols(46), 8)) do
                    result[#result + 1] = {label = '   ' .. line, color = 'text', note = true, quiet = true}
                end
            end
        end
        return result
    end

    -- "Why not live" page for one LAUNCH ONLY group: the reason, the Arsenal
    -- steps, and the library mods in that group (click to open).
    local HOW = {'how.1', 'how.2', 'how.3', 'how.4'}
    -- Explanation pages: title key, then paragraph keys.
    local WHY = {
        script = {'why.script.title', 'why.script.1', 'why.script.2', 'why.script.3'},
        mixed = {'why.mixed.title', 'why.mixed.1', 'why.mixed.2'},
        resource = {'why.resource.title', 'why.resource.1', 'why.resource.2'},
        resource_live = {'why.resource_live.title', 'why.resource_live.1', 'why.resource_live.2', 'why.resource_live.3', 'why.resource_live.4'},
        mixed_live = {'why.mixed_live.title', 'why.mixed_live.1', 'why.mixed_live.2', 'why.mixed_live.3'},
        unknown = {'why.unknown.title', 'why.unknown.1', 'why.unknown.2'},
    }
    P.WHY = {}
    for key, info in pairs(WHY) do
        P.WHY[key] = {}
        for i, text_key in ipairs(info) do P.WHY[key][i] = english(text_key) end
    end
    local function why_info(key)
        if key == 'resource' and live then return WHY.resource_live end
        if key == 'mixed' and live then return WHY.mixed_live end
        return WHY[key] or WHY.unknown
    end
    local function why_rows(key)
        local info = why_info(key)
        local live_page = info == WHY.resource_live or info == WHY.mixed_live
        local result = {{label = L('row.back'), value = '', tone = 'dim', open = function() go('list') end}}
        result[#result + 1] = {header = L(live_page and 'header.how_live' or 'header.why')}
        for i = 2, #info do
            for _, line in ipairs(wrap(L(info[i]), cols(48), 8)) do
                result[#result + 1] = {label = line, color = 'text', note = true, quiet = true}
            end
        end
        if key ~= 'unknown' then
            result[#result + 1] = {header = L('header.how')}
            for _, line in ipairs(HOW) do result[#result + 1] = {label = L(line), color = 'text', note = true, quiet = true} end
            result[#result + 1] = {label = L('note.on_star'), color = 'dim', note = true, quiet = true}
        end
        local members = {}
        for _, entry in ipairs(library and library.entries or {}) do
            if not entry.loader and group_of(entry) == key then members[#members + 1] = entry end
        end
        if #members > 0 then
            result[#result + 1] = {header = L('header.in_library', {count = #members})}
            for _, entry in ipairs(members) do
                local resource = resource_live(entry)
                local state, tone
                if resource then state, tone = resource_value(entry, resource) else state, tone = launch_state(entry) end
                result[#result + 1] = {label = entry.name, value = state, tone = tone, icon = entry.icon, iconic = true, glyph = GLYPH[group_of(entry)], detail = entry.source,
                    open = function() go('library', entry) end,
                    adjust = function() if resource then toggle_resource(entry) else flash(L('flash.launch_only')) end end}
            end
        end
        return result
    end

    -- Resource Lab pages (debug builds only; options.lab).
    local function note(result, text, color, value, tone)
        result[#result + 1] = {label = text, color = color or 'text', note = true, quiet = true, value = value, tone = tone}
    end
    local function lab_action(fn, ...)
        local ok, message = fn(...)
        if message then flash(message) end
        return ok
    end
    local function lab_rows()
        local lab = options.lab
        local result = {{label = '< Back', value = '', tone = 'dim', open = function() go('list') end}}
        result[#result + 1] = {header = 'PACKAGE MONITOR'}
        local resolved, why = lab.resolved()
        if not resolved then
            note(result, why and ('Unavailable: ' .. why) or 'Locating the package loader...', why and 'red' or 'dim')
        else
            note(result, 'Loaded packages', 'text', tostring(#(lab.packages or {})), 'text')
            local boot = lab.boot
            note(result, 'packages/boot (' .. R_BOOT .. ')', 'text', boot and ('RESIDENT, ' .. (#boot.layers - 1) .. ' PATCHES') or 'NOT FOUND',
                boot and 'green' or 'red')
            result[#result + 1] = {label = 'Write the package list to the lab log', value = '', tone = 'dim',
                open = function() lab_action(lab.dump) end}
            local staging, staging_why = lab.staging and lab.staging()
            note(result, 'DirectStorage staging buffer', 'text', staging and (math.floor(staging.size / 1048576) .. ' MB')
                or tostring(staging_why or 'unknown'), staging and 'text' or 'dim')
            result[#result + 1] = {header = 'RECENT CHANGES'}
            local events = lab.events or {}
            if #events == 0 then note(result, 'No package loaded or unloaded yet.', 'dim') end
            for i = #events, math.max(1, #events - 11), -1 do
                local event = events[i]
                note(result, event.time .. '  ' .. (event.kind == 'load' and '+ ' or '- ') .. event.text,
                    event.kind == 'load' and 'green' or 'dim')
            end
        end
        result[#result + 1] = {header = 'STAGED MODS'}
        local any = false
        for id, record in pairs(lab.staged or {}) do
            any = true
            local target
            for _, entry in ipairs(library and library.entries or {}) do if entry.id == id then target = entry end end
            result[#result + 1] = {label = record.name or id, value = #record.files .. ' BUNDLES', tone = 'yellow',
                open = function() if target then go('labmod', target) else flash('Not in the library any more; its files are listed in the lab log.') end end}
        end
        if not any then note(result, 'None.', 'dim') end
        return result
    end
    local function labmod_rows(entry)
        local lab = options.lab
        local state = lab.state_of(entry)
        local result = {{label = '< Back', value = '', tone = 'dim', open = function() go('library', entry) end}}
        result[#result + 1] = {header = 'PATCH FILE'}
        local archive = state.archives[state.archive]
        result[#result + 1] = {label = archive and archive.rel or 'No patch file found', tone = 'text',
            value = #state.archives > 1 and (state.archive .. '/' .. #state.archives) or '',
            open = function() lab_action(lab.cycle_archive, entry) end}
        result[#result + 1] = {header = 'HOME BUNDLES'}
        local scan = state.scan
        local value = scan.state == 'running' and (math.floor(100 * scan.done / math.max(1, scan.total)) .. '%')
            or scan.state == 'done' and 'RESCAN' or 'SCAN'
        result[#result + 1] = {label = 'Find the game bundles that contain these resources', value = value, tone = 'yellow',
            open = function() lab_action(lab.scan, entry) end}
        if scan.state == 'done' then
            note(result, string.format('%d resources: %d replace game resources, %d only in packages/boot, %d new',
                #scan.toc.entries, scan.replaced, scan.boot_only, scan.new), scan.new > 0 and 'yellow' or 'text')
            note(result, #scan.targets .. ' target bundle(s)', 'text')
            for i = 1, math.min(8, #scan.targets) do
                local target = scan.targets[i]
                note(result, '   ' .. target.bundle .. '   ' .. target.hits .. ' resource(s)', 'dim',
                    lab.loaded_bundles[target.bundle] and 'LOADED' or '', 'green')
            end
        end
        result[#result + 1] = {header = 'STAGE (DEBUG)'}
        local record = lab.staged[entry.id]
        if record then
            note(result, 'Staged ' .. (record.time or '') .. ' from ' .. (record.archive or '?'), 'text')
            if record.missing then
                note(result, 'Some copies are gone (a mod manager Deploy removes them). Unstage, then stage again.', 'red')
            end
            for _, file in ipairs(record.files) do
                note(result, '   ' .. file.bundle .. '.patch_' .. file.index, 'dim', file.missing and 'MISSING'
                    or lab.loaded_bundles[file.bundle] and 'LOADED' or '', file.missing and 'red' or 'green')
            end
            result[#result + 1] = {label = 'Unstage (remove the copies)', value = 'UNSTAGE', tone = 'red',
                open = function() lab_action(lab.unstage, entry.id) end}
        elseif scan.state == 'done' and #scan.targets > 0 then
            result[#result + 1] = {label = 'Stage into ' .. #scan.targets .. ' bundle(s)', value = state.confirm and 'CONFIRM' or 'STAGE',
                tone = state.confirm and 'red' or 'yellow', open = function() lab_action(lab.stage, entry, state.confirm) end}
        else
            note(result, 'Find the home bundles first.', 'dim')
        end
        local online = lab.online(entry)
        if online then note(result, 'Resources online now (can_get)', 'text', online.online .. ' / ' .. online.total, 'text') end
        if record then
            result[#result + 1] = {label = 'Write online status to the lab log', value = 'LOG', tone = 'dim',
                open = function() lab_action(lab.log_online, record, 'manual') end}
        end
        local largest = scan.state == 'done' and scan.largest
        if largest and (largest.gpu_size or 0) > 0 then
            note(result, string.format('Largest GPU resource: %.1f MB', largest.gpu_size / 1048576), 'dim', largest.name, 'dim')
        end
        note(result, 'A staged patch mounts the next time the game loads that package (e.g. a new mission).', 'dim')
        return result
    end

    function self.rows()
        if self.page == 'lab' and options.lab then return lab_rows() end
        if self.page == 'labmod' and options.lab and self.target then return labmod_rows(self.target) end
        if self.page == 'help' then return help_rows() end
        if self.page == 'atlas' and options.lab then return atlas_rows() end
        if self.page == 'cost' then return cost_rows() end
        if self.page == 'why' then return why_rows(self.target) end
        if self.page == 'mod' and self.target then return mod_rows(self.target) end
        if self.page == 'library' and self.target then return library_rows(self.target) end
        self.page = 'list'
        return list_rows()
    end

    local function selectable(row) return row and not row.separator and not row.header and not row.note end

    -- Layout and drawing ----------------------------------------------------
    local function layout(width, height, tall)
        local s = height / 1080
        local g = {s = s, w = (options.width or 600) * s, row = 34 * s, size = 19 * s, title = 26 * s,
            pad = 18 * s, border = 3 * s, icon = 26 * s}
        if self.mode == 'tab' then
            -- The ESC menu's content area is large: a wide, full-height page
            -- with larger text. ui.tab_x / tab_top / tab_width / tab_bottom
            -- (1080p units) override the default centred placement.
            g.row, g.size, g.title, g.pad, g.icon = 40 * s, 22 * s, 30 * s, 24 * s, 30 * s
            local aspect_w = width / s
            g.w = math.min(tonumber(ui.tab_width) or 1240, aspect_w - 80) * s
            g.x = tonumber(ui.tab_x) and tonumber(ui.tab_x) * s or (width - g.w) / 2
            g.top = height - (tonumber(ui.tab_top) or 150) * s
            g.header = 72 * s
            g.footer = 150 * s
            local bottom = (tonumber(ui.tab_bottom) or 100) * s
            g.visible_rows = math.max(4, math.floor((g.top - bottom - g.header - g.footer) / g.row))
            g.fill = true
        else
            g.x = width - g.w - (options.right or 64) * s
            g.top = height - (options.top or 130) * s
            g.header = 64 * s
            g.footer = 132 * s
            g.visible_rows = math.max(4, math.floor((height * 0.76 - g.header - g.footer) / g.row))
        end
        -- Pages listing mods get taller rows: the mod's file name goes in
        -- small text under its name (mods may share a name, files do not).
        if tall then
            local base = g.row
            g.row = math.floor(base * 1.36 + 0.5)
            g.file = g.size * 0.64
            if g.fill then
                local bottom = (tonumber(ui.tab_bottom) or 100) * s
                g.visible_rows = math.max(4, math.floor((g.top - bottom - g.header - g.footer) / g.row))
            else
                g.visible_rows = math.max(4, math.floor((height * 0.76 - g.header - g.footer) / g.row))
            end
        end
        -- Wide panels get a description column between name and state.
        g.wide = g.w >= 900 * s
        col_scale = (g.w / s) / 600 * 19 / (g.size / s)
        return g
    end

    local function footer_info()
        local target = self.target
        if self.page == 'help' then
            return {{L('footer.help'), 'dim'}}, nil, OWNER_ID
        end
        if self.page == 'lab' or self.page == 'labmod' then
            return {{'Debug build. Staging copies files into the game data folder.', 'yellow'},
                {'Log: %LOCALAPPDATA%\\MDL\\Helldivers2\\Logs\\MDL-ResourceLab.log', 'dim'}}, nil, OWNER_ID
        end
        if self.page == 'why' then
            return {{L(self.target == 'resource' and live and 'footer.resource_live' or 'footer.why'), 'text'},
                {L('footer.back'), 'dim'}}, nil, OWNER_ID
        end
        if self.page == 'library' and target then
            local lines = {}
            if target.file then lines[#lines + 1] = {short(target.file, cols(50)), 'faint'} end
            for _, line in ipairs(wrap(target.description or '', cols(44), 2)) do lines[#lines + 1] = {line, 'text'} end
            if target.record then
                if target.record.outdated then lines[#lines + 1] = {L('footer.outdated'), 'yellow'} end
                if target.record.error then lines[#lines + 1] = {short(target.record.error, cols(46)), 'red'} end
                if target.record.warning then lines[#lines + 1] = {short(target.record.warning, cols(46)), 'yellow'} end
                lines[#lines + 1] = {L('footer.library_live'), 'dim'}
            elseif resource_live(target) and resource_live(target).state ~= 'unavailable' then
                lines[#lines + 1] = {L('footer.resource_live'), 'dim'}
            else
                lines[#lines + 1] = {L('footer.change_in', {source = target.source}), 'dim'}
            end
            return lines, target.icon
        elseif self.page == 'mod' and target then
            local info, lines = target.info or {}, {}
            local meta = {}
            if info.version then meta[#meta + 1] = 'v' .. info.version end
            if info.author then meta[#meta + 1] = L('footer.by', {author = info.author}) end
            meta[#meta + 1] = L(target.kind == 'boot' and 'footer.launch_addon' or 'footer.live_mod')
            lines[#lines + 1] = {table.concat(meta, '  '), 'dim'}
            if info.description then
                for _, line in ipairs(wrap(info.description, cols(44), 2)) do lines[#lines + 1] = {line, 'text'} end
            end
            if target.outdated then lines[#lines + 1] = {L('footer.outdated'), 'yellow'} end
            if target.error then lines[#lines + 1] = {short(target.error, cols(50)), 'red'} end
            if target.warning then lines[#lines + 1] = {short(target.warning, cols(50)), 'yellow'} end
            return lines, target.icon
        end
        local enabled, total = 0, 0
        for _, mod in ipairs(manager.mods) do
            if mod.kind == 'loose' then total = total + 1; if mod.status == 'enabled' then enabled = enabled + 1 end end
        end
        local cost = 0
        for _, mod in ipairs(manager.mods) do if mod.status == 'enabled' and mod.cost then cost = cost + mod.cost end end
        return {{L('footer.summary', {enabled = enabled, total = total, ms = string.format('%.2f', cost)}), 'dim'},
            {L('footer.hint'), 'dim'},
            {L('footer.hint2'), 'faint'}}, nil, OWNER_ID
    end

    -- Title of the current page.
    local function page_title()
        -- The debug build says so in the main title.
        local title = L('title.main') .. (options.debug_build and ' - DEBUG' or '')
        if self.page == 'help' then title = L('title.help')
        elseif self.page == 'why' then title = L(why_info(self.target)[1])
        elseif self.page == 'lab' then title = 'RESOURCE LAB (DEBUG)'
        elseif self.page == 'atlas' then title = 'UI ATLAS (DEBUG)'
        elseif self.page == 'cost' then title = L('title.cost')
        elseif self.page == 'labmod' and self.target then title = 'LAB: ' .. tostring(self.target.name)
        elseif self.page ~= 'list' and self.target then
            local entry = self.page == 'mod' and self.target.kind == 'boot' and library_entry_of(self.target.id)
            title = self.page == 'library' and self.target.name or entry and entry.name
                or (self.target.info and self.target.info.name or self.target.id)
        end
        return title
    end
    self.title_for_test = page_title

    local function build(width, height)
        rows = self.rows()
        local tall = false
        for _, row in ipairs(rows) do if row.file then tall = true break end end
        local g = layout(width, height, tall)
        local count = #rows
        if self.cursor > count then self.cursor = count end
        if self.cursor < 1 then self.cursor = 1 end
        if not selectable(rows[self.cursor]) then
            for i = self.cursor, count do if selectable(rows[i]) then self.cursor = i break end end
        end
        local shown = math.min(count, g.visible_rows)
        -- Keyboard moves scroll the list to the cursor; the wheel and the
        -- scrollbar move the list and leave the cursor where it is.
        if self.follow_cursor then
            if self.cursor <= self.scroll then self.scroll = self.cursor - 1 end
            if self.cursor > self.scroll + shown then self.scroll = self.cursor - shown end
            -- Keep a section header visible above its first row.
            if self.scroll > 0 and rows[self.scroll] and rows[self.scroll].header and self.cursor == self.scroll + 1 then
                self.scroll = self.scroll - 1
            end
            self.follow_cursor = false
        end
        self.scroll = math.max(0, math.min(self.scroll, count - shown))
        local h = g.header + (g.fill and g.visible_rows or shown) * g.row + g.footer
        local y0 = g.top - h
        g.h, g.y0, g.shown = h, y0, shown
        local list, keys = {}, {}
        local look = theme()
        local pal = look.colors
        -- Texture images are an experiment (debug setting "Texture icons");
        -- the default is the pixel glyphs, which always draw.
        local use_atlas = ui.texture_icons == true and atlas_ok()
        local moving = animating()
        local function paint(color) return pal[color] or COLORS[color] or color end
        local function rect(x, y, w, hh, color, z)
            list[#list + 1] = {rect = true, x = x, y = y, w = w, h = hh, color = paint(color), z = z}
        end
        local function text(value, x, y, size, color, z)
            list[#list + 1] = {text = value, x = x, y = y, size = size, color = paint(color), z = z or 903}
        end
        -- Atlas cell as a textured quad; flip_x / flip_y mirror it (uv swap).
        local WHITE = {255, 255, 255, 255}
        local mode = atlas_mode()
        local function cell(name, x, y, w, hh, color, z, flip_x, flip_y)
            if not use_atlas then return false end
            if mode == 'cells' then
                if name == 'corner' and (flip_x or flip_y) then
                    name = flip_x and flip_y and 'corner_br' or flip_x and 'corner_tr' or 'corner_bl'
                end
                local piece = atlas.pieces and atlas.pieces[name]
                if not piece then return false end
                list[#list + 1] = {bitmap = true, material = piece.material, x = x, y = y, w = w, h = hh,
                    color = color == nil and WHITE or paint(color), z = z or 904}
                keys[#keys + 1] = 'p:' .. name
                return true
            end
            local uv = atlas.cells and atlas.cells[name]
            if not uv then return false end
            local u0, v0, u1, v1 = uv[1], uv[2], uv[3], uv[4]
            if flip_x then u0, u1 = u1, u0 end
            if flip_y then v0, v1 = v1, v0 end
            if ui.atlas_flip_v then v0, v1 = v1, v0 end
            list[#list + 1] = {bitmap = true, material = atlas.material, uv = {u0, v0, u1, v1}, x = x, y = y, w = w, h = hh,
                color = color == nil and WHITE or paint(color), z = z or 904}
            keys[#keys + 1] = 'a:' .. name
            return true
        end
        -- Icon: atlas cell (colour version when `colour`, else the white mask
        -- tinted with a theme colour), else a pixel glyph (mdl_glyphs) in the
        -- theme colour; false when neither exists.
        local function mark(name, x, y, size, color, z, colour)
            if name and use_atlas then
                if colour and cell(name, x, y, size, size, nil, z or 903) then return true end
                if cell(name .. '_mask', x, y, size, size, color, z or 903) then return true end
            end
            local grid = name and glyphs and glyphs.grid(name, paint(color))
            if not grid then return false end
            list[#list + 1] = {icon = grid, x = x, y = y, size = size, z = z or 903}
            keys[#keys + 1] = 'g:' .. grid.id
            return true
        end
        -- Square bullet (archive theme) in front of titles and headers.
        local function bullet(x, y, size, color)
            local b = size * 0.42
            rect(x, y + size * 0.12, b, b, color, 903)
            return b + size * 0.45
        end
        -- Icon tile; mods without an icon (or whose icon cannot be read) get
        -- their type glyph, or a "?" without the glyph module, so names line up.
        local function picture(path, x, y, size, pixels, glyph, ink)
            rect(x, y, size, size, 'iconback', 901)
            local grid = path and icon(path, pixels)
            if grid then
                list[#list + 1] = {icon = grid, x = x, y = y, size = size, z = 902}
            elseif not path or grid == false then
                local inner = size * 0.76
                if not mark(glyph or 'unknown', x + (size - inner) / 2, y + (size - inner) / 2, inner, ink or 'dim', 902,
                        look.colour_icons and ink ~= 'select_text') then
                    local qs = size * 0.62
                    text('?', x + (size - qs * 0.55) / 2, y + (size - qs) / 2 + qs * 0.08, qs, 'faint', 903)
                end
            end
            keys[#keys + 1] = tostring(path) .. ':' .. (grid and grid.id or grid == false and 'x' or 'p')
        end
        -- Layers (the GUI keeps integer z only): 897 background, 898 paper,
        -- 899 ruled lines, 901+ rows, text and frame.
        rect(g.x, y0, g.w, h, 'back', 897)
        g.panel = {x = g.x, y = y0, w = g.w, h = h}
        if look.decor and use_atlas then
            -- Archive decorations from the atlas: ink corner brackets and an
            -- ornamental rule under the title. (Images draw in a GUI layered
            -- above the panel, so no paper grain under the text.)
            local c = 34 * g.s
            local inset = g.border + 4 * g.s
            cell('corner', g.x + inset, g.top - inset - c, c, c, 'yellow', 904)
            cell('corner', g.x + g.w - inset - c, g.top - inset - c, c, c, 'yellow', 904, true)
            cell('corner', g.x + inset, y0 + inset, c, c, 'yellow', 904, false, true)
            cell('corner', g.x + g.w - inset - c, y0 + inset, c, c, 'yellow', 904, true, true)
            cell('rule', g.x + g.pad, g.top - g.header - 4 * g.s, g.w - 2 * g.pad, 8 * g.s, 'yellow', 904)
        end
        if look.rules then
            -- Faint ruled lines behind the rows, like a filing sheet.
            local top = g.top - g.header
            for k = 1, (g.fill and g.visible_rows or shown) do
                rect(g.x + g.border, top - k * g.row, g.w - 2 * g.border, math.max(1, g.s), 'rule', 899)
            end
        end
        rect(g.x, g.top - g.border, g.w, g.border, 'border', 904)
        rect(g.x, y0, g.w, g.border, 'border', 904)
        rect(g.x, y0, g.border, h, 'border', 904)
        rect(g.x + g.w - g.border, y0, g.border, h, 'border', 904)
        rect(g.x + g.border, g.top - g.header, g.w - 2 * g.border, g.header - g.border, 'band', 901)
        -- Animated selection bar: its rects are created here (below the rows,
        -- the GUI draws in creation order) and moved later by the overlay.
        if moving then
            list[#list + 1] = {slot = 'sel_fill', z = 901}
            list[#list + 1] = {slot = 'sel_mark', z = 902}
        end
        local title = page_title()
        local tx, ty = g.x + g.pad, g.top - g.header + (g.header - g.title) / 2
        local logo = g.title * 1.15
        if mark('logo', tx, ty - g.title * 0.12, logo, 'yellow', 904, look.colour_icons) then
            tx = tx + logo + g.title * 0.35
        elseif look.bullets then
            tx = tx + bullet(tx, ty, g.title, 'yellow')
        end
        local title_text = short(title, cols(count > shown and 23 or 29))
        text(title_text, tx, ty, g.title, 'yellow')
        g.title_end = {x = tx + columns(title_text) * g.title * 0.58 + 6 * g.s, y = ty, h = g.title * 0.85}
        -- "?" button opens the help page (click again to return).
        local button = 28 * g.s
        g.help = {x = g.x + g.w - g.pad - button, y = g.top - g.header + (g.header - g.border - button) / 2, w = button, h = button}
        local active = self.page == 'help'
        rect(g.help.x, g.help.y, button, button, active and 'yellow' or 'border', 904)
        rect(g.help.x + 2 * g.s, g.help.y + 2 * g.s, button - 4 * g.s, button - 4 * g.s, active and 'yellow' or 'band', 905)
        text('?', g.help.x + button * 0.33, g.help.y + button * 0.22, g.size * 1.05, active and 'band' or 'yellow', 906)
        -- Scrollbar along the right edge of the rows, with the visible range
        -- in the header; only when the list does not fit.
        g.bar = nil
        if count > shown then
            local track_top = g.top - g.header
            local track_h = shown * g.row
            local bar_w = 6 * g.s
            local thumb_h = math.max(24 * g.s, track_h * shown / count)
            local range = count - shown
            local thumb_top = track_top - (self.scroll / range) * (track_h - thumb_h)
            g.bar = {x = g.x + g.w - g.border - bar_w - 4 * g.s, y = track_top - track_h, w = bar_w, h = track_h,
                thumb_y = thumb_top - thumb_h, thumb_h = thumb_h, range = range}
            rect(g.bar.x, g.bar.y, bar_w, track_h, 'iconback', 905)
            rect(g.bar.x, g.bar.thumb_y, bar_w, thumb_h, self.dragging and 'yellow' or 'dim', 906)
            local range_text = string.format('%d-%d / %d', self.scroll + 1, self.scroll + shown, count)
            text(range_text, g.help.x - 10 * g.s - #range_text * g.size * 0.45, g.top - g.header + 25 * g.s, g.size * 0.75, 'dim')
        end
        g.hits, g.chips, g.folds = {}, {}, {}
        -- Fold switch before a section title: [+] folded, [-] open.
        local function fold_box(row, index, x, y, size)
            local box = math.floor(size * 0.95)
            local hovered = self.hover_fold == index
            rect(x, y, box, box, hovered and 'yellow' or 'border', 907)
            rect(x + g.s, y + g.s, box - 2 * g.s, box - 2 * g.s, hovered and 'yellow' or 'band', 908)
            -- Minus bar, plus the vertical bar when folded.
            local bar = math.max(1, math.floor(2 * g.s))
            local ink = hovered and 'band' or 'yellow'
            rect(x + box * 0.25, y + (box - bar) / 2, box * 0.5, bar, ink, 909)
            if row.collapsed then rect(x + (box - bar) / 2, y + box * 0.25, bar, box * 0.5, ink, 909) end
            g.folds[#g.folds + 1] = {index = index, section = row.fold, x = x - 4 * g.s, y = y - 4 * g.s, w = box + 8 * g.s, h = box + 8 * g.s}
            return box + 8 * g.s
        end
        -- Sort switch at the right end of a section header: "SORT: A-Z".
        local function sort_chip(row, index, ry)
            local mode = sort_mode(row.sort)
            local label = L(SORT_LABEL[mode])
            local size = g.size * 0.66
            local w = columns(label) * size * 0.62 + 16 * g.s
            local h = 22 * g.s
            local right = g.x + g.w - g.pad - (g.bar and 18 * g.s or 4 * g.s)
            local x, y = right - w, ry + 5 * g.s
            local hovered = self.hover_chip == index
            rect(x, y, w, h, hovered and 'yellow' or 'border', 907)
            rect(x + g.s, y + g.s, w - 2 * g.s, h - 2 * g.s, hovered and 'yellow' or 'band', 908)
            text(label, x + 8 * g.s, y + h * 0.2, size, hovered and 'band' or (mode == 'order' and 'dim' or 'yellow'), 909)
            g.chips[#g.chips + 1] = {index = index, section = row.sort, x = x, y = y, w = w, h = h}
            return x
        end
        local has_icons = false
        for index = self.scroll + 1, self.scroll + shown do
            local row = rows[index]
            if row.icon or row.iconic or row.atlas_cell or (row.glyph and (glyphs or use_atlas)) then has_icons = true end
        end
        for index = self.scroll + 1, self.scroll + shown do
            local row = rows[index]
            local slot = index - self.scroll
            local ry = g.top - g.header - slot * g.row
            local baseline = ry + (g.row - g.size) / 2 + g.size * 0.18
            if row.separator then
                rect(g.x + g.pad, ry + g.row / 2, g.w - 2 * g.pad, math.max(1, g.s), 'faint', 901)
            elseif row.header and row.sub then
                -- Library group: type title, count, and a "?" for LAUNCH ONLY groups.
                local size = g.size * 0.72
                local hx = g.x + g.pad + 12 * g.s
                if look.bullets then bullet(g.x + g.pad, ry + 9 * g.s, size * 0.8, 'faint') end
                if row.fold then
                    hx = hx + fold_box(row, index, hx, ry + 8 * g.s, size)
                    if not row.why then g.hits[#g.hits + 1] = {index = index, y = ry, h = g.row} end
                end
                local label = short(row.header, cols(40))
                local hovered = row.why and index == self.hover
                text(label, hx, ry + 9 * g.s, size, row.why and (hovered and 'yellow' or 'dim') or 'green')
                local after = hx + columns(label) * size * 0.62 + 12 * g.s
                if row.count then text(tostring(row.count), after, ry + 9 * g.s, size, 'faint'); after = after + (#tostring(row.count) * size * 0.62) + 12 * g.s end
                if row.why then
                    local q = 22 * g.s
                    local qy = ry + 5 * g.s
                    rect(after, qy, q, q, hovered and 'yellow' or 'border', 904)
                    rect(after + 2 * g.s, qy + 2 * g.s, q - 4 * g.s, q - 4 * g.s, hovered and 'yellow' or 'band', 905)
                    text('?', after + q * 0.3, qy + q * 0.18, size, hovered and 'band' or 'yellow', 906)
                    g.hits[#g.hits + 1] = {index = index, y = ry, h = g.row}
                end
                rect(hx, ry + 3 * g.s, g.w - 2 * g.pad - 12 * g.s, math.max(1, g.s), 'iconback', 901)
                if row.sort then sort_chip(row, index, ry) end
            elseif row.header then
                local hx = g.x + g.pad
                if look.bullets then hx = hx + bullet(hx, ry + 8 * g.s, g.size * 0.78, 'yellow') end
                local title = row.header
                if row.fold then
                    hx = hx + fold_box(row, index, hx, ry + 7 * g.s, g.size * 0.78)
                    g.hits[#g.hits + 1] = {index = index, y = ry, h = g.row}
                    if row.collapsed then title = title .. '  (' .. tostring(row.members or 0) .. ')' end
                end
                text(short(title, cols(row.sort and 38 or 52)), hx, ry + 8 * g.s, g.size * 0.78, self.hover == index and row.fold and 'text' or 'yellow')
                if row.sort then sort_chip(row, index, ry) end
                rect(g.x + g.pad, ry + 3 * g.s, g.w - 2 * g.pad, math.max(1, g.s), 'faint', 901)
            else
                local selected = index == self.cursor and not row.note
                -- Inverted selection (archive): dark bar, light text, square marker.
                local inverted = selected and look.invert
                if selected and moving then
                    -- Drawn by the animation overlay (glides between rows).
                    g.sel = {x = g.x + g.border, y = ry, w = g.w - 2 * g.border, h = g.row, inverted = inverted,
                        page = page_serial, s = g.s, marker = 8 * g.s}
                elseif inverted then
                    rect(g.x + g.border, ry, g.w - 2 * g.border, g.row, 'select_fill', 901)
                    local m = 8 * g.s
                    rect(g.x + g.border + 5 * g.s, ry + (g.row - m) / 2, m, m, 'select_text', 902)
                elseif selected then
                    rect(g.x + g.border, ry, g.w - 2 * g.border, g.row, 'hover', 901)
                    rect(g.x + g.border, ry, 4 * g.s, g.row, 'select', 902)
                end
                local lx = g.x + g.pad
                if has_icons and (row.icon or row.iconic or row.glyph or row.atlas_cell or row.open and not row.note) then
                    local iy = ry + (g.row - g.icon) / 2
                    if row.atlas_cell then
                        cell(row.atlas_cell, lx, iy, g.icon, g.icon, row.atlas_tint, 903)
                    elseif row.icon or row.iconic then
                        picture(row.icon, lx, iy, g.icon, 24, row.glyph, selected and 'yellow' or 'dim')
                    elseif row.glyph then
                        local inner = g.icon * 0.8
                        mark(row.glyph, lx + (g.icon - inner) / 2, iy + (g.icon - inner) / 2, inner,
                            inverted and 'select_text' or selected and 'yellow' or row.tone or 'dim', 902,
                            look.colour_icons and not inverted)
                    end
                    lx = lx + g.icon + 10 * g.s
                end
                local value = row.value and row.value ~= '' and short(row.value, 22) or nil
                local value_cols = value and columns(value) or 0
                local right = g.x + g.w - g.pad - (g.bar and 12 * g.s or 0)
                local value_x = right - value_cols * g.size * 0.56
                local label_cols = math.floor((g.w - (lx - g.x) - g.pad) / (g.size * 0.55)) - value_cols - 2
                -- Frame cost column in front of the state (running mods): same
                -- position on every row, colour by the average.
                if row.cost_state then
                    local csize = g.size * 0.8
                    local stat_right = right - 10 * g.size * 0.56 - 14 * g.s
                    local cost = row.cost
                    if cost then
                        local label = cost_text(cost)
                        text(label, stat_right - #label * csize * 0.56, baseline + g.size * 0.08, csize, cost_tone(cost))
                    end
                    value_x = math.min(value_x, stat_right + 14 * g.s)
                    label_cols = label_cols - 10
                end
                local slider = row.slider
                if slider then
                    -- Track between the name and the value, notch per step.
                    local tx = g.x + g.w * (g.wide and 0.42 or 0.40)
                    local tw = math.max(60 * g.s, value_x - 24 * g.s - tx)
                    local ty = ry + g.row / 2
                    local steps = slider.max - slider.min
                    local fraction = steps > 0 and (slider.value - slider.min) / steps or 0
                    rect(tx, ty - 2 * g.s, tw, 4 * g.s, 'iconback', 902)
                    rect(tx, ty - 2 * g.s, tw * fraction, 4 * g.s, row.tone == 'yellow' and 'yellow' or 'dim', 903)
                    for k = 0, steps do
                        rect(tx + tw * k / steps - g.s, ty - 6 * g.s, 2 * g.s, 12 * g.s, 'faint', 903)
                    end
                    local knob = 16 * g.s
                    local active = self.slider_drag == index
                    rect(tx + tw * fraction - knob / 2, ty - knob / 2, knob, knob, (selected or active) and 'yellow' or 'text', 905)
                    g.sliders = g.sliders or {}
                    g.sliders[index] = {x = tx, w = tw}
                    label_cols = math.min(label_cols, math.floor((tx - lx) / (g.size * 0.55)) - 1)
                end
                local detail = g.wide and type(row.detail) == 'string' and row.detail ~= '' and row.detail or nil
                if detail then
                    -- Description column (wide panels): name | description | cost | state.
                    local dx = g.x + g.w * 0.42
                    label_cols = math.floor((dx - lx) / (g.size * 0.55)) - 1
                    local dsize = g.size * 0.8
                    local dend = row.cost_state and (right - 10 * g.size * 0.56 - 14 * g.s - 8 * dsize * 0.56) or value_x
                    local dcols = math.floor((dend - 16 * g.s - dx) / (dsize * 0.55))
                    if dcols >= 8 then text(short(detail, dcols), dx, baseline + g.size * 0.08, dsize, 'faint') end
                end
                local label_y = baseline
                if row.file and g.file then
                    -- Name in the upper half, file name in small light text below.
                    label_y = ry + g.row * 0.5 + g.size * 0.02
                    local file_cols = math.floor(math.max(8, label_cols) * g.size / g.file * 0.95)
                    text(short(row.file, file_cols), lx, ry + g.row * 0.5 - g.file - 3 * g.s, g.file,
                        inverted and 'select_text' or selected and 'dim' or 'faint')
                end
                text(short(row.label, math.max(8, label_cols)), lx, label_y, g.size,
                    inverted and 'select_text' or selected and 'yellow' or row.color or (row.note and 'dim' or 'text'))
                if value then
                    text(value, value_x, baseline, g.size, inverted and 'select_text' or row.tone or 'text')
                end
                if selectable(row) or row.note then g.hits[#g.hits + 1] = {index = index, y = ry, h = g.row} end
            end
        end
        local lines, footer_icon, pinned = footer_info()
        local fx = g.x + g.pad
        if footer_icon then
            local size = g.footer - 30 * g.s
            picture(footer_icon, fx, y0 + 15 * g.s, size, 56)
            fx = fx + size + 14 * g.s
        end
        rect(g.x + g.pad, y0 + g.footer - 4 * g.s, g.w - 2 * g.pad, math.max(1, g.s), 'faint', 901)
        if self.flash_text and os.clock() < (self.flash_until or 0) then
            local flashed = wrap(self.flash_text, cols(footer_icon and 46 or 60), 2)
            for i = #flashed, 1, -1 do table.insert(lines, 1, {flashed[i], 'yellow'}) end
        else
            self.flash_text = nil
        end
        for i, line in ipairs(lines) do
            if i > 4 then break end
            text(short(line[1], cols(footer_icon and 46 or 60)), fx, y0 + g.footer - 10 * g.s - i * 24 * g.s * g.size / (19 * g.s), g.size * 0.8, line[2])
        end
        if pinned then text(pinned, fx, y0 + 8 * g.s, g.size * 0.8, 'faint') end
        -- MDL's own frame cost, bottom right of the main page.
        local own = self.page == 'list' and options.self_cost and options.self_cost()
        if own then
            local label = L('footer.self_cost', {ms = string.format('%.2f', own.open or 0)})
            local size = g.size * 0.8
            text(label, g.x + g.w - g.pad - columns(label) * size * 0.56, y0 + 8 * g.s, size, cost_tone((own.open or 0) / 4))
        end
        geometry = g
        local parts = {table.concat(keys, ',')}
        for _, item in ipairs(list) do
            if item.rect then
                parts[#parts + 1] = string.format('r%.1f,%.1f,%.1f,%.1f,%d', item.x, item.y, item.w, item.h, item.color[1] + item.color[2])
            elseif item.text then
                parts[#parts + 1] = string.format('t%s@%.1f,%.1f,%d', item.text, item.x, item.y, item.color[2] + item.color[3])
            end
        end
        return list, table.concat(parts, ';')
    end
    self.build = build

    -- Interaction -----------------------------------------------------------
    local function row_at(x, y)
        local g = geometry
        if not g or x < g.x or x > g.x + g.w then return nil end
        for _, hit in ipairs(g.hits or {}) do
            if y >= hit.y and y < hit.y + hit.h then return hit.index end
        end
    end

    local function move(delta)
        local count = rows and #rows or 0
        if count == 0 then return end
        local index = self.cursor
        for _ = 1, count do
            index = (index - 1 + delta) % count + 1
            if selectable(rows[index]) and not rows[index].note then break end
        end
        self.cursor = index
        self.follow_cursor = true
    end

    local function scroll_by(delta)
        local g = geometry
        local range = g and g.bar and g.bar.range or 0
        self.scroll = math.max(0, math.min(range, self.scroll + delta))
    end

    -- Returns true when the pointer interaction belongs to the scrollbar.
    local function scrollbar(x, y)
        local bar = geometry and geometry.bar
        if not bar then self.dragging = nil return false end
        if self.dragging then
            if not input.held('left') then self.dragging = nil return true end
            local thumb_top = y + self.dragging
            local fraction = (bar.y + bar.h - thumb_top) / math.max(1, bar.h - bar.thumb_h)
            self.scroll = math.max(0, math.min(bar.range, math.floor(fraction * bar.range + 0.5)))
            return true
        end
        local slack = 6 * geometry.s
        if x < bar.x - slack or x > bar.x + bar.w + slack or y < bar.y or y > bar.y + bar.h then return false end
        if input.clicked('left') then
            if y >= bar.thumb_y and y <= bar.thumb_y + bar.thumb_h then
                self.dragging = (bar.thumb_y + bar.thumb_h) - y
            elseif y > bar.thumb_y + bar.thumb_h then
                scroll_by(-(geometry.shown - 1))
            else
                scroll_by(geometry.shown - 1)
            end
        end
        return true
    end

    local function activate(row, kind, direction)
        if not selectable(row) then return end
        local handler = kind == 'adjust' and row.adjust or row.open
        if handler then handler(direction) end
    end

    -- Visibility follows the game's ESC menu: the native MenuSystem probe when
    -- it resolved, otherwise ESC presses plus a reset when the game context
    -- changes (level load / cutscene) so the two cannot stay out of sync.
    function self.update_visibility()
        local probe = options.menu_probe and options.menu_probe()
        self.native = probe ~= nil
        if probe ~= nil then
            self.esc_open = probe == true
        else
            local serial = options.context_serial and options.context_serial() or 0
            if input.pressed('esc', 'escape') then
                self.esc_open = not self.esc_open
                self.open_serial = serial
            end
            if self.esc_open and serial ~= self.open_serial then self.esc_open = false end
        end
        self.visible = self.esc_open
        -- Native "MDL Settings" tab: when it is available the panel is drawn only while
        -- that tab is selected, inside the ESC menu's content area; otherwise
        -- (tab disabled or unavailable) it floats on the right as before.
        self.mode = 'float'
        if self.visible and options.tab_state then
            local tab = options.tab_state()
            if tab then
                self.mode = 'tab'
                self.visible = tab.active == true
            end
        end
        return self.visible
    end

    function self.handle_input(width, height)
        if not self.visible or not geometry or not rows then return end
        if flag('keyboard_in_menu', false) then
            if input.pressed('up') then move(-1) end
            if input.pressed('down') then move(1) end
            if input.pressed('left') then activate(rows[self.cursor], 'adjust', -1) end
            if input.pressed('right') then activate(rows[self.cursor], 'adjust', 1) end
            if input.pressed('enter', 'return') then activate(rows[self.cursor], 'open') end
            if input.pressed('backspace') and self.page ~= 'list' then go('list') end
        end
        local x, y = input.cursor(height)
        local help = geometry.help
        if x and help and x >= help.x and x <= help.x + help.w and y >= help.y and y <= help.y + help.h then
            if input.clicked('left') then
                if self.page == 'help' then go('list') else go('help') end
            end
            return
        end
        if x and scrollbar(x, y) then return end
        -- Slider rows: click on the track to jump, hold to drag.
        local sliders = geometry.sliders or {}
        if self.slider_drag then
            local track, row = sliders[self.slider_drag], rows[self.slider_drag]
            if not x or not input.held('left') or not track or not row or not row.slider then
                self.slider_drag = nil
            else
                local s = row.slider
                row.slider.set(s.min + math.max(0, math.min(1, (x - track.x) / track.w)) * (s.max - s.min))
                return
            end
        end
        -- Fold switches on section headers.
        local fold_hover = nil
        for _, fold in ipairs(x and geometry.folds or {}) do
            if x >= fold.x and x <= fold.x + fold.w and y >= fold.y and y <= fold.y + fold.h then fold_hover = fold end
        end
        self.hover_fold = fold_hover and fold_hover.index or nil
        if fold_hover then
            self.hover, self.hover_chip = nil, nil
            if input.clicked('left') or input.clicked('right') then toggle_fold(fold_hover.section) end
            return
        end
        -- Sort switches on section headers.
        local chip_hover = nil
        for _, chip in ipairs(x and geometry.chips or {}) do
            if x >= chip.x and x <= chip.x + chip.w and y >= chip.y and y <= chip.y + chip.h then chip_hover = chip end
        end
        self.hover_chip = chip_hover and chip_hover.index or nil
        if chip_hover then
            self.hover = nil
            if input.clicked('left') then cycle_sort(chip_hover.section)
            elseif input.clicked('right') then
                -- Right click steps backwards.
                cycle_sort(chip_hover.section); cycle_sort(chip_hover.section)
            end
            return
        end
        local index = x and row_at(x, y)
        if index and rows[index].slider and sliders[index] and input.clicked('left') then
            local track, s = sliders[index], rows[index].slider
            if x >= track.x - 12 * geometry.s and x <= track.x + track.w + 12 * geometry.s then
                self.cursor, self.slider_drag, self.hover = index, index, index
                s.set(s.min + math.max(0, math.min(1, (x - track.x) / track.w)) * (s.max - s.min))
                return
            end
        end
        self.hover = index
        if x then
            if index and rows[index].why then
                if input.clicked('left') then go('why', rows[index].why) end
            elseif index and rows[index].fold then
                -- Clicking a section title (no "?") folds / unfolds it.
                if input.clicked('left') or input.clicked('right') then toggle_fold(rows[index].fold) end
            elseif index and not selectable(rows[index]) then
                if (input.clicked('left') or input.clicked('right')) and not rows[index].quiet then
                    flash(rows[index].flash or L('flash.read_only'))
                end
            elseif index then
                self.cursor = index
                local row = rows[index]
                local on_value = x > geometry.x + geometry.w * (geometry.wide and 0.84 or 0.62)
                if input.clicked('left') then
                    activate(row, on_value and row.adjust and 'adjust' or 'open', 1)
                elseif input.clicked('right') then
                    activate(row, 'adjust', -1)
                end
            end
            local wheel = input.wheel()
            if wheel ~= 0 and x >= geometry.x and x <= geometry.x + geometry.w then scroll_by(wheel > 0 and -3 or 3) end
        end
    end

    -- Per-frame cost: while hidden only the visibility check runs. While shown
    -- the row model and draw list are rebuilt only when something visible
    -- changed (page, cursor, scroll, statuses, icons, flash, resolution).
    local last = {}
    local list, key
    local differs = false
    local function see(i, v) if last[i] ~= v then differs = true; last[i] = v end end
    local function changed(width, height)
        local flash_on = self.flash_text ~= nil and os.clock() < (self.flash_until or 0)
        differs = false
        see(1, page_serial); see(2, self.cursor); see(3, self.scroll); see(4, self.dragging and 1 or 0)
        see(5, flash_on and 1 or 0); see(6, manager.revision or 0); see(7, library and library.revision or 0)
        see(8, images and images.done or 0); see(9, width); see(10, height); see(11, math.floor(os.clock())); see(12, self.mode); see(13, self.hover or 0); see(14, self.slider_drag or 0); see(15, live and live.revision or 0); see(16, i18n and i18n.revision or 0)
        see(17, renderer.bitmap_error and 1 or 0); see(18, atlas_ok() and 1 or 0); see(19, animating() and 1 or 0)
        see(22, self.hover_fold or 0)
        see(20, self.hover_chip or 0); see(21, memory and memory.revision or 0)
        if self.dragging or self.slider_drag then differs = true end
        return differs
    end

    function self.frame()
        if self.rescan_library and library then
            self.rescan_library = false
            library.scan()
        end
        if not self.update_visibility() then
            if self.shown then
                self.shown, self.dragging, list = false, nil, nil
                renderer.clear()
            end
            self.opened_at = nil
            if anim then anim.reset() end
            return
        end
        local width, height = renderer.resolution()
        if not width or width < 320 or height < 240 then renderer.clear() return end
        if not self.shown then
            last, list = {}, nil
            -- Automatic language: the game's language may be known by now.
            if i18n and i18n.refresh_auto then pcall(i18n.refresh_auto) end
        end
        self.shown = true
        if images then images.step() end
        if library and not library.scanned then library.scan() end
        -- Mods now deployed by the manager drop their live copies.
        if live and live.reconcile and library and library.scanned and self.reconciled ~= library.revision then
            self.reconciled = library.revision
            pcall(live.reconcile, library.entries)
        end
        -- Memory estimates run in slices of at most 1 ms per frame.
        if memory and memory.busy() then memory.step(0.001) end
        self.handle_input(width, height)
        if not list or changed(width, height) then
            list, key = build(width, height)
            self.builds = (self.builds or 0) + 1
            changed(width, height) -- build may clamp cursor/scroll; record the result
        end
        local ok, reason = renderer.draw(list, key)
        self.draw_status = ok and 'visible' or tostring(reason)
        -- Animation overlay: a few retained rects moved with update_rect.
        if ok and anim and renderer.overlay then
            local items, overlay_key = {}, ''
            if animating() and geometry then
                local now = options.clock and options.clock() or os.clock()
                if self.opened_at == nil then self.opened_at = now; anim.open(now) end
                local made, a, b = pcall(anim.items, geometry, now, function(name) return theme().colors[name] or COLORS[name] end,
                    {blink = theme().blink})
                if made then items, overlay_key = a, b else self_anim_error = tostring(a) end
            end
            local drawn, problem = pcall(renderer.overlay, items, overlay_key)
            if not drawn then
                self_anim_error = tostring(problem)
                if options.log then pcall(options.log, 'animations disabled: ' .. self_anim_error) end
            end
        end
    end

    function self.hide()
        self.esc_open, self.visible, self.shown, list = false, false, false, nil
        renderer.clear()
    end

    return self
end

return P
