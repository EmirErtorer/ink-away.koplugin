-- An editable PDF through KOReader's real MuPDF: the original is copied and the ink
-- and highlights are appended as annotations. The original must stay byte for byte
-- as it was, the copy about as big, every page still there, the annotations real
-- ones (MuPDF reads them back), and stopping must leave no file behind.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/pdfedit.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
package.path = REPO .. "/?.lua;" .. package.path
local ffi = require("ffi")
local Export = require("ink/export")
local Annots = require("ink/export/annots")
local Pdfedit = require("ink/export/pdfedit")
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); local s = f and f:read("*a"); if f then f:close() end; return s end

local tmp = os.getenv("TMPDIR") or "/tmp"
local src, dst = tmp .. "/inkaway_edit_src.pdf", tmp .. "/inkaway_edit_dst.pdf"

-- a 5 page source made with the plain page writer (each page an image)
local W, H = 595, 842
local function bg() local b = ffi.new("uint8_t[?]", W * H * 4); ffi.fill(b, W * H * 4, 255); return b end
local pages = {}
for i = 1, 5 do pages[i] = {} end
local mk = assert(Export.notebookPDFJob(pages, W, H, { style = "blank" }, src, 80, tmp, bg, { bg_opaque = true }))
while true do local s = mk.step(); if s == "done" then break end; assert(s) end
local original = slurp(src)

ok(Pdfedit.available(src), "the MuPDF here can write ink annotations")

-- what the notebook's ops become
local ops = {
    { kind = "ink", style = "ballpoint", width = 4, alpha = 255, color = { 200, 0, 0 }, pts = { 100, 100, 300, 120, 500, 100 } },
    { kind = "ink", style = "highlighter", width = 20, alpha = 255, pts = { 100, 300, 500, 300 } },
    { kind = "shape", shape = "rect", width = 3, alpha = 255, pts = { 100, 400, 300, 500 } },
    { kind = "text", x = 10, y = 10, w = 100, h = 20 },
    { kind = "fill", runs = { 0, 0, 5 }, color = { 0, 0, 0 } },
}
local left = Annots.leftOut({ ops })
ok(left.text == 1 and left.fill == 1 and left.total == 2, "text and a fill are counted as left out")
local groups = Annots.convert(ops, { s = 1, ox = 0, oy = 0 })
ok(#groups == 3, "the strokes, the highlighter and the rectangle become annotations (" .. #groups .. ")")

local work = {
    { page = 2, groups = groups, marks = { { pboxes = { { x = 50, y = 600, w = 200, h = 14 } }, drawer = "lighten", color = "#FFFF00", note = "a note" } } },
    { page = 4, groups = { groups[1] }, marks = {} },
}
local job = assert(Pdfedit.job(src, dst, work))
local steps = 0
while true do
    local state, a = job.step()
    steps = steps + 1
    if state == "done" then break end
    ok(state == "page", "a step reports a page: " .. tostring(state) .. " " .. tostring(a))
    if state ~= "page" then break end
    if steps > 50 then ok(false, "the job never finishes"); break end
end

ok(slurp(src) == original, "the original file is untouched")
local out = slurp(dst) or ""
ok(#out > #original and #out < #original + 20000, ("the copy is the original plus a little (%d -> %d bytes)"):format(#original, #out))
ok(out:sub(1, #original) == original, "the annotations are appended to the original's bytes")
local M = require("ffi/mupdf")
local doc = M.openDocument(dst)
ok(doc:getPages() == 5, "every page is still there")
local p2 = doc:openPage(2)
local embedded = p2:getEmbeddedAnnotations() or {}
ok(#embedded >= 1, "page 2 has the highlight KOReader reads back (" .. #embedded .. ")")
p2:close()
doc:close()
if os.getenv("KEEP") then local f = io.open(tmp .. "/kept.pdf", "wb"); f:write(out); f:close() end
ok(select(2, out:gsub("/Subtype ?/Ink", "")) == 4, "four ink annotations written (3 on page 2, 1 on page 4)")
ok(select(2, out:gsub("/Subtype ?/Highlight", "")) == 1, "one highlight written")

-- stopping part-way leaves nothing
os.remove(dst)
local job2 = assert(Pdfedit.job(src, dst, work))
job2.step(); job2.step()
job2.cancel()
ok(not io.open(dst, "rb"), "stopping removes the partial file")

-- a source that is not there fails cleanly
local job3 = assert(Pdfedit.job(tmp .. "/nope.pdf", dst, work))
local s, e = job3.step()
ok(s == nil and e, "a missing source ends the job with an error")

if os.getenv("KEEP") then print("kept", src, dst) else os.remove(src); os.remove(dst) end
print(("pdfedit: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
