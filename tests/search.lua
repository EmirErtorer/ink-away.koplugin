-- Tests for searching the library (ink/search.lua): what is walked, names and
-- page titles from the start of a notebook file, text inside pages, the cache,
-- and files that cannot be read. Files go to a scratch folder.
-- Run from the plugin root with:  luajit tests/search.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Search = require("ink/search")
local Text = require("ink/text")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local ROOT = TestEnv.libraryDir() .. "/searchtest"
os.execute("rm -rf '" .. ROOT .. "'")
os.execute("mkdir -p '" .. ROOT .. "/School/Math' '" .. ROOT .. "/exports' '" .. ROOT .. "/.trash'")

local function textOp(s)
    local op = Text.new{ x = 10, y = 10, w = 300, size = 20 }
    Text.insert(op, { p = 1, o = 0 }, s, nil)
    return op
end
local function ink() return { kind = "ink", width = 4, alpha = 255, pts = { 1, 1, 50, 50 } } end

-- a notebook in School/Math: a titled page, a page with typed text, a plain one
local nb = Notebook.new(600, 800, { style = "lines", size = 40 })
nb.pages[1].ops = { ink() }
nb.pages[1].title = "Quadratic equations"
nb:addPage()
nb.pages[2].ops = { textOp("The discriminant decides\nhow many Roots there are") }
nb:addPage()
nb.pages[3].ops = { ink() }
nb.pages[3].title = "Homework (week 3) 100%"
local algebra = ROOT .. "/School/Math/Algebra.inkaway"
assert(Project.saveNotebook(nb, algebra))
-- a drawing with a text box
local canvas = { w = 600, h = 800, ops = { ink(), textOp("Grocery list: milk, eggs") } }
local drawing = ROOT .. "/School/Doodle.inkaway"
assert(Project.save(canvas, drawing))
-- a notebook written before files carried their page titles: no list at the top
local old = Notebook.new(600, 800, { style = "grid", size = 40 })
old.pages[1].title = "Lab report"
old.pages[1].ops = { ink() }
local oldText = Project.serializeNotebook(old):gsub('%["toc"%]=%b{},', "")
local oldPath = ROOT .. "/Old notes.inkaway"
do local f = assert(io.open(oldPath, "wb")); f:write(oldText); f:close() end
-- a broken file, and things that must not be searched
do local f = assert(io.open(ROOT .. "/Broken.inkaway", "wb")); f:write("return { this is not lua"); f:close() end
do local f = assert(io.open(ROOT .. "/.trash/Algebra old.inkaway", "wb")); f:write("return {}"); f:close() end
do local f = assert(io.open(ROOT .. "/exports/Algebra.pdf", "wb")); f:write("%PDF"); f:close() end

------------------------------------------------------------------------------
-- The page-title list at the top of a notebook file
------------------------------------------------------------------------------
do
    local head = Search.readHead(algebra)
    ok(head and head.toc and head.toc.n == 3 and #head.toc == 2, "a notebook file starts with its page titles")
    ok(head.toc[1].p == 1 and head.toc[1].t == "Quadratic equations" and head.toc[2].p == 3,
        "each title with its page number")
    ok(Search.readHead(drawing) == nil, "a drawing has no head to read")
    ok(Search.readHead(ROOT .. "/missing.inkaway") == nil, "a missing file reads as nothing")
    -- the list does not change how a notebook loads
    local data = Project.load(algebra)
    local back = Notebook.fromData(data)
    ok(back:count() == 3 and back.pages[3].title == "Homework (week 3) 100%", "the notebook loads as before")
end

------------------------------------------------------------------------------
-- Walking the library
------------------------------------------------------------------------------
local entries = Search.walk(ROOT, { exports = true })
do
    local names = {}
    for _, e in ipairs(entries) do names[#names + 1] = e.kind .. ":" .. e.name end
    local all = table.concat(names, " ")
    ok(all:find("folder:School", 1, true) and all:find("folder:Math", 1, true), "folders are walked, nested ones too")
    ok(all:find("doc:Algebra", 1, true) and all:find("doc:Doodle", 1, true) and all:find("doc:Old notes", 1, true),
        "documents are found by name")
    ok(not all:find("trash", 1, true) and not all:find("exports", 1, true) and not all:find("old", 1, true)
        or not all:find("Algebra old", 1, true), "hidden folders (the trash) and Ink Away's own folders are left out")
    ok(not all:find("Algebra old", 1, true) and not all:find("folder:exports", 1, true), "nothing from the trash or exports")
end

------------------------------------------------------------------------------
-- Names only
------------------------------------------------------------------------------
local function lower(s) return s:lower() end
do
    local loads = 0
    local realLoad = Project.load
    Project.load = function(...) loads = loads + 1; return realLoad(...) end
    local index = Search.newIndex(nil)
    for _, e in ipairs(entries) do if e.kind == "doc" then index:document(e, false) end end
    Project.load = realLoad
    ok(loads == 1, "a names search loads only the notebook without a title list (loaded " .. loads .. ")")
    local function find(q) return Search.find(entries, index.docs, q, lower, false) end
    local r = find("math")
    ok(#r == 1 and r[1].kind == "folder" and r[1].name == "Math", "a folder by name")
    r = find("ALGEBRA")
    ok(#r == 1 and r[1].kind == "doc" and r[1].nb == true, "a notebook by name, any case")
    r = find("quadratic")
    ok(#r == 1 and r[1].kind == "page" and r[1].page == 1 and r[1].path == algebra, "a page by its title")
    r = find("lab report")
    ok(#r == 1 and r[1].kind == "page" and r[1].name == "Old notes", "a page title in a notebook without the list")
    r = find("(week 3) 100%")
    ok(#r == 1 and r[1].page == 3, "symbols in the words are plain text, not patterns")
    r = find("roots")
    ok(#r == 0, "names only does not look at the text on pages")
    r = find("   ")
    ok(#r == 0, "an empty search finds nothing")
    r = find("homework 100%")
    ok(#r == 1, "every word must be there, in any order")
end

------------------------------------------------------------------------------
-- Inside pages, and the cache
------------------------------------------------------------------------------
do
    local index = Search.newIndex(nil)
    for _, e in ipairs(entries) do if e.kind == "doc" then index:document(e, true) end end
    local function find(q) return Search.find(entries, index.docs, q, lower, true) end
    local r = find("roots")
    ok(#r == 1 and r[1].kind == "page" and r[1].page == 2 and r[1].text and r[1].text:find("Roots", 1, true),
        "text on a page is found, with the words around it")
    r = find("eggs")
    ok(#r == 1 and r[1].nb == false and r[1].name == "Doodle", "and in a drawing's text boxes")
    r = find("quadratic")
    ok(#r == 1 and r[1].text == nil, "a title match needs no quote")
    ok(index.changed, "the index notes what it read")
    ok(Search.saveCache(ROOT, index), "the cache is written")

    -- a second search reads only what changed
    local loads = 0
    local realLoad = Project.load
    Project.load = function(...) loads = loads + 1; return realLoad(...) end
    local again = Search.newIndex(Search.loadCache(ROOT))
    for _, e in ipairs(entries) do if e.kind == "doc" then again:document(e, true) end end
    ok(loads == 1, "the cache saves reading unchanged documents (only the broken file again: " .. loads .. ")")
    -- the drawing changes: its size differs, so it is read again
    canvas.ops[2] = textOp("Grocery list: milk, eggs, bread and butter")
    assert(Project.save(canvas, drawing))
    local fresh = Search.walk(ROOT, { exports = true })
    loads = 0
    local third = Search.newIndex(Search.loadCache(ROOT))
    for _, e in ipairs(fresh) do if e.kind == "doc" then third:document(e, true) end end
    Project.load = realLoad
    ok(loads == 2, "a changed document is read again (" .. loads .. ")")
    r = Search.find(fresh, third.docs, "butter", lower, true)
    ok(#r == 1 and r[1].name == "Doodle", "and its new text is found")
    -- a cache from a names search is not enough for a search inside pages
    local names = Search.newIndex(nil)
    local e = { kind = "doc", name = "Algebra", path = algebra, dir = ROOT, mtime = 1, size = 1 }
    names:document(e, false)
    ok(names.docs[algebra].full == false, "a names record keeps only titles")
    names:document(e, true)
    ok(names.docs[algebra].full == true, "and is read in full when the text is wanted")
end

------------------------------------------------------------------------------
-- Damage
------------------------------------------------------------------------------
do
    local index = Search.newIndex({ v = 1, docs = "not a table" })
    ok(type(index.docs) == "table", "a damaged cache starts empty")
    index = Search.newIndex({ v = 99, docs = {} })
    ok(next(index.docs) == nil, "a cache of another version is ignored")
    local rec = index:document({ kind = "doc", path = ROOT .. "/Broken.inkaway", mtime = 1, size = 1 }, true)
    ok(rec == nil, "a file that cannot be read is skipped")
    rec = index:document({ kind = "doc", path = ROOT .. "/nowhere.inkaway", mtime = 1, size = 1 }, false)
    ok(rec == nil, "and so is one that is gone")
    local f = assert(io.open(ROOT .. "/" .. Search.CACHE, "wb")); f:write("garbage {{{"); f:close()
    ok(Search.loadCache(ROOT) == nil, "an unreadable cache file reads as none")
    ok(#Search.walk(ROOT .. "/missing", nil) == 0, "a missing library is empty")
end

os.execute("rm -rf '" .. ROOT .. "'")
print(("search: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
