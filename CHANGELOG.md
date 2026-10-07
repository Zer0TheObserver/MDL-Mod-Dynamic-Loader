# 1.8.7

- **Automatic language (default).** It follows the game: Chinese shows Chinese, and any language MDL has no file for
  shows English. The first source that answers decides:
  1. The game's Text Language setting, when a CowboyBingus menu mod (Mod Options Menu / Mod Bindings Menu) has
     read it into `_G.BingusTranslations`. MDL checks again each time the menu opens.
  2. Steam's language for the game (`ISteamApps::GetCurrentGameLanguage` through steam_api64.dll, asked once).
  3. The Windows display language (`GetUserDefaultUILanguage`; before 1.8.7 MDL used the regional format).
- The Language row steps through Auto, English, Chinese and any added languages. Auto shows as "Auto (English)" /
  "自动（简体中文）" and is stored as no choice. A language the player picked is kept.
- MDL.log names the language source, e.g. `language: zh-CN (automatic, steam: zh-CN)`.

# 1.8.6

- **Folding sections.** Every section of the main list can be folded and opened again. That covers live Lua mods,
  launch addons, the whole mod library, and each library group.
  - Click the [-] / [+] switch before the title. A title without "?" also folds when you click the title itself.
  - A folded top-level title shows how many mods it holds; library groups already show their count.
  - Folding the library hides its groups as well.
  - "Script addons (loaded at launch)" starts folded. The state is saved in MDL.cfg as `ui.collapsed`, and only
    when it differs from the default.
- The debug build shows "- DEBUG" after the panel title.

# 1.8.5

- **Library addons deployed by Arsenal / HD2MM show as running.**
  - MDL starts before the other launch addons, so at its first library scan none of them were loaded yet. Such
    addons stayed OFF in the library, and clicking them started a second copy (seen with Advanced Tank Hull).
  - Now the library state is settled when the startup coordinator reports what it loaded (first frame). It reads
    "ON VIA Arsenal" / "已由 Arsenal 启动" and cannot be started again.
  - Library addons MDL itself restores from the last session now start on the first frame, after that report, so
    an addon that is now deployed is no longer started twice at startup.
  - If a live copy is already running when the report arrives, it is marked RUNNING TWICE (red) and left running:
    stopping it would run its shutdown, which may undo hooks the launch copy shares. Stop it and restart the game.
- **Launch addons show their manager name.** The "Script addons (loaded at launch)" section now shows the
  Arsenal / HD2MM name, file name and icon instead of the addon path. Their page title uses the same name.
- **Engine objects and native memory per live mod** (setting "Track engine objects and native memory"; on in
  the debug build, off in the player build; applies when a mod starts).
  - A live mod sees views of `stingray`, `World` and `require('ffi')`. They are full copies with the same
    functions, except that these also count what they make:
    - `World.spawn_unit` / `destroy_unit`;
    - `create_screen_gui` / `create_world_gui` / `destroy_gui`;
    - `create_particles` / `destroy_particles`;
    - `create_line_object` / `destroy_line_object`;
    - `ffi.C.VirtualAlloc` / `VirtualFree` (release), `malloc` / `calloc` / `free`, `HeapAlloc` / `HeapFree`.
  - The mod page shows the units, GUIs and effects it made, and its native memory. Units the game removed are
    not counted (`Unit.alive`).
  - A stopped mod's page shows what it left behind (red), and the cost page adds native memory and the object
    count per mod.
  - Not counted: `ffi.load` libraries and engine objects made through other APIs.

# 1.8.4

- **Sorting per section.** Every section title has a SORT switch: load order (default), A-Z, or newest
  update first. Click to step forward, right click to step back. It is saved per section in MDL.cfg
  (`ui.sort`). Sections: live Lua mods, launch addons, and each library group.
  - The update time comes from Arsenal's `addedAt`, which Arsenal sets again when a mod is updated.
  - HD2MM mods use the newest patch file instead; Mods-folder mods use their newest .lua file.
  - Launch addons use their library entry's time.
  - In "newest" mode the time is shown next to the file name under each mod; mods without a time go
    last.
- **Memory per running mod (estimate).** LuaJIT keeps every mod in one heap, so MDL estimates what
  each mod holds:
  - The walk starts from the mod's own roots: its environment, captured callbacks, modules, context,
    tasks and the globals it created.
  - It stops at anything shared: _G, globals the mod did not create and the values directly inside
    them, other mods, and MDL's own code.
  - Sizes follow LuaJIT 2.1 without GC64.
  - It runs in slices of at most 1 ms per frame, only while a mod page or the cost page is open.
  - Not included: engine memory the mod causes (units, textures, GUIs) and FFI malloc/VirtualAlloc.
- **Lua allocation rate per running mod.** Heap growth across its update, in KB/s. Frames where the
  collector ran inside the call are skipped, so the figure leans low.
- The MDL frame cost page lists every running live mod with its memory and allocation rate, plus the
  game's whole Lua heap.
- Library pages show the update time and the size of the mod's patch files on disk.

# 1.8.3

- **MIXED mods can go live** (with the live resource switch). This works when:
  - the Lua part declares an addon (`HD2-Addon`);
  - every asset replaces a game asset in a package the game reloads.
- When those hold, "Use live" does three things:
  - scans once;
  - stages the assets like a resource mod;
  - starts the script at once through `on_live` (the manager `enable` request).
- Switching it off stops the script at once; the copies go when their packages unload.
- The group is now "MIXED - SCRIPT NOW, ASSETS NEXT LOAD". The mod page shows the "Script part" state and its frame
  cost.
- The scan counts Lua rows as the script part, not as new assets. The scanned patch file is the one that carries the
  assets, so a Lua-only patch_0 next to an asset patch_1 is handled.
- **Why a MIXED mod stays launch only**, shown on its page and in the click message:
  - the Lua part is not an addon;
  - it adds assets the game does not have (its own HUD textures);
  - some assets exist only in the startup package;
  - the assets are split over several patch files;
  - no assets were found.
- The "?" page explains the rules.
- Expected for the current library:

  | Mod | Result |
  |---|---|
  | Advanced Tank Turret (addon + 2 units) | live |
  | DRIVER HUD | launch only: its own texture |
  | HD2 HUD+ | launch only: Lua not an addon |
  | Mod Bindings Menu | launch only (config) if the config lives in the startup package |

- Language files that MDL writes now carry a `generated` checksum; unedited ones are refreshed when built-in texts
  change. Files you edited are kept.
- Tests:
  - reslab 125 (mixed: live, script start/stop, no_addon, new, boot_only, archives);
  - packed (mixed rows);
  - i18n 1216 (template refresh).

# 1.8.2

- **Icons are pixel glyphs again by default.** The texture images from 1.8.0 and 1.8.1 still did not show inside the
  panel (logo and settings icons missing; the texture probe drew them fine in its own GUIs).
  - Cause: within one GUI the engine draws in creation order and does not sort by z, and textured quads from another
    material appear to be drawn under the panel's own rects.
  - Texture icons are now a debug-only experiment: Settings > Texture icons (debug, experimental). They draw in a
    second GUI created after the panel's, so they sit on top. In that mode there is no paper grain, only the corner
    brackets and the rule.
- New pixel glyphs: MDL logo (before the title, both themes) and gear (frame cost row).
- **Animated selection drawn above the text** (seen in game): the overlay rects were created after the rows, and
  creation order wins.
  - The build now puts two placeholder slots (`sel_fill`, `sel_mark`) after the header band and before the rows.
  - The renderer creates their rects there; the animation only moves them with `update_rect`.
  - When nothing is shown they are hidden, not destroyed.
- Probably fixes the white blocks flashing on screen: no texture quads are drawn in the default mode.
- The player build carries no textures again (Lua only, empty .gpu_resources); the debug build keeps the 41 images and
  the atlas.

# 1.8.1

- **UI images were invisible in 1.8.0.** All `Gui.bitmap_uv` calls on the packed atlas succeeded without an error, but
  nothing showed: no logo, icons or corners, and the icon tiles stayed empty.
  - New default ("cells"): every image (16 icons, 16 masks, paper, 4 pre-mirrored corners, rule, scan, grain, orient)
    is its own power-of-two RGBA texture with mips, plus a GUI material `mods/mdl/ui/<name>` in the debug layout. It
    is drawn with `Gui.bitmap`, the route proven by texture probe G. About 0.9 MB of gpu data.
  - The packed atlas and `bitmap_uv` ("uv" mode) are kept in the debug build only, as an experiment. You can switch
    to them on the UI atlas (debug) page.
  - Texture probe variants for the diagnosis:
    - G: reference;
    - U1: atlas with `Gui.bitmap`;
    - U2: atlas with `bitmap_uv` 0..1;
    - U3: atlas with `bitmap_uv` on the logo cell;
    - P1: logo piece;
    - P2: logo piece at 28 px;
    - P3: tinted mask.
    - State file: `MDL-probe-state-4.txt`.
- **MDL frame cost by part:** the settings row now opens a page with the menu-closed, menu-open and peak values, and
  per-part average / peak for:
  - loader core (without the mods);
  - this panel;
  - live resource mods (package monitor);
  - library watch;
  - logs;
  - texture probe.
- **Less idle work:** the package monitor now reads the package list only while it is needed:
  - every 0.5 s with a pending online check;
  - every 2 s while a live resource mod is staged;
  - not at all otherwise.
  - In the debug build, the full-time monitor is the setting "Package monitor (debug)". "Verbose lab log (debug)"
    turns the LOAD/UNLOAD log lines off.
  - The texture probe costs nothing while it is off.
- Tests:
  - test_mdl_reslab 113 (idle monitor);
  - test_mdl_probe 33;
  - test_mdl_ui_atlas 75 (cells mode, uv mode, cost page).

# 1.8.0

- **UI atlas: MDL becomes a MIX mod.** Its patch now also carries `mods/mdl/ui_atlas`, a 512×512 RGBA texture with
  9 mips, plus a GUI material of the same name. The material uses the `core/performance_hud/debug` layout with a
  texture table, the route proven by texture probe G.
  - Contents, all original and drawn procedurally by `scripts/atlas.py` (no fonts, no third-party art):
    - 16 icons in colour and as white masks: script, resource, mixed, unknown, refresh, bolt, globe, palette, lab,
      help, back, check, cross, warn, gear, MDL logo;
    - Archive decorations: paper grain, corner bracket, ornamental rule, scan glow, grain strip;
    - an orientation test cell.
  - The panel draws them with `Gui.bitmap_uv`:
    - type icons for mods without an icon;
    - settings icons;
    - a logo before the title;
    - in Archive: paper grain tinted with the panel colour, mirrored corner brackets and a rule under the title.
  - Helldivers uses the colour icons; Archive and inverted rows use masks tinted with the theme colour.
  - Fallbacks:
    - if the engine does not report the material online, or a `bitmap_uv` call fails, the pixel glyphs are used as
      before;
    - `ui.atlas_flip_v = true` flips V if the textures appear upside down.
  - `src/mdl_atlas.lua` (cell UVs) is generated by `python3 scripts/atlas.py --lua`; the build checks it is current.
  - Debug: Settings > UI atlas (debug) lists every cell, the orientation cell and a Flip V switch.
- **Animations (test):** Settings > Animations. On by default in the debug build, off in the player build.
  - The panel unfolds from the top when it opens (0.28 s, bright edge line).
  - The selection bar glides between rows (0.10 s).
  - Archive theme: a blinking cursor block after the title.
  - Done with a few retained rects moved by `Gui.update_rect`:
    - nothing is sent while nothing moves;
    - a moving frame costs a few update calls, not a panel rebuild;
    - errors switch animations off with a log line.
- **MDL's own frame cost:**
  - measured around MDL's per-frame work, minus the mods' updates and tasks;
  - smoothed averages with the menu closed and open, plus a decaying peak;
  - shown in Settings, "MDL frame cost (closed / open / peak)", and at the bottom right of the main page;
  - the manager now reports `frame_mods_ms`.
- The player build no longer contains the texture probe module.
- Tests: new test_mdl_ui_atlas (70 checks). The build verifies the mixed archive layout.

# 1.7.4 (+ MDL Texture Probe 1.1.0)

- **Texture probe results (1.7.3):**
  - A: core/performance_hud/gui drew white.
  - D: the probe package's clone of that material also drew white.
  - **E: the font material with the probe texture showed the probe picture** (checker, ring, band, correct
    orientation), monochrome through the font shader. So textures in a MIX package load and can be sampled.
- **Why A and D drew white and A2/B crashed:** core/performance_hud/gui has no texture table (+0x40 = 0). Its slot
  entry sits elsewhere, so the shader samples nothing, and `set_texture` on that material crashed.
  core/performance_hud/debug and the materials of texture mods (DRIVER HUD, HUD Plus) do have one: count 1 at
  +0x40, entry `{u32, 0, slot 0x3aa8b87e, u64 texture}` at +0x80.
- New variants, run in this order:
  - A, E: as before;
  - F: core/performance_hud/debug as is;
  - G: `mdl/textures/probe2`, the debug layout pointing at the probe texture (needs probe package 1.1.0);
  - H: the debug material with set_texture 3aa8b87e → probe;
  - D: last.
- A2 and B were removed.
- State file: `MDL-probe-state-3.txt`.

# 1.7.3

- **Texture probe result from 1.7.2:**
  - A passed;
  - the game crashed during **A2**, right after "A2 perf+atlas: running". A2 uses only game data: the perf-HUD gui
    material with the game's own font atlas.
  - The crash happened inside the synchronous calls, before the result line was logged.
  - Likely cause: `Gui.material(gui, m)` on a material the gui has not drawn with yet. The font material MDL uses is
    already known to every screen gui.
- **The probe now draws first, then sets the texture:**
  - order: `Gui.bitmap`, then `Gui.material` on the instance the draw created, then `Material.set_texture`;
  - every step is logged and flushed before it runs, so a crash names the exact call.
- Material layout cross-check (boot package):
  - the font material stores `{u32 ?, u32 0, u32 slot 0x88bac99b, u64 texture 0x35fcb2056c9c789e (atlas)}` at +0x80;
  - the gui materials store slot 0x3aa8b87e the same way, so 3aa8b87e is the right slot name;
  - ba25de35 is the entry's first word, not a slot, so variant C is removed.
- The state file is now `MDL-probe-state-2.txt`, so the old A2 crash mark from the other call order does not apply.

# 1.7.2

- **Texture probe is crash safe** (debug build only). With the probe package loaded, 1.7.1 ran all variants in one
  frame and the game crashed one second after the ESC menu opened. The crash report has no dump and no GPU DRED
  record, so it was a CPU exception, and it is unknown which variant caused it.
  - Variants now run one at a time, in this order:
    - A: perf_hud gui material;
    - A2: perf_hud with its texture slot 3aa8b87e set to the game's own font atlas. This is a set_texture control
      that uses no mod data;
    - B: the same slot set to the probe texture;
    - D: the probe package's material;
    - E: the font material with the probe texture;
    - C: perf_hud slot ba25de35.
  - Before a variant runs, `<key>=running` is written to `Logs/MDL-probe-state.txt` and MDL.log is flushed.
  - A variant counts as survived only after 90 frames on screen.
  - A variant still `running` at the next start crashed the game. It is logged and shown as CRASHED and never runs
    again. Delete the state file to retry.
  - Closing the panel mid-variant is not counted as a crash.
- test_mdl_probe 29 checks: order, state file, crash recovery, settle frames, guarded variants.

# 1.7.1

- **File name under each mod name** (main list, small light text): the folder Arsenal / HD2MM unpacked the mod into,
  without Arsenal's `_AR<number>` suffix, so mods with the same name can be told apart. Arsenal does not record the
  archive's extension, so none is shown. Also on the mod's library page (footer). Loose mods show their folder when
  `mod.lua` gives a different name. List rows are taller on that page to fit the second line.
- **Auto reload now covers library addons.** A newer version of a running live addon imported into Arsenal / HD2MM
  (for example dragged into Arsenal while the game runs) is picked up without switching it off and on:
  - every 2 s (while auto reload is on or the panel is open) MDL compares the size and time of `hd2a_data.json`
    (HD2MM: `enabled.json` and the Mods folder) and rescans the library once a change has settled for one check;
  - each script addon carries a fingerprint of its Lua resources; a running addon whose fingerprint changed is
    reloaded from the new files when auto reload is on;
  - with auto reload off it keeps running the old code, and its page says a newer version is in the library.
- Texture probe: labels now use the same font material setup as the panel (they were drawn as blocks); the header
  says whether the probe package is loaded.
- Tests: test_mdl_packed 51 (file names, fingerprint, update reloaded / only marked), test_mdl_integration 75
  (library watch rescans once after a settled change).

# 1.7.0

- **Themes.** ESC > MDL Settings > Theme switches between:
  - Helldivers (default, unchanged);
  - Archive: paper beige, dark ink, inverted selection bar with a square marker, square bullets before the title and
    headers, faint ruled lines.
  - Original design, no third-party fonts, logos or art. Saved as `ui.theme` in MDL.cfg; both languages translated.
- **Built-in pixel glyphs** (`mdl_glyphs`, original 12×12 drawings drawn as colour runs, no textures):
  - mods without an icon show their type (script / resource / mixed / unknown) instead of a "?";
  - settings rows get symbols (rescan, auto reload, language, theme, lab).
  - Without the glyph module the old "?" tile is used.
- **Debug only: texture probe** (`mdl_probe`, Settings > Texture probe) to test real pictures through MIX textures:
  - five variants, each in its own screen gui: perf-HUD gui material as is; with slot 3aa8b87e or ba25de35 set to
    the probe texture; the probe package's own material; the font material with the probe texture;
  - variants that need the probe texture run only when `Application.can_get` reports it loaded;
  - results are drawn under each square and logged.
- **New separate package: MDL Texture Probe 1.0.0** (`scripts/build_probe.py`):
  - boot patch with texture `mdl/textures/probe` (256×256 R8G8B8A8, 9 mips, original test pattern) and a material of
    the same name;
  - the texture header copies the layout of the game's own 256×256 RGBA gui texture (the default texture of
    `core/performance_hud/gui`);
  - the material copies that 192-byte material with its texture id pointed at the probe;
  - TOC rows follow deployed texture mods (data align 16, gpu align 64).
- Tests: test_mdl_theme 617 (glyph masks/runs, Theme row, archive colours, inverted selection, rules, bullets,
  fallback) and test_mdl_probe 25 (guarded variants, slot ids, gui per variant, cleanup). test_mdl_integration checks
  the probe is in the debug build only.

# 1.6.3

- **Mod Options Menu compatibility: MDL Settings becomes the 5th ESC tab.** Before, MDL fell back to the floating
  panel when MOM was installed.
  - MDL waits for MOM's 4th tab, then calls the game's `set_labels` with five labels
    `[GAME, SOCIAL, OPTIONS, MOM, MDL]`. MDL's text is set on button 5 first, and the selected button is restored.
  - Static check: the panel switch (`set_panel`, game.dll 0x1474370) only closes and opens panels 0..2. Index 4 is as
    empty as 3, so MDL draws there; MOM keeps drawing on 4.
  - MOM ≤ 1.1 (`ensure_mods_tab`) accepts the bar only when it has exactly 4 tabs. Otherwise it drops its view and
    stops managing the tab.
    - MDL finds MOM's per-frame `step` (an upvalue of MOM's update wrapper, found next to `previous_update` and
      `traceback` by walking the global update chain) and wraps it.
    - While MOM's step runs, the bar's count reads 4. It is set back to 5 right after, and errors still reach MOM's
      own xpcall.
    - Only the count field changes, and only when it is MDL's 5-tab bar.
  - A future MOM that sets `ModOptionsMenu.extra_tabs = true` gets no wrapper.
  - If MOM's update is not found, MDL keeps the floating panel as before. `ui.native_tab = false` still forces the
    floating panel.
  - Tests:
    - test_mdl_nativetab 56: wait for MOM, add tab 5, active only on slot 4, the count shim, error path, foreign 5th
      tab, rebuilt bar;
    - test_mdl_integration 67: a MOM-shaped addon in the update chain only ever sees 3 or 4 tabs.

# 1.6.2

- Library: mods added to Arsenal recently, for example dropped in while the game runs, showed as UNKNOWN under their
  uuid, and Rescan did not help.
  - Cause: newer Arsenal data keeps such a mod in the profile only as uuid + state (`enabled`, `deployed`,
    `optionsConfig`). Its definition (`path`, `label`, `description`, `iconPath`, `options`) is in
    `hd2a_data.json` → `modsLibrary`.
  - MDL now merges the profile entry with its `modsLibrary` definition. uuids are compared case-insensitively.
  - Profile fields win, option on/off comes from `optionsConfig`, and older full entries are unchanged.
  - An entry with no definition yet is logged and stays UNKNOWN.
  - Rescan picks the mod up as soon as Arsenal has written it.

# 1.6.1

- Live resource mods: **conflicts with deployed mods.**
  - What happened in game: F8C was switched on live and mounted, and all 18 resources were online. Yet the tank
    showed F8C's turret on a non-F8C hull.
  - Cause: Advanced Tank Turret was deployed by Arsenal (`9ba626afa44a3aa3.patch_11`) and also replaces the hull unit
    `b0c9faf4af8903f9`. packages/boot loads at start, so its copy of a resource comes online first and wins.
  - New: MDL reads the deployed boot patches and reports every shared resource:
    - the owning library mod is found by comparing file size and the first 4 KB;
    - the toggle message says which mod wins and how many assets it covers;
    - the mod page shows a red conflict row per mod;
    - the log lists the shared resources.
  - New texts: `live.on_conflict`, `live.unknown_mod`, `row.live_conflict`, `flash.live_conflict` (English and
    Simplified Chinese).

# 1.6.0

Two editions from the same source:
- player build (`MDL_RELEASE=1`, `MDL-Mod-Dynamic-Loader-1.6.0.zip`);
- development build (`MDL_DEBUG=1`, `...-1.6.0-debug.zip`), which also keeps the Resource Lab pages, the full package log and the DirectStorage experiments.

- **Live resource mods.** In MOD LIBRARY, resource mods have an ON/OFF switch, shown in the group
  "RESOURCE - LIVE ON NEXT LOAD".
  - The first switch-on finds the game packages that hold the replaced assets. The result is cached per mod in
    `ResourceLab/scans.lua` and stays valid while the mod file and `bundles.nxa` are unchanged.
  - MDL then places the mod as the next patch of each of those packages. It applies the next time the game loads
    them; nothing restarts.
  - States:
    - LIVE ON (yellow): waiting for the next load;
    - LIVE ON (green): active in a loaded package;
    - OFF AFTER UNLOAD: switched off while in use, so the copies are removed when the package unloads;
    - LAUNCH ONLY: the mod only touches assets loaded once at start;
    - COPIES MISSING.
  - The mod page shows how many packages are active or need a reload, and how many of its resources are new.
  - Switching a mod off moves later MDL-placed patches of the same package down one number, so the engine never
    meets a gap. A later patch placed by another tool keeps MDL's copy in place.
  - Copies removed by an Arsenal Deploy are restored at the next start. When Arsenal deploys a mod, MDL drops its
    own copies of it, and a mod enabled in Arsenal cannot be switched live.
  - Player builds log only events that concern live mods, to `Logs/MDL-LiveResources.log`.
  - `ui.live_resources = false` turns the switch off.
- **Localisation.**
  - Every user-facing text has a key (166 keys). The English base lives in `mdl_panel.STRINGS`; Simplified Chinese
    is built in (`mdl_lang`).
  - On first start MDL writes `Languages/en.json`, `zh-CN.json` and `README.txt`, and rewrites
    `reference-en.json` on every start.
  - Players can edit any text, or add a language by copying `en.json`. Keys missing from a file fall back to the
    built-in language, then to English. `{placeholders}` are filled in.
  - A Language row at the bottom of the main page switches the language at once and saves `ui.language`.
  - The default language follows the Windows UI locale (`zh-*` maps to zh-CN).
  - The ESC tab title comes from the language at the next start, unless `ui.tab_text` is set.
- Platform: `move_file`, `locale`, `reader.size`.
- Tests:
  - new `test_mdl_i18n` (958 checks): key coverage and placeholders of every built-in language, language files,
    locale matching, the panel in Chinese;
  - `test_mdl_reslab` (108): the live switch end to end and the player panel;
  - `test_mdl_integration` (58): a player runtime with zh-CN.

# 1.5.5

- **Route A works in game.** Clean run on 2026-10-02:
  - F8C was off in Arsenal, so the boot patches did not contain it.
  - It was staged in the ship into 65ee777b72347cb4 and three other bundles.
  - The next mission loaded `65ee777b72347cb4 +patch 0` and the lab logged MOUNTED.
  - All 18 resources were online 3 s and 15 s later, including the 14 new ones. The whole tank showed the mod's look, without a restart.
- The 34.1 MiB hull loaded with the default 32 MiB staging buffer, so the staging-buffer theory from 1.5.4 is
  wrong. The mod page no longer warns about it or offers RAISE (DirectStorage refused the change at run time anyway,
  hr 0x8924001F). The main lab page still shows the buffer size.
- The missing hull in the first run (1.5.3) is not explained. That session's boot patches were a different set.
- New: at start the lab checks that every staged copy still exists. A mod manager Deploy rewrites `data/` and removes
  them, which made the earlier "NOT mounted" run look like a lab failure. Missing copies are logged and shown as
  MISSING, with a hint to unstage and stage again.

# 1.5.4

- Resource Lab (debug), after the first in-game mount: F8C staged into 65ee777b72347cb4 mounted on the next mission
  (`65ee777b72347cb4 -> .patch_0 +patch 0`) and the turret showed the mod's look, but the hull was missing; with
  Arsenal (boot patch + restart) the whole tank shows.
  - Finding: the hull unit b0c9faf4af8903f9 is the only resource whose GPU data is larger than the vanilla one
    (35.7 MB vs 12.6 MB) and the only one above 32 MiB. NxStorage creates its DirectStorage factory with the default
    32 MiB staging buffer (exe 0x73ec80 sets 0x2000000; the game passes no size, 0x7ab60), and DirectStorage fails a
    request larger than the staging buffer. Prime suspect; to be confirmed in game.
  - New experiment: the lab locates the NxStorage loader (signature `48 8B 05 ?? ?? ?? ?? 48 8B 80 D0 00 00 00 C3 CC
    33 D2 E9`, unique in all six exe dumps) and shows the staging buffer size. The mod page shows the largest GPU
    resource and, when it is above the staging buffer, offers **Raise the staging buffer to 64 MB (until restart)**:
    `IDStorageFactory::SetStagingBufferSize` through the factory's vtable (only when the method lies inside
    dstorage.dll / dstoragecore.dll), then the loader's own copy of the size is updated.
  - Online check: 3 s and 15 s after a package with a staged patch loads, the lab logs `can_get` for every resource
    of the staged mod (with GPU sizes); a "Write online status to the lab log" row does it on demand.
  - Fix: packages list their layers highest patch first, base last. The staged-patch MOUNTED line used the first
    layer's name as the bundle and never matched; the bundle name now strips `.patch_N`.
  - The scan log lists every resource's GPU size and the largest one against the staging buffer.

# 1.5.3

- Resource Lab (debug): 1.5.2 still found nothing. With read access to the game's data folder the reason is clear:
  every game data file - `bundles.nxa`, the `bundles.NN.nxa` parts and the ~30 loose bundles - is a **DSAR
  container** (32-byte header "DSAR" v3, then 32-byte chunk rows: decompressed offset, file offset, decompressed
  size, stored size, codec 0 = stored / 3 = LZ4 block). `bundles.nxa` decompresses (56 chunks, 6.5 -> 14.5 MB) to the
  NxStorage aggregate index ("DSAA": 30 parts, 9715 files, 3522 bundles) whose offsets refer to decompressed part
  data. Mod patch files stay plain (0xF0000011) and the engine reads both.
  - New: LZ4 block decoder on FFI buffers (stops as soon as the needed bytes are out, yields on long chunks) and a
    DSAR store (`R.open_store`: chunk table, one decoded chunk cached, plain files passed through). The index, the
    parts, the loose bundles and the mod's own patch are all read through it.
  - Checked against the real install: the decoded index is byte-identical (SHA-256 6b515178...) to an offline Python
    decoder (`nxa_probe.py` in the research archive), which also read all 3522 bundle tables (0 failures, 5 s) and
    found F8C's four units in 65ee777b72347cb4 (+ 534c2c49..., 0971e953..., 566213f0...); its 10 textures and
    4 materials are new resources.
- Platform: `reader.size()`.

# 1.5.2

- Resource Lab (debug): 1.5.1's `data/game/` assumption was wrong. The game folder log shows the install keeps
  almost every bundle inside the NxStorage containers `data/bundles.00.nxa .. bundles.29.nxa`, indexed by
  `data/bundles.nxa`; only ~30 bundles are loose in `data/`, and `data/game/` holds game.dll and type data.
  - New reader for the aggregate index (format from AggregateArchiveLoader in helldivers2.exe: 24-byte header,
    24-byte file rows sorted by name, part names, 16-byte chunk rows mapping file offsets to part offsets).
    The scan reads each bundle's resource table through it (positioned reads, files opened read-only and shared)
    plus the loose bundles the index lacks. The index is cached while bundles.nxa is unchanged.
  - Staged patches always go to `data/` as loose files: the engine's lookup tries the index first and falls back
    to loose files, which is how Arsenal's boot patches already load. Patch numbering and the unstage check count
    patch files inside the index too (a loose file with a name the index has would be ignored).
  - The log now lists the index summary, how many tables were read / unreadable (with examples), and for every
    mod resource the bundles that contain it. The scan gets 6 ms per frame while it runs (2 ms otherwise).
- Platform: `open_reader(path)` for positioned reads (ReadFile with an OVERLAPPED offset on a synchronous handle).

# 1.5.1

- Resource Lab (debug): the game keeps most bundles in `data/game/` (only ~30, packages/boot among them, are in
  `data/`). The home-bundle scan now reads both folders (1.5.0 only read `data/`, so every resource looked new and
  nothing could be staged), stages each patch next to its bundle, and checks both folders for patch numbering and
  when unstaging. The log lists how many bundles each folder holds.

# 1.5.0

- Debug builds (`MDL_DEBUG=1`, package `...-1.5.0-debug.zip`) add the **Resource Lab**, the route A experiment for
  live resource mods (see analysis_archive_20260930_native_resource_loading):
  - package monitor: finds the engine's PackageLoader in helldivers2.exe (one signature + queue/lookup checks,
    unique and identical in the 2026-06-09 .. 09-26 exe dumps) and logs every package load/unload with its patch
    layers (read-only);
  - home bundles: scans the game data folder's archive tables for the bundles that contain a mod's resources and
    classifies them (replace game resources / only in packages/boot / new);
  - stage / unstage: copies the mod's patch (+ .stream, .gpu_resources) as the next contiguous patch of each
    target bundle, recorded in ResourceLab/staged.lua; unstage removes exactly those files (refuses when a later
    patch exists or a file is in use). Mods with new resources need a second click.
  - `can_get` count of the mod's resources online; log in Logs/MDL-ResourceLab.log.
- Platform: `copy_file` (CopyFileW, never overwrites) and `delete_file`.
- Release and normal builds do not contain the lab (the runtime only uses it when compiled in).

# 1.4.4

- Fix (crash): a live script that took the game's update with `rawget(_G, 'update')` (Advanced Tank Camera;
  Advanced Tank Turret and Driver HUD use the same pattern) got the real update chain, which contains MDL itself.
  Calling it from its own update re-ran the whole frame recursively (thousands of game updates in one frame)
  and crashed the game. In the live sandbox `_G`, `rawget(_G, ...)` and `rawset(_G, ...)` now route
  update/shutdown/init to the loader's capture like plain globals already did; every other global is still the
  real one, so shared state between mods keeps working. `_G.update = f` no longer replaces the real global.
- Safety net: if the game's update is entered again while a frame is running, the nested call is ignored and
  the mod that did it gets a warning, instead of running the frame again.

# 1.4.3

- The list shows each running mod's average frame cost in its own column in front of ON/OFF (green < 0.25 ms,
  yellow < 1 ms, red above). The state column now starts at a fixed position on every row.
- Update rate is a slider on the mod's page: every frame .. every 8th frame, any step in between (was a 4-value
  cycle). Click or drag the track; the arrow keys and a click on the name/value step it.

# 1.4.2 (first public release)

- Same code as 1.4.1 (verified in game), built for release: `MDL_RELEASE=1` strips every comment from the
  shipped Lua (the HD2-Addon declaration line stays). Each module and the assembled runtime are checked to compile
  to identical bytecode with and without comments (deterministic LuaJIT: `-DLUAJIT_SECURITY_PRNG=0`, GC stopped),
  and the offline tests run against the stripped sources.
- The platform object (memory/file helpers) is no longer published as `MDL.platform`; nothing used it.
- Package: player README (English + Chinese) and a minimal MDL-build.json (version, GUID, resource hashes).

# 1.4.1

- Mods without an icon (or with an unreadable icon) get a "?" tile, so every mod name starts in the same column.
  Also applies to library option rows.
- The library list no longer shows the startup loaders (this loader and Bingus Shared Loader): they cannot be
  switched from inside the game. Recognised by content - the mod replaces core/wwise/lua/wwise_flow_callbacks -
  so renamed or future versions are caught too; GUIDs, the MDL runtime entry and names are fallbacks.

# 1.4.0

- MOD LIBRARY is grouped by type with subheaders and counts: SCRIPT - LIVE, SCRIPT - LAUNCH ONLY, MIXED - LAUNCH
  ONLY, RESOURCE - LAUNCH ONLY, UNKNOWN. Mods that cannot start in game are visible at a glance.
- LAUNCH ONLY groups have a "?" (the whole subheader is clickable) that opens an explanation page: why this type
  cannot start in game, the Arsenal steps (close game, enable + options, Deploy, start), and the library mods in
  that group. Launch-only detail pages link to it ("WHY?"); clicking their state shows a hint.
- "MODEL" is now called RESOURCE (models, textures, sounds, materials...).
- MDL Settings tab: the panel uses the ESC menu's large content area: 1240 wide, full height (top 150 / bottom
  100, 1080p units), larger text (22 px rows of 40), and a description column between name and state.
  `ui.tab_bottom` added. Text wrapping scales with the panel width. The state column keeps clear of the scrollbar.

# 1.3.1

- The ESC-menu tab is now titled **MDL Settings** (not "Mods"), so it cannot be confused with Mod Options
  Menu's MODS tab. The game's localized string 0x0227B3B0 is just "#TEXT"; MDL sets its TEXT variable
  (hash 0x57F3D153, top 32 bits of MurmurHash64A, as the game itself uses) on the tab's text widget with the
  widget's native string-argument setter *before* adding the label, so the game measures the tab with the final
  text. The setter is found next to set_label (read from the set_labels loop): the only function in the
  following 0x4000 bytes with the setter shape that calls the text-record string setter (+0x9C0 in all builds
  2026-06-19 .. 09-26). The text buffer is kept alive for the session (the native keeps the pointer).
- After adding the tab MDL also verifies the 4th button's text widget holds the new label id.
- `ui.tab_text` changes the title (default "MDL Settings"); `ui.tab_label` = a localized string id instead.
- If the setter is not found the tab is not added (floating panel), rather than falling back to "Mods".
- Fix: the "Mods" string id was mistyped as 0xF424FA23; the game's id 4095973923 is 0xF4239A23.

# 1.3.0

- Native **MODS** tab in the ESC menu (independent implementation, no Mod Options Menu code or dependency):
  MDL locates the ESC screen initializer by one signature (unique, identical layout in the 2026-06-19 ..
  2026-09-26 dumps), reads the stock GAME / SOCIAL / OPTIONS label ids from the game's own table and calls the
  native set-tab-labels routine once with a 4th id (localized "Mods", 0xF424FA23). Selecting the tab switches
  the native content to the empty panel index 3; MDL draws its panel there. Other tabs hide the MDL panel.
- Safety: every offset is cross-checked (prologue bytes, three independent layout identities); unknown label
  ids, >4 tabs, or a 4th tab MDL did not add are left untouched; a failing or ineffective call disables the
  feature for the session. Falls back to the floating right-side panel. `ui.native_tab = false` disables it;
  with Mod Options Menu installed it is off unless `ui.native_tab = true`.
- Placement in tab mode: centred under the tab bar; `ui.tab_x`, `ui.tab_top`, `ui.tab_width` (1080p units).
- MDL.log: `native tab:` lines (layout, selected tab, bar layout floats for calibration).

# 1.2.1

- Fix: asynchronous `open_log` only submitted text on close(). Logs that stay open and use write + flush for
  the whole session (Mod Options Menu) were never written and their buffer grew without bound. flush() now
  appends to the file (overlapped write at the current offset); rewrite-style logs still coalesce.
- Docs: native MODS tab in the ESC menu is possible (Mod Options Menu does it with native widget calls);
  corrected the earlier "not feasible" note.

# 1.2.0

- Asynchronous, coalesced addon logs: `CowboyBingusModLoader.open_log` now returns an in-memory file; content
  is written with overlapped I/O through one kept-open handle per log, at most every 0.5 s per file, flushed on
  shutdown. Transparent for existing addons (`ui.async_logs = false` to disable).
- Per-mod "Update rate" (every frame, 1/2, 1/4, 1/8 frames) with accumulated dt and staggered phases (opt-in).
- Background tasks for MDL API mods: `ctx.spawn`, `ctx.yield`, `ctx.sleep`, `ctx.wait_frames`, `ctx.checkpoint`,
  run round-robin within a 1 ms frame budget; `ctx.scan` for chunked signature scans.
- The runtime starts before other launch addons so they get these services from their first frame.
- Help page: PERFORMANCE section. Fixed a leaked global in the renderer's redraw counter.

# 1.1.0

- Native ESC-menu state: finds the game's MenuSystem by signature (unique in every dump 2026-06..09) and
  shows the panel only while the in-game menu ("InGame" screen) is open and not hidden, so cutscenes that
  close the UI also close the panel. Screen changes are logged. Fallback: ESC counting reset on world change.
- Performance: no GUI work while hidden; while shown the draw list is rebuilt only on visible changes
  (idle frame 54.6 us -> 3.4 us offline); engine objects re-validated every 60 frames; auto reload uses
  directory change notifications; library scan deferred to first panel open unless an addon must be restored.
- Per-mod frame cost (average / peak ms) on detail pages and a total on the main page (QueryPerformanceCounter).

# 1.0.5

- "?" button in the panel header opens a HELP page: SCRIPT / MIXED / MODEL / UNKNOWN, every state label
  (ON, ON*, OFF, LIVE ON, AT LAUNCH, IDLE, ERROR) and what Arsenal Deploy does; click ? or < Back to return.
- Empty Mods folder hint gets a second line: "...or the Arsenal library (script addons, below)".

# 1.0.4

- Long lists: scrollbar on the right of the rows with the visible range in the header (e.g. `1-17 / 40`).
  Mouse wheel scrolls 3 rows, clicking the track pages up/down, the thumb can be dragged. Scrolling no
  longer jumps back to the selected row.

# 1.0.3

- The panel opens only with the ESC menu: removed the F10 hotkey and the "Show with ESC menu" switch
  (old `hotkey` / `follow_esc` settings are ignored).
- Title is now "MOD DYNAMIC LOADER".
- Main page footer shows the author ID 174513429 in grey below the "Wheel scrolls" hint.

# 1.0.2

- Fix: library script addons written for the game update chain (Solo Vehicle Driver, Tank Clutch Tuner,
  Tank Steer Probe) refused to start under MDL with `game_update_callback_unavailable`, because MDL's sandbox
  exposed `update`/`shutdown` as nil. They now see no-op stand-in callbacks, so they start and are driven by
  MDL's dispatcher (the game's real update is never called twice).
- A live addon that starts but installs no update callback is shown as IDLE with a hint to check its own log.

# 1.0.1

- Fix: library entries looked clickable but their OFF state could not change. Script addons from the
  Arsenal/HD2MM library that declare `-- HD2-Addon:` now have a working "Run live in game" toggle (also on the
  list row): MDL runs them straight from the library archive, no Deploy or restart; stopping calls the
  addon's own shutdown and clears its guard globals so it can start again.
- Addons already loaded at launch show AT LAUNCH and are not started twice.
- Model/asset entries stay read-only; clicking them now shows why (mounted at launch; change in manager).
- Clicking any read-only information row shows a short explanation in the footer.

# 1.0.0

- New package identity: MDL - Mod Dynamic Loader, GUID 761188b2-c45b-4607-9241-f89ca221c47b, global `MDL`,
  runtime resource `mods/mdl/runtime`, data folder `%LOCALAPPDATA%\MDL\Helldivers2`.
- Standalone: owns the Wwise startup resource and provides the BSL API 1 contract (registry, declared-addon
  discovery, shared logs, LuaJIT cache budget). With BSL installed too, BSL's discovery starts MDL instead.
- Live Lua mods: enable / disable / reload in-game, per-mod environment, options UI, transactional native
  writes restored on disable, auto reload on file change.
- Mod library: Arsenal and HD2MM mods with icons (GDI+ decoded, drawn as rectangles), descriptions,
  options, deployed state and content type (MODEL / SCRIPT / MIXED from archive type tables).
- Launch addons can be switched off for the next launch when MDL owns startup.
- Built from BSL v18 lineage (was the local "v19 / hot API 2" prototype).
