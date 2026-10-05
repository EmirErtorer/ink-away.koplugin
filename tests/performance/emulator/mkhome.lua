-- Write a fresh settings.reader.lua for an isolated emulator home: the real
-- emulator settings minus every inkaway_* key, plus the overrides given as
-- key=value (value is Lua) on the command line.
local src, dst, home = arg[1], arg[2], arg[3]
local data = dofile(src)
for k in pairs(data) do if type(k) == "string" and k:match("^inkaway_") then data[k] = nil end end
data.home_dir = home .. "/docs"
data.lastdir = home .. "/docs"
data.start_with = "filemanager"
data.plugins_disabled = { statistics = true, zenos = true }
for i = 4, #arg do
    local k, v = arg[i]:match("^([%w_]+)=(.*)$")
    data[k] = assert(load("return " .. v))()
end
local function ser(v, ind)
    local t = type(v)
    if t == "string" then return string.format("%q", v)
    elseif t ~= "table" then return tostring(v) end
    local out = { "{\n" }
    for k, val in pairs(v) do
        local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
        out[#out + 1] = ind .. "    " .. key .. " = " .. ser(val, ind .. "    ") .. ",\n"
    end
    out[#out + 1] = ind .. "}"
    return table.concat(out)
end
local f = assert(io.open(dst, "w"))
f:write("-- isolated e2e home\nreturn " .. ser(data, "") .. "\n")
f:close()
