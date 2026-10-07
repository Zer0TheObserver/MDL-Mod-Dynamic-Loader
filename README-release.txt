MDL - Mod Dynamic Loader {VERSION} for Helldivers 2
Author ID: 174513429

WHAT IT DOES
  - Adds an "MDL Settings" tab to the in-game ESC menu.
  - Load, stop and reload Lua mods while the game is running - no restart, no Deploy.
  - Shows your HD2 Arsenal / HD2MM library with icons, grouped by type:
      SCRIPT - LIVE            script addons you can start and stop right here
      RESOURCE - LIVE ON NEXT LOAD
                               resource mods (models, textures, ...) you can switch on and
                               off without Deploy or restart; they apply the next time the
                               game loads those assets (next mission or back to the ship)
      SCRIPT / MIXED - LAUNCH ONLY
                               mods the game loads only when it starts; the ? next to
                               the group explains why and how to turn them on in Arsenal
  - Languages: English and Simplified Chinese built in; every text can be changed or
    translated with a JSON file (see LANGUAGES).
  - Two looks: Helldivers (yellow on dark) and Archive (paper beige, dark ink, inverted
    selection, ruled lines). ESC > MDL Settings > Theme. Mods without an icon show a
    small built-in pixel symbol for their type.
  - Optional animations (Settings > Animations) and MDL's own frame cost in Settings
    and at the bottom right of the main page.
  - Each mod's file name is shown under its name, so mods with the same name can be told apart.
  - Auto reload (Settings): changed Lua files in the Mods folder, and new versions of running
    library addons imported into Arsenal / HD2MM, are reloaded without switching them off.
  - Frame cost per running mod, optional reduced update rate, background log writing.
  - Folding: click [-] / [+] before a section title to fold or open it (script addons loaded
    at launch start folded).
  - Sorting: every section has a SORT switch on its title (load order, A-Z, newest update
    first; right click steps back). In "newest" the update time shows under each mod.
  - Memory: a running mod's page shows its Lua memory (an estimate of the Lua objects it
    holds) and how fast its update allocates; the MDL frame cost page lists all running
    mods. Engine memory a mod causes (units, textures) is not part of the estimate.
  - Optional (Settings > Track engine objects and native memory): counts the units, GUIs,
    effects and native memory (VirtualAlloc / malloc through ffi.C) each live mod creates,
    and shows what a stopped mod left behind.
  - Library addons deployed by Arsenal / HD2MM show "ON VIA Arsenal" and are never started
    a second time; the launch addon section shows their Arsenal / HD2MM names.
  - Replaces Bingus Shared Loader: do not install both. MDL has its own startup loader with
    the same addon API (BSL API 1), so mods that ask for BSL keep working, including Mod
    Options Menu and Mod Bindings Menu.

INSTALL
  1. Close the game.
  2. Import this ZIP into HD2 Arsenal (or HD2MM), enable it, click Deploy.
  3. Start the game, press ESC and open the MDL Settings tab.
  Do not install MDL together with Bingus Shared Loader: if BSL is installed, disable it in
  Arsenal / HD2MM before you Deploy. Mods that require BSL work with MDL.

LIVE LUA MODS
  Put each mod in its own folder:
    %LOCALAPPDATA%\MDL\Helldivers2\Mods\<name>\mod.lua      (optional icon.png)
  Only install mods you trust: a Lua mod runs with the same access as the game.

LIVE RESOURCE MODS
  Click OFF next to a resource mod in MOD LIBRARY. The first time, MDL looks up which game
  packages hold the assets it replaces (a few seconds; the result is remembered). It then
  places a copy of the mod next to those packages in the game's data folder. The game uses
  it the next time it loads them: start a mission or go back to the ship. No restart.
  - LIVE ON (yellow): waiting for the next load. LIVE ON (green): active now.
  - Click LIVE ON to switch it off; if its assets are in use, MDL removes the copies when
    the game unloads them (OFF AFTER UNLOAD).
  - LAUNCH ONLY: the mod only changes assets the game loads once at start. Use Arsenal.
  - Use a mod either live or in Arsenal, not both. A mod enabled in Arsenal cannot be
    switched live; when Arsenal deploys a mod, MDL removes its own copies of it.
  - An Arsenal Deploy deletes MDL's copies; MDL puts them back at the next game start.
  - Records: %LOCALAPPDATA%\MDL\Helldivers2\ResourceLab\staged.lua
    Log: %LOCALAPPDATA%\MDL\Helldivers2\Logs\MDL-LiveResources.log
  - To turn the feature off: live_resources = false inside "ui = { ... }" in MDL.cfg.

LANGUAGES
  ESC > MDL Settings > Language (bottom of the list) switches the language at once.
  Files: %LOCALAPPDATA%\MDL\Helldivers2\Languages\<code>.json, written at the first start:
    en.json, zh-CN.json   edit any text (keys you leave out use the built-in text)
    reference-en.json     every current key (rewritten by each MDL version)
  To add a language, copy en.json to e.g. de.json, set "code" and "name", translate the
  texts, and pick it in game. Keep {placeholders} as they are. The ESC tab title follows
  the language at the next start.

SETTINGS
  %LOCALAPPDATA%\MDL\Helldivers2\MDL.cfg (created on first start). Inside "ui = { ... }":
    native_tab = false          floating panel on the right instead of the ESC tab
    language = "zh-CN"          language code (set by the Language row; absent = automatic:
                                the game's language, English when MDL has no such language)
    theme = "archive"           "hd2" (default) or "archive" (set by the Theme row)
    track_engine = true         count engine objects / native memory of live mods
    sort = { resource = "time" } sort mode per section: "name" or "time" (set by the
                                SORT switches; sections loose, addons, live, script,
                                mixed, resource, unknown)
    tab_text = "MDL SETTINGS"   title of the ESC tab (default: from the language)
    live_resources = false      turn the live resource switch off
    tab_x, tab_top, tab_width, tab_bottom = numbers
                                panel position and size in the tab (1080p units)
  Close the game before editing the file.

COMPATIBILITY
  - Mod Options Menu also adds an ESC tab. With it installed, MOD OPTIONS stays the 4th
    tab and MDL Settings becomes the 5th. MOD OPTIONS (1.1 and older) expects exactly
    4 tabs, so while its own code runs MDL shows it a 4-tab bar.
  - After a game update MDL looks up everything it needs again at start. Anything it
    cannot find switches itself off (for example the tab falls back to the floating
    panel) instead of guessing.

TROUBLESHOOTING
  Log: %LOCALAPPDATA%\MDL\Helldivers2\Logs\MDL.log - please attach it to bug reports.

UNINSTALL
  Disable MDL in Arsenal / HD2MM and Deploy. You can delete %LOCALAPPDATA%\MDL afterwards.

CREDITS
  Addon discovery and startup registry based on Bingus Shared Loader v18 by CowboyBingus.
  LuaJIT (MIT licence).

----------------------------------------------------------------------------------------
中文说明
  - 在 ESC 菜单中加入 "MDL Settings" 页签（装有 Mod Options Menu 时，它是第 4 页，MDL 是第 5 页）：游戏运行中加载、停止、重载 Lua mod，无需重启。
  - 显示 Arsenal / HD2MM 的 mod 库（含图标），按类型分组；“仅启动时”的组只能随游戏启动，
    点旁边的 ? 查看原因和 Arsenal 操作步骤。
  - 资源 mod 可以实时开关：在库里点资源 mod 的“关”。第一次会花几秒查找它修改的游戏资源包，
    之后游戏下次加载这些资源时（下一局任务或回到飞船）生效，无需 Deploy、无需重启。
    同一个 mod 请只用一种方式（实时或 Arsenal）；Arsenal Deploy 会删掉 MDL 的副本，MDL 会在下次启动时恢复。
  - 语言：ESC > MDL Settings > 语言（列表底部）。文本文件在
    %LOCALAPPDATA%\MDL\Helldivers2\Languages\<代码>.json，可修改任何文本，或复制 en.json 添加新语言。
  - 设置里可开关“动画”，并可查看“MDL 每帧耗时”（主页右下角也有，可点开看各部分）。
  - 主题：ESC > MDL Settings > 主题，在“地狱潜兵”（深色底黄字）和“档案”（米色纸张、深色文字、反色选中行、
    横格线）之间切换。没有图标的 mod 显示内置的像素类型符号。
  - 每个 mod 名称下方用小字显示它的文件名（Arsenal 解压出的文件夹名，Arsenal 不记录压缩包扩展名），同名 mod 也能区分。
  - 自动重载（设置）：Mods 文件夹中改动的 Lua 文件，以及拖入 Arsenal / HD2MM 的正在运行的库插件新版本，都会自动重载，无需手动关再开。
  - 请勿与 Bingus Shared Loader 同时安装：MDL 自带启动加载器和同样的插件接口（BSL API 1），需要 BSL 的 mod
    （包括 Mod Options Menu、Mod Bindings Menu）在 MDL 下照常工作。装了 BSL 的话先在 Arsenal / HD2MM 中禁用它。
  - 安装：关闭游戏 → 禁用 BSL（如有）→ 导入 Arsenal 或 HD2MM → 启用 → Deploy → 进游戏按 ESC。
  - Live mod 目录：%LOCALAPPDATA%\MDL\Helldivers2\Mods\<名称>\mod.lua。只安装可信的 mod。
  - 问题反馈请附上 %LOCALAPPDATA%\MDL\Helldivers2\Logs\MDL.log。
