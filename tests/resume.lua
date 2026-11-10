-- Notebooks open on the page they were left on, in every way they are left and
-- opened again: another notebook opened in between, Ink Away closed and started
-- anew, pages added or deleted before it, a PDF notebook, and the reader's
-- settings written to disk when Ink Away closes (not only kept in memory).
--   luajit tests/resume.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local TestEnv = require("testenv")
local flushes = 0
_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
    flush = function() flushes = flushes + 1 end,
}
TestEnv.remember_last_doc = true   -- the reader keeps the last document, as it does
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local LastPage = require("ink/lastpage")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end

local dir = TestEnv.libraryDir()
-- a notebook of `n` pages on this screen, saved as `name`
local function write(name, n, mk)
    local nb = (mk or function() return Notebook.new(Screen:getWidth(), Screen:getHeight(), { style = "lines", size = 40 }) end)()
    for _ = nb:count() + 1, n do nb:addPage() end
    nb.index = 1
    local path = dir .. "/" .. name .. ".inkaway"
    assert(Project.saveNotebook(nb, path))
    return path
end
local function newView()
    UIManager.reset()
    local InkAwayView = dofile("ink/view.lua")
    return InkAwayView:new{}
end
local function pageOf(view) return view.notebook and view.notebook.index end

Screen:setSize(1236, 1648)
local a = write("a", 6)
local b = write("b", 4)

-- 1. turn pages, open another notebook, come back: A is where it was left
local view = newView()
ok(view:openDocument(a), "A opens")
ok(pageOf(view) == 1, "a notebook never opened starts on its first page")
view:nbGoTo(4)
local a_id = view.notebook.pages[4].id
ok(view:openDocument(b), "B opens")
ok(pageOf(view) == 1, "B was never opened: its first page")
ok(LastPage.get(_G.G_reader_settings.data[LastPage.SETTING], a) == a_id, "opening B leaves the page A was left on as it was")
view:nbGoTo(3)
ok(view:openDocument(a), "A opens again")
ok(pageOf(view) == 4, "A opens on the page it was left on, after another notebook was opened (page " .. tostring(pageOf(view)) .. ")")
ok(view:openDocument(b), "B opens again")
ok(pageOf(view) == 3, "and so does B (page " .. tostring(pageOf(view)) .. ")")

-- 2. Ink Away closed and started anew: the last notebook is on its page
view:nbGoTo(4)
view:onCloseWidget()
ok(flushes >= 1, "closing writes the reader's settings to disk")
view = newView()
view.open_path = nil
view:openStartDocument()
ok(view.doc_path == b and pageOf(view) == 4, "Ink Away started anew opens the last notebook on page 4 (page " .. tostring(pageOf(view)) .. ")")
-- a page turned right before closing, with no other change since
view:nbGoTo(2)
local before = flushes
view:onCloseWidget()
ok(flushes > before, "a page turned just before closing is written out too")
view = newView()
ok(view:openDocument(b) and pageOf(view) == 2, "and kept (page " .. tostring(pageOf(view)) .. ")")

-- 3. the same page again changes nothing on disk
before = flushes
view:onCloseWidget()
ok(flushes == before, "closing on a page already kept writes nothing")

-- 4. pages deleted before the page left on (the file changed while it was not
-- open, as a synced copy would) keep it found
view = newView()
view:openDocument(a)
view:nbGoTo(5)
local id5 = view.notebook.pages[5].id
view:openDocument(b)
local data = Project.load(a)
local nb = Notebook.fromData(data)
nb.index = 1
nb:deletePage()
assert(Project.saveNotebook(nb, a))
view:openDocument(a)
ok(view.notebook.pages[view.notebook.index].id == id5, "a page deleted before it: the same page")

-- 5. the first page, and a last page that no longer exists
view:nbGoTo(1)
view:openDocument(b); view:openDocument(a)
ok(pageOf(view) == 1, "page 1 is kept as well")
view:nbGoTo(view.notebook:count())
view:openDocument(b)
local gone = write("a", 2)     -- a rewritten with fewer pages (a different file under the same name)
view:openDocument(a)
ok(pageOf(view) >= 1 and pageOf(view) <= view.notebook:count(), "a page that is gone: opens on a page that exists")

-- 6. a notebook made new, left on a page, opened later (also from the start list)
view = newView()
view:newNotebook("lines", dir)
local fresh = view.doc_path
view:nbAddPage(); view:nbAddPage()
ok(pageOf(view) == 3, "adding pages from the bar moves to the new one")
view.canvas:addOp({ kind = "ink", width = 4, alpha = 255, pts = { 100, 100, 200, 200 } })   -- (an empty notebook is not saved yet)
view:markDirty()
view:saveDocument(true)
ok(view.doc_written, "the new notebook is saved")
view:openDocument(a)
view:openDocument(fresh)
ok(pageOf(view) == 3, "a new notebook is kept on its page too (page " .. tostring(pageOf(view)) .. ")")

-- 7. an imported PDF notebook (the PDF may be missing: the pages are still kept)
local pdfnb = write("pdfnb", 5, function()
    return Notebook.forPdf(Screen:getWidth(), Screen:getHeight(), { style = "blank", size = 40, pdf_path = dir .. "/none.pdf" }, 5)
end)
view = newView()
view:openDocument(pdfnb)
view:nbGoTo(5)
view:openDocument(a)
view:openDocument(pdfnb)
ok(pageOf(view) == 5, "a PDF notebook opens on the page left on (page " .. tostring(pageOf(view)) .. ")")

-- 8. renamed: the page goes with the file
local moved = dir .. "/renamed.inkaway"
os.rename(pdfnb, moved)
view:lastPageMoved(pdfnb, moved)
view = newView()
view:openDocument(moved)
ok(pageOf(view) == 5, "a renamed notebook keeps its page (page " .. tostring(pageOf(view)) .. ")")

print(string.format("resume: %d checks, %d failed", checks, fails))
TestEnv.cleanup()
os.exit(fails == 0 and 0 or 1)
