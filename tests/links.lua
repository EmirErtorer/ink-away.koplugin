-- Tests for links between pages and the contents page (ink/links.lua), and a
-- link's place in a selection's changes (ink/transform.lua).
-- Run from the plugin root with:  luajit tests/links.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local Links = require("ink/links")
local Notebook = require("ink/notebook")
local Transform = require("ink/transform")
local Canvas = require("ink/canvas")
local Text = require("ink/text")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- finding a link
do
    local a = Links.new({ x0 = 10, y0 = 10, x1 = 110, y1 = 50 }, { id = 3 })
    local b = Links.new({ x0 = 80, y0 = 30, x1 = 200, y1 = 90 }, { id = 4 })
    local ops = { { kind = "ink", pts = { 0, 0, 5, 5 } }, a, b }
    ok(Links.at(ops, 50, 20) == a, "a point in a link's area finds it")
    ok(Links.at(ops, 90, 40) == b, "where two overlap, the later one")
    local _, idx = Links.at(ops, 150, 60)
    ok(idx == 3, "with its index")
    ok(Links.at(ops, 300, 300) == nil, "nothing elsewhere")
    ok(Links.at(ops, 112, 20, 4) == a, "a fingertip's slop counts")
    ok(#Links.list(ops) == 2, "the links of a page")
    ok(Canvas.opInPoly(a, { 0, 0, 200, 0, 200, 100, 0, 100 }, 0), "the lasso takes a link by its area")
end

-- the page it leads to: by id, through moves, else by number
do
    local nb = Notebook.new(600, 800, { style = "lines", size = 40 })
    for _ = 1, 4 do nb:addPage() end
    local id3 = nb.pages[3].id
    ok(Links.pageIndex(nb, { id = id3, page = 3 }) == 3, "a link finds its page")
    nb.index = 3
    nb:movePage(-1)
    ok(Links.pageIndex(nb, { id = id3, page = 3 }) == 2, "and follows it when the page moves")
    ok(Links.pageIndex(nb, { id = 999, page = 4 }) == 4, "a lost id falls back to the number")
    ok(Links.pageIndex(nb, { id = 999, page = 99 }) == nil, "and a number past the end is nothing")
end

-- the contents
do
    local nb = Notebook.new(600, 800, { style = "lines", size = 40 })
    for _ = 1, 5 do nb:addPage() end
    nb.pages[2].title = "Forces"
    nb.pages[4].title = "Energy"
    nb.pages[1].contents, nb.pages[1].title = true, "Contents"
    local e = Links.contentsEntries(nb)
    ok(#e == 2 and e[1].title == "Forces" and e[2].id == nb.pages[4].id, "the contents lists titled pages, "
        .. "not itself")
    local geo = Links.contentsGeometry(600, 800, 40)
    ok(geo.row == 40 and geo.first == 120 and geo.per == 16, "lines sit on the ruling: " .. geo.per .. " a page")
    local ops = Links.contentsOps({ { id = 7, title = "Forces", page = 2 }, { id = 9, title = "Energy", page = 4 } },
        geo, 600, "Contents")
    local links, texts = {}, {}
    for _, op in ipairs(ops) do
        if op.kind == "link" then links[#links + 1] = op else texts[#texts + 1] = op end
        ok(op.toc == true, "every line of it is marked as the contents'")
    end
    ok(#texts == 5 and Text.plain(texts[1]) == "Contents", "a heading, then a title and a number a line")
    ok(Text.plain(texts[3]) == "2" and texts[3].align == "right", "the page number on the right")
    ok(#links == 2 and links[1].to.id == 7 and links[1].y == 120 and links[2].y == 160
        and links[1].h == 40 and links[1].x == geo.margin, "each line links to its page, a ruling line each")
    ok(#Links.contentsOps({}, geo, 600, nil) == 0, "a continuation page has no heading")
end

-- in a PDF: y runs up, and only links whose page is exported
do
    local ops = { Links.new({ x0 = 10, y0 = 20, x1 = 110, y1 = 60 }, { id = 5 }),
                  Links.new({ x0 = 0, y0 = 0, x1 = 10, y1 = 10 }, { id = 6 }) }
    local a = Links.pdfAnnots(ops, 800, function(to) return to.id == 5 and 3 or nil end)
    ok(#a == 1 and a[1].x0 == 10 and a[1].y0 == 740 and a[1].x1 == 110 and a[1].y1 == 780 and a[1].page == 3,
        "a PDF link: its area with y up, to the page in the file")
end

-- a link moves and resizes with a selection, and stays square on a turn
do
    local l = Links.new({ x0 = 100, y0 = 100, x1 = 200, y1 = 140 }, { id = 1 })
    Transform.scale(l, 100, 100, 2)
    ok(l.x == 100 and l.w == 200 and l.h == 80 and l.size == nil, "a link grows with its selection")
    Transform.rotate(l, 0, 0, math.pi)
    ok(math.abs(l.x + 300) < 1e-9 and l.w == 200 and l.angle == nil, "and turns round its centre, unturned")
    Transform.flip(l, "h", 0)
    ok(math.abs(l.x - 100) < 1e-9, "and mirrors to its place")
    Canvas.translateOp(l, 5, 5)
    ok(math.abs(l.x - 105) < 1e-9, "and moves")
end

print(("links: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
