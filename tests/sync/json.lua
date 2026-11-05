-- The JSON reader and writer of the cloud sync (ink/sync/json.lua).
--   luajit tests/sync/json.lua
package.path = "./?.lua;" .. package.path
local Json = require("ink/sync/json")
local checks, fails = 0, 0
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end

eq(Json.encode({ b = 1, a = "x" }), '{"a":"x","b":1}', "keys sorted")
eq(Json.encode({ 1, 2, 3 }), "[1,2,3]", "array")
eq(Json.encode(setmetatable({}, Json.ARRAY)), "[]", "empty list")
eq(Json.encode({}), "{}", "empty object")
eq(Json.encode("a\"b\\c\n"), '"a\\"b\\\\c\\n"', "escapes")
eq(Json.encode("é"), '"\\u00e9"', "non-ASCII is escaped")
eq(Json.encode("😀"), '"\\ud83d\\ude00"', "pair for a 4-byte character")
eq(Json.encode(1.5), "1.5", "fraction")
eq(Json.encode(3), "3", "whole number")

local v = Json.decode('{"a":[1,2,{"b":null}],"c":"\\u00e9\\ud83d\\ude00x","d":true,"e":-1.5e2}')
eq(v.a[2], 2, "array item")
eq(v.c, "é😀x", "unicode round trip")
eq(v.d, true, "boolean")
eq(v.e, -150, "number with exponent")
eq(Json.decode(Json.encode({ s = "naïve 😀 \t" })).s, "naïve 😀 \t", "round trip")
eq(Json.decode("{"), nil, "unfinished is an error")
eq(Json.decode('{"a":1} x'), nil, "extra text is an error")
eq(Json.decode('[1,]'), nil, "trailing comma is an error")
eq(Json.decode(nil), nil, "nil is an error")
eq(select(2, Json.decode('"abc')) ~= nil, true, "unterminated string says why")
local deep = string.rep("[", 100) .. string.rep("]", 100)
eq(Json.decode(deep), nil, "too deep is an error")

print(string.format("json: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
