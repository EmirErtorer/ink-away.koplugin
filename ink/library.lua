--[[
The library: the folder drawings and notebooks are kept in, the names new ones
get, and bringing the single "last session" file of older versions into it.
Plain Lua, so the headless tests drive it.
]]

local Project = require("ink/project")
local Storage = require("ink/storage")

local Library = {}

-- The clock new names are dated with (replaced in the tests).
Library.now = os.time

-- The library folder: `chosen` when it still exists, else "ink away" in
-- KOReader's data folder, else KOReader's settings folder.
function Library.root(chosen)
    if chosen and Storage.isDir(chosen) then return chosen end
    return Storage.appRoot() or Storage.settingsDir()
end

-- The name a new document gets: its kind and when it was started, e.g.
-- "Notebook 2026-10-03 14.22" (no colon, which some readers' file systems refuse).
function Library.defaultName(label)
    return label .. " " .. os.date("%Y-%m-%d %H.%M", Library.now())
end

-- Is the parsed project worth keeping: any ink, more than one page, or pages
-- over an imported PDF?
function Library.hasContent(data)
    if type(data) ~= "table" then return false end
    if type(data.ops) == "table" then return #data.ops > 0 or data.bg ~= nil end
    if type(data.pages) ~= "table" then return false end
    if #data.pages > 1 or (data.template and data.template.pdf_path) then return true end
    local p = data.pages[1]
    local ops = type(p) == "table" and (p.ops or (p.src == nil and p.id == nil and p)) or nil
    return type(ops) == "table" and #ops > 0
end

-- Move an old session file into `dir` as a document named `name`. Returns the
-- new path, or nil when there was nothing worth keeping. The old file is
-- removed once its content is safe in the library.
function Library.adoptSession(session_path, dir, name)
    local f = io.open(session_path, "rb")
    if not f then return nil end
    local raw = f:read("*a")
    f:close()
    if not Library.hasContent(Project.deserialize(raw)) then
        os.remove(session_path)
        return nil
    end
    local path = Storage.uniquePath(dir, name, Project.EXT)
    if not Storage.writeAtomic(path, raw) then return nil end
    os.remove(session_path)
    return path
end

return Library
