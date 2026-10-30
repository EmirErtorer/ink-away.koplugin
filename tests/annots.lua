-- What an export takes from a book and writes as PDF annotations: ink and shapes as
-- lines in the page's units, the eraser applied first, what a PDF annotation cannot
-- hold counted (ink/export/annots.lua), and which pages a book offers an export
-- (ink/reader/bookexport.lua), on a stand-in book.
--   luajit tests/annots.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Annots = require("ink/export/annots")
local BookExport = require("ink/reader/bookexport")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- ---- ink and shapes become lines in the page's units -------------------------------
do
    local ops = {
        { kind = "ink", style = "solid", width = 8, alpha = 255, color = { 200, 0, 0 }, pts = { 110, 220, 210, 220 } },
        { kind = "ink", style = "highlighter", width = 20, alpha = 255, color = { 255, 235, 59 }, pts = { 10, 10, 90, 10 } },
        { kind = "shape", shape = "rect", width = 4, alpha = 255, pts = { 20, 20, 80, 60 } },
        { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 50, 50 } },   -- a dot
        { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 1, 1, 9, 9 }, hidden = true },
        { kind = "link", x = 0, y = 0, w = 10, h = 10 },
    }
    local g = Annots.convert(ops, { s = 2, ox = 10, oy = 20 })
    ok(#g == 4, "a line, a highlighter, a rectangle and a dot are annotations; hidden ink and links are not (" .. #g .. ")")
    local p1 = g[1].strokes[1]
    ok(near(p1[1].x, 50) and near(p1[1].y, 100) and near(p1[2].x, 100), "the page's units: (px - origin) / scale")
    ok(near(g[1].width, 4) and g[1].color.r == 200 and g[1].opacity == 1, "width follows the scale, colour as drawn, opaque")
    ok(g[2].opacity < 0.6, "a highlighter is written see-through")
    ok(#g[3].strokes == 1 and #g[3].strokes[1] == 5, "a rectangle is its outline, closed")
    ok(g[4].color.r == 0 and #g[4].strokes[1] == 2, "a dot is a stroke of two points, black without a colour")
end

-- ---- the eraser cuts what was drawn before it ---------------------------------------
do
    local ops = {
        { kind = "ink", style = "solid", width = 6, alpha = 255, pts = { 100, 100, 300, 100 } },
        { kind = "erase", width = 20, pts = { 200, 60, 200, 140 } },
        { kind = "ink", style = "solid", width = 6, alpha = 255, pts = { 200, 200, 300, 200 } },   -- after it: whole
    }
    local g = Annots.convert(ops, { s = 1, ox = 0, oy = 0 })
    ok(#g == 3, "a stroke crossed by an eraser is two lines, a later stroke is whole (" .. #g .. ")")
    local right = g[2].strokes[1]
    ok(right[1].x >= 200 + 10, "nothing is left under the eraser")
end

-- ---- what a PDF annotation cannot hold is counted -----------------------------------
do
    local page1 = {
        { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 1, 1, 9, 9 } },
        { kind = "text", x = 0, y = 0, w = 50, h = 20 },
        { kind = "image", x = 0, y = 0, w = 10, h = 10 },
        { kind = "fill", runs = { 0, 0, 5 }, color = { 0, 0, 0 } },
    }
    local page2 = {
        { kind = "shape", shape = "rect", fill = true, width = 3, alpha = 255, pts = { 0, 0, 10, 10 } },
        { kind = "shape", shape = "rect", fill_color = { 255, 0, 0 }, width = 3, alpha = 255, pts = { 0, 0, 10, 10 } },
        { kind = "shape", shape = "rect", width = 3, alpha = 255, pts = { 0, 0, 10, 10 } },   -- an outline is fine
        { kind = "smudge", pts = { 0, 0, 10, 10 }, width = 8 },
        { kind = "text", hidden = true, x = 0, y = 0, w = 50, h = 20 },   -- hidden: not counted
    }
    local n = Annots.leftOut({ page1, page2 })
    ok(n.text == 1 and n.image == 1 and n.fill == 3 and n.smudge == 1 and n.total == 6,
        ("each kind counted (%d text, %d pictures, %d fills, %d smudges)"):format(n.text, n.image, n.fill, n.smudge))
    local none = Annots.leftOut({ { { kind = "ink", style = "solid", width = 4, alpha = 255, pts = { 1, 1, 9, 9 } } } })
    ok(none.total == 0, "plain ink leaves nothing out")
end

-- ---- which pages a book offers, and its ink as ops ----------------------------------
do
    local items = {
        { op = { kind = "ink", style = "solid", width = 2, alpha = 255, pts = { 0, 0, 10, 10 } }, a = { page = 3, x = 5, y = 6 } },
    }
    local function book(paging)
        return {
            ui = { paging = paging and {} or nil,
                document = { getPageCount = function() return 10 end, is_pdf = paging or nil, file = "/books/x.pdf" },
                annotation = { annotations = {
                    { drawer = "lighten", pos0 = {}, page = 7, pboxes = { { x = 10, y = 20, w = 100, h = 12 } }, color = "yellow" },
                    { page = 9 },   -- a bookmark: no drawer, not a highlight
                } } },
            data = function() return { items = items } end,
            doc = function() return { kind = "paging" } end,
            currentPage = function() return 4 end,
            hasInk = function() return true end,
        }
    end
    local b = book(true)
    local function list(t) return table.concat(t, ",") end
    ok(list(BookExport.pages(b, "page")) == "4", "this page: the one shown")
    ok(list(BookExport.pages(b, "all")) == "1,2,3,4,5,6,7,8,9,10", "all pages")
    ok(list(BookExport.pages(b, "ink")) == "3,7", "pages with ink: the ink's page and the highlight's")
    ok(list(BookExport.pages(b, "range", { from = 2, to = 4 })) == "2,3,4", "a range")
    ok(list(BookExport.pages(b, "range", { from = 8, to = 99 })) == "8,9,10", "a range stops at the last page")
    ok(list(BookExport.pages(b, "all", nil, 2)) == "1,3,5,7,9", "two pages on the screen: every second")
    ok(BookExport.pdfPath(b) == "/books/x.pdf" and BookExport.pdfPath(book(false)) == nil, "only a PDF book has a PDF to edit")
    ok(#BookExport.highlights(b) == 1, "a bookmark is not a highlight")

    local ops = BookExport.pageOps(items, nil, 2)
    ok(#ops == 1 and ops[1].pts[1] == 10 and ops[1].pts[2] == 12 and ops[1].width == 4,
        "ink lands at its anchor times the scale, its width scaled")
    local hl = BookExport.pageOps({}, BookExport.marksByPage(b)[7], 2)[1]
    ok(hl and hl.style == "highlighter" and hl.width == 24 and hl.pts[1] == 20 and hl.pts[3] == 220 and hl.pts[2] == 52,
        "a highlight is a highlighter line along its box's middle, as tall as the box")
    local under = BookExport.pageOps({}, { { drawer = "underscore", color = "red", pboxes = { { x = 0, y = 0, w = 10, h = 10 } } } }, 1)[1]
    ok(under.style == "solid" and under.pts[2] == 10, "an underline is a line along the box's foot")
end

print(("annots: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
