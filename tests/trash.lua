-- Tests for the trash (ink/trash.lua): deleting documents, folders and pages
-- into it and putting them back exactly where they were. Files go to a scratch
-- folder.
-- Run from the plugin root with:  luajit tests/trash.lua

package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local TestEnv = require("testenv")
local Storage = require("ink/storage")
local Project = require("ink/project")
local Notebook = require("ink/notebook")
local Folder = require("ink/folder")
local Trash = require("ink/trash")
local Search = require("ink/search")

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

local ROOT = TestEnv.libraryDir() .. "/trashtest"
os.execute("rm -rf '" .. ROOT .. "'")
os.execute("mkdir -p '" .. ROOT .. "/School/Math'")
local SCHOOL = ROOT .. "/School"

local function ink(n) return { kind = "ink", width = 4, alpha = 255, pts = { n, n, n + 10, n + 10 } } end
local function notebook(path, n)
    local nb = Notebook.new(600, 800, { style = "lines", size = 40 })
    nb.pages[1].ops = { ink(1) }
    for i = 2, n do nb:addPage(); nb.pages[i].ops = { ink(i) }; nb.pages[i].title = "Page " .. i end
    assert(Project.saveNotebook(nb, path))
    return nb
end
local A, B, C = SCHOOL .. "/A.inkaway", SCHOOL .. "/B.inkaway", SCHOOL .. "/C.inkaway"
notebook(A, 2); notebook(B, 6); notebook(C, 1)
notebook(SCHOOL .. "/Math/Sums.inkaway", 2)
Folder.update(SCHOOL, function(d)
    d.order = { "A.inkaway", "B.inkaway", "C.inkaway", "Math" }
    d.colors["B.inkaway"] = { 200, 30, 30 }
end)
local function order(dir) return table.concat(Folder.load(dir).order, ",") end
local clock = 1800000000
Trash.now = function() return clock end

------------------------------------------------------------------------------
-- A notebook: away and back, with every page in its order
------------------------------------------------------------------------------
do
    local before = readAll(B)
    local item = Trash.putDocument(ROOT, B, true)
    ok(item and item.kind == "doc" and item.nb == true, "a notebook goes to the trash")
    ok(not Storage.exists(B) and order(SCHOOL) == "A.inkaway,C.inkaway,Math", "it leaves its folder and its binder")
    ok(#Trash.list(ROOT) == 1 and Trash.list(ROOT)[1].from == B, "the trash lists it, with where it came from")
    -- the library, its search and the overview never see the trash
    local seen = {}
    for _, e in ipairs(Search.walk(ROOT, {})) do seen[#seen + 1] = e.name end
    ok(not table.concat(seen, ","):find("B", 1, true) and not table.concat(seen, ","):find("trash", 1, true),
        "the trash is hidden from the library")
    local back = Trash.restore(ROOT, item.id)
    ok(back == B and readAll(B) == before, "it comes back to the same place, unchanged")
    local nb = Notebook.fromData(Project.load(B))
    ok(nb:count() == 6 and nb.pages[4].title == "Page 4" and nb.pages[6].ops[1].pts[1] == 6,
        "with all its pages in their order")
    ok(order(SCHOOL) == "A.inkaway,B.inkaway,C.inkaway,Math", "back in its place among the tabs")
    ok(Folder.load(SCHOOL).colors["B.inkaway"] and Folder.load(SCHOOL).colors["B.inkaway"][1] == 200,
        "with its tab colour")
    ok(#Trash.list(ROOT) == 0, "and leaves the trash")
end

------------------------------------------------------------------------------
-- A name taken in the meantime, a folder, a folder made again
------------------------------------------------------------------------------
do
    local item = Trash.putDocument(ROOT, B, true)
    notebook(B, 1)   -- a new B is made meanwhile
    Folder.update(SCHOOL, function(d) Folder.add(d, "B.inkaway") end)
    local back = Trash.restore(ROOT, item.id)
    ok(back == SCHOOL .. "/B (2).inkaway", "a taken name gets a number: " .. tostring(back))
    ok(Notebook.fromData(Project.load(back)):count() == 6 and Notebook.fromData(Project.load(B)):count() == 1,
        "and neither notebook is overwritten")
    os.remove(back)
    Folder.update(SCHOOL, function(d) Folder.forget(d, "B (2).inkaway") end)

    local math_item = Trash.putFolder(ROOT, SCHOOL .. "/Math")
    ok(math_item and not Storage.exists(SCHOOL .. "/Math"), "a folder goes with everything in it")
    back = Trash.restore(ROOT, math_item.id)
    ok(back == SCHOOL .. "/Math" and Storage.exists(SCHOOL .. "/Math/Sums.inkaway"), "and comes back with it")

    -- a document whose folder was deleted after it comes back with its folder made again
    local sums = Trash.putDocument(ROOT, SCHOOL .. "/Math/Sums.inkaway", true)
    os.execute("rm -rf '" .. SCHOOL .. "/Math'")
    back = Trash.restore(ROOT, sums.id)
    ok(back == SCHOOL .. "/Math/Sums.inkaway" and Storage.exists(back), "a missing folder is made again")
end

------------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------------
-- put a saved page back into the notebook file, as the view does for a closed one
local function insertInFile(nb_path, saved, item)
    local nb
    if Storage.exists(nb_path) then
        nb = Notebook.fromData(Project.load(nb_path))
    else
        nb = Notebook.new(saved.w, saved.h, saved.template)
        nb.pages, nb.next_id = {}, 1
    end
    nb:insertPage(saved.page, Trash.pageSlot(nb, item))
    return Project.saveNotebook(nb, nb_path)
end
do
    local nb = Notebook.fromData(Project.load(B))
    for i = 2, 5 do nb:addPage(); nb.pages[i].ops = { ink(i) } end
    nb.pages[3].title = "Lab"
    assert(Project.saveNotebook(nb, B))
    local id3 = nb.pages[3].id
    local item = Trash.putPage(ROOT, B, nb, 3)
    ok(item and item.kind == "page" and item.page == 3 and item.name == "Lab", "a page goes to the trash")
    nb:takePage(3)
    assert(Project.saveNotebook(nb, B))
    -- meanwhile the page before it is deleted too, and a page is added at the front
    table.remove(nb.pages, 2)
    table.insert(nb.pages, 1, nb:newPage())
    assert(Project.saveNotebook(nb, B))
    local back = Trash.restore(ROOT, item.id, insertInFile)
    local got = Notebook.fromData(Project.load(B))
    local at
    for i, p in ipairs(got.pages) do if p.title == "Lab" then at = i end end
    ok(back == B and at and got.pages[at + 1] and got.pages[at + 1].ops[1].pts[1] == 4,
        "it goes back before the page that followed it")
    ok(got.pages[at].id == id3 and got.pages[at].ops[1].pts[1] == 3, "with its ink and its id, for links to it")
    ok(#Trash.list(ROOT) == 0, "and leaves the trash")

    -- a page of a notebook that was deleted after it: the notebook comes back first
    nb = Notebook.fromData(Project.load(C))
    nb:addPage(); nb.pages[2].title = "Second"
    assert(Project.saveNotebook(nb, C))
    local page_item = Trash.putPage(ROOT, C, nb, 2)
    nb:takePage(2)
    assert(Project.saveNotebook(nb, C))
    local nb_item = Trash.putDocument(ROOT, C, true)
    ok(page_item and nb_item and not Storage.exists(C), "a page and then its notebook go")
    back = Trash.restore(ROOT, page_item.id, insertInFile)
    got = Notebook.fromData(Project.load(C))
    ok(back == C and got:count() == 2 and got.pages[2].title == "Second", "the page brings its notebook back")
    ok(#Trash.list(ROOT) == 0, "both leave the trash")

    -- a page of a notebook that is gone for good: a notebook of its own there
    nb = Notebook.fromData(Project.load(A))
    page_item = Trash.putPage(ROOT, A, nb, 2)
    os.remove(A)
    back = Trash.restore(ROOT, page_item.id, insertInFile)
    got = Notebook.fromData(Project.load(A))
    ok(back == A and got:count() == 1 and got.pages[1].title == "Page 2", "a page whose notebook is gone gets a new one")
end

------------------------------------------------------------------------------
-- Deleting for good
------------------------------------------------------------------------------
do
    local a = Trash.putDocument(ROOT, A, true)
    local s = Trash.putFolder(ROOT, SCHOOL .. "/Math")
    ok(Trash.forget(ROOT, a.id) and #Trash.list(ROOT) == 1, "an item can be deleted for good")
    ok(not Storage.exists(ROOT .. "/.trash/" .. a.id .. ".inkaway"), "and its file is gone")
    clock = clock + 31 * 86400
    local c = Trash.putDocument(ROOT, C, true)
    ok(Trash.purge(ROOT) == 1 and #Trash.list(ROOT) == 1 and Trash.list(ROOT)[1].id == c.id,
        "what waited 30 days goes on its own; the rest stays")
    ok(not Storage.exists(ROOT .. "/.trash/" .. s.id), "a folder's files too")
    Trash.empty(ROOT)
    ok(#Trash.list(ROOT) == 0, "the trash can be emptied")
    local f = assert(io.open(ROOT .. "/.trash/index", "wb")); f:write("{{{ garbage"); f:close()
    ok(#Trash.list(ROOT) == 0, "a damaged trash index reads as empty")
    local r, err = Trash.restore(ROOT, "nothing")
    ok(r == nil and err, "putting back what is not there says so")
    r, err = Trash.putDocument(ROOT, ROOT .. "/missing.inkaway", false)
    ok(r == nil and err, "deleting what is not there says so")
end

os.execute("rm -rf '" .. ROOT .. "'")
print(("trash: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
