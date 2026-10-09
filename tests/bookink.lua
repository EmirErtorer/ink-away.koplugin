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
    -- (an underline keeps its distance from the bottom of its word: 20 px tall then, 30 now)
    ok(math.abs(mx - (40 + (ox - 100))) < 1 and math.abs(my - (520 + 30 + (oy - 220))) < 1,
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
    -- deleted: the ink waits in Ink Away's trash, the book's folder goes
    local lib = root .. "/lib"; sh("mkdir -p '" .. lib .. "'")
    local had_G = rawget(_G, "G_reader_settings")
    _G.G_reader_settings = { readSetting = function(_, k) if k == "inkaway_library_dir" then return lib end end }
    local Trash = require("ink/trash")
    os.remove(b4); DS.updateLocation(b4)
    ok(not isdir(root .. "/books/copy.sdr"), "delete: the book's folder is gone with the book")
    local t = Trash.list(lib)[1]
    ok(t and t.kind == "bookink" and t.gone and t.name == "copy" and t.book == b4,
        "delete: its ink is in Ink Away's trash, named for the book")
    ok(Trash.restore(lib, t.id) == root .. "/books/copy.sdr" and BookInk.exists(root .. "/books/copy.sdr"),
        "delete: put back where the book was, for when it comes back")
    _G.G_reader_settings = had_G

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

-- ---- several pages on the screen; only the ink shown is replaced ------------------------
do
    local Book = require("ink/reader/book")
    local doc = { kind = "paging", zoom = 1 }
    function doc:toPage(x, y) if y < 400 then return 5, x, y, 1 end return 6, x, y - 400, 1 end
    function doc:toScreen(page, px, py) if page == 5 then return px, py, 1 end if page == 6 then return px, py + 400, 1 end end
    local states = { { page = 5 }, { page = 6 } }
    local ui = { paging = true, view = { page_scroll = true, page_states = states, state = { page = 5 } } }
    local b = setmetatable({ ui = ui, rev = 0, has_file = true }, Book)
    b._doc = doc
    b.layoutKey = function() return "L" end
    local function ink(x, y) return { kind = "ink", width = 2, alpha = 255, pts = { x, y, x + 20, y } } end
    local a5, a6 = Place.anchor(ink(10, 100), doc), Place.anchor(ink(10, 500), doc)
    local hidden = Place.anchor(ink(10, 120), doc)            -- on page 5, but not shown (say, unplaceable)
    b._data = { version = 1, items = { a5, a6, hidden, Place.anchor(ink(10, 100), { kind = "paging",
        toPage = function() return 9, 10, 100, 1 end }) } }
    local pages = b:visiblePages()
    ok(#pages == 2 and pages[1] == 5 and pages[2] == 6, "pages: a continuous scroll shows pages 5 and 6")
    local placed = b:pageOps()
    ok(#placed.ops == 4 - 1, "pages: the ink of both pages is placed (page 9's is not)")
    -- the view drops page 6's stroke and draws a new one; page 5's comes back unchanged
    local shown = { a5, a6 }
    local from = { [placed.ops[1]] = a5 }
    local map, now = b:setPageOps({ placed.ops[1], ink(50, 450) }, from, shown)
    ok(map[placed.ops[1]] == a5 and #now == 2, "save: the unchanged stroke keeps its item")
    local has = {}
    for _, it in ipairs(b._data.items) do has[it] = true end
    ok(has[a5] and not has[a6] and has[hidden] and #b._data.items == 4,
        "save: the erased stroke is gone, ink that was not shown is kept")
    -- the page index followed the change, as a full rebuild would have it
    b:pageOps()
    b._placed = nil
    local shown2 = b:pageOps().items
    local map2, now2 = b:setPageOps({ placed.ops[1] }, { [placed.ops[1]] = a5 }, shown2)
    local full = Place.index(b._data.items, doc)
    local same = true
    for p, l in pairs(full) do
        local inc = b._index and b._index[p] or {}
        if #inc ~= #l then same = false end
        for i = 1, #l do if inc[i] ~= l[i] then same = false end end
    end
    ok(b._index ~= nil and same and map2 and #now2 == 1, "index: changed on the shown pages only, as a full rebuild has it")
end

-- ---- the file is written from each item's kept text ------------------------------------
do
    local Project = require("ink/project")
    local data = { version = 1, notes = "/x/Book notes/A.inkaway", items = {
        { op = { kind = "ink", width = 3, alpha = 255, pts = { 1, 2, 3, 4 } }, a = { page = 2, x = 1, y = 2 } },
        { op = { kind = "text", x = 1, y = 2, w = 50, h = 20, text = "a \"note\"" }, a = { xp0 = "/b/p[2].4", dyb = 3 } },
    } }
    local back = Project.decode(BookInk.encode(data))
    ok(back and back.version == 1 and back.notes == data.notes and #back.items == 2
        and back.items[2].op.text == data.items[2].op.text and back.items[1].a.page == 2,
        "file: written from kept item texts, read back the same")
    data.items[3] = { op = { kind = "ink", width = 2, alpha = 255, pts = { 9, 9 } }, a = { page = 3, x = 0, y = 0 } }
    ok(#Project.decode(BookInk.encode(data)).items == 3, "file: a new item is added to the kept ones")
end

-- ---- the smart highlighter: which strokes are along a line of text ---------------------
do
    local Snap = require("ink/reader/snap")
    local hl = function(pts, w) return { kind = "ink", style = "highlighter", width = w or 30, pts = pts } end
    local across = Snap.lineOf(hl({ 100, 210, 180, 214, 260, 208 }))
    ok(across and across.x0 == 100 and across.x1 == 260 and across.h == 6, "snap: a stroke across a line")
    ok(Snap.lineOf(hl({ 100, 100, 110, 300 })) == nil, "snap: a stroke down the page is not")
    ok(Snap.lineOf(hl({ 100, 200, 105, 201 })) == nil, "snap: a dab is not")
    local line = { x0 = 100, x1 = 260, y = 211, h = 6 }
    local words = { { x = 96, y = 200, w = 70, h = 22 }, { x = 172, y = 200, w = 90, h = 22 } }
    ok(Snap.covers(words, line), "snap: words under the whole stroke")
    ok(not Snap.covers({ { x = 96, y = 200, w = 30, h = 22 } }, line), "snap: one short word under a long stroke is not")
    ok(not Snap.covers({ words[1], { x = 20, y = 230, w = 90, h = 22 } }, line), "snap: text running onto the next line is not")
    ok(not Snap.covers(words, { x0 = 100, x1 = 260, y = 211, h = 40 }), "snap: a stroke wandering over two lines is not")
    ok(Snap.colourName({ 255, 235, 59 }, "gray") == "yellow", "snap: the yellow pen highlights in yellow")
    ok(Snap.colourName({ 0, 102, 255 }, "gray") == "blue", "snap: a blue pen in blue")
    ok(Snap.colourName({ 200, 200, 200 }, "gray") == "gray", "snap: a grey pen in the reader's own colour")
end

-- ---- a change outside the ops is undone and redone through the history -----------------
do
    local Canvas = require("ink/canvas")
    local c = Canvas.new(100, 100)
    c:startStroke("ink", 2, 255, nil, "solid"); c:addPoint(5, 5); c:addPoint(50, 50); c:finishStroke()
    ok(#c.ops == 1, "mark: a stroke drawn")
    c:undo(); c.redo_stack = {}                     -- the stroke taken over
    c:pushMark({ item = "hl" })
    ok(#c.ops == 0, "mark: the taken stroke is gone")
    local u, m = c:undo()
    ok(u and m and m.item == "hl" and #c.ops == 0, "mark: undo hands the mark back")
    local r, m2 = c:redo()
    ok(r and m2 == m and c:canUndo(), "mark: and so does redo")
end

-- ---- book notes: a page per chapter, in the book's order -------------------------------
do
    local BookNotes = require("ink/reader/booknotes")
    ok(BookNotes.fileName('A/B: "C"?') == "A B C", "notes: a title made a file name")
    ok(BookNotes.fileName("  ...  ") == "Book", "notes: an empty title still names the file")
    local blank = { { ops = {} } }
    ok(BookNotes.placeFor(blank, 3).claim, "notes: a new notebook's blank page takes the first chapter")
    local pages = {
        { ops = { 1 }, book = { toc = 2 } },        -- chapter 2
        { ops = { 1 } },                             -- added by hand after it
        { ops = { 1 }, book = { toc = 5 } },        -- chapter 5
    }
    ok(BookNotes.placeFor(pages, 2).index == 2, "notes: a chapter opens on its last page (one added by hand)")
    ok(BookNotes.placeFor(pages, 5).index == 3, "notes: and another chapter on its own")
    ok(BookNotes.placeFor(pages, 3).insert == 3, "notes: a new chapter goes between the ones around it")
    ok(BookNotes.placeFor(pages, 1).insert == 1, "notes: an earlier chapter goes first")
    ok(BookNotes.placeFor(pages, 9).insert == 4, "notes: a later one last")
    ok(BookNotes.placeFor(pages, nil).index == 3, "notes: a book without contents opens the last page")
    ok(BookNotes.otherBook({ { book = { toc = 1, md5 = "a" } } }, "b"), "notes: another book's notebook of the same name is told apart")
    ok(not BookNotes.otherBook({ { ops = {} } }, "b"), "notes: a notebook with no chapter pages is not another book's")
    local Notebook = require("ink/notebook")
    local nb = Notebook.fromData({ w = 10, h = 10, pages = { { id = 1, ops = {}, title = "One", book = { toc = 4, md5 = "x" } } } })
    ok(nb.pages[1].book and nb.pages[1].book.toc == 4, "notes: a page keeps its chapter through saving")
end

-- ---- the book gestures: set where free, never over the reader's own ------------------------
do
    local EntryGestures = require("ink/reader/entrygestures")
    local Welcome = require("ink/welcome")
    local R_UP, R_DOWN = "one_finger_swipe_right_edge_up", "one_finger_swipe_right_edge_down"
    local NW, SW = "two_finger_swipe_northwest", "two_finger_swipe_southwest"

    -- a reader without warmth: both along the right edge
    local data = { gesture_fm = {}, gesture_reader = {} }
    local placed, busy, n = EntryGestures.apply(data)
    ok(data.gesture_reader[R_UP].inkaway_booknotes and data.gesture_fm[R_UP].inkaway_booknotes,
        "gestures: book notes along the right edge, in the reader and the file browser")
    ok(data.gesture_reader[R_DOWN].inkaway_annotate and data.gesture_fm[R_DOWN] == nil,
        "gestures: annotating along the right edge, in a book only")
    ok(n == 3 and #busy == 0 and placed.booknotes.gesture_reader == R_UP and placed.annotate.gesture_reader == R_DOWN,
        "gestures: all three placed, nothing in the way")
    local p2, b2, n2 = EntryGestures.apply(data)
    ok(n2 == 0 and #b2 == 0 and p2.booknotes.gesture_fm == R_UP, "gestures: running again changes nothing")
    local c = Welcome.content({ placed = placed, held = {} })
    ok(c.rows[1].gesture == "Swipe down along the right edge" and c.rows[2].gesture == "Swipe up along the right edge"
        and c.rows[2].outside == "Outside a book, it opens Ink Away." and not c.info and #c.warnings == 0,
        "notice: the edge swipes, said plainly, no warning")

    -- a reader with warmth on the right edge (most colour readers): two-finger swipes
    local warm = { increase_frontlight_warmth = 0 }
    local cool = { decrease_frontlight_warmth = 0 }
    data = { gesture_fm = { [R_UP] = warm, [R_DOWN] = cool }, gesture_reader = { [R_UP] = warm, [R_DOWN] = cool } }
    placed, busy, n = EntryGestures.apply(data)
    ok(data.gesture_reader[R_UP] == warm and data.gesture_reader[R_DOWN] == cool, "warmth: the reader's own are kept")
    ok(data.gesture_reader[NW].inkaway_booknotes and data.gesture_fm[NW].inkaway_booknotes,
        "warmth: book notes on the two-finger swipe from bottom right to top left")
    ok(data.gesture_reader[SW].inkaway_annotate and data.gesture_fm[SW] == nil,
        "warmth: annotating on the two-finger swipe from top right to bottom left")
    ok(#busy == 3, ("warmth: the right edge listed as in use (%d)"):format(#busy))
    local held = {}
    for _i, b in ipairs(busy) do
        held[#held + 1] = { feature = b.feature, section = b.section, ges = b.ges,
            what = b.current == warm and "Warmth up" or "Warmth down" }
    end
    c = Welcome.content({ placed = placed, held = held })
    ok(c.rows[1].glyph == "ges_two_swipe_sw" and c.rows[2].glyph == "ges_two_swipe_nw", "notice: the two-finger glyphs")
    ok(c.info and c.info:find("Warmth up") and c.info:find("two%-finger"), "notice: says why two fingers")
    ok(#c.warnings == 0, "notice: no warning when both got a gesture")

    -- the edge in the reader taken, free in the file browser: the same gesture everywhere when one is free in both
    data = { gesture_fm = {}, gesture_reader = { [R_UP] = warm } }
    placed = EntryGestures.apply(data)
    ok(placed.booknotes.gesture_reader == NW and placed.booknotes.gesture_fm == NW and data.gesture_fm[R_UP] == nil,
        "gestures: one gesture free in both is used in both")

    -- everything taken: nothing set, a warning naming what holds them
    data = { gesture_fm = { [R_UP] = warm, [NW] = { toc = true } },
        gesture_reader = { [R_UP] = warm, [R_DOWN] = cool, [NW] = { toc = true }, [SW] = { bookmarks = true } } }
    placed, busy, n = EntryGestures.apply(data)
    ok(n == 0 and placed.booknotes.gesture_reader == nil and placed.annotate.gesture_reader == nil,
        "full: nothing set over the reader's gestures")
    held = {}
    for _i, b in ipairs(busy) do held[#held + 1] = { feature = b.feature, section = b.section, ges = b.ges, what = "X" } end
    c = Welcome.content({ placed = placed, held = held })
    ok(not c.rows[1].gesture and #c.warnings == 3 and c.warnings[1]:find("Annotate the book has no gesture")
        and c.warnings[3]:find("Gesture manager"), "notice: a warning for each, and where to set them")

    -- an emptied gesture counts as free
    local d3 = { gesture_reader = { [R_UP] = {} } }
    EntryGestures.apply(d3)
    ok(d3.gesture_reader[R_UP].inkaway_booknotes, "gestures: an emptied gesture counts as free")

    -- the gesture manager off, or the setup never ran
    c = Welcome.content({ off = true })
    ok(#c.rows == 2 and not c.rows[1].gesture and c.warnings[1]:find("gesture manager is off"), "notice: gesture manager off")
    c = Welcome.content(nil)
    ok(#c.warnings == 2, "notice: no setup yet reads as off")
end

-- ---- what the eraser leaves of a shape stays together -------------------------------
do
    local doc = rollingDoc()
    local shape = { kind = "shape", shape = "rect", width = 4, alpha = 255, pts = { 90, 190, 400, 430 } }
    local base = Place.anchor(shape, doc)
    local left = { kind = "ink", width = 4, alpha = 255, pts = { 90, 190, 180, 190 } }
    local right = { kind = "ink", width = 4, alpha = 255, pts = { 320, 430, 400, 430 } }
    local a, b = Place.anchorWith(left, doc, base.a), Place.anchorWith(right, doc, base.a)
    ok(a.a.xp0 == base.a.xp0 and b.a.xp0 == base.a.xp0, "cut shape: both pieces keep the shape's word")
    local w = doc.words[base.a.xp0]
    w.box = { x = w.box.x + 50, y = w.box.y + 300, w = w.box.w, h = w.box.h }   -- laid out again
    local pa, pb = Place.place(a, doc), Place.place(b, doc)
    ok(pa.pts[1] == 140 and pa.pts[2] == 490 and pb.pts[1] == 370 and pb.pts[2] == 730,
        "cut shape: they move together, as the shape would")
end

-- ---- an underline stays under its word when the word gets taller ----------------------
do
    local doc = rollingDoc()
    local ul = { kind = "ink", width = 3, alpha = 255, pts = { 100, 224, 160, 224 } }   -- under w1 (200..220)
    local item = Place.anchor(ul, doc)
    ok(item.a.dyb ~= nil and item.a.dy == nil, "underline: kept from the bottom of its word")
    doc.words.w1.box = { x = 100, y = 200, w = 90, h = 40 }                      -- a bigger font
    local placed = Place.place(item, doc)
    local _x, y = bbox(placed)
    ok(y > 239, ("underline: still under the taller word (top %.1f)"):format(y))
    local circle = { kind = "ink", width = 3, alpha = 255, pts = { 95, 195, 165, 195, 165, 225, 95, 225 } }
    ok(Place.anchor(circle, rollingDoc()).a.dy ~= nil, "a circle around a word keeps its top offset")
end

-- ---- pictures are kept in the book's folder --------------------------------------------
do
    local root = os.tmpname(); os.remove(root)
    os.execute("mkdir -p '" .. root .. "/pics' '" .. root .. "/a.sdr'")
    local pic = root .. "/pics/photo.png"
    local f = io.open(pic, "wb"); f:write(string.rep("x", 300)); f:close()
    local sdr = root .. "/a.sdr"
    local ref = BookInk.keepPicture(sdr, pic)
    ok(ref:match("^@book/") ~= nil, "picture: named in the book's folder (" .. ref .. ")")
    local file = BookInk.picturePath(sdr, ref)
    local g = io.open(file, "rb")
    ok(g ~= nil and #g:read("*a") == 300, "picture: copied there")
    if g then g:close() end
    ok(BookInk.keepPicture(sdr, pic) == ref, "picture: placed again, kept once")
    ok(BookInk.keepPicture(sdr, file) == ref, "picture: one already there keeps its name")
    os.remove(pic)
    ok(io.open(BookInk.picturePath(sdr, ref), "rb") ~= nil, "picture: the original can go, the book keeps its copy")
    -- moved with the book's folder
    os.execute("mkdir -p '" .. root .. "/b.sdr'")
    local d = io.open(BookInk.path(sdr), "wb"); d:write("return {version=1,items={}}"); d:close()
    BookInk.transfer(sdr, root .. "/b.sdr", false)
    ok(io.open(BookInk.picturePath(root .. "/b.sdr", ref), "rb") ~= nil
        and io.open(BookInk.picturePath(sdr, ref), "rb") == nil, "picture: moves with the book's ink")
    -- unused pictures go (and the emptied folder)
    BookInk.prunePictures(root .. "/b.sdr", { { op = { kind = "image", path = ref } } })
    ok(io.open(BookInk.picturePath(root .. "/b.sdr", ref), "rb") ~= nil, "prune: a picture in use stays")
    BookInk.prunePictures(root .. "/b.sdr", {})
    ok(io.open(BookInk.picturePath(root .. "/b.sdr", ref), "rb") == nil, "prune: an unused one goes")
    os.execute("rm -rf '" .. root .. "'")
end

-- ---- a book's annotations to the trash and back ------------------------------------------------
do
    local Trash = require("ink/trash")
    local root = os.tmpname(); os.remove(root)
    os.execute("mkdir -p '" .. root .. "/lib' '" .. root .. "/book.sdr' '" .. root .. "/pics'")
    local lib, sdr = root .. "/lib", root .. "/book.sdr"
    local function exists(p) local f = io.open(p, "rb"); if f then f:close() end; return f ~= nil end
    local ko = sdr .. "/metadata.epub.lua"
    local k = io.open(ko, "wb"); k:write("return {}"); k:close()
    local pic = root .. "/pics/p.png"
    local f = io.open(pic, "wb"); f:write("png"); f:close()
    local ref = BookInk.keepPicture(sdr, pic)
    local stroke = { a = { page = 1, x = 1, y = 1 }, op = { kind = "ink", width = 2, alpha = 255, pts = { 1, 1, 5, 5 } } }
    local image = { a = { page = 1, x = 1, y = 1 }, op = { kind = "image", path = ref, x = 0, y = 0, w = 10, h = 10 } }
    BookInk.save(sdr, { version = 1, items = { stroke, image } })
    BookInk.save(sdr, { version = 1, items = { stroke, image } })   -- leaves a .old as well
    ok(exists(BookInk.path(sdr) .. ".old"), "trash: a backup to go too")

    local item = Trash.putBookInk(lib, sdr, { name = "The Book", book = root .. "/book.epub" })
    ok(item and item.kind == "bookink" and item.name == "The Book", "trash: the book's annotations are in")
    ok(not BookInk.exists(sdr) and not exists(BookInk.path(sdr) .. ".old"), "trash: its ink file and backup left the book")
    ok(not exists(BookInk.picturePath(sdr, ref)), "trash: its pictures too")
    ok(exists(ko), "trash: KOReader's own file stays")
    ok(BookInk.load(sdr).items[1] == nil, "trash: the book reads as having no ink")
    ok(#Trash.list(lib) == 1 and Trash.list(lib)[1].id == item.id, "trash: listed")

    -- ink made since is kept when they come back, the two put together
    local fresh = { a = { page = 2, x = 3, y = 3 }, op = { kind = "ink", width = 2, alpha = 255, pts = { 3, 3, 9, 9 } } }
    BookInk.save(sdr, { version = 1, items = { fresh }, notes = "/notes.inkn" })
    local back = Trash.restore(lib, item.id)
    ok(back == sdr, "restore: back in the book's folder (the book file is gone, so its old folder)")
    local data = BookInk.load(sdr)
    ok(#data.items == 3 and data.notes == "/notes.inkn", ("restore: joined with what was made since (%d items)"):format(#data.items))
    ok(exists(BookInk.picturePath(sdr, ref)), "restore: the pictures are back")
    ok(#Trash.list(lib) == 0, "restore: gone from the trash")

    -- deleted for good
    item = Trash.putBookInk(lib, sdr, { name = "The Book" })
    ok(item ~= nil, "forget: in again")
    Trash.forget(lib, item.id)
    ok(#Trash.list(lib) == 0 and not exists(lib .. "/" .. Trash.DIR .. "/" .. item.id), "forget: gone for good")
    ok(Trash.putBookInk(lib, sdr, { name = "x" }) == nil, "trash: nothing to move, nothing done")
    os.execute("rm -rf '" .. root .. "'")
end

print(("bookink: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
