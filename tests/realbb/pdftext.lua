-- Invisible page text under a page's picture (ink/pdf.lua text layer), through
-- KOReader's real MuPDF and, when installed, poppler's text extractor: every line
-- comes back as written, in Latin, Turkish, Greek and Cyrillic, where it was put, and
-- the page still shows only its picture.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/pdftext.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
package.path = REPO .. "/?.lua;" .. package.path
local ffi = require("ffi")
local Export = require("ink/export")
local Pdf = require("ink/pdf")
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); local s = f and f:read("*a"); if f then f:close() end; return s end
local function have(cmd) local p = io.popen("command -v " .. cmd .. " 2>/dev/null"); local r = p:read("*l"); p:close(); return r ~= nil and r ~= "" end

local tmp = os.getenv("TMPDIR") or "/tmp"
local out = tmp .. "/inkaway_text.pdf"
local W, H = 300, 400
local function bg() local b = ffi.new("uint8_t[?]", W * H * 4); ffi.fill(b, W * H * 4, 255); return b end
local LINES = {
    { { s = "But stealing money was different.", x = 20, y = 350, w = 250, size = 12 },
      { s = "robbing Sir Gerald, it would be no use", x = 20, y = 330, w = 250, size = 12 } },
    { { s = "İstanbul’da şğı çöü İ ı", x = 20, y = 350, w = 200, size = 12 },
      { s = "Привет, мир", x = 20, y = 330, w = 100, size = 12 },
      { s = "Γειά σου κόσμε", x = 20, y = 310, w = 120, size = 12 } },
}
local pages = { {}, {} }
local job = assert(Export.notebookPDFJob(pages, W, H, { style = "blank" }, out, 80, tmp, bg,
    { bg_opaque = true, text = function(i) return LINES[i] end }))
local state
repeat state = job.step() until state ~= "page"
ok(state == "done", "the export finishes")
local pdf = slurp(out) or ""
ok(pdf:find("/Type0", 1, true) and pdf:find("/ToUnicode", 1, true), "the text font is in the file")
ok(select(2, pdf:gsub("/Type0", "")) == 1, "one font serves every page")
ok(select(2, pdf:gsub("3 Tr", "")) == 2, "each page's text is invisible (render mode 3)")

local M = require("ffi/mupdf")
local dok, doc = pcall(M.openDocument, out)
ok(dok and doc and doc:getPages() == 2, "MuPDF opens the PDF with both pages")
if dok and doc then doc:close() end

if have("qpdf") then
    local rc = os.execute("qpdf --check '" .. out .. "' >/dev/null 2>&1")
    ok(rc == 0 or rc == true, "qpdf finds the file sound")
end
if have("pdftotext") then
    local function text(n)
        local p = io.popen("pdftotext -f " .. n .. " -l " .. n .. " '" .. out .. "' - 2>/dev/null")
        local t = p:read("*a"); p:close(); return t
    end
    local t1, t2 = text(1), text(2)
    ok(t1:find("But stealing money was different.", 1, true) and t1:find("robbing Sir Gerald, it would be no use", 1, true),
        "page 1's lines come back as written")
    ok(t2:find("İstanbul’da şğı çöü İ ı", 1, true), "Turkish letters come back")
    ok(t2:find("Привет, мир", 1, true), "Cyrillic comes back")
    ok(t2:find("Γειά σου κόσμε", 1, true), "Greek comes back")
    -- where a line is: poppler's boxes
    local p = io.popen("pdftotext -f 1 -l 1 -bbox '" .. out .. "' - 2>/dev/null")
    local bb = p:read("*a"); p:close()
    local xmin, ymin, xmax = bb:match('<word xMin="([%d%.]+)" yMin="([%d%.]+)" xMax="[%d%.]+" yMax="[%d%.]+">But<')
    ok(xmin and math.abs(tonumber(xmin) - 20) < 1.5, "the first word starts where the line does (" .. tostring(xmin) .. ")")
    local lastx = 0
    for xm in bb:gmatch('xMax="([%d%.]+)" yMax="[%d%.]+">different') do lastx = tonumber(xm) end
    ok(lastx > 240 and lastx < 275, "and the line ends near its width (" .. tostring(lastx) .. ")")
end
if have("pdftoppm") then
    os.execute("pdftoppm -r 36 -f 1 -l 1 '" .. out .. "' '" .. tmp .. "/inkaway_tx' 2>/dev/null")
    local ppm = slurp(tmp .. "/inkaway_tx-1.ppm") or slurp(tmp .. "/inkaway_tx-01.ppm")
    local white = ppm ~= nil
    if ppm then
        local hdr = ppm:match("^P6%s+%d+%s+%d+%s+255%s()")
        for i = hdr, #ppm do if ppm:byte(i) ~= 255 then white = false; break end end
    end
    ok(white, "the page shows only its picture: the text is not drawn")
    os.remove(tmp .. "/inkaway_tx-1.ppm"); os.remove(tmp .. "/inkaway_tx-01.ppm")
end
os.remove(out)
print(("pdftext: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
