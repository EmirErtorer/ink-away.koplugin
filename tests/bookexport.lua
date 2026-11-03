-- Fixed-page export routing, native ink placement and bounded quality, without
-- a live reader. Actual archive/render/encoder coverage: realbb/comicexport.lua.
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local ffi = require("ffi")
local env = require("testenv")
local Pdf = require("ink/pdf")
local Pdfedit = require("ink/export/pdfedit")
local BookExport = require("ink/reader/bookexport")
local freed, closed, rendered = 0, 0, {}
local dims = { { w = 2000, h = 3000 }, { w = 6000, h = 2000 }, { w = 5000, h = 5000 } }
local doc = { close = function() closed = closed + 1 end }
package.loaded["document/document"] = {
    getNativePageDimensions = function(_, p) return dims[p] end,
}
package.loaded["document/documentregistry"] = { openDocument = function() return doc end }
local ImageProc = require("ink/imageproc")
ImageProc.bbToRGBA = function(_, w, h) return ffi.new("uint8_t[?]", w * h * 4) end
local View = require("ink/view/exportbook")
local checks, failures = 0, 0
local function ok(c, what)
    checks = checks + 1
    if not c then failures = failures + 1; print("FAIL: " .. what) end
end
local function near(a, b) return math.abs(a - b) < 0.001 end
local function fixture(name, bytes)
    local path = env.libraryDir() .. "/" .. name
    local f = assert(io.open(path, "wb")); f:write(bytes); f:close()
    return path
end
local files = {
    fixture("book.cbz", "PK\003\004%PDF-1.7"),
    fixture("book.cbr", "Rar!\026\007\001\000"),
    fixture("book.djvu", "AT&TFORM"),
    fixture("fake.pdf", "PK\003\004%PDF-1.7"),
}
local pdf = fixture("actual.bin", "%PDF-1.7\n")
local item = { op = { kind = "ink", pts = { 0, 0, 100, 50 }, width = 8 }, a = { page = 1, x = 400, y = 600 } }
local book = {
    ui = { paging = {}, document = { is_pdf = true, getPageCount = function() return 3 end } },
    data = function() return { items = { item } } end,
    doc = function() return { kind = "paging" } end,
    currentPage = function() return 2 end,
}
local options = { scope = "all", include_bg = true }
local view = setmetatable({ book = book, view = { canvas_w = 100, canvas_h = 200 } }, { __index = View })
function view:exportOptions() return options end
function view:exportDress(t) return t end
function view:renderPdfPage(_, page, w, h)
    rendered[#rendered + 1] = page
    return { free = function() freed = freed + 1 end, w = w, h = h }
end
for _, path in ipairs(files) do
    book.ui.document.file = path
    ok(BookExport.pdfPath(book) == nil and not Pdfedit.available(path), "non-PDF is never eligible for editable export: " .. path)
    local job, err = Pdfedit.job(path, env.libraryDir() .. "/bad.pdf", {})
    ok(job == nil and err and not io.open(env.libraryDir() .. "/bad.pdf"), "non-PDF cannot be copied into a .pdf")
    local before = #rendered
    local spec = view:exportSpec()
    ok(spec.n == 3 and #rendered == before, "fixed-page spec is lazy and does not visit the reader")
    local w, h = spec.size(1)
    ok(w == 1066 and h == 1600, "full page quality is independent of the 100x200 editor")
    local op = spec.pages(1)[1]
    ok(near(op.pts[1], 400 * 1600 / 3000) and near(op.pts[2], 600 * 1600 / 3000)
        and near(op.width, 8 * 1600 / 3000), "native ink anchor and width follow the full page")
    spec.bg(1)
    ok(rendered[#rendered] == 1 and freed == #rendered, "each requested page renders once and its bitmap is freed")
    local pw, ph = spec.box(1)
    ok(pw == 2000 and ph == 3000, "page box preserves native aspect ratio")
    spec.done(); spec.done()
end
ok(closed == #files, "each export releases its document once")
book.ui.document.file = pdf
ok(Pdf.isPDF(pdf) and BookExport.pdfPath(book) == pdf, "real PDF identified by content, independent of extension")
book.ui.paging = nil
ok(BookExport.pdfPath(book) == nil, "reflow documents cannot use the fixed-page PDF path")
local reflowed = false
view.reflowBookSpec = function() reflowed = true; return {} end
view:exportSpec()
ok(reflowed, "EPUB/MOBI keep their existing reflow export")
book.ui.paging = {}
options.page_quality = "detailed"
local detailed = view:exportSpec()
local w, h = detailed.size(1)
ok(w == 1600 and h == 2400 and detailed.quality == 90, "Detailed selects higher resolution and JPEG quality")
w, h = detailed.size(3)
ok(w == 2000 and h == 2000, "Detailed bounds square-page work to four million pixels")
detailed.done()
options.scope, options.range = "range", { from = 2, to = 3 }
local range = view:exportSpec()
ok(range.n == 2 and #range.pages(1) == 0, "ranges retain source page identity and do not borrow another page's ink")
w, h = range.size(1)
ok(w == 2400 and h == 800, "landscape pages retain their own dimensions")
range.bg(1)
ok(rendered[#rendered] == 2, "range renders source page two as output page one")
range.done()
options.scope, options.include_bg = "all", false
local ink = view:exportSpec()
ok(ink.bg == nil and #ink.pages(1) == 1, "ink-only export keeps ink without rendering backgrounds")
ink.done()
options.include_bg = true
local broken = view:exportSpec()
view.renderPdfPage = function() return nil end
local success, err = pcall(broken.bg, 1)
ok(not success and tostring(err):find("Could not render page 1", 1, true), "render failures report an error instead of exporting a blank page")
broken.done()
local old = dims[1]
dims[1] = { w = 0, h = 0 }
local invalid = view:exportSpec()
ok(not pcall(invalid.size, 1), "invalid source dimensions fail instead of guessing from the panel")
invalid.done(); dims[1] = old
package.loaded["document/documentregistry"].openDocument = function() return nil end
local missing = view:exportSpec()
ok(not pcall(missing.size, 1), "an unavailable source fails cleanly on its first export step")
missing.done()
ok(item.a.x == 400 and item.op.pts[1] == 0 and item.op.width == 8, "exports never rewrite saved annotations")
env.cleanup()
print(("bookexport: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
