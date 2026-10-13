-- Tests for the notebooks on a Bookshelf shelf (ink/bookshelf.lua): the
-- library walk (notebooks only, across folders, without drawings, hidden files
-- or Ink Away's own folders), the records and their paths, each notebook's
-- cover look (its own style and colour, its tab colour, the default) and how
-- it is kept, the source spec Bookshelf gets (a new shelf faces its notebooks
-- out, a reader's own choices stay, a long press opens the cover sheet), the
-- cover queue (nothing kept for notebooks that are gone), and registering with
-- and without Bookshelf.
-- Files go to a scratch folder.
-- Run from the plugin root with:  luajit tests/bookshelf.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Library = require("ink/library")
local Folder = require("ink/folder")
local Cover = require("ink/notebookcover")
local Shelf = require("ink/bookshelf")
local Palette = require("ink/palette")

-- KOReader's settings, for the default cover style
local SETTINGS = {}
_G.G_reader_settings = { readSetting = function(_, k) return SETTINGS[k] end,
    saveSetting = function(_, k, v) SETTINGS[k] = v end }

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
    -- a notebook that is gone is not remembered
    os.rename(ROOT .. "/Physics.inkaway", ROOT .. "/Physics.away")
    Shelf.notebooks(ROOT)
    os.rename(ROOT .. "/Physics.away", ROOT .. "/Physics.inkaway")
    reads = 0
    Shelf.notebooks(ROOT)
    ok(reads == 1, "notebooks: what was known of a gone file is dropped, so it is read when back")
    Library.isNotebookFile = real

    ok(#Shelf.notebooks(ROOT .. "/missing") == 0, "notebooks: a missing library is an empty shelf")
    ok(#Shelf.notebooks(nil) == 0, "notebooks: no library at all is an empty shelf")

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
    ok(rec.cover_image_path == "/c/cover.png" and rec.has_cover == true, "record: the cover file, said to be there")
    ok(rec.format == "INKAWAY", "record: an upper case format for the Format filter")
    ok(rec.added_time == 1700000000 and rec.last_opened == 1700000000, "record: times for the sorts")
    local bare = Shelf.record({ path = p, name = "Maths", mtime = 1 })
    ok(bare.cover_image_path == nil and bare.has_cover == false, "record: no cover until one is drawn, said so")

    local a = Shelf.coverName(p, 100, "abc1")
    ok(a:match("^%x+%-100%-abc1%.png$") ~= nil, "coverName: path code, change time, look code, png")
    ok(Shelf.coverName(p, 101, "abc1") ~= a, "coverName: an edited notebook gets a new cover")
    ok(Shelf.coverName(p, 100, "abc2") ~= a, "coverName: a restyled notebook gets a new cover")
    ok(Shelf.coverName(ROOT .. "/Other.inkaway", 100, "abc1") ~= a, "coverName: each notebook its own")
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
        render = function(path, file, look, view)
            Q.renders[#Q.renders + 1] = { path = path, look = look, view = view }
            return render(path, file, look, view)
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
    local nb = { path = ROOT .. "/Physics.inkaway", name = "Physics", mtime = 50, key = "k1",
        look = { style = "page" } }
    ok(Q.covers.get(nb, dir) == nil, "covers: none yet, so none given")
    ok(#Q.jobs == 1, "covers: and one is queued")
    ok(Q.covers.get(nb, dir) == nil and #Q.jobs == 1, "covers: asked again, it is not queued twice")
    Q.run()
    ok(#Q.renders == 1 and Q.renders[1].view == nil, "covers: drawn in the background, without a view")
    ok(Q.changed == 1, "covers: the shelf redraws once it lands")
    local file = Q.covers.get(nb, dir)
    ok(file == Storage.join(dir, Shelf.coverName(nb.path, 50, "k1")), "covers: then given")
    ok(Q.renders[1].look == nb.look, "covers: drawn in the notebook's look")
    ok(#Q.jobs == 0, "covers: and nothing more is queued")

    -- the notebook changes: a new cover; the old one stays for Bookshelf's
    -- records that still point at it, until it is pruned as stale
    local nb2 = { path = nb.path, name = "Physics", mtime = 60, key = "k1" }
    ok(Q.covers.get(nb2, dir) == nil, "covers: an edited notebook waits for its new cover")
    Q.run()
    ok(Q.covers.get(nb2, dir) ~= nil, "covers: the new cover is drawn")
    ok(Storage.exists(file), "covers: the old one is not deleted at once")
    local now = os.time()
    Q.covers.prune({ nb2 }, dir, now)
    ok(Storage.exists(file), "prune: a fresh old cover is kept a while")
    Q.covers.prune({ nb2 }, dir, now + Shelf.STALE_AFTER + 5)
    ok(not Storage.exists(file) and Q.covers.get(nb2, dir) ~= nil, "prune: then it goes, the current one stays")
    -- restyled: a new cover too, the old style's pruned later
    local nb3 = { path = nb.path, name = "Physics", mtime = 60, key = "k2" }
    local before3 = Q.covers.get(nb2, dir)
    ok(Q.covers.get(nb3, dir) == nil, "covers: a restyled notebook waits for its new cover")
    Q.run()
    ok(Q.covers.get(nb3, dir) ~= nil, "covers: drawn in its new style")
    Q.covers.prune({ nb3 }, dir, now + Shelf.STALE_AFTER + 5)
    ok(not Storage.exists(before3), "prune: the old style's goes once stale")

    -- many notebooks: one at a time, one redraw for the run
    Q.changed = 0
    local drawn = #Q.renders
    for i = 1, 4 do Q.covers.get({ path = ROOT .. "/n" .. i .. ".inkaway", name = "n", mtime = 1 }, dir) end
    ok(#Q.jobs == 1, "covers: a run of covers starts one job")
    Q.run()
    ok(#Q.renders == drawn + 4, "covers: every queued cover is drawn")
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
    local later = os.time() + Shelf.STALE_AFTER + 5
    Q.covers.prune({ live }, dir, later)
    ok(Q.covers.get(live, dir) ~= nil, "prune: a notebook's cover stays")
    ok(not Storage.exists(Storage.join(dir, Shelf.coverName(gone.path, 1))), "prune: a gone notebook's goes")
    writeAll(Storage.join(dir, Library.pathCode(gone.path) .. "-7.png"), "old")
    writeAll(Storage.join(dir, "half.png.tmp"), "x")
    Q.covers.prune({ live }, dir, later)
    ok(not Storage.exists(Storage.join(dir, Library.pathCode(gone.path) .. "-7.png")),
        "prune: covers named the earlier way go too")
    ok(not Storage.exists(Storage.join(dir, "half.png.tmp")), "prune: half-written covers go too")
    -- failed covers of gone notebooks are forgotten
    F.covers.forgetGone({})
    ok(next(F.covers.failed) == nil, "forgetGone: nothing kept for notebooks that are gone")
    ok(Storage.exists(Storage.join(dir, "notes.txt")), "prune: other files are left alone")

    -- closing a notebook opened from the shelf: drawn now, by its view
    local real = ROOT .. "/Physics.inkaway"
    Q.changed = 0
    local before = #Q.renders
    local view = {}
    Q.covers.redraw(real, view)
    ok(#Q.renders == before + 1 and Q.renders[#Q.renders].view == view, "redraw: drawn by the closing view")
    local look = Shelf.lookOf(real)
    ok(Q.renders[#Q.renders].look.style == look.style, "redraw: in the notebook's look")
    ok(Q.covers.get({ path = real, name = "Physics", mtime = Storage.mtime(real), key = Shelf.lookKey(look) }, dir) ~= nil,
        "redraw: the cover for the saved notebook")
    ok(Q.changed == 1, "redraw: the shelf redraws")
end

------------------------------------------------------------------------------
-- Looks: style and colour
------------------------------------------------------------------------------
do
    local p = ROOT .. "/School/Maths.inkaway"
    local look = Shelf.lookOf(p)
    ok(look.style == Cover.DEFAULT and not look.own_style, "look: the default style")
    ok(Palette.sameColor(look.colour, Cover.boardOf(p)) and not look.own_colour and look.tab == nil,
        "look: no tab colour, so one picked from its path")

    Folder.update(ROOT .. "/School", function(d) d.colors["Maths.inkaway"] = { 0, 80, 208 } end)
    look = Shelf.lookOf(p)
    ok(Palette.sameColor(look.colour, { 0, 80, 208 }) and Palette.sameColor(look.tab, { 0, 80, 208 }),
        "look: its tab colour by default")

    Shelf.setDefaultStyle("legal")
    ok(Shelf.defaultStyle() == "legal" and Shelf.lookOf(p).style == "legal", "look: a new default style")
    Shelf.setDefaultStyle("nonsense")
    ok(Shelf.defaultStyle() == Cover.DEFAULT, "look: a style that isn't one is the default")

    Shelf.setLook(p, "kraft")
    look = Shelf.lookOf(p)
    ok(look.style == "kraft" and look.own_style, "setLook: its own style")
    Shelf.setLook(p, nil, { 128, 0, 176 })
    look = Shelf.lookOf(p)
    ok(look.style == "kraft" and Palette.sameColor(look.colour, { 128, 0, 176 }) and look.own_colour,
        "setLook: its own colour, its style kept")
    ok(Palette.sameColor(look.tab, { 0, 80, 208 }), "setLook: the tab colour is still known")
    local k1 = Shelf.lookKey(look)
    Shelf.setLook(p, nil, false)
    look = Shelf.lookOf(p)
    ok(Palette.sameColor(look.colour, { 0, 80, 208 }) and not look.own_colour, "setLook: back to the tab colour")
    ok(Shelf.lookKey(look) ~= k1, "lookKey: another colour, another key")
    ok(Shelf.lookKey({ style = "page", colour = { 1, 2, 3 } }) ~= Shelf.lookKey({ style = "kraft", colour = { 1, 2, 3 } }),
        "lookKey: another style, another key")
    Shelf.setLook(p, false)
    ok(not Shelf.lookOf(p).own_style, "setLook: back to the default style")
    ok(Folder.load(ROOT .. "/School").covers["Maths.inkaway"] == nil, "setLook: nothing left kept for it")

    -- kept in the binder, so it follows a rename and is forgotten with the file
    Shelf.setLook(p, "composition", { 1, 2, 3 })
    Folder.update(ROOT .. "/School", function(d) Folder.rename(d, "Maths.inkaway", "Algebra.inkaway") end)
    local d = Folder.load(ROOT .. "/School")
    ok(d.covers["Algebra.inkaway"] and d.covers["Algebra.inkaway"].style == "composition"
        and d.covers["Maths.inkaway"] == nil, "binder: a rename keeps the cover")
    Folder.update(ROOT .. "/School", function(dd) Folder.forget(dd, "Algebra.inkaway") end)
    ok(Folder.load(ROOT .. "/School").covers["Algebra.inkaway"] == nil, "binder: a forgotten document's cover goes")
    Folder.update(ROOT .. "/School", function(dd) dd.colors = {}; dd.covers = {} end)
    Shelf.setDefaultStyle("page")

    -- a binder that isn't one is no cover at all
    writeAll(ROOT .. "/School/.inkaway-folder", "return { covers = 5, colors = { ['Maths.inkaway'] = 'red' } }")
    look = Shelf.lookOf(p)
    ok(look.style == Cover.DEFAULT and Palette.sameColor(look.colour, Cover.boardOf(p)), "look: a bad binder is ignored")
    os.remove(ROOT .. "/School/.inkaway-folder")
end

------------------------------------------------------------------------------
-- The source spec
------------------------------------------------------------------------------
do
    local opened
    local Q = newQueue(writeCover)
    local chosen
    local spec = Shelf.spec{
        root = function() return ROOT end,
        covers = Q.covers,
        open = function(path) opened = path end,
        choose = function(path) chosen = path end,
    }
    ok(spec.api == 1, "spec: written for source API 1")
    ok(spec.remote_prefix == "inkaway://", "spec: notebooks are under a prefix of their own")
    ok(spec.label() == "Ink Away notebooks", "spec: its name in the source picker")
    ok(spec.available() == true, "spec: always available")
    ok(type(spec.list) == "function" and spec.fetch == nil, "spec: list mode, so Bookshelf sorts, filters and draws spines")
    ok(spec.sort_default[1].key == "last_opened" and spec.sort_default[1].reverse == true,
        "spec: a new shelf starts newest first")

    local recs = spec.list({ kind = Shelf.ID })
    ok(#recs == 0, "list: a notebook waits for its cover before it joins the shelf")
    ok(#Q.jobs > 0, "list: and its cover is on the way")
    Q.run()
    recs = spec.list({ kind = Shelf.ID })
    ok(#recs == 3, "list: a record per notebook once covered: " .. #recs)
    ok(recs[1].title == "Maths", "list: newest first")
    local covered = 0
    for _, r in ipairs(recs) do if r.cover_image_path and Storage.exists(r.cover_image_path) then covered = covered + 1 end end
    ok(covered == 3, "list: every notebook with its cover")
    -- one whose cover can't be drawn still joins, without one
    local F2 = newQueue(function() return false end)
    local fspec = Shelf.spec{ root = function() return ROOT end, covers = F2.covers, open = function() end }
    fspec.list({ kind = Shelf.ID }); F2.run()
    local frecs = fspec.list({ kind = Shelf.ID })
    ok(#frecs == 3 and frecs[1].has_cover == false, "list: a notebook whose cover fails still shows")

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
    spec.info(recs[1])
    ok(chosen == ROOT .. "/School/Maths.inkaway", "info: a long press opens the notebook's cover sheet")
    chosen = nil
    spec.info({ filepath = "/books/Emma.epub" })
    ok(chosen == nil, "info: not for a book that isn't ours")

    -- each record's cover in the notebook's look
    Shelf.setLook(ROOT .. "/Physics.inkaway", "hardcover")
    Q.renders = {}
    spec.list({ kind = Shelf.ID })
    Q.run()
    local styled
    for _, r in ipairs(Q.renders) do if r.path == ROOT .. "/Physics.inkaway" then styled = r.look end end
    ok(styled and styled.style == "hardcover", "list: a restyled notebook's cover is drawn again in its style")
    Shelf.setLook(ROOT .. "/Physics.inkaway", false)

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
    ok(Shelf.registered == true, "register: Ink Away knows Bookshelf is there")
    -- redrawing the shelf drops a Spines shelf's kept list first
    local asked = 0
    local live = { _widget = { _spine_fetch_cache = { items = {} } } }
    function live:sourceChanged(id) asked = asked + (id == Shelf.ID and 1 or 0) end
    Shelf.redrawShelf(live)
    ok(live._widget._spine_fetch_cache == nil and asked == 1, "redrawShelf: a fresh listing, then the redraw")
    local bare = {}
    function bare:sourceChanged() asked = asked + 1 end
    Shelf.redrawShelf(bare)
    ok(asked == 2, "redrawShelf: without a shelf on screen it only asks for the redraw")
    ok(type(got.spec.info) == "function", "register: a long press has a cover sheet")
    -- closing lets go of the view: the hook clears itself
    local covers = Shelf.covers
    Shelf.covers = { redraw = function() end }
    view.after_close()
    ok(view.after_close == nil, "register: the close hook lets go of the view once run")
    Shelf.covers = covers
end

TestEnv.cleanup()
print(string.format("bookshelf: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
