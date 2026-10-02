--[[
Editable project files. A drawing is a list of ops, so a project is that list
written out, and a reopened project stays fully editable. The file is a small Lua
chunk ("return { ... }") loaded in a sandbox with no globals, so a tampered file
can define data but cannot run code.
]]

local Project = {}

Project.EXT = "inkaway"

-- Serialize a Lua value into `out`: numbers, booleans, strings, and tables with
-- an array part and string keys, which is all an ops list holds.
local function ser(v, out)
    local t = type(v)
    if t == "number" then
        out[#out + 1] = string.format("%.6g", v)
    elseif t == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "table" then
        out[#out + 1] = "{"
        local n = #v
        for i = 1, n do ser(v[i], out); out[#out + 1] = "," end
        for k, val in pairs(v) do
            if type(k) == "string" then
                out[#out + 1] = "[" .. string.format("%q", k) .. "]="
                ser(val, out)
                out[#out + 1] = ","
            end
        end
        out[#out + 1] = "}"
    else
        out[#out + 1] = "nil"
    end
end

local function serializeRoot(root)
    local out = { "return " }
    ser(root, out)
    return table.concat(out)
end

-- Serialize a single-page canvas (v1) to a project string.
function Project.serialize(canvas)
    return serializeRoot({ v = 1, w = canvas.w, h = canvas.h, ops = canvas.ops })
end

-- Serialize a multi-page notebook (v2): the template plus one ops list per page.
function Project.serializeNotebook(nb)
    return serializeRoot({ v = 2, w = nb.w, h = nb.h, template = nb.template, pages = nb.pages })
end

-- Parse a project string. Returns a table { w, h, ops } or nil, error.
function Project.deserialize(str)
    if type(str) ~= "string" or str == "" then return nil, "empty" end
    local chunk, err = load(str, "inkaway-project", "t", {})   -- sandbox: no env
    if not chunk then return nil, err end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then return nil, "not a project" end
    if type(data.w) ~= "number" or type(data.h) ~= "number"
        or (type(data.ops) ~= "table" and type(data.pages) ~= "table") then
        return nil, "missing fields"
    end
    return data
end

-- Is this parsed project a multi-page notebook (v2) rather than a single canvas?
function Project.isNotebook(data)
    return type(data) == "table" and type(data.pages) == "table"
end

local function writeFile(path, s)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    f:write(s)
    f:close()
    return true
end

-- Write the canvas to a file at `path`. Returns ok, err.
function Project.save(canvas, path)
    return writeFile(path, Project.serialize(canvas))
end

-- Write a notebook to a file at `path`. Returns ok, err.
function Project.saveNotebook(nb, path)
    return writeFile(path, Project.serializeNotebook(nb))
end

-- Read a project file. Returns { w, h, ops } or nil, err.
function Project.load(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local data = f:read("*a")
    f:close()
    return Project.deserialize(data)
end

return Project
