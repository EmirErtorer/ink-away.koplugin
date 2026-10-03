-- A long notebook export (300 pages, PDF-import style backgrounds) through the real
-- JPEG encoder: memory must stay flat page after page, the file must be complete
-- (KOReader's own MuPDF opens it with every page), and stopping must delete it.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/pdfexport.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
package.path = REPO .. "/?.lua;" .. package.path
local ffi = require("ffi")
local Export = require("ink/export")
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local W, H, N = 1072, 1448, 300
local tmp = os.getenv("TMPDIR") or "/tmp"
local out = tmp .. "/inkaway_export_test.pdf"
local function bg(i)                 -- a fresh, opaque page image each time, like a rendered PDF page
    local b = ffi.new("uint8_t[?]", W * H * 4)
    ffi.fill(b, W * H * 4, 255)
    local g = (i * 37) % 200
    for y = 100, 140 do
        for x = 80, 479 do local o = (y * W + x) * 4; b[o], b[o + 1], b[o + 2] = g, g, g end
    end
    return b
end
local pages = {}
for i = 1, N do pages[i] = {} end
pages[26] = { { kind = "ink", width = 6, alpha = 255, pts = { 100, 300, 600, 340, 900, 500 } } }

collectgarbage("collect")
local base = collectgarbage("count")
local job = assert(Export.notebookPDFJob(pages, W, H, { style = "blank" }, out, 90, tmp, bg, { bg_opaque = true }))
local peak, mid, t0 = 0, nil, os.clock()
while true do
    local state, a = job:step()
    if state == "page" then
        local kb = collectgarbage("count")
        if kb > peak then peak = kb end
        if a == 150 then mid = kb end
    elseif state == "done" then break
    else ok(false, "export step failed: " .. tostring(a)); break end
end
local secs = os.clock() - t0
local grow_mb = (peak - base) / 1024
print(string.format("  300 pages in %.1fs (%.0f ms/page on this machine), heap growth peak %.1f MB", secs, secs * 1000 / N, grow_mb))
ok(grow_mb < 40, ("memory stays flat over a 300-page export (peak growth %.1f MB)"):format(grow_mb))
ok(mid and math.abs(mid - peak) / 1024 < 40, "no build-up between page 150 and the end")
local f = io.open(out, "rb"); local s = f:read("*a"); f:close()
ok(s:find("/Count 300", 1, true) ~= nil, "the PDF lists all 300 pages")
local mok, Mupdf = pcall(require, "ffi/mupdf")
if mok then
    local dok, doc = pcall(Mupdf.openDocument, out)
    ok(dok and doc and doc:getPages() == 300, "KOReader's MuPDF opens the exported PDF with all 300 pages")
    if dok and doc then doc:close() end
end
os.remove(out)

-- stopping part-way deletes the partial file
local job2 = assert(Export.notebookPDFJob(pages, W, H, { style = "blank" }, out, 90, tmp, bg, {}))
job2:step(); job2:step()
job2.cancel()
ok(io.open(out, "rb") == nil, "stopping an export removes the partial PDF")
-- an empty page over an opaque background is encoded straight from the background:
-- the JPEG bytes must equal the general path's
do
    local Canvas = require("ink/canvas")
    local c = Canvas.new(W, H)
    local b = bg(7)
    local a_path, b_path = tmp .. "/inkaway_direct.jpg", tmp .. "/inkaway_general.jpg"
    assert(Export.saveJPEG(c, a_path, 90, { bg = b, bg_opaque = true }))
    assert(Export.saveJPEG(c, b_path, 90, { bg = b, no_fast = true }))
    local fa = io.open(a_path, "rb"); local da = fa:read("*a"); fa:close()
    local fb = io.open(b_path, "rb"); local db = fb:read("*a"); fb:close()
    ok(#da > 0 and da == db, "an empty PDF page encoded directly is byte-identical to the general path")
    os.remove(a_path); os.remove(b_path)
end
-- pages with and without a background, and per-page templates and bookmarks: a
-- page whose background function gives nothing (a blank page inserted into an
-- imported PDF) is plain paper, and KOReader reads the bookmarks
do
    local mixed = { {}, { { kind = "ink", width = 6, alpha = 255, pts = { 100, 300, 600, 340 } } }, {} }
    local job3 = assert(Export.notebookPDFJob(mixed, W, H,
        function(i) return { style = (i == 2) and "lines" or "blank", size = 40, gray = 200 } end,
        out, 85, tmp, function(i) if i ~= 2 then return bg(i) end end,
        { outline = { { title = "Start", page = 1, kids = { { title = "Math", page = 2,
            kids = { { title = "Şekil 2", page = 2 } } } } } } }))
    local okc, state, err
    repeat okc, state, err = pcall(job3.step) until not okc or state ~= "page"
    if not okc then state, err = nil, state end
    ok(state == "done", "a mix of pages with and without backgrounds exports: " .. tostring(err))
    if mok and state == "done" then
        local dok, doc = pcall(Mupdf.openDocument, out)
        ok(dok and doc and doc:getPages() == 3, "and MuPDF opens all three pages")
        if dok and doc then
            local toc = doc:getToc() or {}
            ok(#toc == 3 and toc[1].title == "Start" and toc[3].title == "Şekil 2" and toc[3].page == 2,
                "the bookmarks read back, in Turkish")
            ok(toc[1].depth == 1 and toc[2].depth == 2 and toc[3].depth == 3, "nested three deep, as a folder's are")
            doc:close()
        end
    end
    os.remove(out)
end
print(("realbb pdfexport: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
