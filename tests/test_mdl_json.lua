-- Usage: luajit tests/test_mdl_json.lua <src directory>
local json = assert(loadfile(assert(arg[1]) .. '/mdl_json.lua'))()
local checks = 0
local function check(v, m) checks = checks + 1; assert(v, m) end
local t = json.decode('\239\187\191 {"a": [1, 2.5, -3e2, true, false, null, "x\\u00e9\\ud83d\\ude00\\n"], "b": {"c": null, "d": "\\\\\\/"}, "e": []}')
check(t.a[1] == 1 and t.a[2] == 2.5 and t.a[3] == -300 and t.a[4] == true and t.a[5] == false, 'scalars')
check(t.a[6] == json.null and t.a[7] == 'x\195\169\240\159\152\128\n', 'null in arrays and unicode escapes')
check(t.b.c == nil and t.b.d == '\\/', 'null members dropped, escapes')
check(type(t.e) == 'table' and #t.e == 0, 'empty array')
check(json.decode('"\228\184\173\230\150\135"') == '\228\184\173\230\150\135', 'raw UTF-8 kept')
check(json.decode('null') == nil, 'top-level null')
for _, bad in ipairs({'{', '{"a":}', '[1,]', '{"a":1}x', '"abc', '{a:1}', '[1 2]', '"\\x"'}) do
    check(not pcall(json.decode, bad), 'rejects ' .. bad)
end
local deep = string.rep('[', 100) .. string.rep(']', 100)
check(not pcall(json.decode, deep), 'depth limit')
print('PASS: MDL JSON decoder (' .. checks .. ' checks)')
