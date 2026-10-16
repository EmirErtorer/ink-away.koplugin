-- Tests for the drawings on a Bookshelf shelf (ink/drawingshelf.lua): the
-- library walk (drawings only, notebooks left to their own shelf), the frames
-- dealt at random to new drawings (all twelve before any repeats, kept, never
-- dealt again, following a rename), a frame picked by the reader, the source
-- spec (a new shelf faces its drawings out and is called Drawings, a reader's
-- own choices stay, each source owns only its own records, a long press opens
-- the frame sheet), the cover queue (its own folder, a new frame or snapshot
-- gives a new cover, the old one shown meanwhile, unused covers pruned but
-- never the notebooks'), snapshots, and registering with and without
-- Bookshelf.
-- Run from the plugin root with:  luajit tests/drawingshelf.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Folder = require("ink/folder")
local Shelf = require("ink/bookshelf")
local DShelf = require("ink/drawingshelf")
local FrameCover = require("ink/framecover")

local SETTINGS = {}
_G.G_reader_settings = { readSetting = function(_, k) return SETTINGS[k] end,
    saveSetting = function(_, k, v) SETTINGS[k] = v end }

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function writeAll(path, s)
    os.execute("mkdir -p '" .. Storage.dirName(path) .. "'")
    local f = assert(io.open(path, "wb"))
    f:write(s)
    f:close()
end
local function drawingFile(path, stamp)
    writeAll(path, Project.serialize({ w = 600, h = 800, ops = {} }))
    if stamp then os.execute("touch -t " .. stamp .. " '" .. path .. "'") end
end
local function notebookFile(path)
    writeAll(path, Project.serializeNotebook(Notebook.new(600, 800, { style = "lines", size = 40 })))
end

local ROOT = TestEnv.libraryDir() .. "/dshelf"
Storage.ensureDir(ROOT)

-- a fixed sequence for math.random's place
local function seq(...)
    local list, i = { ... }, 0
    return function(n) i = i + 1; local v = list[(i - 1) % #list + 1]; return math.min(n, v) end
end

------------------------------------------------------------------------------
-- The frames
------------------------------------------------------------------------------
do
    local frames = FrameCover.frames()
    ok(#frames == 12, "frames: twelve from the manifest (" .. #frames .. ")")
    local names = FrameCover.names()
    for _, f in ipairs(frames) do ok(names[f], "frames: " .. f .. " has a name") end
    ok(FrameCover.frames()[1] == "baroque" and FrameCover.frames()[12] == "canvas" or FrameCover.frames()[11] == "instant",
        "frames: from old to modern")
    local k, o = FrameCover.lookOf("deco", "emerald")
    ok(k == "deco" and o == "emerald", "frames: a frame and its finish")
    k, o = FrameCover.lookOf("deco", "pink")
    ok(k == "deco" and o == "black", "frames: an unknown finish falls back to the first")
    ok(FrameCover.lookOf(nil) == nil and FrameCover.lookOf("frameless") == nil, "frames: no frame, no look")
end

------------------------------------------------------------------------------
-- The library walk
------------------------------------------------------------------------------
do
    drawingFile(ROOT .. "/Cat.inkaway", "202610010900")
    drawingFile(ROOT .. "/Trips/Beach.inkaway", "202610030900")
    drawingFile(ROOT .. "/Trips/Old/Hill.inkaway", "202610020900")
    notebookFile(ROOT .. "/Physics.inkaway")
    drawingFile(ROOT .. "/.Hidden.inkaway")
    drawingFile(ROOT .. "/exports/Exported.inkaway")
    local ds = Shelf.documents(ROOT, true)
    local names = {}
    for _, d in ipairs(ds) do names[#names + 1] = d.name end
    ok(table.concat(names, ",") == "Beach,Hill,Cat", "walk: the drawings, newest first (" .. table.concat(names, ",") .. ")")
    local nbs = Shelf.notebooks(ROOT)
    ok(#nbs == 1 and nbs[1].name == "Physics", "walk: the notebooks' shelf still sees only its notebook")
    ok(#Shelf.documents(ROOT, true) == 3, "walk: a walk of the notebooks forgets nothing the drawings need")
end

------------------------------------------------------------------------------
-- Frames dealt to new drawings
------------------------------------------------------------------------------
do
    local dir = ROOT .. "/deal"
    local ds = {}
    for i = 1, 14 do
        local p = string.format("%s/D%02d.inkaway", dir, i)
        drawingFile(p)
        ds[#ds + 1] = { path = p }
    end
    ok(DShelf.lookOf(ds[1].path).frame == nil, "deal: a drawing has no frame until the shelf sees it")
    local binders = {}
    local n = DShelf.dealFrames(ds, binders, math.random)
    ok(n == 14, "deal: every new drawing gets one (" .. n .. ")")
    local seen, all = {}, true
    for i = 1, 12 do
        local l = DShelf.lookOf(ds[i].path)
        if not l.frame then all = false else seen[l.frame] = true end
        local okopt = false
        for _, o in ipairs(FrameCover.options(l.frame or "")) do if o == l.option then okopt = true end end
        ok(okopt, "deal: " .. tostring(l.frame) .. " gets one of its own finishes")
    end
    local kinds = 0
    for _ in pairs(seen) do kinds = kinds + 1 end
    ok(all and kinds == 12, "deal: the first twelve get all twelve frames (" .. kinds .. ")")
    ok(binders[dir] ~= nil and binders[dir].covers["D01.inkaway"].frame ~= nil, "deal: the binders are kept up to date")
    local before = DShelf.lookOf(ds[3].path).frame
    ok(DShelf.dealFrames(ds, {}, math.random) == 0, "deal: never dealt again")
    ok(DShelf.lookOf(ds[3].path).frame == before, "deal: a frame stays")
    -- a rename keeps it (the library renames through the binder)
    Folder.update(dir, function(d) Folder.rename(d, "D03.inkaway", "Renamed.inkaway") end)
    os.rename(ds[3].path, dir .. "/Renamed.inkaway")
    ok(DShelf.lookOf(dir .. "/Renamed.inkaway").frame == before, "deal: a renamed drawing keeps its frame")
    -- a notebook's cover choice in the same binder is left alone
    notebookFile(dir .. "/Book.inkaway")
    Shelf.setLook(dir .. "/Book.inkaway", "kraft")
    DShelf.setLook(ds[1].path, "museum", "oak")
    ok(Shelf.lookOf(dir .. "/Book.inkaway").style == "kraft", "deal: a notebook's cover stays its own")
    local l = DShelf.lookOf(ds[1].path)
    ok(l.frame == "museum" and l.option == "oak", "pick: the reader's frame and finish are kept")
    DShelf.setLook(ds[1].path, "painted")
    l = DShelf.lookOf(ds[1].path)
    ok(l.frame == "painted" and l.option == "red", "pick: a frame alone takes its first finish")
    ok(not DShelf.setLook(ds[1].path, "nope"), "pick: an unknown frame is refused")
    ok(DShelf.lookOf(ds[1].path).frame == "painted", "pick: and changes nothing")
    ok(DShelf.lookKey({ frame = "deco", option = "black" }) ~= DShelf.lookKey({ frame = "deco", option = "ivory" }),
        "pick: another finish is another cover")
end

------------------------------------------------------------------------------
-- The cover queue and the source
------------------------------------------------------------------------------
local function newQueue()
    local Q = { jobs = {}, now = 0, renders = {}, drafts = {}, changed = 0 }
    local cache = TestEnv.libraryDir() .. "/dcache"
    Storage.ensureDir(cache)
    Q.covers = DShelf.newCovers{
        cacheDir = function() return cache end,
        render = function(path, file, look, picture)
            Q.renders[#Q.renders + 1] = { path = path, look = look, picture = picture }
            writeAll(file, "png")
            return true
        end,
        draft = function(path, file)
            Q.drafts[#Q.drafts + 1] = path
            writeAll(file, "draft")
            return true
        end,
        schedule = function(sec, fn) Q.jobs[#Q.jobs + 1] = { t = Q.now + sec, fn = fn } end,
        unschedule = function(fn)
            for i = #Q.jobs, 1, -1 do if Q.jobs[i].fn == fn then table.remove(Q.jobs, i) end end
        end,
        changed = function() Q.changed = Q.changed + 1 end,
        busy = function() return Q.busy end,
    }
    function Q.run()
        local n = 0
        while #Q.jobs > 0 and n < 500 do
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

do
    local LIB = TestEnv.libraryDir() .. "/dlib"
    drawingFile(LIB .. "/Sun.inkaway", "202610010900")
    drawingFile(LIB .. "/Moon.inkaway", "202610020900")
    notebookFile(LIB .. "/Notes.inkaway")
    local Q = newQueue()
    local opened, chosen
    local spec = DShelf.spec{ root = function() return LIB end, covers = Q.covers,
        open = function(p) opened = p end, choose = function(p) chosen = p end, now = function() return os.time() + Q.now end }
    ok(spec.api == 1 and spec.remote_prefix == DShelf.PREFIX, "spec: version 1, its own prefix")
    ok(spec.label() == "Ink Away drawings", "spec: named for the reader")
    -- a new shelf: covers, face out, called Drawings; the reader's own choices stay
    local draft = { label = "New shelf" }
    spec.new_shelf(draft)
    ok(draft.view_mode == "covers" and draft.spine_face_out == "all" and draft.label == "Drawings",
        "spec: a new shelf shows the drawings face out, called Drawings")
    local mine = { label = "My art", view_mode = "spines", spine_face_out = "none" }
    spec.new_shelf(mine)
    ok(mine.label == "My art" and mine.view_mode == "spines" and mine.spine_face_out == "none",
        "spec: a reader's own choices stay")
    -- the first listing: no covers yet, all queued; the drawings get frames
    local out = spec.list()
    ok(#out == 0, "list: a drawing joins with its cover, none drawn yet")
    ok(DShelf.lookOf(LIB .. "/Sun.inkaway").frame ~= nil, "list: new drawings were dealt frames")
    ok(DShelf.lookOf(LIB .. "/Notes.inkaway").frame == nil, "list: the notebook was not")
    Q.run()
    ok(#Q.renders == 2, "list: both covers drawn in the background (" .. #Q.renders .. ")")
    ok(#Q.drafts == 2, "list: each never-opened drawing's picture drawn once, after the covers")
    out = spec.list()
    ok(#out == 2, "list: both on the shelf now (" .. #out .. ")")
    local sun
    for _, r in ipairs(out) do if r.title == "Sun" then sun = r end end
    ok(sun and sun.has_cover and sun.cover_image_path and Storage.exists(sun.cover_image_path),
        "record: with its cover file")
    ok(sun and sun.filepath == DShelf.PREFIX .. LIB .. "/Sun.inkaway" and sun.inkaway_drawing,
        "record: under the drawings' prefix")
    ok(sun and sun.cover_image_path:find("/frames/", 1, true), "record: covers in the frames' own folder")
    -- the drafts give new covers (they show the drawing), drawn once more
    Q.run()
    local renders = #Q.renders
    spec.list(); Q.run()
    ok(#Q.renders == renders, "list: nothing drawn again while nothing changed")
    -- owning: each source only its own records
    local nspec = Shelf.spec{ root = function() return LIB end, covers = Q.covers, open = function() end }
    ok(spec.owns(sun) and not nspec.owns(sun), "owns: a drawing is the drawings' only")
    ok(not spec.owns({ filepath = Shelf.PREFIX .. LIB .. "/Notes.inkaway" }), "owns: a notebook is not the drawings'")
    ok(not spec.owns({ filepath = LIB .. "/Sun.inkaway" }) and not spec.owns("x"), "owns: nor a plain file")
    spec.open(sun)
    ok(opened == LIB .. "/Sun.inkaway", "open: the drawing opens in Ink Away")
    spec.info(sun)
    ok(chosen == LIB .. "/Sun.inkaway", "info: a long press opens its frame sheet")
    -- a new frame: a new cover; the old one shown until it lands
    local old
    for _, r in ipairs(spec.list()) do if r.title == "Sun" then old = r.cover_image_path end end
    ok(old and old ~= sun.cover_image_path, "draft: the cover was drawn again with the drawing on it")
    DShelf.setLook(LIB .. "/Sun.inkaway", "deco", "emerald")
    out = spec.list()
    local again
    for _, r in ipairs(out) do if r.title == "Sun" then again = r end end
    ok(again and again.cover_image_path == old, "reframe: the old cover stays on the shelf meanwhile")
    Q.run()
    out = spec.list()
    for _, r in ipairs(out) do if r.title == "Sun" then again = r end end
    ok(again and again.cover_image_path ~= old, "reframe: then the new cover")
    ok(Q.renders[#Q.renders].look.frame == "deco" and Q.renders[#Q.renders].look.option == "emerald",
        "reframe: drawn in the frame picked")
    -- redraw at once (after the picker, or a new snapshot)
    DShelf.setLook(LIB .. "/Sun.inkaway", "metal", "brass")
    local before = #Q.renders
    Q.covers.redraw(LIB .. "/Sun.inkaway")
    ok(#Q.renders == before + 1 and Q.renders[#Q.renders].look.frame == "metal", "redraw: drawn now, in its frame")
    -- pruning: stale covers go, a minute later; the notebooks' covers never
    local ndir = Storage.join(Storage.dirName(Q.covers.dir()), Shelf.COVER_DIR)
    Storage.ensureDir(ndir)
    writeAll(ndir .. "/nb-0-x.png", "png")
    os.execute("touch -t 202001010000 '" .. ndir .. "/nb-0-x.png'")
    os.execute("touch -t 202001010000 '" .. old .. "'")
    Q.now = Q.now + 120
    spec.list()
    ok(not Storage.exists(old), "prune: a cover no drawing uses goes once stale")
    ok(Storage.exists(ndir .. "/nb-0-x.png"), "prune: the notebooks' covers are not the drawings'")
    -- a deleted drawing: forgotten, its covers pruned
    os.remove(LIB .. "/Moon.inkaway")
    out = spec.list()
    ok(#out == 1, "gone: a deleted drawing leaves the shelf")
end

------------------------------------------------------------------------------
-- The covers' shape, after Bookshelf's "True cover aspect"
------------------------------------------------------------------------------
do
    ok(DShelf.shape() == "fill", "shape: 2:3 when Bookshelf's settings can't be read")
    local on = false
    package.loaded["lib/bookshelf_settings_store"] = { isTrue = function(k) return k == "true_cover_aspect" and on end }
    ok(DShelf.shape() == "fill", "shape: 2:3 with True cover aspect off, as Bookshelf shows covers")
    on = true
    ok(DShelf.shape() == "true", "shape: the drawing's own with it on")
    package.loaded["lib/bookshelf_settings_store"] = { isTrue = function() error("broken") end }
    ok(DShelf.shape() == "fill", "shape: 2:3 if Bookshelf's settings fail")
    package.loaded["lib/bookshelf_settings_store"] = nil
    ok(DShelf.lookKey({ frame = "deco", option = "black", shape = "true" })
        ~= DShelf.lookKey({ frame = "deco", option = "black", shape = "fill" }), "shape: another shape is another cover")
    -- a PNG's size from its header, for Bookshelf's size tag
    local png = TestEnv.libraryDir() .. "/size.png"
    local function be32(n) return string.char(bit.band(bit.rshift(n, 24), 255), bit.band(bit.rshift(n, 16), 255),
        bit.band(bit.rshift(n, 8), 255), bit.band(n, 255)) end
    writeAll(png, "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(480) .. be32(652) .. "rest")
    ok(DShelf.sizeTag(png) == "480x652", "shape: a cover's size read from its header (" .. tostring(DShelf.sizeTag(png)) .. ")")
    writeAll(png .. ".txt", "not a png at all, nope")
    ok(DShelf.sizeTag(png .. ".txt") == nil and DShelf.sizeTag(nil) == nil, "shape: nothing for what isn't a PNG")
    local d = { path = ROOT .. "/Cat.inkaway", name = "Cat", mtime = 1, look = { shape = "true" } }
    ok(DShelf.record(d, png).cover_sizetag == "480x652", "record: in their own shapes, covers say their size")
    d.look.shape = "fill"
    ok(DShelf.record(d, png).cover_sizetag == nil, "record: at 2:3 they leave Bookshelf's default")
end

------------------------------------------------------------------------------
-- Snapshots
------------------------------------------------------------------------------
do
    local Q = newQueue()
    DShelf.covers, DShelf.registered = Q.covers, true
    local real = Shelf.writeSnapshot
    local wrote = 0
    Shelf.writeSnapshot = function(bb, file) wrote = wrote + 1; writeAll(file, "snap"); return true end
    local path = TestEnv.libraryDir() .. "/dsnap/Pic.inkaway"
    drawingFile(path, "202610010900")
    local view = { canvas_bb = {}, doc_written = true, doc_path = path }
    ok(DShelf.takeSnapshot(view) and wrote == 1, "snapshot: taken the first time")
    ok(not DShelf.takeSnapshot(view) and wrote == 1, "snapshot: not again while the drawing is unchanged")
    os.execute("touch -t 203001010000 '" .. path .. "'")
    ok(DShelf.takeSnapshot(view) and wrote == 2, "snapshot: again once the drawing was saved since")
    ok(not DShelf.takeSnapshot{ canvas_bb = {}, doc_written = true, doc_path = path, notebook = {} },
        "snapshot: not for a notebook (its own shelf takes those)")
    ok(not DShelf.takeSnapshot{ canvas_bb = {}, doc_written = false, doc_path = path }, "snapshot: not before it is saved")
    ok(not DShelf.takeSnapshot{ canvas_bb = {}, doc_written = true, doc_path = path,
        nightInk = function() return true end }, "snapshot: not in night colours")
    local draft = Shelf.draftFile(Q.covers.dir(), path)
    writeAll(draft, "d")
    os.execute("touch -t 203101010000 '" .. path .. "'")
    DShelf.takeSnapshot(view)
    ok(not Storage.exists(draft), "snapshot: the real picture replaces the draft")
    DShelf.registered = false
    ok(not DShelf.takeSnapshot(view), "snapshot: nothing without Bookshelf")
    Shelf.writeSnapshot = real
    DShelf.covers = nil
end

------------------------------------------------------------------------------
-- Registering
------------------------------------------------------------------------------
do
    ok(DShelf.register(nil) == false and DShelf.register({}) == false, "register: no Bookshelf, quietly nothing")
    ok(DShelf.register({ bookshelf = { SOURCE_API = 0, registerSource = function() error("x") end } }) == false,
        "register: an older Bookshelf, nothing")
    local got = {}
    local bs = { SOURCE_API = 1 }
    function bs:registerSource(id, spec) got.id, got.spec = id, spec; return true end
    ok(DShelf.register({ bookshelf = bs }, {}) == true and got.id == DShelf.ID, "register: the drawings' source")
    ok(DShelf.ID ~= Shelf.ID and DShelf.PREFIX ~= Shelf.PREFIX, "register: an id and prefix of its own")
    ok(DShelf.covers and DShelf.covers.dir():match("/frames$"), "register: covers in their own folder")
    local broken = { SOURCE_API = 1 }
    function broken:registerSource() error("boom") end
    ok(DShelf.register({ bookshelf = broken }, {}) == false, "register: a failing Bookshelf is survived")
end

TestEnv.cleanup()
print(string.format("drawingshelf: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
