-- Tests for documents on disk: Storage paths and safe writes, project files and
-- the per-page save cache, notebook page ids, and the library (names, adopting
-- an old session file). Files go to a scratch folder.
-- Run from the plugin root with:  luajit tests/library.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Library = require("ink/library")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function readAll(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeAll(path, s)
    local f = assert(io.open(path, "wb"))
    f:write(s)
    f:close()
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not deepEqual(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local DIR = TestEnv.libraryDir()

------------------------------------------------------------------------------
-- Storage: path pieces, unique names, safe writes
------------------------------------------------------------------------------
do
    ok(Storage.dirName("/a/b/c.inkaway") == "/a/b", "dirName")
    ok(Storage.baseName("/a/b/c.inkaway") == "c.inkaway", "baseName")
    ok(Storage.stem("/a/b/My notes.v2.inkaway") == "My notes.v2", "stem drops only the last extension")
    ok(Storage.stem("/a/b/plain") == "plain", "stem of a name with no extension")

    local p1 = Storage.uniquePath(DIR, "Sketch", "inkaway")
    ok(p1 == DIR .. "/Sketch.inkaway", "uniquePath uses the plain name when it is free")
    writeAll(p1, "x")
    local p2 = Storage.uniquePath(DIR, "Sketch", "inkaway")
    ok(p2 == DIR .. "/Sketch (2).inkaway", "uniquePath numbers a taken name")
    writeAll(p2, "x")
    ok(Storage.uniquePath(DIR, "Sketch", "inkaway") == DIR .. "/Sketch (3).inkaway", "and keeps counting")
    ok(Storage.uniquePath(DIR, "a/b", "inkaway") == DIR .. "/a_b.inkaway", "uniquePath keeps slashes out of names")

    local path = DIR .. "/atomic.txt"
    ok(Storage.writeAtomic(path, "first"), "writeAtomic writes a new file")
    ok(readAll(path) == "first", "the file holds what was written")
    ok(Storage.writeAtomic(path, "second"), "writeAtomic replaces an existing file")
    ok(readAll(path) == "second", "the replacement is complete")
    ok(not Storage.exists(path .. ".tmp"), "no temporary file is left behind")
    ok(not Storage.writeAtomic(DIR .. "/missing/x.txt", "y"), "writeAtomic fails cleanly in a missing folder")
    ok(Storage.isDir(DIR) and not Storage.isDir(path), "isDir tells folders from files")
end

------------------------------------------------------------------------------
-- Project files: extra fields, the background, recovering a cut-short save
------------------------------------------------------------------------------
do
    local Canvas = require("ink/canvas")
    local c = Canvas.new(300, 400)
    c:startStroke("ink", 8, 255); c:addPoint(10, 10); c:addPoint(60, 40); c:finishStroke()
    local path = DIR .. "/bg drawing.inkaway"
    ok(Project.save(c, path, { bg = "/pics/photo.png" }), "a drawing saves with extra fields")
    local data = Project.load(path)
    ok(data and data.bg == "/pics/photo.png" and #data.ops == 1, "the background path and ops reload")
    ok(not Project.isNotebook(data), "a drawing is not a notebook")

    -- a save that stopped after writing its temporary file is still read
    local lost = DIR .. "/half saved.inkaway"
    writeAll(lost .. ".tmp", Project.serialize(c))
    local back = Project.load(lost)
    ok(back and #back.ops == 1, "load falls back to the temporary file of a cut-short save")
    ok(Project.load(DIR .. "/nothing here.inkaway") == nil, "a missing file loads as nil")
end

------------------------------------------------------------------------------
-- Canvas: the change counter a save checks
------------------------------------------------------------------------------
do
    local Canvas = require("ink/canvas")
    local c = Canvas.new(100, 100)
    local r0 = c.rev
    c:startStroke("ink", 4, 255); c:addPoint(1, 1); c:addPoint(9, 9)
    ok(c.rev == r0, "a stroke in progress is not a change yet")
    c:finishStroke()
    local r1 = c.rev
    ok(r1 > r0, "a committed stroke counts")
    c:undo(); ok(c.rev > r1, "undo counts")
    local r2 = c.rev
    c:redo(); ok(c.rev > r2, "redo counts")
    local r3 = c.rev
    c:pushHistory(); ok(c.rev > r3, "an edit checkpoint counts")
    local r4 = c.rev
    c:setOps({}); ok(c.rev > r4, "replacing the ops counts")
end

------------------------------------------------------------------------------
-- Notebook pages: ids, times and the fields that travel with a page
------------------------------------------------------------------------------
do
    local clock = 1000
    Notebook.now = function() return clock end
    local nb = Notebook.new(600, 800)
    ok(nb.pages[1].id == 1 and nb.pages[1].created == 1000 and nb.pages[1].modified == 1000,
        "the first page has an id and times")
    clock = 1100
    nb:addPage()
    ok(nb.pages[2].id == 2 and nb.pages[2].created == 1100, "an added page gets the next id")
    nb.pages[2].title, nb.pages[2].paper, nb.pages[2].star = "Plans", { style = "grid" }, true
    nb.pages[2].ops = { { kind = "ink", pts = { 1, 2 } } }
    nb:duplicatePage()
    local copy = nb.pages[3]
    ok(copy.id == 3, "a duplicate is a new page with its own id")
    ok(copy.title == "Plans" and copy.paper.style == "grid" and not copy.star,
        "a duplicate keeps the title and paper, not the star")
    ok(copy.paper ~= nb.pages[2].paper and copy.ops ~= nb.pages[2].ops, "and shares no tables with its source")
    clock = 1200
    nb:touch(1)
    ok(nb.pages[1].modified == 1200 and nb.pages[1].created == 1000, "touch stamps the change time only")
    ok(nb:hasInk(), "hasInk sees ink on any page")
    ok(not Notebook.new(10, 10):hasInk(), "a new notebook has no ink")

    -- ids and fields survive a save and reload, and the next id continues after
    local data = Project.deserialize(Project.serializeNotebook(nb))
    local nb2 = Notebook.fromData(data)
    ok(nb2.pages[2].id == 2 and nb2.pages[2].title == "Plans" and nb2.pages[2].star == true,
        "page ids and fields round-trip")
    nb2:addPage()
    ok(nb2.pages[nb2.index].id == 4, "new pages after a reload get unused ids")

    -- older files: bare op arrays and pages without ids get ids, existing ones kept
    local old = Notebook.fromData({ w = 10, h = 10, pages = {
        { { kind = "ink", pts = { 0, 0 } } },
        { ops = {}, src = 3 },
        { id = 7, ops = {} } } })
    ok(old.pages[3].id == 7, "an existing id is kept")
    ok(old.pages[1].id == 8 and old.pages[2].id == 9, "pages without one are numbered after the highest")
    ok(#old.pages[1].ops == 1 and old.pages[2].src == 3, "their ops and source pages are kept")

    -- a notebook over a PDF numbers its pages from one and ties each to its page
    local pdf = Notebook.forPdf(10, 10, { style = "blank", pdf_path = "x.pdf" }, 3)
    ok(pdf:count() == 3 and pdf.pages[1].id == 1 and pdf.pages[3].id == 3 and pdf.pages[3].src == 3,
        "forPdf makes one numbered page per PDF page")
    Notebook.now = os.time
end

------------------------------------------------------------------------------
-- Notebook pages: their own paper, inserting before, moving to a position
------------------------------------------------------------------------------
do
    local nb = Notebook.new(600, 800, { style = "lines", size = 40, strength = 45 })
    ok(nb:pageTemplate() == nb.template, "a page without its own paper uses the notebook's template")
    nb.pages[1].paper = "grid"
    local t = nb:pageTemplate(1)
    ok(t ~= nb.template and t.style == "grid" and t.size == 40, "a page's own paper keeps the notebook's spacing")
    ok(nb:pageTemplate(1) == t, "and is the same table each time, so it can be compared")
    nb.template.size = 60
    ok(t.size == 60, "spacing changes still reach it")
    nb.pages[1].paper = "lines"
    ok(nb:pageTemplate(1) == nb.template, "a page paper equal to the notebook's is just the notebook's")
    nb.pages[1].paper = "dots"
    nb:addPage()
    ok(nb.pages[2].paper == "dots" and nb.index == 2, "a new page takes the paper of the page it follows")
    nb.pages[2].ops = { { kind = "ink" } }
    nb:insertPageBefore()
    ok(nb:count() == 3 and nb.index == 2 and #nb.pages[2].ops == 0 and #nb.pages[3].ops == 1,
        "insert before puts a blank page in front and goes to it")
    ok(nb.pages[2].paper == "dots", "on the same paper")
    local moving = nb.pages[3]
    nb:gotoPage(3)
    nb:movePageTo(1)
    ok(nb.pages[1] == moving and nb.index == 1, "move to a position takes the page there and follows it")
    nb:movePageTo(99)
    ok(nb.pages[3] == moving and nb.index == 3, "a position past the end means the last page")
    nb:movePageTo(0)
    ok(nb.pages[1] == moving and nb.index == 1, "and before the start the first")
end

------------------------------------------------------------------------------
-- The per-page save cache: unchanged pages are reused, and the cached text
-- always matches a full save
------------------------------------------------------------------------------
do
    local nb = Notebook.new(600, 800, { style = "lines", size = 40 })
    for _ = 1, 3 do nb:addPage() end
    for i, page in ipairs(nb.pages) do page.ops = { { kind = "ink", width = 3, pts = { i, i, i + 5, i + 9 } } } end
    local cache = setmetatable({}, { __mode = "k" })
    local first = Project.serializeNotebook(nb, cache)
    ok(first == Project.serializeNotebook(nb), "a cached save is identical to a full one")
    local n = 0
    for _ in pairs(cache) do n = n + 1 end
    ok(n == 4, "every page is cached after a save")

    -- a cached page is reused as it is: a marker stands in for page 2
    local real = cache[nb.pages[2]]
    cache[nb.pages[2]] = '{["ops"]={},["id"]=99,}'
    local reused = Project.deserialize(Project.serializeNotebook(nb, cache))
    ok(reused and reused.pages[2].id == 99, "unchanged pages are not serialized again")
    cache[nb.pages[2]] = real

    -- change page 3, drop it from the cache, and the save matches a full one
    nb.pages[3].ops[#nb.pages[3].ops + 1] = { kind = "ink", width = 9, pts = { 1, 1, 50, 50 } }
    cache[nb.pages[3]] = nil
    local a = Project.deserialize(Project.serializeNotebook(nb, cache))
    local b = Project.deserialize(Project.serializeNotebook(nb))
    ok(deepEqual(a, b), "after a change the cached save equals a full save")
    ok(#a.pages[3].ops == 2, "and holds the change")

    -- reordering, adding and deleting pages need no cache changes
    nb:gotoPage(1); nb:movePage(1); nb:addPage(); nb:gotoPage(4); nb:deletePage()
    ok(deepEqual(Project.deserialize(Project.serializeNotebook(nb, cache)),
        Project.deserialize(Project.serializeNotebook(nb))), "page moves, adds and deletes stay in step")
    local extra = Project.deserialize(Project.serializeNotebook(nb, cache, { note = "x" }))
    ok(extra.note == "x" and extra.v == 2 and #extra.pages == nb:count(), "extra fields sit beside the pages")
end

------------------------------------------------------------------------------
-- Library: names, content, adopting an old session file
------------------------------------------------------------------------------
do
    Library.now = function() return os.time({ year = 2026, month = 10, day = 3, hour = 14, min = 22 }) end
    ok(Library.defaultName("Notebook") == "Notebook 2026-10-03 14.22", "default names carry the date and time")
    Library.now = os.time
    ok(Library.root(DIR) == DIR, "the chosen library folder is used when it exists")
    ok(Library.root(DIR .. "/gone") ~= DIR .. "/gone", "a missing chosen folder falls back")

    ok(not Library.hasContent({ w = 1, h = 1, ops = {} }), "an empty drawing has no content")
    ok(Library.hasContent({ w = 1, h = 1, ops = { {} } }), "a drawing with an op has content")
    ok(Library.hasContent({ w = 1, h = 1, ops = {}, bg = "/x.png" }), "a drawing with a background has content")
    ok(not Library.hasContent({ w = 1, h = 1, pages = { { ops = {} } } }), "a blank one-page notebook has none")
    ok(Library.hasContent({ w = 1, h = 1, pages = { { ops = {} }, { ops = {} } } }), "two pages count")
    ok(Library.hasContent({ w = 1, h = 1, template = { pdf_path = "a.pdf" }, pages = { { ops = {} } } }),
        "a notebook over a PDF counts")
    ok(Library.hasContent({ w = 1, h = 1, pages = { { { kind = "ink" } } } }), "a bare ops page with ink counts")

    local Canvas = require("ink/canvas")
    local c = Canvas.new(50, 50)
    c:startStroke("ink", 4, 255); c:addPoint(1, 1); c:addPoint(20, 20); c:finishStroke()
    local session = DIR .. "/old_session.inkaway"
    local raw = Project.serialize(c)
    writeAll(session, raw)
    local adopted = Library.adoptSession(session, DIR, "Recovered 2026-10-03 14.22")
    ok(adopted == DIR .. "/Recovered 2026-10-03 14.22.inkaway", "a session with ink becomes a named document")
    ok(readAll(adopted) == raw, "its content is moved byte for byte")
    ok(not Storage.exists(session), "and the old file is removed")

    writeAll(session, Project.serialize(Canvas.new(50, 50)))
    ok(Library.adoptSession(session, DIR, "Recovered empty") == nil, "an empty session is not kept")
    ok(not Storage.exists(session) and not Storage.exists(DIR .. "/Recovered empty.inkaway"),
        "it is removed and makes no document")
    ok(Library.adoptSession(DIR .. "/no session.inkaway", DIR, "x") == nil, "no session file, nothing to do")
end

------------------------------------------------------------------------------
-- Library folders: listing, moving, duplicating and deleting
------------------------------------------------------------------------------
do
    local ROOT = DIR .. "/lib"
    os.execute("mkdir -p '" .. ROOT .. "/School/Maths' '" .. ROOT .. "/drawings' '" .. ROOT .. "/.thumbs'")
    writeAll(ROOT .. "/Old.inkaway", "x")
    writeAll(ROOT .. "/new.inkaway", "x")
    writeAll(ROOT .. "/notes.txt", "x")
    writeAll(ROOT .. "/.hidden.inkaway", "x")
    writeAll(ROOT .. "/School/Physics.inkaway", "x")
    os.execute("touch -t 202601010000 '" .. ROOT .. "/Old.inkaway'")
    os.execute("touch -t 202602010000 '" .. ROOT .. "/new.inkaway'")

    local names = {}
    for _, e in ipairs(Storage.list(ROOT)) do names[e.name] = e.mode end
    ok(names["School"] == "directory" and names["Old.inkaway"] == "file" and names[".thumbs"] == "directory",
        "Storage.list sees files and folders, hidden ones too")
    ok(names["."] == nil and names[".."] == nil, "but not . and ..")

    local folders, docs = Library.list(ROOT, ROOT)
    ok(#folders == 1 and folders[1].name == "School", "the library shows its folders, not internal or hidden ones")
    ok(#docs == 2, "and only document files, not hidden ones")
    ok(docs[1].name == "new.inkaway" and docs[2].name == "Old.inkaway", "documents come newest first")
    local _, by_name = Library.list(ROOT, ROOT, "name")
    ok(by_name[1].name == "new.inkaway" and by_name[2].name == "Old.inkaway", "or by name, ignoring case")
    local sub = Library.list(ROOT .. "/School", ROOT)
    ok(#sub == 1 and sub[1].name == "Maths", "inside a folder the same rules apply")
    os.execute("mkdir -p '" .. ROOT .. "/School/drawings'")
    ok(#Library.list(ROOT .. "/School", ROOT) == 2, "a folder named like an internal one is shown below the top")

    ok(Storage.within(ROOT .. "/School/a.inkaway", ROOT .. "/School"), "within: a file in a folder")
    ok(Storage.within(ROOT .. "/School", ROOT .. "/School/"), "within: the folder itself")
    ok(not Storage.within(ROOT .. "/Schoolwork/a.inkaway", ROOT .. "/School"), "within: not a sibling with a longer name")

    -- moving a document into a folder, and a clash
    local moved = Library.move(ROOT .. "/Old.inkaway", ROOT .. "/School")
    ok(moved == ROOT .. "/School/Old.inkaway" and Storage.exists(moved) and not Storage.exists(ROOT .. "/Old.inkaway"),
        "a document moves into a folder")
    writeAll(ROOT .. "/Physics.inkaway", "y")
    local clash = Library.move(ROOT .. "/Physics.inkaway", ROOT .. "/School")
    ok(clash == ROOT .. "/School/Physics (2).inkaway", "a name taken in the folder gets a number")
    ok(Library.move(moved, ROOT .. "/School") == moved, "moving to where it already is changes nothing")
    -- folders
    local mf = Library.move(ROOT .. "/School/Maths", ROOT)
    ok(mf == ROOT .. "/Maths" and Storage.isDir(mf), "a folder moves too")
    local bad = Library.move(ROOT .. "/School", ROOT .. "/School/drawings")
    ok(bad == nil and Storage.isDir(ROOT .. "/School"), "a folder never moves inside itself")

    local copy = Library.duplicate(moved)
    ok(copy == ROOT .. "/School/Old (2).inkaway" and readAll(copy) == "x", "duplicate copies next to it with a number")

    ok(Storage.removeTree(ROOT .. "/School"), "removeTree deletes a folder with everything in it")
    ok(not Storage.exists(ROOT .. "/School/Old.inkaway") and not Storage.exists(ROOT .. "/School"), "nothing is left")

    local name = Library.thumbName("/a/b.inkaway", 123, 40, 50)
    ok(name == Library.pathCode("/a/b.inkaway") .. "-123-40x50.png", "a thumbnail name carries path, time and size")
    ok(Library.pathCode("/a/b.inkaway") ~= Library.pathCode("/a/c.inkaway"), "different paths, different codes")
    ok(Library.pathCode("") == "811c9dc5" and Library.pathCode("foobar") == "bf9cf968", "path codes are FNV-1a")
end

------------------------------------------------------------------------------
-- Binders: a folder's tab order and colours, and pages moving between notebooks
------------------------------------------------------------------------------
do
    local Folder = require("ink/folder")
    local B = DIR .. "/binder"
    os.execute("mkdir -p '" .. B .. "'")
    ok(Project.decode(Project.encode({ a = { 1, 2 }, b = "x" })).a[2] == 2, "encode and decode round-trip a value")
    ok(Project.decode("os.exit()") == nil, "decode runs nothing")

    local empty = Folder.load(B)
    ok(#empty.order == 0 and next(empty.colors) == nil, "a folder without binder data has none")
    local docs = { { name = "b.inkaway", mtime = 30 }, { name = "a.inkaway", mtime = 10 }, { name = "c.inkaway", mtime = 20 } }
    local function names(list) local t = {} for i, d in ipairs(list) do t[i] = d.name:sub(1, 1) end return table.concat(t) end
    ok(names(Folder.arrange(empty, docs)) == "acb", "unknown documents come oldest first")
    local data = { order = { "b.inkaway", "gone.inkaway" }, colors = {} }
    local arranged = Folder.arrange(data, docs)
    ok(names(arranged) == "bac", "known documents keep their order, missing ones are skipped")
    ok(Folder.move(data, arranged, "c.inkaway", -1) and names(arranged) == "bca", "a tab moves up")
    ok(data.order[1] == "b.inkaway" and data.order[2] == "c.inkaway", "and the order is remembered")
    ok(not Folder.move(data, arranged, "b.inkaway", -1), "the first tab cannot move up")
    -- only b and a are tabs (c is a drawing): a moves up past c, which stays
    local tab = { ["b.inkaway"] = true, ["a.inkaway"] = true }
    local isTab = function(d) return tab[d.name] end
    ok(Folder.move(data, arranged, "a.inkaway", -1, isTab) and names(arranged) == "acb",
        "a tab moves past a document that is not a tab")
    ok(not Folder.move(data, arranged, "a.inkaway", -1, isTab), "and the first tab still cannot move up")

    -- a notebook or a drawing, from the start of the file
    local nbf, drf = B .. "/n.inkaway", B .. "/d.inkaway"
    local tricky = '["pages"]={'
    writeAll(nbf, Project.serializeNotebook({ w = 10, h = 10, template = { style = "lines" },
        pages = { { ops = { { kind = "text", text = '["ops"]={' } } } } }))
    writeAll(drf, Project.serialize({ w = 10, h = 10, ops = { { kind = "text", text = tricky } } }))
    ok(Library.isNotebookFile(nbf), "a notebook file is a notebook")
    ok(not Library.isNotebookFile(drf), "a drawing file is not, even with the key in its text")
    local big = {}
    for i = 1, 400 do big[i] = { kind = "stroke", pts = { i, i, i + 1, i + 1 } } end
    big[401] = { kind = "text", text = tricky }
    writeAll(drf, Project.serialize({ w = 10, h = 10, ops = big }))
    ok(not Library.isNotebookFile(drf), "nor a long drawing")
    os.rename(nbf, nbf .. ".tmp")
    ok(Library.isNotebookFile(nbf), "a notebook only in its .tmp file is still one")
    os.remove(nbf .. ".tmp"); os.remove(drf)
    ok(not Library.isNotebookFile(nbf), "a missing file is not a notebook")
    data.colors["c.inkaway"] = { 1, 2, 3 }
    Folder.rename(data, "c.inkaway", "z.inkaway")
    ok(data.order[2] == "z.inkaway" and data.colors["z.inkaway"][3] == 3 and data.colors["c.inkaway"] == nil,
        "a renamed tab keeps its place and colour")
    ok(Folder.save(B, data), "binder data saves")
    local back = Folder.load(B)
    ok(back.order[2] == "z.inkaway" and back.colors["z.inkaway"][1] == 1, "and loads back")
    Folder.forget(back, "z.inkaway")
    ok(#back.order == 2 and back.colors["z.inkaway"] == nil, "a deleted tab is forgotten")
    ok(Storage.exists(B .. "/" .. Folder.FILE) and #Library.list(B, DIR) == 0, "the binder file is hidden from the library")

    local a = Notebook.new(10, 10, { style = "lines", pdf_path = "x.pdf" })
    a.pages = { a:newPage(1), a:newPage(2), a:newPage(3) }
    a.pages[2].title, a.pages[2].ops = "Two", { { kind = "ink" } }
    a.index = 3
    local taken = a:takePage(2)
    ok(taken.title == "Two" and a:count() == 2 and a.index == 2, "takePage removes a page and keeps the current one in view")
    local b = Notebook.new(10, 10, { style = "grid" })
    local at = b:putPage(taken, false)
    ok(at == 2 and b.pages[2].title == "Two" and #b.pages[2].ops == 1 and b.pages[2].src == nil,
        "putPage adds a copy at the end, without a tie to another PDF")
    ok(b.pages[2].id ~= b.pages[1].id and b.pages[2].ops ~= taken.ops, "as a new page with its own id and ops")
    ok(a:putPage(taken, true) == 3 and a.pages[3].src == 2, "within the same PDF the page keeps its PDF page")
    ok(b.pages[2].paper == nil and a.pages[3].paper == nil, "a page on the notebook's own paper needs none of its own")
    b:putPage(taken, false, "lines")
    ok(b.pages[3].paper == "lines", "a page from lined paper stays lined in a grid notebook")
    b:putPage(taken, false, "grid")
    ok(b.pages[4].paper == nil, "and one already on this notebook's paper just uses it")
    local one = Notebook.new(10, 10)
    ok(one:takePage(1) == nil and one:count() == 1, "the only page cannot be taken")
end

------------------------------------------------------------------------------
-- Page templates
------------------------------------------------------------------------------
do
    local Templates = require("ink/templates")
    local ROOT = DIR .. "/tpl"
    os.execute("mkdir -p '" .. ROOT .. "'")
    ok(#Templates.list(ROOT) == 0, "no templates to begin with")
    local nb = Notebook.new(600, 800, { style = "lines", size = 40, strength = 45, pdf_path = "lecture.pdf" })
    nb.pages[1].ops = { { kind = "ink", width = 3, pts = { 1, 2, 3, 4 } } }
    nb.pages[1].title = "Week plan"
    nb.pages[1].paper = "cornell"
    ok(Templates.save(ROOT, "Week plan", nb.pages[1], nb:pageTemplate(1), nb.w, nb.h), "a page saves as a template")
    ok(Templates.save(ROOT, "agenda", nb.pages[1], nb.template, nb.w, nb.h), "and another")
    local names = Templates.list(ROOT)
    ok(#names == 2 and names[1] == "agenda" and names[2] == "Week plan", "templates are listed by name")
    ok(#Library.list(ROOT, ROOT) == 0, "the templates folder is hidden from the library")
    local page, style = Templates.load(ROOT, "Week plan")
    ok(page and #page.ops == 1 and page.title == "Week plan" and style == "cornell",
        "a template keeps its ink, title and paper")
    local data = Project.load(Templates.path(ROOT, "Week plan"))
    ok(data.template.pdf_path == nil, "a template never ties itself to a PDF")
    page.ops[1].pts[1] = 99
    local again = Templates.load(ROOT, "Week plan")
    ok(again.ops[1].pts[1] == 1, "each load is a fresh copy")

    local target = Notebook.new(600, 800, { style = "grid" })
    target:addPage()
    target:gotoPage(1)
    local at = target:putPage(again, false, "cornell", 2)
    ok(at == 2 and target:count() == 3 and target.pages[2].paper == "cornell" and target.index == 1,
        "putPage can insert a template page after the current one")
    target:gotoPage(3)
    target:putPage(again, false, "grid", 1)
    ok(target.index == 4 and target.pages[1].paper == nil, "inserting before the current page keeps it in view")
    ok(Templates.remove(ROOT, "agenda") and #Templates.list(ROOT) == 1, "a template can be deleted")
end

TestEnv.cleanup()
print(("library: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
