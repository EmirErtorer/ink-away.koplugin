-- Ink on books (ink/reader/place.lua, ink/reader/bookink.lua): anchored to a
-- word in a reflowing book it follows the word to a new layout; anchored to a
-- page in a fixed-page book it follows the zoom; and it is kept in the book's
-- own folder.
--   luajit tests/bookink.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Place = require("ink/reader/place")
local BookInk = require("ink/reader/bookink")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function bbox(op)
    local x0, y0 = math.huge, math.huge
    for i = 1, #op.pts, 2 do x0 = math.min(x0, op.pts[i]); y0 = math.min(y0, op.pts[i + 1]) end
    return x0 - op.width / 2 - 1, y0 - op.width / 2 - 1
end

-- A stand-in reflowing book: words at known boxes on known pages, which a
-- "relayout" moves.
local function rollingDoc()
    local d = { kind = "rolling", page = 3, words = {} }
    d.words["w1"] = { xp1 = "w1e", page = 3, box = { x = 100, y = 200, w = 60, h = 20 } }
    d.words["w2"] = { xp1 = "w2e", page = 3, box = { x = 300, y = 400, w = 80, h = 20 } }
    function d:wordAt(x, y)
        for xp, w in pairs(self.words) do
            local b = w.box
            if w.page == self.page and x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
                return { xp0 = xp, xp1 = w.xp1, box = b }
            end
        end
    end
    function d:nearestWord(x, y)
        local best, bd
        for xp, w in pairs(self.words) do
            if w.page == self.page then
                local dd = math.abs(w.box.x - x) + math.abs(w.box.y - y)
                if not bd or dd < bd then best, bd = { xp0 = xp, xp1 = w.xp1, box = w.box }, dd end
            end
        end
        return best
    end
    function d:pageTop() return "top" .. self.page end
    function d:pageOf(xp)
        if self.words[xp] then return self.words[xp].page end
        return tonumber(xp:match("^top(%d+)$"))
    end
    function d:boxOf(xp0)
        local w = self.words[xp0]
        if w and w.page == self.page then return w.box end
    end
    return d
end

-- ---- a stroke under a word follows it to a new layout ---------------------------
do
    local doc = rollingDoc()
    local stroke = { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 100, 222, 160, 222 } }
    local item = Place.anchor(stroke, doc)
    ok(item and item.a.xp0 == "w1", "rolling: an underline anchors to the word above it")
    local back = Place.place(item, doc)
    local x0, y0 = bbox(back)
    local ox, oy = bbox(stroke)
    ok(math.abs(x0 - ox) < 1 and math.abs(y0 - oy) < 1, "rolling: placed back where it was drawn")
    -- the book is laid out again with a bigger font: the word moves to page 4
    doc.words.w1.page, doc.words.w1.box = 4, { x = 40, y = 520, w = 90, h = 30 }
    ok(Place.pageOf(item, doc) == 4, "rolling: it now belongs to page 4")
    doc.page = 3
    ok(Place.place(item, doc) == nil, "rolling: not shown on page 3 any more")
    doc.page = 4
    local moved = Place.place(item, doc)
    local mx, my = bbox(moved)
    ok(math.abs(mx - (40 + (ox - 100))) < 1 and math.abs(my - (520 + (oy - 200))) < 1,
        "rolling: on page 4 it sits under its word again")
end

-- ---- an underline anchors to the word above it; margin ink stays in the margin --
do
    local doc = rollingDoc()
    doc.width = function() return 600 end
    -- an underline under w1, its middle in the gap below the word
    local ul = { kind = "ink", style = "solid", width = 3, alpha = 255, pts = { 100, 226, 160, 226 } }
    ok(Place.anchor(ul, doc).a.xp0 == "w1", "underline: anchors to the word above it")
    -- a note in the right margin, beside w2
    local note = { kind = "ink", style = "solid", width = 3, alpha = 255, pts = { 520, 400, 560, 430 } }
    local item = Place.anchor(note, doc)
    ok(item.a.xp0 == "w2" and item.a.mr ~= nil, "margin: right-margin ink keeps its distance from the edge")
    doc.words.w2.box = { x = 60, y = 600, w = 80, h = 20 }      -- the word moves left and down
    local back = Place.place(item, doc)
    local bx, by = bbox(back)
    ok(bx > 500 and by > 590, "margin: it moved down with its word but stayed in the right margin")
end

-- ---- a margin note anchors to the nearest word; a page with no words to the page
do
    local doc = rollingDoc()
    local note = { kind = "ink", style = "solid", width = 3, alpha = 255, pts = { 200, 420, 240, 440 } }
    local item = Place.anchor(note, doc)
    ok(item.a.xp0 == "w2", "margin: anchors to the nearest word")
    doc.words = {}
    local pic = { kind = "ink", style = "solid", width = 3, alpha = 255, pts = { 500, 500, 520, 520 } }
    local pi = Place.anchor(pic, doc)
    ok(pi.a.pxp == "top3" and pi.a.dx > 0, "picture page: anchored to the page itself")
    local back = Place.place(pi, doc)
    local bx = bbox(back)
    ok(math.abs(bx - bbox(pic)) < 1, "picture page: placed back on the same spot")
end

-- ---- a fixed-page book: page units, and the zoom ------------------------------------
do
    local doc = { kind = "paging", zoom = 2, page = 7, ox = 30, oy = 10 }
    function doc:toPage(x, y) return self.page, (x - self.ox) / self.zoom, (y - self.oy) / self.zoom, self.zoom end
    function doc:toScreen(page, px, py)
        if page ~= self.page then return nil end
        return self.ox + px * self.zoom, self.oy + py * self.zoom, self.zoom
    end
    local stroke = { kind = "ink", style = "solid", width = 8, alpha = 255, pts = { 230, 410, 430, 410 } }
    local item = Place.anchor(stroke, doc)
    ok(item.a.page == 7 and math.abs(item.op.width - 4) < 1e-6, "paging: kept at page scale (width halved)")
    doc.zoom = 1                         -- zoomed out
    local back = Place.place(item, doc)
    ok(math.abs(back.width - 4) < 1e-6, "paging: at zoom 1 it is drawn at page size")
    local x0 = bbox(back)
    ok(math.abs(x0 - (30 + (bbox(stroke) - 30) / 2)) < 1.5, "paging: and on the same spot of the page")
    doc.page = 8
    ok(Place.place(item, doc) == nil, "paging: not on another page")
end

-- ---- the page index -------------------------------------------------------------------
do
    local doc = rollingDoc()
    local items = {
        Place.anchor({ kind = "ink", width = 3, alpha = 255, pts = { 110, 205, 150, 205 } }, doc),
        Place.anchor({ kind = "ink", width = 3, alpha = 255, pts = { 310, 405, 350, 405 } }, doc),
    }
    doc.words.w2.page = 9
    local idx = Place.index(items, doc)
    ok(idx[3] and #idx[3] == 1 and idx[9] and #idx[9] == 1, "index: items by page for this layout")
end

-- ---- kept in the book's folder ------------------------------------------------------------
do
    local dir = os.tmpname(); os.remove(dir)
    local data = BookInk.load(dir)
    ok(#data.items == 0, "store: a book with no ink")
    data.items[1] = { op = { kind = "ink", width = 3, alpha = 255, pts = { 0, 0, 10, 10 } },
                      a = { xp0 = "/body/p[2]/text().4", xp1 = "/body/p[2]/text().9", dx = -3, dy = 18 } }
    ok(BookInk.save(dir, data), "store: saved (the folder made if needed)")
    local back = BookInk.load(dir)
    ok(#back.items == 1 and back.items[1].a.xp0 == "/body/p[2]/text().4" and back.items[1].a.dy == 18,
        "store: read back")
    back.items = {}
    BookInk.save(dir, back)
    ok(io.open(BookInk.path(dir)) == nil, "store: a book whose ink is all gone leaves no file")
    os.remove(dir)
end

-- ---- the book's KOReader folder ------------------------------------------------------
-- A stand-in for KOReader's DocSettings, as it places, moves and removes a
-- book's ".sdr" folder (frontend/docsettings.lua), over real temporary folders.
do
    local root = os.tmpname(); os.remove(root)
    os.execute("mkdir -p '" .. root .. "/books' '" .. root .. "/ko'")
    local DS_DIR, HASH_DIR = root .. "/ko/docsettings", root .. "/ko/hashdocsettings"
    local setting = "doc"
    local function sh(c) os.execute(c .. " 2>/dev/null") end
    local function isfile(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
    local function isdir(p) return os.execute("test -d '" .. p .. "'") == 0 or os.execute("test -d '" .. p .. "'") == true end
    local function write(p, s) sh("mkdir -p '" .. p:match("^(.*)/") .. "'"); local f = io.open(p, "wb"); f:write(s); f:close() end
    local function read(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
    local META = "metadata.epub.lua"
    local DS = {}
    function DS.isHashLocationEnabled() return isdir(HASH_DIR) end
    function DS:getSidecarDir(doc, loc)
        local base = doc:match("(.*)%.") or doc
        loc = loc or setting
        if loc == "dir" then return DS_DIR .. base .. ".sdr" end
        if loc == "hash" then return HASH_DIR .. "/ab/abcd" .. #doc .. ".sdr" end
        return base .. ".sdr"
    end
    local function order()
        if setting == "hash" then return { "hash", "doc", "dir" } end
        local l = setting == "doc" and { "doc", "dir" } or { "dir", "doc" }
        if DS.isHashLocationEnabled() then l[#l + 1] = "hash" end
        return l
    end
    function DS:findSidecarFile(doc)
        for _, loc in ipairs(order()) do
            local f = self:getSidecarDir(doc, loc) .. "/" .. META
            if isfile(f) then return f, loc end
        end
    end
    function DS:getCustomLocationCandidates(doc)
        local f = self:findSidecarFile(doc)
        if f then return { f:match("^(.*)/[^/]+$") } end
        if setting == "doc" then return { self:getSidecarDir(doc, "doc"), self:getSidecarDir(doc, "dir") } end
        return { self:getSidecarDir(doc, setting) }
    end
    function DS.removeSidecarDir(dir) sh("rmdir '" .. dir .. "'") end
    -- KOReader's own: its metadata file only, then the old folder if empty
    function DS.updateLocation(doc, new, copy)
        local f = DS:findSidecarFile(doc)
        if not f then return end
        local old_dir = f:match("^(.*)/[^/]+$")
        if new then
            if setting == "hash" and doc ~= new then return end
            write(DS:getSidecarDir(new) .. "/" .. META, read(f))
            if copy then return end
        end
        os.remove(f)
        DS.removeSidecarDir(old_dir)
    end
    package.loaded["docsettings"] = DS
    local function opened(doc) write(DS:findSidecarFile(doc) or (DS:getSidecarDir(doc) .. "/" .. META), "return {}") end
    local some = { version = 1, items = { { op = { kind = "ink", width = 3, alpha = 255, pts = { 0, 0, 9, 9 } },
                                            a = { page = 2, x = 5, y = 6 } } } }

    -- the docsettings location: kept there, nothing next to the book
    setting = "dir"
    local book = root .. "/books/a.epub"; write(book, "x")
    opened(book)
    local w = BookInk.locate(book)
    ok(w.dir == DS_DIR .. root .. "/books/a.sdr", "folder: with the docsettings location, the ink goes there")
    BookInk.save(w.dir, some)
    ok(isfile(w.dir .. "/inkaway.lua") and not isdir(root .. "/books/a.sdr"),
        "folder: and nothing is made next to the book")
    ok(read(w.dir .. "/" .. META) == "return {}", "folder: the reader's own file is left as it was")

    -- a book already with a folder (and ink): read, kept, backed up on the next save
    local again = BookInk.load(w.dir)
    ok(#again.items == 1, "existing: ink already in the folder is read")
    again.items[2] = some.items[1]
    BookInk.save(w.dir, again)
    ok(#BookInk.load(w.dir).items == 2 and isfile(w.dir .. "/inkaway.lua.old"),
        "existing: saved again, the previous copy kept as .old")

    -- damaged: put aside, never written over; the backup is read instead
    write(w.dir .. "/inkaway.lua", "return {{{ not lua")
    local d = BookInk.load(w.dir)
    ok(#d.items == 1 and isfile(w.dir .. "/inkaway.lua.unreadable"), "damaged: kept aside, the backup read")
    os.remove(w.dir .. "/inkaway.lua.old")
    write(w.dir .. "/inkaway.lua", "garbage(")
    ok(#BookInk.load(w.dir).items == 0, "damaged, no backup: starts empty")
    BookInk.save(w.dir, some)
    ok(read(w.dir .. "/inkaway.lua.unreadable") == "return {{{ not lua", "damaged: the put-aside file is never written over")

    -- from a newer Ink Away: shown, not changed
    local Project = require("ink/project")
    write(w.dir .. "/inkaway.lua", Project.encode({ version = 99, items = some.items, extra = true }))
    local newer = BookInk.load(w.dir)
    ok(newer.read_only and not BookInk.save(w.dir, newer), "newer: read, but not saved over")

    -- the location setting changed (KOReader moved its file): the ink follows
    setting = "doc"
    local b2 = root .. "/books/b.epub"; write(b2, "x")
    setting = "dir"; opened(b2); BookInk.save(BookInk.locate(b2).dir, some)
    setting = "doc"; DS.updateLocation(b2, b2)        -- KOReader's "Move book metadata"
    local moved = BookInk.locate(b2)
    ok(moved.dir == root .. "/books/b.sdr" and BookInk.exists(moved.dir), "setting changed: the ink is brought beside the settings")
    ok(not isdir(DS:getSidecarDir(b2, "dir")), "setting changed: and the old folder is gone")

    -- moved, copied and deleted in the file browser: the ink goes with the book
    BookInk.installFollow()
    BookInk.installFollow()                                -- once only
    local b3 = root .. "/books/moved.epub"
    os.rename(b2, b3); DS.updateLocation(b2, b3)
    ok(BookInk.exists(root .. "/books/moved.sdr") and not isdir(root .. "/books/b.sdr"),
        "move: the ink went with the book, no folder left behind")
    local b4 = root .. "/books/copy.epub"
    write(b4, "x"); DS.updateLocation(b3, b4, true)
    ok(BookInk.exists(root .. "/books/copy.sdr") and BookInk.exists(root .. "/books/moved.sdr"), "copy: both have the ink")
    os.remove(b4); DS.updateLocation(b4)
    ok(not isdir(root .. "/books/copy.sdr"), "delete: the ink and the folder are gone with the book")

    -- moved onto a folder that already has ink: the two put together
    local b5 = root .. "/books/other.epub"; write(b5, "x"); opened(b5)
    local mine = { version = 1, items = { { op = { kind = "ink", width = 2, alpha = 255, pts = { 1, 1, 3, 3 } },
                                            a = { page = 9, x = 1, y = 1 } }, some.items[1] } }
    BookInk.save(root .. "/books/other.sdr", mine)
    BookInk.transfer(root .. "/books/moved.sdr", root .. "/books/other.sdr", false)
    ok(#BookInk.load(root .. "/books/other.sdr").items == 2, "merge: ink on both sides kept, nothing twice")

    package.loaded["docsettings"] = nil
    sh("rm -rf '" .. root .. "'")
end

print(("bookink: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
