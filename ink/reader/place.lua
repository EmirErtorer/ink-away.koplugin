--[[
Where ink drawn on a book goes, and where it comes back.

Ink is drawn on the page as the screen shows it. To keep it with the text when
the book is laid out again (another font size, margins, a turned screen), each
op is saved against an anchor:

  * a reflowing book (EPUB, MOBI, FB2...): the word nearest the op, by its
    xpointers, and the op's offset from that word's box. When the text moves,
    the ink moves with its word. A page with no words (a picture) anchors to the
    page's first xpointer, at the op's place on the screen.
  * a fixed-page book (PDF, DjVu, CBZ): the page number and the op's place on
    the page, in the page's own units, so zooming or turning the screen keeps
    it on the same spot of the page.

The op itself is kept with its top-left at its anchor's origin, and for fixed
pages at the page's scale (1 page unit = 1 px), so it can be moved and scaled
back onto any layout. Everything that asks the book something goes through a
small adapter (see ink/reader/annotate.lua), so this file is plain Lua and the
headless tests drive it with a stand-in.

An item is { op = <op in anchor space>, a = <anchor> }:
  rolling, word:  a = { xp0, xp1, dx, dy }        dx, dy from the word's box;
                  ml or mr instead of dx for ink in the left or right margin: its
                  distance from that screen edge, so it stays in the margin
  rolling, page:  a = { pxp, dx, dy }              dx, dy on the screen
  paging:         a = { page, x, y }               page units
]]

local Canvas = require("ink/canvas")
local Transform = require("ink/transform")

local Place = {}

local floor = math.floor

local function copy(op)
    return Canvas.cloneOp(nil, op)
end

-- The op moved by (dx, dy) and scaled by s about the origin first: a new op.
function Place.moved(op, dx, dy, s)
    local c = copy(op)
    if s and s ~= 1 then Transform.scale(c, 0, 0, s) end
    if dx ~= 0 or dy ~= 0 then Canvas.translateOp(c, dx, dy) end
    return c
end

-- The box of an op on the screen: x0, y0 (nil when it draws nothing).
local function origin(op)
    local x0, y0 = Canvas.opBox(op)
    if not x0 then return nil end
    return floor(x0), floor(y0)
end

-- Anchor a screen op. Returns the item, or nil for an op that draws nothing.
function Place.anchor(op, doc)
    local x0, y0 = origin(op)
    if not x0 then return nil end
    if doc.kind == "paging" then
        local page, px, py, zoom = doc:toPage(x0, y0)
        if not page then return nil end
        -- the top-left at the origin, then in page units (the zoom undone)
        return { op = Place.moved(Place.moved(op, -x0, -y0), 0, 0, 1 / zoom),
                 a = { page = page, x = px, y = py } }
    end
    local x1, y1 = select(3, Canvas.opBox(op))
    local cx, cy = floor((x0 + x1) / 2), floor((y0 + y1) / 2)
    -- the word under the middle; for an underline (whose middle is between two
    -- lines) the word just above it; then just below; then the nearest one
    local w = doc:wordAt(cx, cy) or doc:wordAt(cx, y0 - 6) or doc:wordAt(cx, y1 + 6)
        or doc:nearestWord(cx, cy)
    local local_op = Place.moved(op, -x0, -y0)
    if w and w.box then
        local a = { xp0 = w.xp0, xp1 = w.xp1, dx = x0 - w.box.x, dy = y0 - w.box.y }
        -- ink in a side margin stays in it: kept by its distance from that edge
        local W = doc.width and doc:width()
        if W then
            if x0 >= w.box.x + w.box.w + 16 and x0 > W * 0.75 then a.dx, a.mr = nil, W - x0
            elseif x1 <= w.box.x - 16 and x1 < W * 0.25 then a.dx, a.ml = nil, x0 end
        end
        return { op = local_op, a = a }
    end
    return { op = local_op, a = { pxp = doc:pageTop(), dx = x0, dy = y0 } }
end

-- Which page an item is on, for this layout (nil if it cannot be placed).
function Place.pageOf(item, doc)
    local a = item.a
    if a.page then return a.page end
    if a.xp0 then return doc:pageOf(a.xp0) end
    if a.pxp then return doc:pageOf(a.pxp) end
    return nil
end

-- An item as a screen op on the page now shown, or nil if it is not on it.
function Place.place(item, doc)
    local a = item.a
    if a.page then
        local sx, sy, zoom = doc:toScreen(a.page, a.x, a.y)
        if not sx then return nil end
        return Place.moved(Place.moved(item.op, 0, 0, zoom), sx, sy)
    end
    if a.xp0 then
        local box = doc:boxOf(a.xp0, a.xp1)
        if not box then return nil end
        local x
        if a.mr then x = (doc.width and doc:width() or 0) - a.mr
        elseif a.ml then x = a.ml
        else x = box.x + (a.dx or 0) end
        return Place.moved(item.op, x, box.y + a.dy)
    end
    if a.pxp then return Place.moved(item.op, a.dx, a.dy) end
    return nil
end

-- Which items are on which page, for the layout `doc` describes: a table page
-- -> list of item indexes. Built once per layout; cheap to ask again.
function Place.index(items, doc)
    local idx = {}
    for i, item in ipairs(items) do
        local p = Place.pageOf(item, doc)
        if p then
            local l = idx[p]
            if not l then l = {}; idx[p] = l end
            l[#l + 1] = i
        end
    end
    return idx
end

return Place
