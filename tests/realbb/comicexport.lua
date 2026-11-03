-- Real MuPDF archive decoding, native blitbuffers, ink compositor, JPEG encoder
-- and streaming PDF writer. UI and KOReader document registry are adapters.
-- Generate fixtures with comic_fixtures.py, then from a KOReader runtime:
-- ./luajit REPO/tests/realbb/comicexport.lua REPO FIXTURE_DIR
local REPO, FIXTURES = assert(arg[1]), arg[2]
local generated = FIXTURES == nil
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
if generated then
    FIXTURES = os.tmpname()
    os.remove(FIXTURES)
    assert(os.execute("python3 " .. quote(REPO .. "/tests/realbb/comic_fixtures.py") .. " " .. quote(FIXTURES)) == 0)
end
require("ffi/loadlib")
require("ffi/blitbuffer")
local M = require("ffi/mupdf")
package.path = REPO .. "/?.lua;" .. REPO .. "/tests/mock/?.lua;" .. package.path
local Export = require("ink/export")
local BookExport = require("ink/reader/bookexport")
local Pdfedit = require("ink/export/pdfedit")
local View = require("ink/view/exportbook")
local NotebookView = require("ink/view/notebook")
local checks, failures = 0, 0
local function ok(c, what)
    checks = checks + 1
    if not c then failures = failures + 1; print("FAIL: " .. what) end
end
local function rss()
    local f = assert(io.open("/proc/self/status"))
    local kb = tonumber(f:read("*a"):match("VmRSS:%s+(%d+)")); f:close()
    return kb / 1024
end
local function dc(z) return { zoom = z, rotate = 0, offset_x = 0, offset_y = 0, gamma = 1, saturation = 1 } end
local released = 0
local tiles = {}
local function releaseTiles()
    for _, tile in ipairs(tiles) do tile:free() end
    tiles = {}
end
package.loaded["document/document"] = {
    getNativePageDimensions = function(doc, p)
        local page = doc.native:openPage(p)
        local w, h = page:getSize(dc(1)); page:close()
        return { w = w, h = h }
    end,
    renderPage = function(doc, p, rect, zoom)
        local page = doc.native:openPage(p)
        local bb = page:draw_new(dc(zoom), rect.w, rect.h, 0, 0)
        page:close(); tiles[#tiles + 1] = bb
        return { bb = bb }
    end,
}
package.loaded["document/documentregistry"] = {
    openDocument = function(_, path)
        local native = M.openDocument(path)
        native:setColorRendering(true)
        return { native = native, close = function() native:close(); released = released + 1 end }
    end,
}
for _, ext in ipairs({ "cbz", "cbr" }) do
    local path = FIXTURES .. "/comic." .. ext
    local source = M.openDocument(path)
    local n = source:getPages()
    local first = source:openPage(1)
    local pw, ph = first:getSize(dc(1)); first:close(); source:close()
    local item = { op = { kind = "ink", style = "solid", width = pw * 0.02, alpha = 255,
        color = { 255, 0, 0 }, pts = { 0, 0, pw * 0.3, 0 } }, a = { page = 1, x = pw * 0.2, y = ph * 0.2 } }
    local book = {
        ui = { paging = {}, document = { file = path, is_pdf = true, getPageCount = function() return n end } },
        data = function() return { items = { item } } end,
        doc = function() return { kind = "paging" } end,
        currentPage = function() return 1 end,
    }
    local options = { scope = "all", include_bg = true }
    local view = setmetatable({ book = book, view = { canvas_w = 150, canvas_h = 200 } }, { __index = View })
    function view:exportOptions() return options end
    function view:exportDress(t) return t end
    function view:renderPdfPage(...)
        local image = NotebookView.renderPdfPage(self, ...)
        releaseTiles()
        return image
    end
    ok(BookExport.pdfPath(book) == nil and not Pdfedit.available(path), ext .. " cannot use editable-PDF export")
    local spec = view:exportSpec()
    local output = FIXTURES .. "/export-" .. ext .. ".pdf"
    local job = assert(Export.notebookPDFJob(spec.pages, nil, nil, spec.template, output, spec.quality,
        FIXTURES, spec.bg, { n = spec.n, size = spec.size, box = spec.box, bg_opaque = true }))
    collectgarbage("collect")
    local start, peak, halfway, t0 = rss(), rss(), nil, os.clock()
    while true do
        local state, i = job.step()
        assert(state, i)
        peak = math.max(peak, rss())
        if i == math.floor(n / 2) then halfway = rss() end
        if state == "done" then break end
    end
    spec.done()
    local f = assert(io.open(output, "rb")); local bytes = f:seek("end"); f:close()
    print(("  %s: %d pages, %.2f CPU seconds, PDF %.2f MB, RSS start %.1f / peak %.1f / halfway %.1f MB")
        :format(ext, n, os.clock() - t0, bytes / 1e6, start, peak, halfway or peak))
    if n >= 50 then
        ok(peak - start < 100, ext .. " pixel working memory stays bounded below 100 MB growth")
        ok(peak - halfway < 40, ext .. " memory does not accumulate in the second half")
    end
    local pdf = M.openDocument(output)
    pdf:setColorRendering(true)
    ok(pdf:getPages() == n, ext .. " exported PDF reopens with every page")
    local p = pdf:openPage(1)
    local ew, eh = p:getSize(dc(1))
    ok(math.abs(ew - pw) < 0.01 and math.abs(eh - ph) < 0.01, ext .. " retains original page geometry")
    local z = 400 / math.max(pw, ph)
    local bb = p:draw_new(dc(z), math.floor(pw * z), math.floor(ph * z), 0, 0)
    local pixel = bb:getPixel(math.floor(pw * 0.35 * z), math.floor(ph * 0.2 * z)):getColorRGB32()
    ok(pixel:getR() > 180 and pixel:getG() < 100 and pixel:getB() < 100, ext .. " saved native ink appears at the right position")
    bb:free(); p:close(); pdf:close()
    options.scope = "ink"
    local stopped = view:exportSpec()
    ok(stopped.n == 1, ext .. " annotated-pages-only excludes untouched pages")
    local partial = FIXTURES .. "/cancel-" .. ext .. ".pdf"
    local cancel = assert(Export.notebookPDFJob(stopped.pages, nil, nil, stopped.template, partial,
        stopped.quality, FIXTURES, stopped.bg, { n = stopped.n, size = stopped.size, box = stopped.box, bg_opaque = true }))
    assert(cancel.step()); cancel.cancel(); stopped.done()
    ok(not io.open(partial, "rb") and not io.open(FIXTURES .. "/inkaway_page.jpg", "rb"), ext .. " cancellation deletes partial PDF and scratch JPEG")
end
ok(released == 4, "finished and cancelled exports release every opened document")
print(("comicexport: %d checks, %d failures"):format(checks, failures))
if generated then
    for _, ext in ipairs({ "cbz", "cbr" }) do
        os.remove(FIXTURES .. "/comic." .. ext)
        os.remove(FIXTURES .. "/export-" .. ext .. ".pdf")
    end
    require("libs/libkoreader-lfs").rmdir(FIXTURES)
end
os.exit(failures == 0 and 0 or 1)
