--[[
A book's ink, kept as inkaway.lua in the book's own KOReader folder: the same
".sdr" folder as the reader's settings for the book, wherever the "Book metadata
location" setting puts it (next to the book, in KOReader's docsettings folder,
or by the book's hash). { version, items = { { op, a }, ... }, notes } (see
ink/reader/place.lua for the items; notes is the path of the book's notebook,
see ink/reader/booknotes.lua).

The folder is KOReader's. Ink Away only adds its own file to it and never
touches the reader's files, so a book that already has a folder keeps
everything in it. The previous copy is kept as inkaway.lua.old (as KOReader
keeps its own), and a new one is written through a temporary file, so neither a
power cut nor a damaged file loses the ink: a file that cannot be read is put
aside as inkaway.lua.unreadable, never written over. A file from a newer Ink
Away is shown but not changed.

KOReader moves, copies and deletes the folder's own files with the book, but
not a plugin's (DocSettings.updateLocation). BookInk.installFollow makes the ink
follow the book through those too, and BookInk.locate brings it back beside the
reader's settings when they moved some other way (the location setting
changed), so no stray folder is left behind.
]]

local Project = require("ink/project")
local Storage = require("ink/storage")
local logger = require("logger")

local BookInk = {}

BookInk.FILE = "inkaway.lua"
BookInk.VERSION = 1

local SUFFIXES = { "", ".old" }

function BookInk.new()
    return { version = BookInk.VERSION, items = {} }
end

-- The file for a sidecar folder.
function BookInk.path(sidecar_dir)
    return sidecar_dir and sidecar_dir ~= "" and (sidecar_dir .. "/" .. BookInk.FILE) or nil
end

local function isFile(p)
    if not p then return false end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then return lfs.attributes(p, "mode") == "file" end
    return Storage.exists(p)
end

-- Is there ink (or its backup) in this folder?
function BookInk.exists(sidecar_dir)
    local p = BookInk.path(sidecar_dir)
    return p ~= nil and (isFile(p) or isFile(p .. ".old"))
end

local function readFile(p)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function decode(s)
    local ok, data = pcall(Project.decode, s)
    if ok and type(data) == "table" and type(data.items) == "table" then return data end
end

-- Make the folder and any missing parents (the docsettings location mirrors
-- the whole path of the book).
local function makePath(dir)
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then pcall(util.makePath, dir) end
    if Storage.ensureDir(dir) then return true end
    local parent = dir:match("^(.+)/[^/]+$")
    if parent and parent ~= dir then makePath(parent) end
    return Storage.ensureDir(dir)
end

-- The book's ink, or a fresh, empty one.
function BookInk.load(sidecar_dir)
    local p = BookInk.path(sidecar_dir)
    if not p then return BookInk.new() end
    for _i, sfx in ipairs(SUFFIXES) do
        local s = readFile(p .. sfx)
        if s then
            local data = decode(s)
            if data then
                if (tonumber(data.version) or 1) > BookInk.VERSION then data.read_only = true end
                return data
            end
            -- damaged: kept aside (never over an earlier one), so the next
            -- save cannot write over it
            local aside, n = p .. ".unreadable", 1
            while isFile(aside) do n = n + 1; aside = p .. ".unreadable." .. n end
            logger.warn("Ink Away: the book's ink could not be read, kept as", aside)
            os.rename(p .. sfx, aside)
        end
    end
    return BookInk.new()
end

-- Keep it. One with no ink and no book notes removes the files, so such a book
-- leaves none. Returns whether it is kept.
function BookInk.save(sidecar_dir, data)
    local p = BookInk.path(sidecar_dir)
    if not p or data.read_only then return false end
    if #data.items == 0 and not data.notes then
        os.remove(p)
        os.remove(p .. ".old")
        return true
    end
    if not makePath(sidecar_dir) then return false end
    local stored = { version = BookInk.VERSION, items = data.items, notes = data.notes }
    if isFile(p) then
        os.remove(p .. ".old")
        os.rename(p, p .. ".old")
    end
    local ok = Storage.writeAtomic(p, Project.encode(stored))
    if not ok and isFile(p .. ".old") and not isFile(p) then os.rename(p .. ".old", p) end
    return ok and true or false
end

-- Keep it in the first of `dirs` that takes it. Returns that folder, or nil.
function BookInk.saveAny(dirs, data)
    for _i, dir in ipairs(dirs) do
        local ok, kept = pcall(BookInk.save, dir, data)
        if ok and kept then return dir end
    end
    return nil
end

------------------------------------------------------------------------------
-- Where the folder is
------------------------------------------------------------------------------

local function docSettings()
    local ok, DocSettings = pcall(require, "docsettings")
    return ok and DocSettings or nil
end

-- The folders the book's ink belongs in, best first: where KOReader keeps the
-- book's settings now, or for a book never opened where it will (next to the
-- book first, KOReader's docsettings folder if the book's storage is
-- read-only), as KOReader places its custom covers.
function BookInk.dirsFor(doc_path)
    local DocSettings = docSettings()
    if not (DocSettings and doc_path) then return {} end
    if DocSettings.getCustomLocationCandidates then
        local ok, c = pcall(DocSettings.getCustomLocationCandidates, DocSettings, doc_path)
        if ok and type(c) == "table" and c[1] then return c end
    end
    local ok, d = pcall(DocSettings.getSidecarDir, DocSettings, doc_path)
    return ok and d and d ~= "" and { d } or {}
end

-- Every folder KOReader may have kept the book's settings in, whatever the
-- location setting was then.
function BookInk.allDirsFor(doc_path)
    local DocSettings = docSettings()
    if not (DocSettings and doc_path) then return {} end
    local locs = { "doc", "dir" }
    local hok, hash = pcall(function() return DocSettings.isHashLocationEnabled() end)
    if hok and hash then locs[#locs + 1] = "hash" end
    local out, seen = {}, {}
    for _i, loc in ipairs(locs) do
        local ok, d = pcall(DocSettings.getSidecarDir, DocSettings, doc_path, loc)
        if ok and d and d ~= "" and not seen[d] then seen[d] = true; out[#out + 1] = d end
    end
    return out
end

-- The folder holding the book's ink now, or nil.
function BookInk.find(doc_path)
    for _i, d in ipairs(BookInk.dirsFor(doc_path)) do
        if BookInk.exists(d) then return d end
    end
    for _i, d in ipairs(BookInk.allDirsFor(doc_path)) do
        if BookInk.exists(d) then return d end
    end
end

-- Remove the folder if nothing is left in it, as KOReader tidies its own.
local function tidy(dir)
    local DocSettings = docSettings()
    if DocSettings and DocSettings.removeSidecarDir then pcall(DocSettings.removeSidecarDir, dir)
    else pcall(os.remove, dir) end
end

-- Two ink files as one: every item of both, once.
local function merge(into, from)
    local seen = {}
    for _i, item in ipairs(into.items) do seen[Project.encode(item)] = true end
    for _i, item in ipairs(from.items) do
        if not seen[Project.encode(item)] then into.items[#into.items + 1] = item end
    end
    return into
end

-- Bring the ink in folder `src` to folder `dst` (a copy when `copy`). Ink
-- already in `dst` is kept, the two put together. Returns whether it is there.
function BookInk.transfer(src, dst, copy)
    if src == dst then return true end
    if BookInk.exists(dst) then
        local into, from = BookInk.load(dst), BookInk.load(src)
        if into.read_only or from.read_only then return false end
        if not BookInk.save(dst, merge(into, from)) then return false end
    else
        if not makePath(dst) then return false end
        for _i, sfx in ipairs(SUFFIXES) do
            local a, b = BookInk.path(src) .. sfx, BookInk.path(dst) .. sfx
            if isFile(a) then
                local moved = not copy and os.rename(a, b)
                if not moved and not Storage.copyFile(a, b) then return false end
            end
        end
    end
    if not copy then
        for _i, sfx in ipairs(SUFFIXES) do os.remove(BookInk.path(src) .. sfx) end
        tidy(src)
    end
    return true
end

-- Where the book's ink is kept: { dir = <folder>, dirs = <folders to try> }.
-- Ink left in another of the book's folders (the location setting was changed
-- since) is brought beside the reader's settings first.
function BookInk.locate(doc_path)
    local dirs = BookInk.dirsFor(doc_path)
    for _i, d in ipairs(dirs) do
        if BookInk.exists(d) then return { dir = d, dirs = dirs } end
    end
    local have = BookInk.find(doc_path)
    if have then
        for _i, d in ipairs(dirs) do
            if BookInk.transfer(have, d, false) then return { dir = d, dirs = dirs } end
        end
        return { dir = have, dirs = dirs }
    end
    return { dir = dirs[1], dirs = dirs }
end

-- Ink follows its book when KOReader moves, renames, copies or deletes it (the
-- file browser, "Move book metadata"...). Once per KOReader run.
function BookInk.installFollow()
    local DocSettings = docSettings()
    if not (DocSettings and DocSettings.updateLocation) or DocSettings._inkaway_follows then return end
    DocSettings._inkaway_follows = true
    local orig = DocSettings.updateLocation
    DocSettings.updateLocation = function(doc_path, new_doc_path, copy)
        local src
        pcall(function() src = BookInk.find(doc_path) end)
        -- deleted: the ink goes with the book, before KOReader removes its folder
        if src and not new_doc_path then
            for _i, sfx in ipairs(SUFFIXES) do os.remove(BookInk.path(src) .. sfx) end
        end
        local r = { orig(doc_path, new_doc_path, copy) }
        if src and new_doc_path then
            local ok, err = pcall(function()
                for _i, d in ipairs(BookInk.dirsFor(new_doc_path)) do
                    if BookInk.transfer(src, d, copy) then return end
                end
            end)
            if not ok then logger.warn("Ink Away: the book's ink could not follow it:", err) end
        end
        return unpack(r)
    end
end

return BookInk
