-- A picture over a page of a PDF (ink/export/pdfoverlay.lua), through KOReader's real
-- MuPDF: the page's placeholder becomes a stamp annotation, the original bytes stay
-- as they were, MuPDF and (when installed) qpdf and poppler read the result, the
-- picture shows where it should, and a turned page falls back to plain annotations.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/pdfoverlay.lua <repo>
local REPO = arg[1] or "."
require("ffi/loadlib")
package.path = REPO .. "/?.lua;" .. package.path
local ffi = require("ffi")
local Export = require("ink/export")
local Annots = require("ink/export/annots")
local Overlay = require("ink/export/pdfoverlay")
local Pdfedit = require("ink/export/pdfedit")
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); local s = f and f:read("*a"); if f then f:close() end; return s end
local function have(cmd) local p = io.popen("command -v " .. cmd .. " 2>/dev/null"); local r = p:read("*l"); p:close(); return r ~= nil and r ~= "" end

local tmp = os.getenv("TMPDIR") or "/tmp"
local src, dst, dst2 = tmp .. "/inkaway_ov_src.pdf", tmp .. "/inkaway_ov_dst.pdf", tmp .. "/inkaway_ov_dst2.pdf"
local W, H = 300, 400
local function bg() local b = ffi.new("uint8_t[?]", W * H * 4); ffi.fill(b, W * H * 4, 255); return b end
local pages = {}
for i = 1, 5 do pages[i] = {} end
local mk = assert(Export.notebookPDFJob(pages, W, H, { style = "blank" }, src, 80, tmp, bg, { bg_opaque = true }))
while true do local s = mk.step(); if s == "done" then break end; assert(s) end
local original = slurp(src)

-- a 40 x 20 red picture, opaque, to cover the box (50..90, 100..120) of page 2
local function overlay()
    local n = 40 * 20
    local rgb = string.rep("\255\0\0", n)
    local alpha = string.rep("\255", n)
    return Overlay.pack(40, 20, rgb, alpha, 50, 100, 90, 120)
end
local groups = Annots.convert({ { kind = "ink", style = "solid", width = 3, alpha = 255, color = { 0, 0, 200 },
    pts = { 10, 10, 200, 10 } } }, { s = 1, ox = 0, oy = 0 })
local work = {
    { page = 2, groups = groups, marks = {}, overlay = overlay },
    { page = 4, groups = groups, marks = {} },
}

local function run(from, to, w)
    local job = assert(Pdfedit.job(from, to, w))
    local steps = 0
    while true do
        local state, a = job.step()
        steps = steps + 1
        if state == "done" then break end
        if state ~= "page" or steps > 60 then ok(false, "the job ends: " .. tostring(state) .. " " .. tostring(a)); break end
    end
    return job
end

local job = run(src, dst, work)
local out = slurp(dst) or ""
ok(out:sub(1, #original) == original, "the original's bytes are untouched")
ok(not job.fell_back, "the picture was written, no fall back (" .. tostring(job.fell_back) .. ")")
ok(out:find("/Subtype /Stamp", 1, true) and out:find("InkAwayOverlay2", 1, true), "a stamp annotation holds page 2's picture")
ok(select(2, out:gsub("/Subtype/Ink", "")) == 1, "page 4 has its ink as an annotation, page 2 has none (" .. select(2, out:gsub("/Subtype/Ink", "")) .. ")")
local M = require("ffi/mupdf")
local doc = M.openDocument(dst)
ok(doc:getPages() == 5, "MuPDF opens the result with every page")
doc:close()
if have("qpdf") then
    local rc = os.execute("qpdf --check '" .. dst .. "' >/dev/null 2>&1")
    ok(rc == 0 or rc == true, "qpdf finds the file sound")
end
if have("pdftoppm") then
    os.execute("pdftoppm -r 72 -f 2 -l 2 '" .. dst .. "' '" .. tmp .. "/inkaway_ov' 2>/dev/null")
    local ppm = slurp(tmp .. "/inkaway_ov-2.ppm") or slurp(tmp .. "/inkaway_ov-02.ppm") or slurp(tmp .. "/inkaway_ov-1.ppm")
    if ppm then
        local w, h, hdr = ppm:match("^P6%s+(%d+)%s+(%d+)%s+255%s()")
        w, h = tonumber(w), tonumber(h)
        local function px(x, y) local o = hdr + (y * w + x) * 3; return ppm:byte(o), ppm:byte(o + 1), ppm:byte(o + 2) end
        local r, g, b = px(70, 110)     -- inside the picture's box
        ok(r > 200 and g < 60 and b < 60, ("the picture shows red on the page at its place (%d,%d,%d)"):format(r, g, b))
        r, g, b = px(70, 150)           -- outside it
        ok(r > 240 and g > 240 and b > 240, "and the page is white outside it")
        ok(w == W and h == H, "the page keeps its size")
    else
        ok(false, "poppler rendered page 2")
    end
    os.remove(tmp .. "/inkaway_ov-2.ppm")
end

-- a PDF whose cross reference is a stream (objects packed) takes it as well
if have("qpdf") then
    local xs = tmp .. "/inkaway_ov_xs.pdf"
    os.execute("qpdf --object-streams=generate '" .. src .. "' '" .. xs .. "' >/dev/null 2>&1")
    if slurp(xs) then
        local j2 = run(xs, dst2, work)
        ok(not j2.fell_back, "a PDF with object streams takes the picture too (" .. tostring(j2.fell_back) .. ")")
        local rc = os.execute("qpdf --check '" .. dst2 .. "' >/dev/null 2>&1")
        ok(rc == 0 or rc == true, "qpdf finds that file sound")
        os.remove(dst2)
    end
    os.remove(xs)
    -- a turned page: no picture, the page's ink as annotations
    local rot = tmp .. "/inkaway_ov_rot.pdf"
    os.execute("qpdf --rotate=+90:2 '" .. src .. "' '" .. rot .. "' >/dev/null 2>&1")
    if slurp(rot) then
        local j3 = run(rot, dst2, work)
        local o3 = slurp(dst2) or ""
        ok(j3.fell_back, "a turned page falls back")
        ok(not o3:find("/Subtype /Stamp", 1, true) and select(2, o3:gsub("/Subtype/Ink", "")) == 2,
            "and keeps the ink of both pages as annotations, with no stamp")
        local rc = os.execute("qpdf --check '" .. dst2 .. "' >/dev/null 2>&1")
        ok(rc == 0 or rc == true, "qpdf finds the fallback file sound")
        os.remove(dst2)
    end
    os.remove(rot)
end

if not os.getenv("KEEP") then os.remove(src); os.remove(dst) end
print(("pdfoverlay: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
