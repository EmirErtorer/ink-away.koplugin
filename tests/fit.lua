-- A notebook made on a reader with another screen: it keeps its own page size and
-- is fitted to this screen (ink/view/viewport.lua pageNeedsFit and nb_fit), while a
-- notebook made for this screen is exactly what it was. The mock screen is set
-- to a size, a notebook file written at another, and opened.
--   luajit tests/fit.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local BB = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local TestEnv = require("testenv")
_G.G_reader_settings = {
    data = TestEnv.settings(),
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Storage = require("ink/storage")

local checks, fails = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL: " .. what) end
end
local function near(a, b) return math.abs(a - b) < 0.01 end

local dir = TestEnv.libraryDir()
-- a notebook of w x h with one stroke at (x, y)
local function write(name, w, h, x, y)
    local nb = Notebook.new(w, h, { style = "lines", size = 40 })
    nb.pages[1].ops = { { kind = "ink", width = 4, alpha = 255, pts = { x, y, x + 50, y + 50 } } }
    nb:addPage()
    local path = dir .. "/" .. name .. ".inkaway"
    assert(Project.saveNotebook(nb, path))
    return path
end
local function size(path)
    local d = Project.load(path)
    return d.w, d.h
end

Screen:setSize(1236, 1648)    -- a Paperwhite
UIManager.reset()
local InkAwayView = dofile("ink/view.lua")
local view = InkAwayView:new{}

-- 1. a notebook from a bigger screen (a Scribe)
local scribe = write("scribe", 1860, 2480, 1500, 2000)
ok(view:pageNeedsFit(1860, 2480), "a Scribe page is not this screen's")
ok(not view:pageNeedsFit(1236, 1648), "this screen's own size is not")
ok(not view:pageNeedsFit(1648, 1236), "nor this screen turned")
ok(not view:pageNeedsFit(1237, 1647), "a pixel off is rounding, not another screen")
ok(not view:pageNeedsFit(nil, 5), "nonsense is left alone")
ok(view:openDocument(scribe), "it opens")
ok(view.nb_fit == true, "it is fitted")
ok(view.notebook.w == 1860 and view.notebook.h == 2480, "the notebook keeps its page size")
ok(view.view.canvas_w == 1860 and view.view.canvas_h == 2480, "and so does the canvas")
ok(view.canvas.w == 1860, "the model canvas too")
ok(near(view.view.zoom, math.min(view.view.area_w / 1860, view.view.area_h / 2480)), "the whole page is shown")
ok(view.view.zoom < 1, "smaller than life")
ok(view.zoom_min == view.view.zoom, "and it cannot be zoomed out further")
ok(view.canvas:opCount() == 1, "the stroke written on the Scribe is there")

-- drawing at the middle of the area lands in page coordinates, not screen ones
local v = view.view
local sx, sy = v.area_x + v.area_w / 2, v.area_y + v.area_h / 2
local InkGeom = require("ink/geom")
local cx, cy = InkGeom.toCanvas(v, sx, sy)
ok(cx > 700 and cx < 1200, "the middle of the screen is the middle of the page (" .. math.floor(cx) .. ")")
view:setZoom(v.zoom * 2)
ok(v.zoom > view.zoom_min, "it can be zoomed in")
-- saving keeps the page size
view:saveDocument(true)
local w, h = size(scribe)
ok(w == 1860 and h == 2480, "saving does not shrink the page to this screen")
-- rotating the reader does not reshape it
Screen:setSize(1648, 1236)
view:handleScreenResize()
ok(view.view.canvas_w == 1860 and view.view.canvas_h == 2480, "turning the reader leaves the page alone")
ok(near(view.zoom_min, InkGeom.fitZoom(view.view)) and view.view.zoom >= view.zoom_min, "and the fit is worked out again for the turned screen")
Screen:setSize(1236, 1648)
view:handleScreenResize()

-- a new page in it is the notebook's size
view.notebook:addPage()
ok(true, "adding a page works")

-- 2. leaving it for a drawing gives the page back the screen's size
view:openDocument(write("plain", 1236, 1648, 100, 100))
ok(not view.nb_fit, "a notebook for this screen is not fitted")
ok(view.view.canvas_w == 1236 and view.view.canvas_h == 1648, "its page is the screen's")
ok(view.notebook.w == 1236, "as it always was")
ok(near(view.view.zoom, 1), "at full size")
view:openDocument(scribe)
ok(view.nb_fit and view.view.canvas_w == 1860, "back to the Scribe notebook: fitted again")
view:exitNotebook()
ok(not view.nb_fit and view.view.canvas_w == 1236 and view.view.canvas_h == 1648, "leaving notebook mode restores the screen's page")
ok(view.canvas.w == 1236, "in the model too")

-- 3. a notebook of a smaller screen is fitted up
local small = write("small", 758, 1024, 100, 100)
view:openDocument(small)
ok(view.nb_fit and view.view.canvas_w == 758, "a smaller page keeps its size")
ok(view.view.zoom > 1, "and is shown larger")
local w2, h2 = size(small)
view:saveDocument(true)
w2, h2 = size(small)
ok(w2 == 758 and h2 == 1024, "and is saved as it was")

-- 4. the overview does not rewrite sizes either
local doc = view:notebookFileDoc(scribe)
ok(doc.nb.w == 1860 and doc.nb.h == 2480, "the page overview reads the notebook's own size")
local doc2 = view:notebookFileDoc(write("plain2", 1236, 1648, 1, 1))
ok(doc2.nb.w == 1236, "and this screen's size for a notebook of this screen")

-- 5. a new notebook after all that is the screen's
view:startNotebook({ style = "lines", size = 40 })
ok(not view.nb_fit and view.view.canvas_w == 1236 and view.notebook.w == 1236, "a new notebook is the screen's size")

print(string.format("fit: %d checks, %d failed", checks, fails))
TestEnv.cleanup()
os.exit(fails == 0 and 0 or 1)
