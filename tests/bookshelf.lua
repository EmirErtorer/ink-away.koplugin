-- Tests for the notebooks on a Bookshelf shelf (ink/bookshelf.lua): the
-- library walk (notebooks only, across folders, without drawings, hidden files
-- or Ink Away's own folders), the records and their paths, the source spec
-- Bookshelf gets (a new shelf faces its notebooks out, a reader's own choices
-- stay), the cover queue, and registering with and without Bookshelf.
-- Files go to a scratch folder.
-- Run from the plugin root with:  luajit tests/bookshelf.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Library = require("ink/library")
local Shelf = require("ink/bookshelf")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function writeAll(path, s)
    local f = assert(io.open(path, "wb"))
    f:write(s)
    f:close()
end

-- A notebook file at `path`, last changed at `stamp` (touch's [[CC]YY]MMDDhhmm).
local function notebookFile(path, stamp)
    os.execute("mkdir -p '" .. Storage.dirName(path) .. "'")
    writeAll(path, Project.serializeNotebook(Notebook.new(600, 800, { style = "lines", size = 40 })))
    if stamp then os.execute("touch -t " .. stamp .. " '" .. path .. "'") end
end

local ROOT = TestEnv.libraryDir() .. "/shelf"
Storage.ensureDir(ROOT)

------------------------------------------------------------------------------
-- The library walk
------------------------------------------------------------------------------
do
    notebookFile(ROOT .. "/Physics.inkaway", "202610010900")
    notebookFile(ROOT .. "/School/Maths.inkaway", "202610030900")
    notebookFile(ROOT .. "/School/Deep/Chemistry.inkaway", "202610020900")
    writeAll(ROOT .. "/Sketch.inkaway", Project.serialize({ w = 10, h = 10, ops = {} }))   -- a drawing
    notebookFile(ROOT .. "/.Hidden.inkaway")
    notebookFile(ROOT .. "/exports/Exported.inkaway")   -- Ink Away's own folder
    writeAll(ROOT .. "/notes.txt", "not a document")

    local nbs = Shelf.notebooks(ROOT)
    ok(#nbs == 3, "notebooks: the three notebooks, across folders: " .. #nbs)
    ok(nbs[1] and nbs[1].name == "Maths", "notebooks: newest first")
    ok(nbs[2] and nbs[2].name == "Chemistry" and nbs[3] and nbs[3].name == "Physics", "notebooks: then older ones")
    local names = {}
    for _, nb in ipairs(nbs) do names[nb.name] = true end
    ok(not names.Sketch, "notebooks: a drawing is not a notebook")
    ok(not names.Hidden and not names[".Hidden"], "notebooks: hidden files are left out")
    ok(not names.Exported, "notebooks: Ink Away's own folders are left out")
    ok(nbs[1].path == ROOT .. "/School/Maths.inkaway", "notebooks: each has its path")
    ok(type(nbs[1].mtime) == "number" and nbs[1].mtime > 0, "notebooks: and when it last changed")

    ok(#Shelf.notebooks(ROOT .. "/missing") == 0, "notebooks: a missing library is an empty shelf")
    ok(#Shelf.notebooks(nil) == 0, "notebooks: no library at all is an empty shelf")

    -- a notebook's kind is read once while its file is unchanged
    local reads = 0
    local real = Library.isNotebookFile
    Library.isNotebookFile = function(p) reads = reads + 1; return real(p) end
    Shelf.notebooks(ROOT)
    ok(reads == 0, "notebooks: unchanged files are not read again")
    Shelf.forget(ROOT .. "/Physics.inkaway")
    Shelf.notebooks(ROOT)
    ok(reads == 1, "notebooks: a forgotten one is read again")
    Shelf.forget()
    reads = 0
    Shelf.notebooks(ROOT)
    ok(reads >= 4, "notebooks: forgetting all reads them all again")
    Library.isNotebookFile = real

    local depth = ROOT .. "/deep"
    for i = 1, Shelf.MAX_DEPTH + 1 do depth = depth .. "/d" .. i end
    notebookFile(depth .. "/TooDeep.inkaway")
    local deep = false
    for _, nb in ipairs(Shelf.notebooks(ROOT)) do if nb.name == "TooDeep" then deep = true end end
    ok(not deep, "notebooks: the walk stops at a sane depth")
end

------------------------------------------------------------------------------
-- Records and paths
------------------------------------------------------------------------------
do
    local p = ROOT .. "/School/Maths.inkaway"
    ok(Shelf.shelfPath(p) == "inkaway://" .. p, "shelfPath: under the prefix")
    ok(Shelf.notebookPath(Shelf.shelfPath(p)) == p, "notebookPath: back to the file")
    ok(Shelf.notebookPath(p) == nil, "notebookPath: a book file is not ours")
    ok(Shelf.notebookPath(nil) == nil and Shelf.notebookPath(5) == nil, "notebookPath: nothing is not ours")

    local rec = Shelf.record({ path = p, name = "Maths", mtime = 1700000000 }, "/c/cover.png")
    ok(rec.filepath == "inkaway://" .. p, "record: its path is the notebook's, under the prefix")
    ok(rec.title == "Maths" and rec.display_title == "Maths", "record: the name is the title")
    ok(rec.cover_image_path == "/c/cover.png", "record: the cover file")
    ok(rec.format == "INKAWAY", "record: an upper case format for the Format filter")
    ok(rec.added_time == 1700000000 and rec.last_opened == 1700000000, "record: times for the sorts")
    ok(Shelf.record({ path = p, name = "Maths", mtime = 1 }).cover_image_path == nil,
        "record: no cover until one is drawn")

    local a = Shelf.coverName(p, 100)
    ok(a:match("^%x+%-100%.png$") ~= nil, "coverName: path code, change time, png")
    ok(Shelf.coverName(p, 101) ~= a, "coverName: an edited notebook gets a new cover")
    ok(Shelf.coverName(ROOT .. "/Other.inkaway", 100) ~= a, "coverName: each notebook its own")
end

------------------------------------------------------------------------------
-- The cover queue
------------------------------------------------------------------------------
-- A queue on a scratch cache folder with a fake clock: `jobs` holds what was
-- scheduled and when, run() runs it all in time order.
local function newQueue(render)
    local cache = TestEnv.libraryDir() .. "/cache" .. tostring(math.random(1e9))
    Storage.ensureDir(cache)
    local Q = { jobs = {}, changed = 0, renders = {}, now = 0 }
    Q.covers = Shelf.newCovers{
        cacheDir = function() return cache end,
        render = function(path, file, view)
            Q.renders[#Q.renders + 1] = { path = path, view = view }
            return render(path, file, view)
        end,
        schedule = function(sec, fn) Q.jobs[#Q.jobs + 1] = { t = Q.now + sec, fn = fn } end,
        unschedule = function(fn)
            for i = #Q.jobs, 1, -1 do if Q.jobs[i].fn == fn then table.remove(Q.jobs, i) end end
        end,
        changed = function() Q.changed = Q.changed + 1 end,
    }
    function Q.run()
        local n = 0
        while #Q.jobs > 0 and n < 100 do
            local first = 1
            for i = 2, #Q.jobs do if Q.jobs[i].t < Q.jobs[first].t then first = i end end
            local job = table.remove(Q.jobs, first)
            Q.now = job.t
            job.fn()
            n = n + 1
        end
    end
    return Q
end
local function writeCover(_, file) writeAll(file, "png"); return true end

do
    local Q = newQueue(writeCover)
    local dir = Q.covers.dir()
    ok(dir ~= nil and Storage.isDir(dir), "covers: the cover folder is made")
    local nb = { path = ROOT .. "/Physics.inkaway", name = "Physics", mtime = 50 }
    ok(Q.covers.get(nb, dir) == nil, "covers: none yet, so none given")
    ok(#Q.jobs == 1, "covers: and one is queued")
    ok(Q.covers.get(nb, dir) == nil and #Q.jobs == 1, "covers: asked again, it is not queued twice")
    Q.run()
    ok(#Q.renders == 1 and Q.renders[1].view == nil, "covers: drawn in the background, without a view")
    ok(Q.changed == 1, "covers: the shelf redraws once it lands")
    local file = Q.covers.get(nb, dir)
    ok(file == Storage.join(dir, Shelf.coverName(nb.path, 50)), "covers: then given")
    ok(#Q.jobs == 0, "covers: and nothing more is queued")

    -- the notebook changes: a new cover, and the old one goes
    local nb2 = { path = nb.path, name = "Physics", mtime = 60 }
    ok(Q.covers.get(nb2, dir) == nil, "covers: an edited notebook waits for its new cover")
    Q.run()
    ok(Q.covers.get(nb2, dir) ~= nil, "covers: the new cover is drawn")
    ok(not Storage.exists(file), "covers: the old one is deleted")

    -- many notebooks: one at a time, one redraw for the run
    Q.changed = 0
    for i = 1, 4 do Q.covers.get({ path = ROOT .. "/n" .. i .. ".inkaway", name = "n", mtime = 1 }, dir) end
    ok(#Q.jobs == 1, "covers: a run of covers starts one job")
    Q.run()
    ok(#Q.renders == 6, "covers: every queued cover is drawn")
    ok(Q.changed == 1, "covers: and the shelf redraws once for the run")

    -- a notebook that can't be drawn isn't tried again until it changes
    local F = newQueue(function() return false end)
    local fdir = F.covers.dir()
    local bad = { path = ROOT .. "/bad.inkaway", name = "bad", mtime = 5 }
    F.covers.get(bad, fdir); F.run()
    ok(#F.renders == 1 and F.changed == 0, "covers: a failed cover is not a redraw")
    F.covers.get(bad, fdir); F.run()
    ok(#F.renders == 1, "covers: nor tried again while unchanged")
    F.covers.get({ path = bad.path, name = "bad", mtime = 6 }, fdir); F.run()
    ok(#F.renders == 2, "covers: but tried once it changes")

    -- covers of notebooks gone from the library are cleared away
    local live = { path = ROOT .. "/live.inkaway", name = "live", mtime = 1 }
    local gone = { path = ROOT .. "/gone.inkaway", name = "gone", mtime = 1 }
    Q.covers.get(live, dir); Q.covers.get(gone, dir); Q.run()
    writeAll(Storage.join(dir, "notes.txt"), "keep")
    Q.covers.prune({ live }, dir)
    ok(Q.covers.get(live, dir) ~= nil, "prune: a notebook's cover stays")
    ok(not Storage.exists(Storage.join(dir, Shelf.coverName(gone.path, 1))), "prune: a gone notebook's goes")
    ok(Storage.exists(Storage.join(dir, "notes.txt")), "prune: other files are left alone")

    -- closing a notebook opened from the shelf: drawn now, by its view
    local real = ROOT .. "/Physics.inkaway"
    Q.changed = 0
    local before = #Q.renders
    local view = {}
    Q.covers.redraw(real, view)
    ok(#Q.renders == before + 1 and Q.renders[#Q.renders].view == view, "redraw: drawn by the closing view")
    ok(Q.covers.get({ path = real, name = "Physics", mtime = Storage.mtime(real) }, dir) ~= nil,
        "redraw: the cover for the saved notebook")
    ok(Q.changed == 1, "redraw: the shelf redraws")
end

------------------------------------------------------------------------------
-- The source spec
------------------------------------------------------------------------------
do
    local opened
    local Q = newQueue(writeCover)
    local spec = Shelf.spec{
        root = function() return ROOT end,
        covers = Q.covers,
        open = function(path) opened = path end,
    }
    ok(spec.api == 1, "spec: written for source API 1")
    ok(spec.remote_prefix == "inkaway://", "spec: notebooks are under a prefix of their own")
    ok(spec.label() == "Ink Away notebooks", "spec: its name in the source picker")
    ok(spec.available() == true, "spec: always available")
    ok(type(spec.list) == "function" and spec.fetch == nil, "spec: list mode, so Bookshelf sorts, filters and draws spines")
    ok(spec.sort_default[1].key == "last_opened" and spec.sort_default[1].reverse == true,
        "spec: a new shelf starts newest first")

    local recs = spec.list({ kind = Shelf.ID })
    ok(#recs == 3, "list: a record per notebook: " .. #recs)
    ok(recs[1].title == "Maths", "list: newest first")
    ok(recs[1].cover_image_path == nil, "list: covers still to draw")
    Q.run()
    recs = spec.list({ kind = Shelf.ID })
    local covered = 0
    for _, r in ipairs(recs) do if r.cover_image_path and Storage.exists(r.cover_image_path) then covered = covered + 1 end end
    ok(covered == 3, "list: every notebook with its cover once drawn")

    -- a new shelf: all face out on the plank, named Notebooks
    local draft = { label = "New shelf", source = { kind = Shelf.ID } }
    spec.new_shelf(draft)
    ok(draft.view_mode == "spines", "new_shelf: the shelf view")
    ok(draft.spine_face_out == "all", "new_shelf: every notebook faces out")
    ok(draft.label == "Notebooks", "new_shelf: named Notebooks")
    -- what the reader chose stays (the hook also runs when a shelf's source changes)
    local mine = { label = "Uni", view_mode = "covers", spine_face_out = false, source = { kind = Shelf.ID } }
    spec.new_shelf(mine)
    ok(mine.view_mode == "covers" and mine.spine_face_out == false and mine.label == "Uni",
        "new_shelf: a reader's own choices stay")

    ok(spec.owns(recs[1]) == true, "owns: a notebook record")
    ok(spec.owns({ filepath = recs[1].filepath }) == true, "owns: one rebuilt from its path alone")
    ok(spec.owns({ filepath = "/books/Emma.epub" }) == false, "owns: not a book")
    ok(spec.owns(nil) == false, "owns: not nothing")

    ok(spec.open(recs[1]) == true, "open: handled, so Bookshelf opens nothing itself")
    ok(opened == ROOT .. "/School/Maths.inkaway", "open: Ink Away opens the notebook's file")
    opened = nil
    spec.open({ filepath = "/books/Emma.epub" })
    ok(opened == nil, "open: a book that isn't ours opens nothing in Ink Away")

    -- invalidate: only our notebooks are forgotten, everything on nil
    local reads = 0
    local real = Library.isNotebookFile
    Library.isNotebookFile = function(p) reads = reads + 1; return real(p) end
    spec.invalidate("/books/Emma.epub")
    spec.list({ kind = Shelf.ID })
    ok(reads == 0, "invalidate: another book's change reads nothing again")
    spec.invalidate(recs[1].filepath)
    spec.list({ kind = Shelf.ID })
    ok(reads == 1, "invalidate: a notebook's change reads that one again")
    reads = 0
    spec.invalidate(nil)
    spec.list({ kind = Shelf.ID })
    ok(reads >= 3, "invalidate: nil reads them all again")
    Library.isNotebookFile = real
end

------------------------------------------------------------------------------
-- Registering
------------------------------------------------------------------------------
do
    local plugin = { openCanvas = function() return {} end }
    ok(Shelf.register(nil, plugin) == false, "register: no ui, no shelf")
    ok(Shelf.register({}, plugin) == false, "register: without Bookshelf it gives up quietly")
    ok(Shelf.register({ bookshelf = {} }, plugin) == false, "register: a Bookshelf without sources")
    local old = { SOURCE_API = 0, registerSource = function() error("not called") end }
    ok(Shelf.register({ bookshelf = old }, plugin) == false, "register: a Bookshelf too old")

    local got = {}
    local bs = { SOURCE_API = 1, sourceChanged = function() end }
    function bs:registerSource(id, spec) got.id, got.spec = id, spec; return true end
    ok(Shelf.register({ bookshelf = bs }, plugin) == true, "register: with Bookshelf")
    ok(got.id == "inkaway_notebooks" and type(got.spec) == "table" and got.spec.api == 1,
        "register: under its fixed id, with the spec")
    local newer = { SOURCE_API = 3 }
    function newer:registerSource() return true end
    ok(Shelf.register({ bookshelf = newer }, plugin) == true, "register: a newer Bookshelf still takes version 1")

    local refused = { SOURCE_API = 1 }
    function refused:registerSource() return false, "no" end
    ok(Shelf.register({ bookshelf = refused }, plugin) == false, "register: refused is not registered")
    local broken = { SOURCE_API = 1 }
    function broken:registerSource() error("boom") end
    ok(Shelf.register({ bookshelf = broken }, plugin) == false, "register: a failing Bookshelf is no error")

    -- opening from the shelf: the view redraws the cover as it closes
    local view = {}
    plugin.openCanvas = function(_, library, path) plugin.args = { library, path }; return view end
    Shelf.register({ bookshelf = bs }, plugin)
    got.spec.open({ filepath = "inkaway://" .. ROOT .. "/Physics.inkaway" })
    ok(plugin.args and plugin.args[1] == nil and plugin.args[2] == ROOT .. "/Physics.inkaway",
        "register: open shows Ink Away on the notebook")
    ok(type(view.after_close) == "function", "register: and the view redraws the shelf when it closes")
end

TestEnv.cleanup()
print(string.format("bookshelf: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
