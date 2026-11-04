-- The parts of the cloud sync (ink/sync/areas.lua) that can be turned on and off
-- one by one, run through the real engine on a pretend cloud: exports, imports,
-- screen clips, book notes and the ink on books, each on two readers.
--   luajit tests/sync/areas.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
require("testenv")
local Areas = require("ink/sync/areas")
local BookIndex = require("ink/sync/bookindex")
local BookInk = require("ink/reader/bookink")
local Engine = require("ink/sync/engine")
local Prefs = require("ink/sync/prefs")
local Project = require("ink/project")
local State = require("ink/sync/state")
local Mock = require("sync/mockcloud")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end
local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function write(path, data)
    os.execute("mkdir -p '" .. path:match("^(.*)/[^/]*$") .. "'")
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end
local function doc(n) return string.format('return {["w"]=600,["h"]=800,["pages"]={{["ops"]={},["n"]=%d}}}', n) end

local BASE = (os.getenv("INKAWAY_TMP") or "/tmp") .. "/inkaway-areas-test-" .. os.time()
os.execute("rm -rf '" .. BASE .. "'; mkdir -p '" .. BASE .. "'")

------------------------------------------------------------------------------
-- the settings
------------------------------------------------------------------------------
local none = function() return nil end
ok(Areas.enabled("notebooks", none) and Areas.enabled("booknotes", none), "notebooks and book notes are on as they always were")
ok(not Areas.enabled("exports", none) and not Areas.enabled("bookink", none) and not Areas.enabled("clips", none)
    and not Areas.enabled("imports", none), "everything new starts off")
eq(Areas.enabled("nothing", none), false, "an unknown part is off")
local store = {}
Areas.setEnabled("exports", true, function(k, v) store[k] = v end)
eq(store.inkaway_sync_area_exports, true, "turning a part on is kept in a setting")
ok(Areas.enabled("exports", function(k) return store[k] end), "and read back")
eq(#Areas.DEFS, 7, "seven parts")
for _i, d in ipairs(Areas.DEFS) do ok(d.label ~= "" and d.hint ~= "", d.id .. " has a name and a line of explanation") end

------------------------------------------------------------------------------
-- two readers with a library, a few folders of Ink Away's own, and some books
------------------------------------------------------------------------------
local cloud = Mock.cloud()
local clock = 2000000
local function reader(name)
    local dir = BASE .. "/" .. name
    os.execute("mkdir -p '" .. dir .. "/lib' '" .. dir .. "/sync' '" .. dir .. "/app'")
    return { name = name, dir = dir, root = dir .. "/lib", sync = dir .. "/sync", app = dir .. "/app", backup = dir .. "/backup",
        provider = Mock.provider(cloud, name), settings = {}, state = State.load(dir .. "/sync") }
end
local function run(r, o)
    o = o or {}
    clock = clock + 100
    local areas = Areas.build({
        get = function(k) return r.settings[k] end, root = r.root,
        appPath = function(name) return r.app .. "/" .. name end,
        books = function() return BookIndex.list(r.sync) end, merge = BookInk.merge,
        prefsPath = r.sync .. "/preferences.json", mergePrefs = Prefs.merge,
    })
    return Engine.run({ root = r.root, provider = r.provider, state = r.state, backup_dir = r.backup, device = r.name,
        areas = areas, now = function() return clock end, sleep = function() end, stop = function() return false end,
        skip = o.skip,
        validate = function(rel, path)
            if rel == Prefs.REL then return Prefs.valid(path) end
            if rel:match("/inkaway%.lua$") then return BookInk.valid(path) end
            if not rel:match("%.inkaway$") then return true end
            return Project.load(path) and true or false, "not a notebook"
        end })
end
local function enable(r, id, on) r.settings[Areas.SETTING .. id] = on end
local function inCloud(prefix) local n = 0 for k in pairs(cloud.files) do if k:sub(1, #prefix) == prefix then n = n + 1 end end return n end

local A, B = reader("A"), reader("B")
write(A.root .. "/Math.inkaway", doc(1))
write(A.root .. "/Book notes/Dune.inkaway", doc(2))
write(A.app .. "/exports/Math.pdf", "%PDF export one")
write(A.app .. "/imported pdfs/paper.pdf", "%PDF imported")
write(A.app .. "/screen clips/clip-1-1.png", "clip one")
write(A.app .. "/clipped images/clip-1-2.png", "kept clip")

-- 1. with the defaults only the library goes
local r = run(A)
eq(r.fatal, nil, "no fatal error")
eq(r.uploaded, 2, "by default only the notebooks and the book notes go")
eq(inCloud(".areas"), 0, "nothing of the other parts reaches the cloud")

-- 2. one part at a time
enable(A, "exports", true)
r = run(A)
eq(r.uploaded, 1, "turning exports on sends them")
ok(cloud.files[".areas/exports/math.pdf"], "under the exports folder of the cloud")
eq(inCloud(".areas/clips"), 0, "and still no clips")
enable(A, "clips", true)
enable(A, "imports", true)
r = run(A)
eq(r.uploaded, 3, "clips (both folders) and imports go when turned on")
ok(cloud.files[".areas/clips/clip-1-1.png"] and cloud.files[".areas/clipped/clip-1-2.png"] and cloud.files[".areas/imports/pdfs/paper.pdf"], "each in its own place")

-- 3. the other reader chooses for itself
r = run(B)
eq(r.downloaded, 2, "a reader with the defaults gets only the library")
ok(read(B.app .. "/exports/Math.pdf") == nil, "and no exports")
enable(B, "exports", true)
r = run(B)
eq(r.downloaded, 1, "turning exports on there brings them")
eq(read(B.app .. "/exports/Math.pdf"), "%PDF export one", "whole")
eq(r.deleted, 0, "nothing was deleted by turning parts on or off")

-- 4. a part that is off is left alone on both sides
enable(B, "exports", false)
os.remove(B.app .. "/exports/Math.pdf")
r = run(B)
eq(r.deleted, 0, "a file removed from a part that is off is not removed from the cloud")
ok(cloud.files[".areas/exports/math.pdf"], "it is still in the cloud")
write(A.app .. "/exports/Math.pdf", "%PDF export two")
r = run(A)
eq(r.uploaded, 1, "a change in a part that is on still goes")
enable(B, "exports", true)
r = run(B)
eq(read(B.app .. "/exports/Math.pdf"), "%PDF export two", "turning it on again brings the latest")
eq(r.conflicts, 0, "with no conflict")

-- 5. notebooks off, book notes on
enable(A, "notebooks", false)
write(A.root .. "/Math.inkaway", doc(9))
write(A.root .. "/Book notes/Dune.inkaway", doc(8))
r = run(A)
eq(r.uploaded, 1, "with notebooks off only the book notes go")
enable(A, "notebooks", true)
r = run(A)
eq(r.uploaded, 1, "turning notebooks on sends what waited")

-- 6. exports and notebooks can be told apart from the bookkeeping names
write(A.app .. "/exports/.hidden", "x")
r = run(A)
eq(r.uploaded, 0, "hidden files are not sent")

-- 7. ink on books: matched by checksum, wherever the book is
local MD5 = "0123456789abcdef0123456789abcdef"
local function item(n) return { op = { kind = "stroke", n = n }, a = { page = 1, x = n, y = n } } end
local function saveInk(dir, items) assert(BookInk.save(dir, { version = 1, items = items })) end
local function inkCount(dir)
    local d = BookInk.load(dir)
    return #d.items
end
local aBook, bBook = A.dir .. "/books/dune.sdr", B.dir .. "/elsewhere/Dune.epub.sdr"
saveInk(aBook, { item(1), item(2) })
write(aBook .. "/inkaway-pictures/p1.png", "picture")
write(aBook .. "/metadata.epub.lua", "return { reader = 'settings that stay' }")
BookIndex.note(A.sync, MD5, aBook, A.dir .. "/books/Dune.epub")
r = run(A)
eq(inCloud(".areas/books"), 0, "ink on books is off until it is turned on")
enable(A, "bookink", true)
r = run(A)
eq(r.uploaded, 3, "turned on, the ink, its picture and the book's name go")
ok(cloud.files[(".areas/books/" .. MD5 .. "/inkaway-book-Dune.txt"):lower()], "the book's name sits beside its ink, so the folder says which book it is")
ok(cloud.files[".areas/books/" .. MD5 .. "/inkaway.lua"] and cloud.files[".areas/books/" .. MD5 .. "/inkaway-pictures/p1.png"], "under the book's checksum")
ok(not cloud.files[".areas/books/" .. MD5 .. "/metadata.epub.lua"], "KOReader's own settings of the book are never sent")
enable(B, "bookink", true)
r = run(B)
ok(inCloud(".areas/books") > 0 and read(bBook .. "/inkaway.lua") == nil, "a reader that does not know the book leaves its ink in the cloud")
BookIndex.note(B.sync, MD5, bBook, B.dir .. "/elsewhere/Dune.epub")
r = run(B)
eq(r.downloaded, 3, "once the book is known there, its ink, picture and name arrive")
eq(inkCount(bBook), 2, "in the book's folder on that reader")
eq(read(bBook .. "/inkaway-pictures/p1.png"), "picture", "with its picture")
ok(read(bBook .. "/metadata.epub.lua") == nil, "and nothing else")

-- 8. two readers draw on the same book: the ink is combined, not copied twice
saveInk(aBook, { item(1), item(2), item(3) })
saveInk(bBook, { item(1), item(2), item(4) })
r = run(A)
eq(r.uploaded, 1, "A sends its new stroke")
r = run(B)
eq(r.merged, 1, "B combines the two instead of keeping a conflict copy")
eq(r.conflicts, 0, "no copy is left in the book's folder")
eq(inkCount(bBook), 4, "all four strokes are there on B")
eq(r.uploaded, 1, "and the combined ink goes up in the same run")
r = run(A)
eq(r.downloaded, 1, "A receives the combined ink")
eq(inkCount(aBook), 4, "all four strokes on A too")
r = run(B)
eq(r.uploaded + r.downloaded + r.merged, 0, "then nothing more to do")
local copies = io.popen("ls '" .. bBook .. "'"):read("*a")
ok(not copies:find("conflict", 1, true), "no conflict file next to the book's settings")
local saved = io.popen("find '" .. B.backup .. "' -name 'inkaway.lua' | head -1"):read("*a")
ok(saved:find("inkaway.lua", 1, true), "B's ink was copied to the safety folder before it was replaced")

-- 9. a book open on the reader is not touched
saveInk(aBook, { item(1), item(2), item(3), item(4), item(5) })
run(A)
r = run(B, { skip = function(key) return key:find(MD5, 1, true) ~= nil end })
eq(r.waiting, 1, "a book open in the reader waits")
eq(inkCount(bBook), 4, "its ink is not replaced while it is open")
r = run(B)
eq(inkCount(bBook), 5, "and comes when it is closed")

-- 10. the cloud can't write outside a book's ink
local evil = ".areas/books/" .. MD5 .. "/evil.lua"
cloud.files[evil] = { rel = evil, data = "x", rev = "rx", hash = require("ink/sync/hash").dropboxOfString("x"), history = {} }
cloud.changes[#cloud.changes + 1] = evil
r = run(B)
ok(r.downloaded == 0 and #r.errors == 0, "it is not even asked for")
ok(read(bBook .. "/evil.lua") == nil, "a file the cloud lists in a book's folder, other than its ink, is ignored")

-- 10b. preferences: only the listed keys, in one small file
local mine = Prefs.export(function(k)
    return ({ inkaway_accent = "green", inkaway_library_dir = "/mnt/us/x", inkaway_ocr_api = { key = "SECRET" },
        inkaway_pens = { red = { w = 3 } }, inkaway_paper = 2 })[k]
end)
ok(mine.inkaway_accent == "green" and mine.inkaway_paper == 2 and mine.inkaway_pens.red.w == 3, "chosen preferences are exported")
ok(mine.inkaway_library_dir == nil and mine.inkaway_ocr_api == nil, "folders and keys that belong to one reader never are")
eq(Prefs.decode('{"inkaway_accent":"blue","inkaway_library_dir":"/x","bogus":1}').inkaway_library_dir, nil, "a file cannot set a setting outside the list")
eq(Prefs.decode("not json"), nil, "a damaged file is refused")
local set = {}
eq(Prefs.apply({ inkaway_accent = "blue", inkaway_paper = 3 }, function(k, v) set[k] = v end), 2, "preferences from a file are put into the settings")
eq(set.inkaway_paper, 3, "with their values")
write(A.sync .. "/preferences.json", Prefs.encode({ inkaway_accent = "green", inkaway_paper = 1 }))
r = run(A)
eq(r.uploaded, 0, "preferences stay home while that part is off")
enable(A, "settings", true)
r = run(A)
eq(r.uploaded, 1, "turned on, they go as one file")
ok(cloud.files[".areas/settings/preferences.json"], "in the cloud's settings folder")
write(B.sync .. "/preferences.json", Prefs.encode({ inkaway_accent = "red", inkaway_grid_size = 40 }))
enable(B, "settings", true)
r = run(B)
eq(r.merged, 1, "a reader with its own choices combines them with the cloud's")
local got = Prefs.decode(read(B.sync .. "/preferences.json"))
ok(got.inkaway_accent == "green" and got.inkaway_grid_size == 40 and got.inkaway_paper == 1, "all keys kept, the cloud's value where both set one")
r = run(A)
eq(Prefs.decode(read(A.sync .. "/preferences.json")).inkaway_grid_size, 40, "and the first reader gets the combined set")

-- 11. the index
local idx = BookIndex.load(A.sync)
ok(idx.books[MD5] ~= nil, "the book is listed")
eq(BookIndex.note(A.sync, "not hex!", "/x", "/y"), false, "a bad checksum is not listed")
eq(BookIndex.markerName("/books/My Book: Part 1.epub"), "inkaway-book-My Book_ Part 1.txt", "the book's name is made safe for a file name")
eq(BookIndex.markerName("/books/Kitap\xc4\xb1.epub"), "inkaway-book-Kitap\xc4\xb1.txt", "letters beyond ASCII stay")
eq(BookIndex.markerName(string.rep("\xc4\xb1", 100) .. ".epub"), "inkaway-book-" .. string.rep("\xc4\xb1", 60) .. ".txt", "a long name is cut between characters")
eq(BookIndex.markerName(nil), nil, "no file, no name")
local files = { A.dir .. "/books/Dune.epub" }
write(files[1], "book")
local n = BookIndex.scan(A.sync, files, function() return "FEDCBA9876543210" end, function() return A.dir .. "/s.sdr" end, 1e9, true)
eq(n, 1, "a look through the history lists books")
eq(BookIndex.scan(A.sync, files, function() return "FEDCBA9876543210" end, function() return A.dir .. "/s.sdr" end, 1e9 + 10), 0, "and does not look again within the hour")

print(string.format("areas: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
