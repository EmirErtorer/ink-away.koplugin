-- Native renderer, encoder and decoder; no network or private images.
local REPO = arg[1] or "."
require("ffi/loadlib")
package.path = REPO .. "/?.lua;" .. package.path
local ffi = require("ffi")
local Image = require("ink/ocr/image")
local Canvas = require("ink/canvas")
local png = require("ffi/png")
local c = Canvas.new(320, 240)
c.ops = {
    { kind = "ink", pen = "ballpoint", pts = { 40, 60, 120, 60, 180, 60 }, width = 5, pr = { 20, 120, 220 } },
    { kind = "erase", pts = { 100, 45, 100, 75 }, width = 16 },
    { kind = "ink", pts = { 40, 120, 180, 120 }, width = 4 },
    { kind = "text", x = 0, y = 0, w = 320, h = 240 },
}
local snapshot = assert(Image.snapshot(c, { c.ops[1], c.ops[3] }))
local bytes = assert(Image.png(snapshot))
assert(bytes:sub(1, 8) == "\137PNG\13\10\26\10", "native PNG signature")
local path = os.tmpname()
local f = assert(io.open(path, "wb")); f:write(bytes); f:close()
local ok, decoded = png.decodeFromFile(path, 4)
os.remove(path)
assert(ok, decoded)
local r = snapshot.rect
assert(decoded.width == r.w and decoded.height == r.h)
local function red(x, y) return decoded.data[((y - r.y) * r.w + x - r.x) * 4] end
assert(red(100, 60) == 255, "erased ink stays white after native PNG round trip")
assert(red(60, 120) == 0, "second handwritten line survives native PNG round trip")
assert(red(r.x, r.y) == 255, "white paper without guide/background")
ffi.C.free(decoded.data)
print("native OCR image: multiline renderer/erase/PNG round trip passed")
