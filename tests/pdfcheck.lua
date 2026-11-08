-- What is a PDF for the editable export (Pdf.isPDF, ink/pdf.lua): a comic archive
-- KOReader also opens as "PDF" never is; a PDF with bytes before its header is.
--   luajit tests/pdfcheck.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local env = require("testenv")
local Pdf = require("ink/pdf")
local Pdfedit = require("ink/export/pdfedit")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local dir = env.libraryDir()
local function file(name, bytes)
    local p = dir .. "/" .. name
    local f = assert(io.open(p, "wb")); f:write(bytes); f:close()
    return p
end
ok(Pdf.isPDF(file("a.pdf", "%PDF-1.7\n%\226\227\207\211\n1 0 obj")), "a PDF")
ok(Pdf.isPDF(file("junk.pdf", string.rep("\0", 300) .. "%PDF-1.4\n")), "a PDF with bytes before its header")
ok(not Pdf.isPDF(file("late.pdf", string.rep(" ", 1100) .. "%PDF-1.4\n")), "a header past the first 1024 bytes: not one")
ok(not Pdf.isPDF(file("comic.cbz", "PK\3\4" .. string.rep("x", 200))), "a CBZ (zip)")
ok(not Pdf.isPDF(file("comic.cbr", "Rar!\26\7\0" .. string.rep("x", 200))), "a CBR (rar)")
ok(not Pdf.isPDF(file("renamed.pdf", "PK\3\4" .. string.rep("x", 200))), "a comic renamed .pdf")
ok(not Pdf.isPDF(dir .. "/missing.pdf") and not Pdf.isPDF(nil), "no file, no path")
ok(not Pdfedit.available(dir .. "/comic.cbz"), "the editable export: never for a comic")
local job, err = Pdfedit.job(dir .. "/comic.cbz", dir .. "/out.pdf", {})
ok(job == nil and err ~= nil, "and no copy of one is written")
env.cleanup()
print(("pdfcheck: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
