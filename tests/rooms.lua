-- Room made in a book's text (ink/reader/rooms.lua): the style rules from a
-- paragraph's xpointer, a box drawn on the page made into a band or side space,
-- ink kept in a room (ink/reader/place.lua), and rooms kept in the book's ink
-- file (ink/reader/bookink.lua), merged with another copy's.
--   luajit tests/rooms.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Rooms = require("ink/reader/rooms")
local Place = require("ink/reader/place")
local BookInk = require("ink/reader/bookink")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- ---- paragraphs and selectors ---------------------------------------------------
do
    ok(Rooms.blockOf("/body/DocFragment[9]/body/p[10]/text().15") == "/body/DocFragment[9]/body/p[10]",
        "block: the paragraph holding a word")
    ok(Rooms.blockOf("/body/DocFragment[3]/body/div/p[4]/span[2]/em/text()[2].3") == "/body/DocFragment[3]/body/div/p[4]",
        "block: inline elements are inside the paragraph")
    ok(Rooms.blockOf("/body/DocFragment[3]/body/text().0") == nil, "block: text right in the body has none")
    ok(Rooms.blockOf("not an xpointer") == nil and Rooms.blockOf(nil) == nil, "block: nonsense is nil")
    ok(Rooms.selector("/body/DocFragment[9]/body/p[10]") ==
        "DocFragment:nth-of-type(9) > body:nth-of-type(1) > p:nth-of-type(10)",
        "selector: from DocFragment (crengine matches nothing above it), indexes as nth-of-type")
    ok(Rooms.selector("/body[1]/DocFragment[14]/body[1]/div/p[152]") ==
        "DocFragment:nth-of-type(14) > body:nth-of-type(1) > div:nth-of-type(1) > p:nth-of-type(152)",
        "selector: an unindexed step is the first of its name")
    ok(Rooms.selector("/FictionBook/body/section[3]/p[5]") ==
        "body:nth-of-type(1) > section:nth-of-type(3) > p:nth-of-type(5)",
        "selector: a book without DocFragment, from under its root")
    ok(Rooms.selector("/body/DocFragment[2]/body/p[1]{bad}") == nil, "selector: an odd name gives none")
end

-- ---- the style rules ----------------------------------------------------------------
do
    local P = "/body/DocFragment[9]/body/p[10]"
    local Q = "/body/DocFragment[9]/body/p[11]"
    local css = Rooms.css({ { id = "a", kind = "band", xp = P, h = 200 } }, 1)
    ok(css == "DocFragment:nth-of-type(9) > body:nth-of-type(1) > p:nth-of-type(10) { padding-top: 200px !important; }",
        "css: a band is padding above its paragraph")
    css = Rooms.css({ { id = "a", kind = "band", xp = P, h = 200 },
                      { id = "b", kind = "side", side = "right", xp = P, xps = { P, Q }, w = 300 } }, 0.5)
    ok(css:find("p:nth-of-type(10) { padding-top: 100px !important; padding-right: 150px !important; }", 1, true) ~= nil,
        "css: a band and side space on one paragraph go in one rule, scaled to the book's pixels")
    ok(css:find("p:nth-of-type(11) { padding-right: 150px !important; }", 1, true) ~= nil,
        "css: side space narrows every paragraph it covers")
    ok(not css:find("margin", 1, true) and not css:find("::before", 1, true) and not css:find("float", 1, true),
        "css: only padding (a margin vanishes at a page top; boxes and floats make KOReader reload the book)")
    ok(Rooms.css({}, 1) == "", "css: no rooms, no rules")
    css = Rooms.css({ { id = "a", kind = "side", side = "left", xp = P, w = 120 } }, 1)
    ok(css:find("padding-left: 120px", 1, true) ~= nil, "css: space on the left")
end

-- ---- a box on the page ---------------------------------------------------------------
do
    local area = { x0 = 40, y0 = 30, x1 = 1040, y1 = 1430 }   -- 1000 x 1400
    local blocks = {
        { xp = "/b/p[1]", y0 = 30, y1 = 200, starts = false },   -- began on the page before
        { xp = "/b/p[2]", y0 = 210, y1 = 500, starts = true },
        { xp = "/b/p[3]", y0 = 510, y1 = 900, starts = true },
        { xp = "/b/p[4]", y0 = 910, y1 = 1420, starts = true },
    }
    local r, box = Rooms.plan({ x = 100, y = 480, w = 800, h = 300 }, blocks, area)
    ok(r and r.kind == "band" and r.xp == "/b/p[3]" and r.h == 300, "plan: a wide box is a band before the nearest paragraph")
    ok(box and box.y == 510 and box.x == 40 and box.w == 1000 and box.h == 300, "plan: the band spans the text area")
    r = Rooms.plan({ x = 400, y = 220, w = 200, h = 100 }, blocks, area)
    ok(r and r.kind == "band" and r.xp == "/b/p[2]", "plan: a box in the middle of the text is a band too")
    r = Rooms.plan({ x = 100, y = 40, w = 800, h = 100 }, blocks, area)
    ok(r and r.xp == "/b/p[2]", "plan: a paragraph that began on the page before is no break")
    r = Rooms.plan({ x = 100, y = 480, w = 800, h = 5 }, blocks, area)
    ok(r and r.h == math.floor(0.04 * 1400 + 0.5), "plan: a band is at least a little high")
    r = Rooms.plan({ x = 100, y = 480, w = 800, h = 5000 }, blocks, area)
    ok(r and r.h == math.floor(0.85 * 1400 + 0.5), "plan: and never taller than most of the page")
    r, box = Rooms.plan({ x = 700, y = 250, w = 330, h = 400 }, blocks, area)
    ok(r and r.kind == "side" and r.side == "right" and r.w == 340, "plan: a box at the right is side space from the edge")
    ok(r and #r.xps == 2 and r.xps[1] == "/b/p[2]" and r.xps[2] == "/b/p[3]" and r.xp == "/b/p[2]",
        "plan: side space covers the paragraphs the box touches")
    ok(box and box.x == 1040 - 340 and box.y == 210 and box.h == 900 - 210, "plan: its box beside them")
    r = Rooms.plan({ x = 45, y = 250, w = 200, h = 100 }, blocks, area)
    ok(r and r.kind == "side" and r.side == "left" and r.w == 205, "plan: on the left")
    r = Rooms.plan({ x = 45, y = 250, w = 30, h = 100 }, blocks, area)
    ok(r and r.w == 150, "plan: side space is at least a little wide")
    r = Rooms.plan({ x = 45, y = 250, w = 900, h = 100 }, blocks, area)
    ok(r and r.kind == "band", "plan: a box from side to side is a band")
    local none, why = Rooms.plan({ x = 100, y = 480, w = 800, h = 300 }, {}, area)
    ok(none == nil and why == "no_text", "plan: a page without text has no room")
    none, why = Rooms.plan({ x = 100, y = 40, w = 800, h = 100 }, { blocks[1] }, area)
    ok(none == nil and why == "no_break", "plan: a page with no paragraph starting on it has no band")
end

-- ---- paragraphs from a page's words -------------------------------------------
do
    local words = {
        { xp = "/body/DocFragment[2]/body/p[3]/text().40", y = 30, h = 30 },
        { xp = "/body/DocFragment[2]/body/p[3]/text().46", y = 70, h = 30 },
        { xp = "/body/DocFragment[2]/body/p[4]/text().0", y = 110, h = 30 },
        { xp = "/body/DocFragment[2]/body/p[4]/em/text().0", y = 150, h = 30 },
        { xp = "/body/DocFragment[2]/body/p[5]/text().0", y = 190, h = 30 },
    }
    local b = Rooms.blocksFromWords(words, function() return false end)
    ok(#b == 3 and b[1].xp == "/body/DocFragment[2]/body/p[3]" and b[1].starts == false, "blocks: one per paragraph")
    ok(b[2].y0 == 110 and b[2].y1 == 180 and b[2].starts, "blocks: from its first line's top to its last line's foot")
end

-- ---- ink kept in a room ---------------------------------------------------------
-- A stand-in book with a band (top-left at its box) and side space on the right.
local function roomDoc()
    local d = { kind = "rolling", page = 4, rooms = {}, words = {} }
    d.rooms.band = { room = { id = "band", kind = "band" }, box = { x = 40, y = 500, w = 1000, h = 300 }, page = 4 }
    d.rooms.side = { room = { id = "side", kind = "side" }, box = { x = 700, y = 100, w = 340, h = 300 }, page = 4 }
    d.words.w1 = { box = { x = 100, y = 150, w = 80, h = 30 }, page = 4 }
    function d:width() return 1080 end
    function d:roomAt(x0, y0, x1, y1)
        local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        for _k, e in pairs(self.rooms) do
            local b = e.box
            if e.page == self.page and cx >= b.x and cx <= b.x + b.w and cy >= b.y and cy <= b.y + b.h then return e.room, b end
        end
    end
    function d:roomBox(id) local e = self.rooms[id]; return e and e.page == self.page and e.box or nil end
    function d:roomPage(id) local e = self.rooms[id]; return e and e.page end
    function d:roomX(id) local e = self.rooms[id]; return e and e.box.x end
    function d:wordAt(x, y)
        for xp, w in pairs(self.words) do
            local b = w.box
            if w.page == self.page and x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h then
                return { xp0 = xp, xp1 = xp .. "e", box = b }
            end
        end
    end
    function d:nearestWord() return { xp0 = "w1", xp1 = "w1e", box = self.words.w1.box } end
    function d:pageOf(xp) local w = self.words[xp:gsub("e$", "")]; return w and w.page end
    function d:boxOf(xp0) local w = self.words[xp0]; return w and w.page == self.page and w.box or nil end
    function d:pageTop() return "top" end
    return d
end
do
    local doc = roomDoc()
    local note = { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 300, 600, 500, 650 } }
    local item = Place.anchor(note, doc)
    ok(item and item.a.room == "band" and item.a.xp0 == nil, "room: ink in a band is kept with the band")
    -- the text moves: the band goes down the page and so does the ink
    doc.rooms.band.box = { x = 40, y = 900, w = 1000, h = 300 }
    local back = Place.place(item, doc)
    local x0, y0 = math.huge, math.huge
    for i = 1, #back.pts, 2 do x0 = math.min(x0, back.pts[i]); y0 = math.min(y0, back.pts[i + 1]) end
    ok(math.abs(y0 - (600 + 400)) <= 1 and math.abs(x0 - 300) <= 1, "room: it follows its band down the page")
    -- to the next page: the ink goes with it
    doc.rooms.band.page = 5
    ok(Place.pageOf(item, doc) == 5, "room: the band's page is the ink's")
    ok(Place.place(item, doc) == nil, "room: not shown where the band is not")
    -- hidden rooms hide their ink
    doc.page = 5
    local saved = doc.rooms.band
    doc.rooms.band = nil
    ok(Place.place(item, doc) == nil and Place.pageOf(item, doc) == nil, "room: hidden, its ink is too")
    doc.rooms.band = saved
    -- side space: down from its word, across from the room's edge
    doc.page = 4
    local side = { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 760, 160, 900, 200 } }
    local s = Place.anchor(side, doc)
    ok(s and s.a.room == "side" and s.a.xp0 == "w1" and s.a.dx == nil and s.a.rx ~= nil,
        "room: ink in side space keeps its word and the room's edge")
    doc.rooms.side.box = { x = 600, y = 100, w = 440, h = 300 }
    local sb = Place.place(s, doc)
    local sx = math.huge
    for i = 1, #sb.pts, 2 do sx = math.min(sx, sb.pts[i]) end
    ok(math.abs(sx - (760 - 100)) <= 1, "room: it moves with the room's edge")
    -- a piece of a cut stroke in a room finds its room again
    doc.rooms.band.page = 4
    local piece = Place.anchorWith({ kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 320, 910, 340, 920 } },
        doc, item.a)
    ok(piece and piece.a.room == "band", "room: a cut piece stays in the room")
    -- outside any room, ink anchors to words as before
    local out = Place.anchor({ kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 110, 160, 150, 160 } }, doc)
    ok(out and out.a.room == nil and out.a.xp0 == "w1", "room: ink outside the rooms follows its word")
end

-- ---- kept in the book's ink file -------------------------------------------------
do
    local dir = os.tmpname(); os.remove(dir)
    local data = BookInk.load(dir)
    data.rooms = { { id = "r1", kind = "band", xp = "/body/DocFragment[2]/body/p[3]", h = 200 } }
    ok(BookInk.save(dir, data), "file: rooms alone are worth a file")
    local back = BookInk.load(dir)
    ok(back.rooms and #back.rooms == 1 and back.rooms[1].h == 200, "file: the room comes back")
    back.rooms_off = true
    BookInk.save(dir, back)
    ok(BookInk.load(dir).rooms_off == true, "file: hidden stays hidden")
    -- a room this version cannot read is left out
    local f = io.open(BookInk.path(dir), "wb")
    f:write('return { version = 1, items = {}, rooms = { { id = "x", kind = "spiral", xp = "/a" },'
        .. ' { id = "r2", kind = "side", side = "left", xp = "/b", w = 90 } } }')
    f:close()
    local mixed = BookInk.load(dir)
    ok(mixed.rooms and #mixed.rooms == 1 and mixed.rooms[1].id == "r2", "file: an unknown room is left out")
    -- two copies merged (the cloud sync): every room of both, once
    local other = os.tmpname(); os.remove(other)
    BookInk.save(other, { version = 1, items = {}, rooms = {
        { id = "r2", kind = "side", side = "left", xp = "/b", w = 90 },
        { id = "r3", kind = "band", xp = "/c", h = 50 } } })
    local text = BookInk.merge(BookInk.path(dir), BookInk.path(other))
    local merged = assert(load(text))()
    local ids = {}
    for _i, r in ipairs(merged.rooms or {}) do ids[#ids + 1] = r.id end
    table.sort(ids)
    ok(table.concat(ids, ",") == "r2,r3", "file: merged rooms, each once")
    -- a book laid out with markers keeps them, its rooms gone
    BookInk.save(dir, { version = 1, items = {}, rooms_ready = true })
    ok(BookInk.exists(dir) and BookInk.load(dir).rooms_ready == true, "file: the markers are kept with no room left")
    BookInk.save(other, { version = 1, items = {}, rooms = { { id = "r3", kind = "band", xp = "/c", h = 50 } } })
    merged = assert(load(BookInk.merge(BookInk.path(other), BookInk.path(dir))))()
    ok(merged.rooms_ready == true, "file: merged, the markers kept if either had them")
    -- no rooms, no ink, no notes: no file
    BookInk.save(dir, { version = 1, items = {} })
    ok(not BookInk.exists(dir), "file: nothing left, no file")
    os.execute("rm -rf '" .. dir .. "' '" .. other .. "'")
end

-- ---- exact rooms: the planner (Rooms.planBox) -------------------------------------------
do
    local area = { x0 = 30, y0 = 45, x1 = 2114, y1 = 1640 }
    local P0 = "/body/DocFragment[11]/body/p[30]"
    local P1 = "/body/DocFragment[11]/body/p[31]"
    local P2 = "/body/DocFragment[11]/body/p[32]"
    -- lines of 92 px: p[30] began on the page before and ends at 229; p[31] runs
    -- 321..1517; p[32] starts at 1517
    local blocks = {
        { xp = P0, y0 = 45, y1 = 321, starts = false, l1 = 137, lt = 229, lb = 321, ends = true },
        { xp = P1, y0 = 321, y1 = 1517, starts = true, l1 = 413, lt = 1425, lb = 1517, ends = true },
        { xp = P2, y0 = 1517, y1 = 1609, starts = true, l1 = 1609, lt = 1517, lb = 1609, ends = false },
    }
    local page = { area = area, blocks = blocks, cl = 30, cr = 2114, bottom = 1609 }
    -- a box at the right, inside a line of p[31]: pushed down from p[30]'s last line
    local r, box, free = Rooms.planBox({ x = 1694, y = 535, w = 420, h = 300 }, page)
    ok(r and r.kind == "box" and r.side == "right" and r.xp == P1 and r.sp == P0 and r.spp == "after",
        "box: held by its paragraph's marker, pushed by the one before")
    ok(r and r.sh == 535 + 1 - 229 and r.off == -1, "box: pushed to one pixel under its top (the line above keeps its width)")
    ok(box and box.x == 1694 and box.y == 535 and box.w == 420 and box.h == 300, "box: the box drawn, exactly")
    ok(free and free.y == 536 and free.h == 299, "box: its marker from one pixel lower, to the same bottom")
    -- at the left, from the edge to the box's far side
    r, box = Rooms.planBox({ x = 60, y = 700, w = 300, h = 200 }, page)
    ok(r and r.side == "left" and box.x == 30 and box.w == 330, "box: at the left, from the column's edge")
    -- wide, or with too little text beside: across
    r = Rooms.planBox({ x = 300, y = 700, w = 1500, h = 200 }, page)
    ok(r and r.side == "full" and r.w == 2084, "box: wide, across the column")
    -- in a paragraph's first line: its marker at the line's top, the box as drawn
    r, box, free = Rooms.planBox({ x = 1694, y = 340, w = 420, h = 100 }, page)
    ok(r and r.sp == nil and r.off == 19 and box.y == 340 and free.y == 321, "box: in a first line, from its top")
    -- at a paragraph's top exactly
    r = Rooms.planBox({ x = 1694, y = 321, w = 420, h = 100 }, page)
    ok(r and r.sp == nil and r.off == 0, "box: at a paragraph's top, nothing pushes it")
    -- in a paragraph from the page before: from the next one starting on the page
    r, box = Rooms.planBox({ x = 1694, y = 100, w = 420, h = 400 }, page)
    ok(r and r.xp == P1 and box.y == 321 and box.h == 179, "box: above every start, from the next paragraph's")
    -- cut to the page's last line and the column
    r, box = Rooms.planBox({ x = 1694, y = 1400, w = 600, h = 600 }, page)
    ok(box and box.y + box.h == 1609 and box.x + box.w == 2114, "box: cut to the page and the column")
    ok(Rooms.planBox({ x = 1694, y = 700, w = 5, h = 200 }, page) == nil, "box: too thin, none")
    -- another room: its paragraph is taken, and boxes do not overlap
    local used = { [P1 .. "::before"] = true, [P0 .. "::after"] = true }
    local others = { { side = "right", top = 536, bottom = 835, x0 = 1694, x1 = 2114, b = Rooms.slot(2, "before"), s = Rooms.slot(1, "after") } }
    local busy = { area = area, blocks = blocks, cl = 30, cr = 2114, bottom = 1609, used = used, rooms = others }
    local none, why = Rooms.planBox({ x = 30, y = 1000, w = 300, h = 100 }, busy)
    ok(none == nil and why == "taken", "box: one room to a paragraph")
    none, why = Rooms.planBox({ x = 1600, y = 600, w = 500, h = 100 }, busy)
    ok(none == nil and why == "overlap", "box: not over another room")
    r = Rooms.planBox({ x = 30, y = 1517, w = 300, h = 80 }, busy)
    ok(r and r.xp == P2 and r.side == "left", "box: the next paragraph's start is free")
    -- markers in order: a right room under another right room cannot be pushed by a
    -- marker before the higher one's box
    local blocks4 = {
        { xp = P0, y0 = 45, y1 = 321, starts = true, l1 = 137, lt = 229, lb = 321, ends = true },
        { xp = P1, y0 = 321, y1 = 1517, starts = true, l1 = 413, lt = 1425, lb = 1517, ends = true },
    }
    local high = { { side = "right", top = 1000, bottom = 1100, x0 = 1694, x1 = 2114, b = Rooms.slot(2, "before"), s = Rooms.slot(1, "after") } }
    local used4 = { [P1 .. "::before"] = true, [P0 .. "::after"] = true }
    r, why = Rooms.planBox({ x = 1694, y = 160, w = 420, h = 60 },
        { area = area, blocks = blocks4, cl = 30, cr = 2114, bottom = 1609, used = used4, rooms = high })
    ok(r and r.xp == P0 and r.sp == nil, "box: higher on the page, its markers come first")
end

-- ---- exact rooms: the style rules ----------------------------------------------------------
do
    local P = "/body/DocFragment[9]/body/p[10]"
    local O = "/body/DocFragment[9]/body/p[9]"
    local room = { id = "a", kind = "box", side = "right", x = 1694, w = 420, h = 300, xp = P, sp = O, spp = "after", sh = 307, off = -1 }
    local css = Rooms.css({ room }, 1, { ready = true, floats = true })
    ok(css:find(Rooms.MARKERS, 1, true) == 1, "css: the markers first")
    ok(css:find("p:nth-of-type(9)::after { float: right !important; padding-bottom: 307px !important; }", 1, true) ~= nil,
        "css: the marker that pushes, with no width")
    ok(css:find("p:nth-of-type(10)::before { float: right !important; clear: right !important; width: 420px !important; padding-bottom: 299px !important; }", 1, true) ~= nil,
        "css: the box, its height from one pixel under its top")
    css = Rooms.css({ room }, 96 / 300, { ready = true, floats = true })
    ok(css:find("width: 134.4px", 1, true) ~= nil, "css: in the book's own pixels, to a hundredth")
    room.side = "full"
    ok(Rooms.css({ room }, 1, { ready = true, floats = true }):find("float: left !important; clear: both", 1, true) ~= nil,
        "css: across, it clears both sides")
    room.side = "right"
    css = Rooms.css({ room }, 1, { ready = true, floats = false })
    ok(css:find("padding-right: 420px", 1, true) ~= nil and not css:find("clear", 1, true),
        "css: a render mode with no floats, made of paragraphs")
    ok(Rooms.css({}, 1, { ready = true }) == Rooms.MARKERS, "css: no rooms, the markers stay")
    ok(Rooms.hostable(P) and Rooms.hostable("/body/div[2]") and not Rooms.hostable("/body/p/span"), "markers: block elements only")
    ok(Rooms.valid(room) and not Rooms.valid({ id = "b", kind = "box", xp = P, side = "up", x = 1, w = 2, h = 3 }),
        "valid: a box room, and one with no side")
end

print(("rooms: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
