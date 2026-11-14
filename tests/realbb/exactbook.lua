-- The edited copy of a book for Exact lines (ink/reader/exactbook.lua), with KOReader's
-- real archiver: the book's file is only read and keeps its bytes; the copy is named
-- after the book's content and marks, so a moved, renamed or copied book finds the
-- same copy; a book that is not the one the marks were made in, a damaged file or a
-- missing chapter leave the book as it is; old copies are tidied.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/exactbook.lua <repo>
local REPO = arg[1] or "."
require("setupkoenv")
package.path = REPO .. "/?.lua;" .. package.path
local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local Exact = require("ink/reader/exactbook")
local ExactMark = require("ink/reader/exactmark")
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function slurp(p) local f = io.open(p, "rb"); local s = f and f:read("*a"); if f then f:close() end; return s end
local function md5(s) return require("ffi/sha2").md5(s) end

local tmp = os.tmpname(); os.remove(tmp); lfs.mkdir(tmp)
-- the copies go to a folder of this test, not to the reader's
package.loaded["datastorage"] = { getDataDir = function() return tmp end }
local function sh(c) os.execute(c) end

local PARA = "The quick brown fox jumps over the lazy dog while the tripod machines stride across the heather and the pine trees."
local CH1 = '<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body>' ..
    "<p>" .. PARA .. "</p><p>Second paragraph.</p></body></html>"
local OPF = '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="i"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="i">x</dc:identifier><dc:title>T</dc:title></metadata><manifest><item id="c1" href="ch1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>'
local CONTAINER = '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
local function makeEpub(path, ch1, extra)
    local w = Archiver.Writer:new(); assert(w:open(path, "epub"))
    w:setZipCompression("store"); w:addFileFromMemory("mimetype", "application/epub+zip")
    w:setZipCompression("deflate")
    w:addFileFromMemory("META-INF/container.xml", CONTAINER)
    w:addFileFromMemory("OEBPS/content.opf", OPF)
    w:addFileFromMemory("OEBPS/ch1.xhtml", ch1 or CH1)
    w:setZipCompression("store"); w:addFileFromMemory("OEBPS/cover.png", "\137PNG fake image bytes")
    for name, data in pairs(extra or {}) do w:addFileFromMemory(name, data) end
    w:close()
end

local book = tmp .. "/book.epub"
makeEpub(book)
local before = slurp(book)
local off = PARA:find("tripod", 1, true) - 1
local marks = { { id = "m1", frag = 1, steps = { { name = "p", idx = 1 } }, text = 1, off = off, word = "tripod" } }

-- built: the word wrapped, everything else as it was
local dest = Exact.pathFor(book, marks)
ok(dest and dest:find(tmp, 1, true) == 1, "the copy is in the cache folder, not beside the book")
local built, skipped = Exact.build(book, marks, dest)
ok(built == dest and #skipped == 0, "the copy is built: " .. tostring(built) .. " " .. tostring(skipped))
ok(slurp(book) == before, "the book's file is byte for byte as it was")
local function entries(path)
    local r = Archiver.Reader:new(); assert(r:open(path))
    local out, order = {}, {}
    for e in r:iterate() do
        if e.mode == "file" then order[#order + 1] = e.path end
    end
    for _i, p in ipairs(order) do out[p] = r:extractToMemory(p) end
    r:close()
    return out, order
end
local orig, orig_order = entries(book)
local copy, copy_order = entries(dest)
ok(copy["OEBPS/ch1.xhtml"]:find('<span class="iar"', 1, true) ~= nil, "the word is wrapped in the copy")
ok(copy["OEBPS/ch1.xhtml"]:find(">tripod</span>", 1, true) ~= nil, "and the span holds the word")
ok(orig["OEBPS/ch1.xhtml"]:find("iar", 1, true) == nil, "the original has no mark")
local same = true
for p, data in pairs(orig) do if p ~= "OEBPS/ch1.xhtml" and copy[p] ~= data then same = false end end
ok(same and #copy_order == #orig_order, "every other file of the book is the same")
ok(copy_order[1] == "mimetype" and copy["mimetype"] == "application/epub+zip", "the mimetype comes first")
local stripped = copy["OEBPS/ch1.xhtml"]:gsub('<span class="iar"[^>]*>', ""):gsub("</span>", "")
ok(stripped == CH1, "taking the span out gives the chapter as it was")

-- moved, renamed, copied: the same content gives the same copy
sh("mkdir -p '" .. tmp .. "/other/place' && cp '" .. book .. "' '" .. tmp .. "/other/place/renamed.epub'")
local moved = tmp .. "/other/place/renamed.epub"
ok(Exact.pathFor(moved, marks) == dest, "a moved or renamed book finds the same copy")
ok(Exact.keyFor(book, marks) == Exact.keyFor(moved, marks), "the key is its content and its marks")
-- other marks, another copy
local marks2 = { marks[1], { id = "m2", frag = 1, steps = { { name = "p", idx = 1 } }, text = 1, off = PARA:find("heather", 1, true) - 1, word = "heather" } }
ok(Exact.pathFor(book, marks2) ~= dest, "another set of marks is another copy")
local d2 = Exact.build(book, marks2, Exact.pathFor(book, marks2))
local c2 = d2 and entries(d2)
ok(c2 and select(2, c2["OEBPS/ch1.xhtml"]:gsub('class="iar"', "")) == 2, "two marks make two spans")
-- the xpointers of the marks (what the book's own rooms hang on)
local xps = Exact.spanXPointers(book, marks2)
ok(xps and xps.m1 and xps.m2 and xps.m1 ~= xps.m2 and xps.m1:find("span%[1%]$") and xps.m2:find("span%[2%]$"), "each span has its own xpointer")

-- a different book under the same marks: the marks that do not fit are left out
local other = tmp .. "/different.epub"
makeEpub(other, (CH1:gsub("tripod", "saucer")))
local ob, sk = Exact.build(other, marks, tmp .. "/different-copy.epub")
ok(ob and #sk == 1, "a book the marks do not fit leaves them out, not a wrong edit")
local oc = ob and entries(ob)
ok(oc and oc["OEBPS/ch1.xhtml"]:find("iar", 1, true) == nil, "and the copy has no span")

-- a damaged file, a mark in a chapter that is not there: no copy, the book opens as it is
local broken = tmp .. "/broken.epub"
local f = io.open(broken, "wb"); f:write(before:sub(1, 90)); f:close()
ok(Exact.build(broken, marks, tmp .. "/broken-copy.epub") == nil, "a damaged book gives no copy")
ok(Exact.build(tmp .. "/nonexistent.epub", marks, tmp .. "/x.epub") == nil, "a missing book gives no copy")
local far = { { id = "z", frag = 9, steps = { { name = "p", idx = 1 } }, text = 1, off = 0, word = "The" } }
local fb, fs = Exact.build(book, far, tmp .. "/far-copy.epub")
ok(fb == nil or (fs and #fs == 1), "a mark in a chapter the book lacks is left out")
ok(not io.open(tmp .. "/broken-copy.epub") and not io.open(tmp .. "/broken-copy.epub.part"), "no half-written file is left")

-- tidying: newest copies kept, an older state of the same book dropped
local dir = Exact.dir()
for i = 1, 9 do
    local p = string.format("%s/%032d-%010d.epub", dir, i, i)
    local fh = io.open(p, "wb"); fh:write("x"); fh:close()
    lfs.touch(p, os.time() - 1000 + i)
end
Exact.prune(dest)
local left = 0
for name in lfs.dir(dir) do if name:match("%.epub$") then left = left + 1 end end
ok(left <= Exact.KEEP, "old copies are tidied (" .. left .. " left)")
ok(slurp(dest) ~= nil, "the copy in use is kept")
ok(Exact.pathFor(book, marks2) and slurp(Exact.pathFor(book, marks2)) == nil, "an older state of this book's copy is dropped")

-- signature: ids only, in any order
ok(Exact.signature({ { id = "a" }, { id = "b" } }) == Exact.signature({ { id = "b" }, { id = "a" } }), "the signature does not depend on order")
ok(Exact.signature({ { id = "a" } }) ~= Exact.signature({ { id = "a" }, { id = "b" } }), "and tells sets apart")

sh("rm -rf '" .. tmp .. "'")
print(("realbb exactbook: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
