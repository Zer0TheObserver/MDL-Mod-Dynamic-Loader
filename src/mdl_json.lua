-- MDL: small strict JSON decoder for mod-manager metadata (manifest.json,
-- Arsenal hd2a_data.json, HD2MM enabled.json). Objects become Lua tables,
-- JSON null becomes nil (json.null inside arrays keeps positions).
local json = {null = setmetatable({}, {__tostring = function() return 'null' end})}

local escapes = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}

local function utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

function json.decode(text, max_depth)
    assert(type(text) == 'string', 'JSON text expected')
    max_depth = max_depth or 64
    local pos = 1
    if text:sub(1, 3) == '\239\187\191' then pos = 4 end
    local function fail(message) error(string.format('JSON %s at byte %d', message, pos), 0) end
    local function skip()
        pos = text:find('[^ \t\r\n]', pos) or #text + 1
    end
    local value
    local function string_value()
        pos = pos + 1
        local parts = {}
        while true do
            local stop = text:find('["\\]', pos)
            if not stop then fail('unterminated string') end
            parts[#parts + 1] = text:sub(pos, stop - 1)
            pos = stop + 1
            if text:sub(stop, stop) == '"' then break end
            local c = text:sub(pos, pos)
            if c == 'u' then
                local hex = text:sub(pos + 1, pos + 4)
                if not hex:match('^%x%x%x%x$') then fail('bad unicode escape') end
                local code = tonumber(hex, 16)
                pos = pos + 5
                if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == '\\u' then
                    local low = tonumber(text:sub(pos + 2, pos + 5), 16)
                    if low and low >= 0xDC00 and low <= 0xDFFF then
                        code = 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
                        pos = pos + 6
                    end
                end
                parts[#parts + 1] = utf8(code)
            elseif escapes[c] then
                parts[#parts + 1] = escapes[c]
                pos = pos + 1
            else
                fail('bad escape')
            end
        end
        return table.concat(parts)
    end
    function value(depth)
        if depth > max_depth then fail('too deep') end
        skip()
        local c = text:sub(pos, pos)
        if c == '{' then
            pos = pos + 1
            local result = {}
            skip()
            if text:sub(pos, pos) == '}' then pos = pos + 1 return result end
            while true do
                skip()
                if text:sub(pos, pos) ~= '"' then fail('object key expected') end
                local key = string_value()
                skip()
                if text:sub(pos, pos) ~= ':' then fail('colon expected') end
                pos = pos + 1
                local item = value(depth + 1)
                if item ~= json.null then result[key] = item end
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == '}' then return result end
                if sep ~= ',' then fail('comma expected') end
            end
        elseif c == '[' then
            pos = pos + 1
            local result, n = {}, 0
            skip()
            if text:sub(pos, pos) == ']' then pos = pos + 1 return result end
            while true do
                n = n + 1
                result[n] = value(depth + 1)
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == ']' then return result end
                if sep ~= ',' then fail('comma expected') end
            end
        elseif c == '"' then
            return string_value()
        elseif text:sub(pos, pos + 3) == 'true' then pos = pos + 4 return true
        elseif text:sub(pos, pos + 4) == 'false' then pos = pos + 5 return false
        elseif text:sub(pos, pos + 3) == 'null' then pos = pos + 4 return json.null
        else
            local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
            if not number or number == '' or number == '-' then fail('unexpected character') end
            pos = pos + #number
            return tonumber(number) or fail('bad number')
        end
    end
    local result = value(1)
    skip()
    if pos <= #text then fail('trailing data') end
    if result == json.null then return nil end
    return result
end

return json
