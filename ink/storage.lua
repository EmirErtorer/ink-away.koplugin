--[[
Files and folders: small helpers for the paths Ink Away saves to.
]]

local Storage = {}

local function getLfs()
    local ok, m = pcall(require, "libs/libkoreader-lfs")
    return ok and m or nil
end

local function getDataStorage()
    local ok, m = pcall(require, "datastorage")
    return ok and m or nil
end

-- Return `p` if it is an existing directory, else nil. Without lfs (outside
-- KOReader) any path is taken as it is.
function Storage.existingDir(p)
    if not p then return nil end
    local fs = getLfs()
    if not fs or fs.attributes(p, "mode") == "directory" then return p end
    return nil
end

-- Is `p` an existing directory?
function Storage.isDir(p)
    local fs = getLfs()
    return fs ~= nil and p ~= nil and fs.attributes(p, "mode") == "directory"
end

-- Make the directory `p` if it is missing. Returns whether it exists now.
function Storage.ensureDir(p)
    local fs = getLfs()
    if not fs then return false end
    if fs.attributes(p, "mode") ~= "directory" then pcall(fs.mkdir, p) end
    return fs.attributes(p, "mode") == "directory"
end

-- KOReader's data folder, or nil outside KOReader.
function Storage.dataDir()
    local ds = getDataStorage()
    return ds and ds:getDataDir() or nil
end

-- KOReader's settings folder, or /tmp outside KOReader.
function Storage.settingsDir()
    local ds = getDataStorage()
    return (ds and ds:getSettingsDir()) or "/tmp"
end

-- A folder under "ink away" in KOReader's data folder, made if missing, or nil
-- when it can't be made.
function Storage.appDir(name)
    local data = Storage.dataDir()
    if not data then return nil end
    local parent = data .. "/ink away"
    local dir = parent .. "/" .. name
    Storage.ensureDir(parent)
    return Storage.ensureDir(dir) and dir or nil
end

-- `dir` and `name` joined with a single slash.
function Storage.join(dir, name)
    return dir .. ((dir:sub(-1) == "/") and "" or "/") .. name
end

-- A file name from what was typed: path separators replaced, and ".ext" added
-- unless it is already there.
function Storage.fileName(name, ext)
    name = name:gsub("[/\\]", "_")
    if not name:lower():match("%." .. ext .. "$") then name = name .. "." .. ext end
    return name
end

return Storage
