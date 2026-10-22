package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Image = require("ink/ocr/image")
local Canvas = require("ink/canvas")
local c = Canvas.new(220, 180)
local function ink(y, layer)
    return { kind = "ink", pts = { 30, y, 180, y }, width = 4, layer = layer }
end
local a, b = ink(50, 1), ink(100, 2)
local erase = { kind = "erase", pts = { 100, 35, 100, 65 }, width = 20, layer = 1 }
c.ops = { a, b, erase, { kind = "text", x = 10, y = 10, w = 200, h = 100 },
    { kind = "image", x = 0, y = 0, w = 220, h = 180 } }
local snap = assert(Image.snapshot(c, { a }))
local buf, w, h = Image.pixels(snap)
local function pixel(x, y)
    return buf[((y - snap.rect.y) * w + x - snap.rect.x) * 4]
end
assert(pixel(60, 50) == 0 and pixel(100, 50) == 255, "native erasure survives OCR raster")
assert(#snap.layers[1].ops == 2, "unselected ink, text and images excluded")
assert(pixel(60, snap.rect.y) == 255, "white background, no paper or book image")
assert(w * h <= Image.MAX_PIXELS)
assert(a.color == nil and a.pts[1] == 30, "snapshot leaves source untouched")
a.pts[1] = 55
assert(snap.layers[1].ops[1].pts[1] == 30, "snapshot points detached")
a.pts[1] = 30
erase.hidden = true
snap = assert(Image.snapshot(c, { a })); buf, w = Image.pixels(snap)
assert(pixel(100, 50) == 0, "hidden eraser excluded")
erase.hidden = nil
c.layers, c.hidden_layers = { { id = 1 }, { id = 2 } }, {}
erase.layer = 2
snap = assert(Image.snapshot(c, { a })); buf, w = Image.pixels(snap)
assert(pixel(100, 50) == 0, "other-layer erasure cannot remove selected ink")
erase.layer = 1
snap = assert(Image.snapshot(c, { a, b })); buf, w = Image.pixels(snap)
assert(pixel(100, 50) == 255 and pixel(100, 100) == 0, "layers erase independently")
local first = c.ops[1]
c.ops = { erase, first }
snap = assert(Image.snapshot(c, { a })); buf, w = Image.pixels(snap)
assert(pixel(100, 50) == 0, "erase before selected ink does not erase it")
a.sym = "vert"
snap = assert(Image.snapshot(c, { a }))
assert(snap.rect.x <= 24 and snap.rect.x + snap.rect.w >= 196, "crop includes mirrored ink and brush margin")
local large = Canvas.new(5000, 5000)
large.ops = { { kind = "ink", pts = { 0, 0, 4999, 4999 }, width = 4 } }
assert(not Image.snapshot(large, large.ops), "oversized selection rejected before pixel allocation")
assert(not Image.snapshot(c, {}), "empty selection rejected")
print("ocr_image: selected foreground, geometry, erase, layer, snapshot and size checks passed")
