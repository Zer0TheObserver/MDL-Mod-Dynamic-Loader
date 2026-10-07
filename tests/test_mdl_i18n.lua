-- Localisation: key coverage of the built-in languages, language files
-- (override, new language, broken file), locale matching, placeholders and
-- the panel in another language.
-- Usage: luajit tests/test_mdl_i18n.lua <src directory>
local source = assert(arg[1])
local function module(name) return assert(loadfile(source .. '/' .. name .. '.lua'))() end
local I, json, lang, panel_module, manager_module = module('mdl_i18n'), module('mdl_json'), module('mdl_lang'), module('mdl_panel'), module('mdl_manager')
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end
local BASE = panel_module.STRINGS

-- 1. Built-in languages cover exactly the base keys, with the same placeholders.
local function placeholders(text)
    local list = {}
    for name in text:gmatch('{([%w_]+)}') do list[#list + 1] = name end
    table.sort(list)
    return table.concat(list, ',')
end
for code, language in pairs(lang) do
    for key, text in pairs(BASE) do
        check(language.strings[key], code .. ' translates ' .. key)
        check(placeholders(language.strings[key]) == placeholders(text), code .. ' keeps the placeholders of ' .. key)
    end
    for key in pairs(language.strings) do check(BASE[key], code .. ' has no unknown key ' .. key) end
end

-- 2. Every key the panel asks for exists in the base.
do
    local file = assert(io.open(source .. '/mdl_panel.lua', 'rb'))
    local text = file:read('*a')
    file:close()
    local used = 0
    for key in text:gmatch("L%('([%w_%.]+)'") do
        used = used + 1
        if key:sub(-1) ~= '.' then check(BASE[key], 'panel key exists: ' .. key) end
    end
    -- Keys held in tables (help, why, groups, states).
    for key in text:gmatch("'((%l[%l_]*)%.[%w_%.]+)'") do
        local prefix = key:match('^(%l[%l_]*)%.')
        if ({help = 1, why = 1, group = 1, state = 1, how = 1, category = 1, row = 1, note = 1, header = 1, footer = 1, flash = 1, live = 1, reason = 1, rate = 1, title = 1, tab = 1})[prefix]
            and not key:find('%.lua$') then
            check(BASE[key], 'table key exists: ' .. key)
        end
    end
    check(used > 60, 'panel uses localised text (' .. used .. ' calls)')
end

-- 3. Language files.
local files, logs = {}, {}
local platform = {}
function platform.mkdir() return true end
function platform.read(path) return files[path] end
function platform.read_head(path, n) return files[path] and files[path]:sub(1, n) end
function platform.write(path, data) files[path] = data; return true end
function platform.list(dir, pattern)
    local out = {}
    local glob = '^' .. pattern:gsub('%.', '%%.'):gsub('%*', '.*') .. '$'
    for path in pairs(files) do
        local name = path:match('^' .. dir:gsub('%p', '%%%0') .. '/([^/]+)$')
        if name and name:match(glob) then out[#out + 1] = {name = name} end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end
local DIR = 'C:/MDL/Languages'
local function make(code, locale)
    return I.new({platform = platform, json = json, dir = DIR, base = BASE, builtin = lang, code = code, locale = locale,
        log = function(line) logs[#logs + 1] = line end})
end
local i18n = make(nil, 'en-US')
check(i18n.code == 'en' and i18n.t('row.rescan') == 'Rescan mods and library', 'English by default')
check(files[DIR .. '/en.json'] and files[DIR .. '/zh-CN.json'] and files[DIR .. '/README.txt'] and files[DIR .. '/reference-en.json'],
    'templates written')
local en_file = json.decode(files[DIR .. '/en.json'])
check(en_file.code == 'en' and en_file.strings['row.rescan'] == 'Rescan mods and library', 'en.json lists the base texts')
local zh_file = json.decode(files[DIR .. '/zh-CN.json'])
check(zh_file.name == '简体中文' and zh_file.strings['row.rescan'] == '重新扫描 mod 和库', 'zh-CN.json written in UTF-8')
check(json.decode(files[DIR .. '/en.json']).strings['note.put_mods']:find('\\MDL\\', 1, true), 'backslashes survive the JSON round trip')
-- The player's edits win and are never overwritten.
zh_file.strings['row.rescan'] = '刷新'
zh_file.strings['row.back'] = nil
files[DIR .. '/zh-CN.json'] = I.encode('zh-CN', '简体中文', zh_file.strings)
files[DIR .. '/de.json'] = '{"code": "de", "name": "Deutsch", "strings": {"row.rescan": "Neu scannen", "row.in_source": "In {source} \\"x\\""}}'
files[DIR .. '/broken.json'] = '{"code": "xx", '
local zh = make(nil, 'zh-Hans-CN')
check(zh.code == 'zh-CN', 'zh-Hans-CN locale picks zh-CN')
check(zh.t('row.rescan') == '刷新', 'file overrides the built-in text')
check(zh.t('row.back') == '< 返回', 'key missing in the file falls back to the built-in language')
check(files[DIR .. '/zh-CN.json']:find('刷新', 1, true), 'existing file kept')
check(#logs > 0 and logs[#logs]:find('broken.json', 1, true), 'broken file ignored with a log line')
local de = make('de')
check(de.code == 'de' and de.t('row.rescan') == 'Neu scannen' and de.t('row.back') == '< Back', 'new language with English fallback')
check(de.t('row.in_source', {source = 'Arsenal'}) == 'In Arsenal "x"', 'placeholders filled in')
check(de.t('row.in_source') == 'In {source} "x"' and de.t('no.such.key') == 'no.such.key', 'missing values stay visible')
check(make(nil, 'de-AT').code == 'de' and make(nil, 'fr-FR').code == 'en' and make('xx', 'zh-TW').code == 'zh-CN', 'locale matching and fallbacks')
local list = de.languages()
check(list[1].code == 'en' and #list == 3, 'language list: English first, then the others')
check(de.next(1) ~= 'de' and de.revision > 0, 'next language')
check(I.encode('a', 'b', {k = 'tab\there "q" \\ 中'}):find('"k": "tab\\there \\"q\\" \\\\ 中"', 1, true), 'encoder escapes')
-- Generated templates: refreshed while unedited, kept once edited.
do
    local stale = {['row.rescan'] = 'OLD TEXT'}
    for key, text in pairs(BASE) do if key ~= 'row.rescan' then stale[key] = text end end
    files[DIR .. '/en.json'] = I.encode('en', 'English', stale, true)
    make(nil, 'en-US')
    check(json.decode(files[DIR .. '/en.json']).strings['row.rescan'] == 'Rescan mods and library', 'unedited generated template refreshed')
    local edited = json.decode(files[DIR .. '/en.json'])
    edited.strings['row.back'] = 'MY BACK'
    local text = I.encode('en', 'English', edited.strings, true):gsub('"generated": "%x+"', '"generated": "' .. edited.generated .. '"')
    files[DIR .. '/en.json'] = text
    make(nil, 'en-US')
    check(json.decode(files[DIR .. '/en.json']).strings['row.back'] == 'MY BACK', 'edited template kept')
end

-- 4. The panel in another language.
do
    local fs = {mkdir = function() return true end, read = function() return nil end, read_head = function() return nil end,
        write = function() return true end, list = function() return {} end}
    local m = manager_module.new({base_dir = 'C:/T', platform = fs, globals = _G})
    m.start()
    local entries = {{id = 'a', name = 'Armor', category = 'RESOURCE', source = 'Arsenal', options = {}, types = {}, enabled = false}}
    local library = {scanned = true, sources = {'Arsenal'}, entries = entries, scan = function() end, describe_types = function() return '' end}
    local input = {pressed = function() return false end, cursor = function() return nil end, clicked = function() return false end,
        held = function() return false end, wheel = function() return 0 end}
    local renderer = {resolution = function() return 1920, 1080 end, draw = function() return true end, clear = function() end}
    local zh2 = make('zh-CN')
    local panel = panel_module.new(m, input, renderer, {library = library, i18n = zh2, menu_probe = function() return true end})
    local text = {}
    for _, row in ipairs(panel.rows()) do text[#text + 1] = tostring(row.label or row.header) .. '=' .. tostring(row.value) end
    text = table.concat(text, '|')
    check(text:find('实时 LUA MOD', 1, true) and text:find('资源  -  仅启动时', 1, true) and text:find('Armor=关', 1, true),
        'list in Chinese: ' .. text)
    panel.page = 'help'
    local help = {}
    for _, row in ipairs(panel.rows()) do help[#help + 1] = tostring(row.label or row.header) end
    check(table.concat(help, '|'):find('MOD 类型', 1, true), 'help page in Chinese')
    panel.frame()
    check(panel.draw_status == 'visible', 'draws in Chinese')
    -- Switching language rebuilds the rows.
    zh2.set('en')
    panel.page = 'list'
    local back = {}
    for _, row in ipairs(panel.rows()) do back[#back + 1] = tostring(row.label or row.header) end
    check(table.concat(back, '|'):find('LIVE LUA MODS', 1, true), 'back to English')
end

-- Automatic language: the first source that answers decides; English when
-- no language file matches it; a picked language wins.
do
    local answer, source = 'zh-Hans', 'game'
    local function auto_new(code, locale)
        return I.new({base = BASE, builtin = lang, code = code, locale = locale, auto = function() return answer, source end})
    end
    local a = auto_new(nil, 'en-US')
    check(a.auto and a.code == 'zh-CN' and a.auto_source == 'game' and a.choice() == 'auto', 'game Chinese -> zh-CN')
    answer = 'de-DE'
    check(a.refresh_auto() and a.code == 'en', 'game German, no German file -> English (not the Windows fallback)')
    answer, source = nil, nil
    a.refresh_auto()
    check(a.code == 'en' and a.auto_source == 'windows', 'nothing from the game: Windows locale (en-US)')
    check(auto_new('auto', 'zh-TW').code == 'zh-CN', 'auto by name; Traditional Chinese falls back to the Chinese file')
    answer = I.STEAM.schinese
    check(answer == 'zh-CN' and auto_new(nil, nil).code == 'zh-CN', 'Steam schinese')
    local picked = auto_new('en', nil)
    check(not picked.auto and picked.code == 'en' and picked.refresh_auto() == false, 'picked language is kept')
    check(auto_new('xx-missing', nil).auto, 'a picked language without a file falls back to automatic')
    -- The Language row steps: automatic, English, Chinese, automatic.
    local steps = {}
    for _ = 1, 3 do steps[#steps + 1] = picked.next(1) end
    check(table.concat(steps, ',') == 'zh-CN,auto,en' and not picked.auto, 'cycle: ' .. table.concat(steps, ','))
    check(picked.next(1) == 'zh-CN', 'cycle continues')
end

print('PASS: MDL localisation (coverage, language files, locale matching, panel) (' .. checks .. ' checks)')
