-- The page a notebook was left on, in KOReader's real emulator: the real view in
-- the real window stack, the real settings file written to disk when Ink Away
-- closes and read back by a fresh settings object (what a restart does). Notebooks
-- made in Ink Away and an imported PDF's, another notebook opened in between, the
-- pages turned from the notebook bar.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/resume.lua <repo>
local REPO = arg[1] or "."
require("setupkoenv")
local ffi = require("ffi")
ffi.cdef[[int setenv(const char *name, const char *value, int overwrite);]]
local lfs = require("libs/libkoreader-lfs")
local tmp = os.tmpname()
os.remove(tmp)
assert(lfs.mkdir(tmp))
ffi.C.setenv("KO_HOME", tmp, 1)
ffi.C.setenv("SDL_VIDEODRIVER", "dummy", 1)
_G.G_defaults = require("luadefaults"):open()
local settings_file = tmp .. "/settings.reader.lua"
local function openSettings()
    local s = require("luasettings"):open(settings_file)
    return s
end
G_reader_settings = openSettings()
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
package.path = REPO .. "/?.lua;" .. package.path   -- (not the mocks: every widget is KOReader's)
G_reader_settings:saveSetting("inkaway_library_dir", tmp .. "/lib")
G_reader_settings:saveSetting("inkaway_session_migrated", true)
G_reader_settings:saveSetting("inkaway_welcome_seen", true)
lfs.mkdir(tmp .. "/lib")
G_reader_settings:flush()
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Screen = Device.screen

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local lib = tmp .. "/lib"
local W, H = Screen:getWidth(), Screen:getHeight()
local function write(name, n, mk)
    local nb = (mk or function() return Notebook.new(W, H, { style = "lines", size = 40 }) end)()
    for _ = nb:count() + 1, n do nb:addPage() end
    nb.index = 1
    local path = lib .. "/" .. name .. ".inkaway"
    assert(Project.saveNotebook(nb, path))
    return path
end
-- a new Ink Away: a fresh settings object read from the file on disk, a new view
local function start()
    G_reader_settings = openSettings()
    local view = dofile(REPO .. "/ink/view.lua"):new{}
    UIManager:show(view)
    return view
end
local function quit(view)
    UIManager:close(view)      -- the real close: it calls onCloseWidget
end
local function page(view) return view.notebook and view.notebook.index end

local a = write("a", 8)
local b = write("b", 5)
local pdf = write("scan", 12, function()
    return Notebook.forPdf(W, H, { style = "blank", size = 40, pdf_path = tmp .. "/gone.pdf" }, 12)
end)

-- 1. open, turn pages the way the bar does, close; start anew
local view = start()
ok(view:openDocument(a) and page(view) == 1, "A opens on page 1 the first time")
view:nbGo(1); view:nbGo(1); view:nbGo(1)
ok(page(view) == 4, "three page turns: page 4")
quit(view)
view = start()
view:openStartDocument()
ok(view.doc_path == a and page(view) == 4, "Ink Away started anew opens A on page 4 (page " .. tostring(page(view)) .. ")")

-- 2. another notebook in between, in the same session
view:nbGoTo(7)
ok(view:openDocument(b), "B opens")
view:nbGo(1); view:nbGo(1)
ok(view:openDocument(a) and page(view) == 7, "back to A: page 7 (page " .. tostring(page(view)) .. ")")
ok(view:openDocument(b) and page(view) == 3, "back to B: page 3 (page " .. tostring(page(view)) .. ")")
quit(view)

-- 3. an imported PDF's notebook
view = start()
ok(view:openDocument(pdf), "the PDF notebook opens")
view:nbGoTo(9)
quit(view)
view = start()
view:openStartDocument()
ok(view.doc_path == pdf and page(view) == 9, "the PDF notebook comes back on page 9 (page " .. tostring(page(view)) .. ")")

-- 4. the reader is killed after a page turn: what was written when the notebook was
-- left is there, and the settings file holds every notebook's page
local raw = openSettings()
local map = raw:readSetting("inkaway_nb_last_page") or {}
local n = 0
for _p in pairs(map) do n = n + 1 end
ok(n == 3, "the settings file on disk holds the three notebooks' pages (" .. n .. ")")

-- 5. a notebook made now, with pages added, left on page 3
view:newNotebook("lines", lib)
view.canvas:addOp({ kind = "ink", width = 4, alpha = 255, pts = { 100, 100, 300, 300 } })
view:nbAddPage(); view:nbAddPage()
view:markDirty()
local fresh = view.doc_path
quit(view)
view = start()
view:openStartDocument()
ok(view.doc_path == fresh and page(view) == 3, "a notebook made now opens on page 3 (page " .. tostring(page(view)) .. ")")
quit(view)

-- 6. a page turned right before the reader is shut down (flush on close only)
view = start()
view:openDocument(a)
view:nbGoTo(2)
quit(view)
ok(openSettings():readSetting("inkaway_nb_last_page")[a].id == 2, "a page turned just before closing is on disk")

print(("realbb resume: %d checks, %d failures"):format(checks, failures))
os.execute("rm -rf '" .. tmp .. "'")
os.exit(failures == 0 and 0 or 1)
