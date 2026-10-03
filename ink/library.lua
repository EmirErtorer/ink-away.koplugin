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

-- Folders in the "ink away" folder that hold Ink Away's own files (exports and
-- downloaded pictures) rather than documents. The library leaves them out.
Library.INTERNAL = { drawings = true, notebooks = true, exports = true,
    ["online images"] = true, ["processed images"] = true }

-- Is `name` a document file?
function Library.isDocument(name)
    return name:lower():match("%." .. Project.EXT .. "$") ~= nil
end

-- What is in library folder `dir`: its subfolders and documents, without hidden
-- entries (and, at `root`, without the internal folders). Folders come by name,
-- documents by `sort`: "name", or most recently changed first. Returns folders,
-- documents; each entry is { name, path, mtime }.
function Library.list(dir, root, sort)
    local folders, docs = {}, {}
    for _, e in ipairs(Storage.list(dir)) do
        if e.name:sub(1, 1) ~= "." then
            if e.mode == "directory" then
                if not (dir == root and Library.INTERNAL[e.name]) then folders[#folders + 1] = e end
            elseif e.mode == "file" and Library.isDocument(e.name) then
                docs[#docs + 1] = e
            end
        end
    end
    local function byName(a, b) return a.name:lower() < b.name:lower() end
    table.sort(folders, byName)
    if sort == "name" then
        table.sort(docs, byName)
    else
        table.sort(docs, function(a, b)
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return byName(a, b)
        end)
    end
    return folders, docs
end

-- Move the file or folder at `path` into folder `dir`, under a free name.
-- Returns the new path, or nil, err.
function Library.move(path, dir)
    if Storage.dirName(path) == dir then return path end
    if Storage.within(dir, path) then return nil, "a folder cannot go inside itself" end
    local base = Storage.baseName(path)
    local target
    if Storage.isDir(path) then
        target = Storage.join(dir, base)
        local n = 2
        while Storage.exists(target) do target = Storage.join(dir, string.format("%s (%d)", base, n)); n = n + 1 end
    else
        target = Storage.uniquePath(dir, Storage.stem(path), Project.EXT)
    end
    local ok, err = os.rename(path, target)
    if not ok then return nil, err end
    return target
end

-- Copy the document at `path` next to it under a free name. Returns the new
-- path, or nil, err.
function Library.duplicate(path)
    local target = Storage.uniquePath(Storage.dirName(path), Storage.stem(path), Project.EXT)
    local ok, err = Storage.copyFile(path, target)
    if not ok then return nil, err end
    return target
end

-- A short, stable code for a path (FNV-1a), used to name its cached thumbnail.
function Library.pathCode(path)
    local h = bit.tobit(2166136261)
    for i = 1, #path do
        h = bit.bxor(h, path:byte(i))
        h = bit.tobit(bit.lshift(h, 24) + h * 403)   -- h * 16777619, kept to 32 bits
    end
    return bit.tohex(h)
end

-- The cached thumbnail file name for a document: its path code, when it last
-- changed and the thumbnail size, so any change to the file makes a new one.
function Library.thumbName(path, mtime, w, h)
    return string.format("%s-%d-%dx%d.png", Library.pathCode(path), mtime or 0, w, h)
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
