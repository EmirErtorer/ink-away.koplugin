--[[
A notebook's cover for Bookshelf (ink/bookshelf.lua): the notebook seen from
the front, its first page filling the cover, a spiral binding whose wire loops
wrap round the left edge, and the name on a coloured band at the bottom. Written once to a PNG in the cache, and again only
when the notebook changes.

The page is drawn by an Ink Away view when one is at hand (as its library
thumbnails are: text, pictures and an imported PDF's page included), else by
the export engine, which draws the paper, ruling, ink, shapes and fills but
leaves out text and pictures (they need the view's fonts and image cache).
]]

local Canvas = require("ink/canvas")
local Export = require("ink/export")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Storage = require("ink/storage")

local Cover = {}

-- The cover's size in pixels, a book's proportions. Bookshelf scales it to
-- the shelf, so one size does for every screen.
Cover.W, Cover.H = 480, 672

-- Band colours, one per notebook by its path, so each keeps its own colour
-- and neighbours on the shelf usually differ. Dark enough that the white name
-- stands out on grey screens too.
Cover.BOARDS = {
    { 0x2E, 0x4A, 0x7A },   -- navy
    { 0x2F, 0x6B, 0x4F },   -- green
    { 0x8A, 0x2F, 0x3A },   -- red
    { 0x3C, 0x3C, 0x44 },   -- charcoal
    { 0x5B, 0x3F, 0x7A },   -- plum
    { 0x1F, 0x6E, 0x78 },   -- teal
}

-- The band colour of the notebook at `path`.
function Cover.boardOf(path)
    local n = tonumber(Library.pathCode(path), 16) or 0
    return Cover.BOARDS[n % #Cover.BOARDS + 1]
end

-- The name band's height at the bottom of the cover.
Cover.BAND = 104

-- Where the parts go: the page (x, y, w, h) above the name band, edge to
-- edge (Bookshelf lays a cover on black, so nothing can stick out past it),
-- and the band.
function Cover.layout()
    return { x = 0, y = 0, w = Cover.W, h = Cover.H - Cover.BAND },
        { x = 0, y = Cover.H - Cover.BAND, w = Cover.W, h = Cover.BAND }
end

-- Render page `pageno` of the PDF at `pdf_path` to fit `w` x `h`, as the
-- notebook view does. Returns a BlitBuffer or nil.
local function pdfPage(pdf_path, pageno, w, h)
    local img
    pcall(function()
        local doc = require("document/documentregistry"):openDocument(pdf_path)
        if not doc then return end
        pcall(function()
            local Document = require("document/document")
            local Geom = require("ui/geometry")
            local native = Document.getNativePageDimensions(doc, pageno)
            if not (native and native.w and native.h) then return end
            local zoom = math.min(w / native.w, h / native.h)
            local rect = Geom:new{ x = 0, y = 0,
                w = math.floor(native.w * zoom + 0.5), h = math.floor(native.h * zoom + 0.5) }
            local tile = Document.renderPage(doc, pageno, rect, zoom, 0, 1.0, 1.0, false)
            if tile and tile.bb then img = tile.bb:copy() end
        end)
        doc:close()
    end)
    return img
end

-- The notebook's first page at `w` x `h` through the export engine: its paper,
-- ruling and ink (over the PDF page, for an imported PDF). Returns an RGB32
-- BlitBuffer.
function Cover.pageImage(nb, w, h)
    local BB = require("ffi/blitbuffer")
    local RenderImage = require("ui/renderimage")
    local page = nb.pages[1]
    local template = nb:pageTemplate(1)
    local canvas = Canvas.new(nb.w, nb.h)
    canvas:setOps(page.ops)
    local pdf = template.pdf_path and page.src and Storage.exists(template.pdf_path)
    -- see-through over a PDF page, else on the page's paper
    local buf, ow, oh = Export.buildPNGRGBA(canvas, { template = template, white = not pdf })
    local full = BB.new(ow, oh, BB.TYPE_BBRGB32, buf)
    local ink = RenderImage:scaleBlitBuffer(full, w, h, false)
    full = nil   -- luacheck: ignore 311
    buf = nil    -- luacheck: ignore 311
    local out = BB.new(w, h, BB.TYPE_BBRGB32)
    local paper = template.paper or { 255, 255, 255 }
    out:paintRectRGB32(0, 0, w, h, BB.ColorRGB32(paper[1], paper[2], paper[3], 0xFF))
    if pdf then
        local bg = pdfPage(template.pdf_path, page.src, w, h)
        if bg then
            out:blitFrom(bg, math.floor((w - bg:getWidth()) / 2), math.floor((h - bg:getHeight()) / 2),
                0, 0, bg:getWidth(), bg:getHeight())
            bg:free()
        end
        out:alphablitFrom(ink, 0, 0, 0, 0, w, h)
    else
        out:blitFrom(ink, 0, 0, 0, 0, w, h)
    end
    ink:free()
    return out
end

-- One wire loop of the spiral, an oval ring from x0 to x1 centred on row y.
-- A loop starting left of the cover is drawn whole on a scrap holding what
-- is under it, and only its part on the cover goes back, so the wire runs off
-- the edge.
local function paintLoop(bb, x0, x1, y, wire, edge)
    local BB = require("ffi/blitbuffer")
    local w, h = x1 - x0 + 2, 20
    local left, top = x0 - 1, y - 10
    local cut = math.max(0, -left)   -- scrap columns left of the cover
    local t = BB.new(w, h, BB.TYPE_BBRGB32)
    t:blitFrom(bb, cut, 0, left + cut, top, w - cut, h)
    t:paintBorderRGB32(0, 0, w, h, 7, edge, 9)
    t:paintBorderRGB32(1, 1, w - 2, h - 2, 5, wire, 8)
    bb:blitFrom(t, left + cut, top, cut, 0, w - cut, h)
    t:free()
end

-- The spiral down the page's left edge: a punched hole near the edge and a
-- wire loop from it round the edge, every few millimetres, the band included.
local function paintSpiral(bb)
    local BB = require("ffi/blitbuffer")
    local hole = BB.ColorRGB32(0x3A, 0x3A, 0x3A, 0xFF)
    local wire = BB.ColorRGB32(0xD8, 0xD8, 0xDC, 0xFF)
    local edge = BB.ColorRGB32(0x60, 0x60, 0x68, 0xFF)
    local hx = 22
    for y = 18, Cover.H - 12, 30 do
        bb:paintRoundedRectRGB32(hx - 6, y - 6, 12, 12, hole, 6)
        paintLoop(bb, -16, hx + 5, y, wire, edge)
    end
end

-- The notebook's name in white, centred on the band, shrunk to fit and cut
-- short with an ellipsis when still too long.
local function paintName(bb, band, name)
    local BB = require("ffi/blitbuffer")
    local Font = require("ui/font")
    local RenderText = require("ui/rendertext")
    local Screen = require("device").screen
    -- Font sizes scale with the screen; the cover is in plain pixels.
    local per = Screen:scaleBySize(1000) / 1000
    local left = 34   -- clear of the spiral
    local room = band.w - left - 24
    local face, tw, text
    for px = 44, 26, -6 do
        face = Font:getFace("cfont", px / per)
        text = name
        tw = RenderText:sizeUtf8Text(0, room * 4, face, text, true, true).x
        if tw <= room then break end
    end
    if tw > room then
        text = RenderText:truncateTextByWidth(name, face, room, true, true)
        tw = RenderText:sizeUtf8Text(0, room, face, text, true, true).x
    end
    local baseline = band.y + math.floor(band.h / 2 + face.size * 0.35)
    RenderText:renderUtf8Text(bb, band.x + left + math.floor((room - tw) / 2), baseline, face, text,
        true, true, BB.COLOR_WHITE)
end

-- The first page of the notebook at `path` drawn by Ink Away view `view`, on
-- the page's paper, at `w` x `h`. Returns an RGB32 BlitBuffer or nil.
local function viewPage(view, path, w, h)
    local BB = require("ffi/blitbuffer")
    local ok, thumb = pcall(view.renderDocThumb, view, path, w, h)
    if not (ok and thumb) then return nil end
    local out = BB.new(w, h, BB.TYPE_BBRGB32)
    out:paintRectRGB32(0, 0, w, h, BB.ColorRGB32(0xFF, 0xFF, 0xFF, 0xFF))
    local tw, th = thumb:getWidth(), thumb:getHeight()
    out:blitFrom(thumb, math.floor((w - tw) / 2), math.floor((h - th) / 2), 0, 0, tw, th)
    thumb:free()
    return out
end

-- The cover of the notebook at `path` as an RGB32 BlitBuffer, or nil when it
-- can't be read. `view`, an Ink Away view, draws the page when given.
function Cover.render(path, view)
    local data = Project.load(path)
    if not (data and Project.isNotebook(data)) then return nil end
    local nb = Notebook.fromData(data)
    if #nb.pages == 0 then return nil end
    local BB = require("ffi/blitbuffer")
    local colour = Cover.boardOf(path)
    local page, band = Cover.layout()
    local bb = BB.new(Cover.W, Cover.H, BB.TYPE_BBRGB32)
    -- the page at the cover's width, its top part showing above the band
    local full_h = math.max(page.h, math.floor(page.w * nb.h / nb.w + 0.5))
    local img = view and viewPage(view, path, page.w, full_h) or Cover.pageImage(nb, page.w, full_h)
    bb:blitFrom(img, page.x, page.y, 0, 0, page.w, page.h)
    img:free()
    bb:paintRectRGB32(band.x, band.y, band.w, band.h, BB.ColorRGB32(colour[1], colour[2], colour[3], 0xFF))
    paintSpiral(bb)
    paintName(bb, band, Storage.stem(path))
    return bb
end

-- Draw the cover of the notebook at `path` to PNG `file`, the page by `view`
-- when given. Returns whether it was written.
function Cover.write(path, file, view)
    local ok, bb = pcall(Cover.render, path, view)
    if not (ok and bb) then return false end
    local tmp = file .. ".tmp"
    local wrote = pcall(function() bb:writePNG(tmp) end)
    bb:free()
    if not (wrote and Storage.exists(tmp)) then os.remove(tmp); return false end
    return os.rename(tmp, file) == true
end

return Cover
