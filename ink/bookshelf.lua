--[[
Ink Away's notebooks on a shelf of the Bookshelf plugin (AndyHazz's
bookshelf.koplugin), through the shelf source interface it offers other plugins
(its SOURCE_API.md, version 1). The reader adds a shelf, picks "Ink Away
notebooks" as its source, and every notebook in the library stands on it face
out, on a cover drawn from its first page (ink/notebookcover.lua). A tap opens
the notebook in Ink Away.

Nothing here runs without Bookshelf: register() looks for it and gives up
quietly. The listing, the records and the cover queue are plain Lua with the
KOReader parts handed in, so the headless tests drive them.
]]

local Library = require("ink/library")
local Storage = require("ink/storage")

local Shelf = {}

-- The source id a Bookshelf shelf stores. Never change it: shelves readers made
-- would stop finding their notebooks.
Shelf.ID = "inkaway_notebooks"

-- How deep the library walk goes into folders.
Shelf.MAX_DEPTH = 8

-- What a notebook's path starts with on the shelf. Bookshelf takes a record
-- under a prefix of its own for one that is not a book file: it then never
-- rebuilds it from the file (KOReader can't read a notebook, so the preview
-- panel would lose the cover and title) and offers no book file actions for it.
Shelf.PREFIX = "inkaway://"

-- The shelf path of the notebook at `path`, and back (nil for one not ours).
function Shelf.shelfPath(path) return Shelf.PREFIX .. path end
function Shelf.notebookPath(filepath)
    if type(filepath) ~= "string" or filepath:sub(1, #Shelf.PREFIX) ~= Shelf.PREFIX then return nil end
    return filepath:sub(#Shelf.PREFIX + 1)
end

-- The cover cache folder's name, under Ink Away's cache folder.
Shelf.COVER_DIR = "covers"

-- Whether each document is a notebook, by path, kept while its file is
-- unchanged: { mtime, notebook }. Asked on every redraw of the shelf, so a
-- document's start is read once, not each time.
local kinds = {}

-- Is the document at `path` (changed at `mtime`) a notebook? Cached by mtime.
local function isNotebook(path, mtime)
    local k = kinds[path]
    if k and k.mtime == mtime then return k.notebook end
    local nb = Library.isNotebookFile(path)
    kinds[path] = { mtime = mtime, notebook = nb }
    return nb
end

-- Every notebook in library folder `root` and its folders, as { path, name,
-- mtime }, newest first. Hidden entries and Ink Away's own folders (exports,
-- downloaded pictures) are left out, as the library leaves them out.
function Shelf.notebooks(root)
    local out = {}
    local function walk(dir, depth)
        local folders, docs = Library.list(dir, root)
        for _, e in ipairs(docs) do
            if isNotebook(e.path, e.mtime) then
                out[#out + 1] = { path = e.path, name = Storage.stem(e.path), mtime = e.mtime }
            end
        end
        if depth < Shelf.MAX_DEPTH then
            for _, f in ipairs(folders) do walk(f.path, depth + 1) end
        end
    end
    if root and Storage.isDir(root) then walk(root, 1) end
    table.sort(out, function(a, b)
        if a.mtime ~= b.mtime then return a.mtime > b.mtime end
        return a.path < b.path
    end)
    return out
end

-- Forget what is known about the document at `path` (all of them when nil).
function Shelf.forget(path)
    if path then kinds[path] = nil else kinds = {} end
end

-- The cover file name for a notebook: its path code and when it last changed,
-- so an edited notebook gets a new cover and the shelf never shows a stale one.
function Shelf.coverName(path, mtime)
    return string.format("%s-%d.png", Library.pathCode(path), mtime or 0)
end

-- The record Bookshelf shows for notebook `nb` ({ path, name, mtime }), with
-- `cover` (a PNG path) when one is drawn. Its path (under Shelf.PREFIX) is the
-- notebook's identity; its name is the title on the spine and under the cover.
function Shelf.record(nb, cover)
    return {
        filepath = Shelf.shelfPath(nb.path),
        title = nb.name,
        display_title = nb.name,
        cover_image_path = cover,
        format = "INKAWAY",
        added_time = nb.mtime,
        last_opened = nb.mtime,
        last_read_time = nb.mtime,
        inkaway_notebook = true,
    }
end

-- The cover queue. `opts` gives the KOReader parts: cacheDir() (made if
-- missing), render(path, file, view) drawing a notebook's cover to PNG `file`,
-- its page by Ink Away view `view` when given (returns ok), schedule(seconds, fn), unschedule(fn) and changed() (the
-- shelf redraws). Covers are drawn one at a time between redraws, newest
-- notebook first, so the shelf stays responsive while a library is covered.
function Shelf.newCovers(opts)
    local C = { queue = {}, queued = {}, failed = {} }

    -- The cover folder, or nil when it can't be made.
    function C.dir()
        local base = opts.cacheDir()
        if not base then return nil end
        local dir = Storage.join(base, Shelf.COVER_DIR)
        return Storage.ensureDir(dir) and dir or nil
    end

    -- The redraw after covers land, once for a run of them.
    local function changed() opts.changed() end

    -- Draw the next queued cover, then come back for the one after.
    local function step()
        local nb = table.remove(C.queue, 1)
        if not nb then return end
        C.queued[nb.path] = nil
        local dir = C.dir()
        if dir then
            local file = Storage.join(dir, Shelf.coverName(nb.path, nb.mtime))
            if opts.render(nb.path, file) then
                C.drop(nb.path, file)
                opts.unschedule(changed)
                opts.schedule(#C.queue > 0 and 1 or 0.1, changed)
            else
                C.failed[nb.path] = nb.mtime   -- not again until the notebook changes
            end
        end
        if #C.queue > 0 then opts.schedule(0.05, step) end
    end
    C.step = step

    -- The cover file for `nb` if it is drawn, else nil, and `nb` queued.
    function C.get(nb, dir)
        local file = dir and Storage.join(dir, Shelf.coverName(nb.path, nb.mtime))
        if file and Storage.exists(file) then return file end
        if dir and not C.queued[nb.path] and C.failed[nb.path] ~= nb.mtime then
            C.queued[nb.path] = true
            C.queue[#C.queue + 1] = nb
            if #C.queue == 1 then opts.schedule(0.2, step) end
        end
        return nil
    end

    -- Draw the cover of the notebook at `path` now with Ink Away view `view`
    -- (closing on it, so text and pictures are drawn too), then redraw the shelf.
    function C.redraw(path, view)
        local dir, mtime = C.dir(), Storage.mtime(path)
        if dir and mtime then
            local file = Storage.join(dir, Shelf.coverName(path, mtime))
            if opts.render(path, file, view) then
                C.drop(path, file)
                C.failed[path] = nil
            end
        end
        changed()
    end

    -- Delete the covers of the notebook at `path`, except `keep`.
    function C.drop(path, keep)
        local dir = C.dir()
        if not dir then return end
        local code = Library.pathCode(path) .. "-"
        for _, e in ipairs(Storage.list(dir)) do
            if e.name:sub(1, #code) == code and e.path ~= keep then os.remove(e.path) end
        end
    end

    -- Delete covers of notebooks no longer in `nbs` (renamed, moved or deleted).
    function C.prune(nbs, dir)
        if not dir then return end
        local live = {}
        for _, nb in ipairs(nbs) do live[Library.pathCode(nb.path)] = true end
        for _, e in ipairs(Storage.list(dir)) do
            local code = e.name:match("^(%x+)%-%d+%.png$")
            if code and not live[code] then os.remove(e.path) end
        end
    end

    return C
end

-- The source spec Bookshelf is given. `opts`: root() (the library folder),
-- covers (from newCovers), open(path) (opens the notebook in Ink Away) and
-- `_` (gettext).
function Shelf.spec(opts)
    local _ = opts._ or function(s) return s end
    local pruned = false
    return {
        api = 1,
        remote_prefix = Shelf.PREFIX,
        label = function() return _("Ink Away notebooks") end,
        available = function() return true end,
        sort_default = { { key = "last_opened", reverse = true } },
        -- every notebook in the library, with its cover once drawn
        list = function()
            local nbs = Shelf.notebooks(opts.root())
            local dir = opts.covers.dir()
            if not pruned then pruned = true; opts.covers.prune(nbs, dir) end
            local out = {}
            for i, nb in ipairs(nbs) do out[i] = Shelf.record(nb, opts.covers.get(nb, dir)) end
            return out
        end,
        -- A new shelf of notebooks stands them all face out on the plank, where
        -- the cover shows (a standing spine only has room for the name). Only
        -- what the reader has not chosen, as this also runs when a shelf's
        -- source is changed to ours.
        new_shelf = function(draft)
            if draft.view_mode == nil then draft.view_mode = "spines" end
            if draft.spine_face_out == nil then draft.spine_face_out = "all" end
            if draft.label == nil or draft.label == "New shelf" or draft.label == _("New shelf") then
                draft.label = _("Notebooks")
            end
        end,
        owns = function(book)
            return type(book) == "table" and Shelf.notebookPath(book.filepath) ~= nil
        end,
        open = function(book)
            local path = Shelf.notebookPath(book.filepath)
            if path then opts.open(path) end
            return true
        end,
        -- a book changed (any book, or all of them when nil); only ours matter
        invalidate = function(filepath)
            if filepath == nil then Shelf.forget() return end
            local path = Shelf.notebookPath(filepath)
            if path then Shelf.forget(path) end
        end,
    }
end

-- Put the notebooks on Bookshelf, when it is there and new enough. `plugin` is
-- Ink Away's plugin (its openCanvas opens a notebook). Returns whether the
-- source was registered; false, quietly, without Bookshelf.
function Shelf.register(ui, plugin)
    local bs = ui and ui.bookshelf
    if not (type(bs) == "table" and type(bs.registerSource) == "function"
            and (tonumber(bs.SOURCE_API) or 0) >= 1) then
        return false
    end
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")
    local covers = Shelf.covers
    if not covers then
        covers = Shelf.newCovers{
            cacheDir = Storage.cacheDir,
            render = function(path, file, view) return require("ink/notebookcover").write(path, file, view) end,
            schedule = function(s, fn) UIManager:scheduleIn(s, fn) end,
            unschedule = function(fn) UIManager:unschedule(fn) end,
            changed = function() pcall(function() bs:sourceChanged(Shelf.ID) end) end,
        }
        Shelf.covers = covers
    end
    local ok = pcall(function()
        local done = bs:registerSource(Shelf.ID, Shelf.spec{
            _ = _,
            root = function()
                local G = rawget(_G, "G_reader_settings")
                return Library.root(G and G:readSetting("inkaway_library_dir"))
            end,
            covers = covers,
            open = function(path)
                local view = plugin:openCanvas(nil, path)
                -- back on the shelf, the notebook's cover drawn by the view
                -- it was open in
                if view then view.after_close = function() covers.redraw(path, view) end end
            end,
        })
        if not done then error("refused") end
    end)
    return ok
end

return Shelf
