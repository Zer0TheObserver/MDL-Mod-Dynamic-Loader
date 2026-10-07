-- MDL localisation. Every user-facing text has a key; the English text is the
-- base (mdl_panel STRINGS). Languages come from the built-in table (mdl_lang)
-- and from JSON files in %LOCALAPPDATA%\MDL\Helldivers2\Languages:
--   { "code": "zh-CN", "name": "简体中文", "strings": { "row.rescan": "...", ... } }
-- A file overrides the built-in strings of the same code key by key; a key
-- missing everywhere falls back to English. "{name}" in a text is replaced by
-- the value given for it.
local I = {}

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

local function quote(text)
    return '"' .. tostring(text):gsub('[%c"\\]', function(c)
        if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' elseif c == '\n' then return '\\n'
        elseif c == '\t' then return '\\t' elseif c == '\r' then return '\\r' end
        return string.format('\\u%04x', c:byte())
    end) .. '"'
end

-- Checksum of a strings table (keys sorted), to tell whether a generated
-- language file was edited by the player.
function I.checksum(strings)
    local keys = sorted_keys(strings)
    local a, b = 1, 0
    for _, key in ipairs(keys) do
        local text = key .. '=' .. tostring(strings[key]) .. '\n'
        for i = 1, #text do
            a = (a + text:byte(i)) % 65521
            b = (b + a) % 65521
        end
    end
    return string.format('%08x', b * 65536 + a)
end

-- Language file text: code, name, then the strings sorted by key. Files MDL
-- writes itself carry "generated" = checksum of their strings; unedited ones
-- are refreshed when a new MDL version changes the built-in texts.
function I.encode(code, name, strings, generated)
    local lines = {'{', '  "code": ' .. quote(code) .. ',', '  "name": ' .. quote(name) .. ','}
    if generated then lines[#lines + 1] = '  "generated": ' .. quote(I.checksum(strings)) .. ',' end
    lines[#lines + 1] = '  "strings": {'
    local keys = sorted_keys(strings)
    for i, key in ipairs(keys) do
        lines[#lines + 1] = '    ' .. quote(key) .. ': ' .. quote(strings[key]) .. (i < #keys and ',' or '')
    end
    lines[#lines + 1] = '  }'
    lines[#lines + 1] = '}'
    return table.concat(lines, '\n') .. '\n'
end

local README = [[
MDL language files

Each <code>.json file here is one language. MDL reads them when the game starts
and when you pick a language in MDL Settings (ESC menu > MDL Settings > Language).

  "code"     language code, e.g. "en", "zh-CN", "de"
  "name"     name shown in the Language row
  "strings"  key -> text. Keys you leave out use the built-in text, then English.
             {name} placeholders are filled in by MDL; keep them.

To add a language: copy en.json to <code>.json, change "code" and "name",
translate the texts, then pick it in game (or restart).
MDL never overwrites a file that already exists. reference-en.json is
rewritten by every MDL version and always lists all current keys.
The tab title in the ESC menu follows the language at the next start.
]]

-- Steam API language names (ISteamApps::GetCurrentGameLanguage) -> tags.
I.STEAM = {english = 'en', schinese = 'zh-CN', tchinese = 'zh-TW', japanese = 'ja', koreana = 'ko', russian = 'ru',
    german = 'de', french = 'fr', italian = 'it', spanish = 'es', latam = 'es-419', polish = 'pl', brazilian = 'pt-BR',
    portuguese = 'pt', ukrainian = 'uk', czech = 'cs', dutch = 'nl', turkish = 'tr', thai = 'th', vietnamese = 'vi',
    danish = 'da', finnish = 'fi', norwegian = 'no', swedish = 'sv', hungarian = 'hu', romanian = 'ro',
    bulgarian = 'bg', greek = 'el', arabic = 'ar', indonesian = 'id'}

-- options = {platform=, json=, dir=, base=, builtin={code={name=, strings=}}, code=, locale=, auto=, log=}
function I.new(options)
    local platform, json = options.platform, options.json
    local base = options.base or {}
    local self = {revision = 0}
    local languages = {}   -- code -> {code=, name=, strings=, file=}
    local function log(text) if options.log then pcall(options.log, text) end end

    local function add(code, name, strings, file)
        local language = languages[code] or {code = code, name = name or code, strings = {}}
        if name then language.name = name end
        for key, text in pairs(strings or {}) do
            if type(key) == 'string' and type(text) == 'string' then language.strings[key] = text end
        end
        if file then language.file = file end
        languages[code] = language
    end

    local function load()
        languages = {}
        add('en', 'English', {})
        for code, item in pairs(options.builtin or {}) do add(code, item.name, item.strings) end
        local dir = options.dir
        if not dir or not platform then return end
        platform.mkdir(dir)
        -- Templates for translators (never overwrite a player's file).
        local function ensure(name, text)
            local path = dir .. '/' .. name
            if platform.read_head(path, 1) == nil then platform.write(path, text) return end
            -- Refresh a generated template the player has not edited.
            local ok, value = pcall(json.decode, platform.read(path) or '')
            if ok and type(value) == 'table' and type(value.strings) == 'table' and type(value.generated) == 'string'
                and value.generated == I.checksum(value.strings) and platform.read(path) ~= text then
                platform.write(path, text)
                log('language file ' .. name .. ' refreshed (unedited template)')
            end
        end
        ensure('en.json', I.encode('en', 'English', base, true))
        for code, item in pairs(options.builtin or {}) do
            local merged = {}
            for key in pairs(base) do merged[key] = item.strings[key] or base[key] end
            ensure(code .. '.json', I.encode(code, item.name or code, merged, true))
        end
        ensure('README.txt', README)
        platform.write(dir .. '/reference-en.json', I.encode('en', 'English', base))
        for _, entry in ipairs(platform.list(dir, '*.json')) do
            if not entry.dir and entry.name ~= 'reference-en.json' then
                local text = platform.read(dir .. '/' .. entry.name)
                local ok, value = pcall(json.decode, text or '')
                if ok and type(value) == 'table' and type(value.strings) == 'table' then
                    local code = type(value.code) == 'string' and value.code ~= '' and value.code or entry.name:gsub('%.json$', '')
                    add(code, type(value.name) == 'string' and value.name or nil, value.strings, entry.name)
                else
                    log('language file ' .. entry.name .. ' ignored: ' .. tostring(ok and 'no "strings" object' or value))
                end
            end
        end
    end

    -- Best match for a locale like "zh-CN" / "zh-Hans-CN" / "de-DE".
    local function match(locale)
        if type(locale) ~= 'string' or locale == '' then return nil end
        if languages[locale] then return locale end
        local lower = locale:lower()
        for code in pairs(languages) do if code:lower() == lower then return code end end
        local primary = lower:match('^(%a+)')
        if primary == 'zh' then
            local traditional = lower:find('hant') or lower:find('%-tw') or lower:find('%-hk') or lower:find('%-mo')
            local want = traditional and 'zh-TW' or 'zh-CN'
            if languages[want] then return want end
        end
        for _, code in ipairs(sorted_keys(languages)) do
            if code:lower():match('^(%a+)') == primary then return code end
        end
        return nil
    end

    load()
    -- Language choice: options.code is a language the player picked, or
    -- 'auto' / nil to follow the game. Automatic: the first language source
    -- that answers (options.auto() -> locale, source; else options.locale)
    -- decides; when no language file matches it, English.
    local function automatic()
        local locale, source
        if options.auto then
            local ok, a, b = pcall(options.auto)
            if ok then locale, source = a, b end
        end
        if not locale and options.locale then locale, source = options.locale, 'windows' end
        return match(locale) or 'en', locale, source
    end
    self.auto = options.code == nil or options.code == 'auto' or not match(options.code)
    if self.auto then
        self.code, self.auto_locale, self.auto_source = automatic()
    else
        self.code = match(options.code)
    end
    -- Automatic mode: look again (the game's language can become known
    -- after start). Returns true when the language changed.
    function self.refresh_auto()
        if not self.auto then return false end
        local code, locale, source = automatic()
        self.auto_locale, self.auto_source = locale, source
        if code == self.code then return false end
        self.code = code
        self.revision = self.revision + 1
        return true
    end
    -- 'auto' or a language code.
    function self.choice() return self.auto and 'auto' or self.code end

    function self.languages()
        local list = {}
        for _, code in ipairs(sorted_keys(languages)) do list[#list + 1] = {code = code, name = languages[code].name} end
        table.sort(list, function(a, b) if a.code == 'en' then return true elseif b.code == 'en' then return false end return a.code < b.code end)
        return list
    end
    function self.name(code)
        local language = languages[code or self.code]
        return language and language.name or tostring(code)
    end
    function self.set(code)
        if not languages[code] then return false end
        self.auto = false
        self.code = code
        self.revision = self.revision + 1
        return true
    end
    -- Re-reads the language files (keeps the current language when it still exists).
    function self.reload()
        load()
        if self.auto then self.code = automatic()
        elseif not languages[self.code] then self.code = 'en' end
        self.revision = self.revision + 1
    end
    -- Next language in the list (for the Language row).
    -- Steps through Automatic, then every language. Returns 'auto' or a code.
    function self.next(direction)
        local list = {'auto'}
        for _, item in ipairs(self.languages()) do list[#list + 1] = item.code end
        local current, at = self.choice(), 1
        for i, code in ipairs(list) do if code == current then at = i end end
        local target = list[(at - 1 + (direction or 1)) % #list + 1]
        if target == 'auto' then
            self.auto = true
            self.code, self.auto_locale, self.auto_source = automatic()
            self.revision = self.revision + 1
        else
            self.auto = false
            self.set(target)
        end
        return target
    end
    function self.t(key, vars)
        local language = languages[self.code]
        local text = language and language.strings[key] or base[key] or key
        if vars then
            text = text:gsub('{([%w_]+)}', function(name)
                local value = vars[name]
                if value == nil then return '{' .. name .. '}' end
                return tostring(value)
            end)
        end
        return text
    end
    function self.has(key) return base[key] ~= nil end
    return self
end

return I
