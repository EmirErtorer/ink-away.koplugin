-- Performance benchmark for Ink Away on KOReader's real blitter (headless), for
-- comparing two versions of the plugin. Drives the real InkAwayView and records,
-- per action: wall time (handler + the paint after it), what it asked the e-ink
-- screen to refresh (area and flashes), memory, bytes on disk, and JIT trace
-- flushes. Features one version lacks are skipped there. "Old" below means the
-- versions before the library (a session file, Save sheet, page grid); "new"
-- the ones with it (every document a file, autosave, library, overview).
-- One plugin version, one screen config and one part per process; run.sh runs
-- them all.
--   cd <emulator>/koreader && ./luajit bench.lua <plugin_dir> <mock_dir> <cfg> <out> <WxH> <part>
--   cfg: grey:<rot> | colour:<rot>; part: ui | io
local REPO, MOCK, CFG, OUT, SIZE, PART = arg[1], arg[2], arg[3], arg[4], arg[5] or "1072x1448", arg[6] or "ui"
local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)/") or "."
local H = dofile(HERE .. "/harness.lua")(REPO, MOCK, CFG, SIZE)
local ffi, BB, real_lfs, now_us = H.ffi, H.BB, H.real_lfs, H.now_us
local Screen, UIManager, gd, TMP, settings = H.Screen, H.UIManager, H.gd, H.TMP, H.settings
local colour, rot, SW, SH = H.colour, H.rot, H.SW, H.SH

------------------------------------------------------------------------------
-- Recording
------------------------------------------------------------------------------

local samples, order = {}, {}
local function rec(metric, v)
    local t = samples[metric]
    if not t then t = {}; samples[metric] = t; order[#order + 1] = metric end
    t[#t + 1] = v
end

Screen.bb = BB.new(SW, SH, colour and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
Screen.bb:setRotation(rot)
local SCREEN_AREA = Screen:getWidth() * Screen:getHeight()
UIManager.reset()
math.randomseed(7)

-- What the actions since the last reset asked the screen to refresh: the share
-- of the screen covered (summed over requests, so 2.0 = two full refreshes) and
-- how many requests were flashing ("full" / "flash*") ones.
local function refreshStats()
    local area, flashes, n = 0, 0, 0
    for _, r in ipairs(UIManager.refreshes) do
        local mode, region = r.mode, r.region
        if type(mode) == "function" then mode, region = mode() end
        n = n + 1
        if mode == "full" or (type(mode) == "string" and mode:find("^flash")) then flashes = flashes + 1 end
        if region and region.w then
            area = area + region.w * region.h
        else
            local d = r.widget and type(r.widget) == "table" and r.widget.dimen
            area = area + ((d and d.w and d.w * d.h) or SCREEN_AREA)
        end
    end
    return area / SCREEN_AREA, flashes, n
end

local t0 = now_us()
local View = dofile(REPO .. "/ink/view.lua")
rec("open.load_modules", now_us() - t0)
local loaded_files = 0
for name in pairs(package.loaded) do if name:find("^ink/") then loaded_files = loaded_files + 1 end end
rec("open.ink_modules_loaded", loaded_files)
t0 = now_us()
local view = View:new{}
UIManager:show(view)
rec("open.init", now_us() - t0)
view.nowMs = function() return 0 end
local function paint() view:paintTo(Screen.bb, 0, 0) end
t0 = now_us(); paint(); rec("open.first_paint", now_us() - t0)
UIManager.fireScheduled()

local function mem(tag)
    collectgarbage("collect"); collectgarbage("collect")
    rec("mem." .. tag, collectgarbage("count"))   -- KB
end
mem("open")

local function P(x, y) return { pos = { x = math.floor(x), y = math.floor(y) } } end
-- time fn plus the paint after it; with `rf`, also what it refreshed
local function timed(metric, fn, rf)
    UIManager.refreshes = {}
    local t = now_us(); fn(); paint(); rec(metric, now_us() - t)
    if rf then
        local a, fl = refreshStats()
        rec("refresh." .. metric .. ".area", a)
        rec("refresh." .. metric .. ".flashes", fl)
    end
    UIManager.refreshes = {}
end

local function wave(x0, y0, x1, n, amp, phase)
    local t = {}
    for i = 0, n do
        local u = i / n
        t[#t + 1] = x0 + (x1 - x0) * u
        t[#t + 1] = y0 + math.sin(u * math.pi * 3 + (phase or 0)) * amp
    end
    return t
end

local function stroke(prefix, pts)
    timed(prefix .. ".down", function() view:onIaTouch(nil, P(pts[1], pts[2])) end)
    for i = 3, #pts, 2 do
        timed(prefix .. ".move", function() view:onIaPan(nil, P(pts[i], pts[i + 1])) end)
    end
    timed(prefix .. ".lift", function() view:onIaPanRelease(nil, P(pts[#pts - 1], pts[#pts])) end)
    timed(prefix .. ".commit", function() view:flushPending() end)
    UIManager.fireScheduled()
    UIManager.refreshes = {}
end

local v = view.view
local function area() return v.area_x, v.area_y, v.area_w, v.area_h end

local function strokes(prefix, n, npts, amp)
    local ax, ay, aw, ah = area()
    for k = 1, n do
        local y = ay + 60 + (k - 1) * (ah - 120) / math.max(1, n - 1)
        local x0 = ax + 40 + (k % 3) * 20
        stroke(k == 1 and (prefix .. ".first") or prefix, wave(x0, y, x0 + aw * 0.75, npts, amp, k))
    end
end

local function closeShown(w)
    if w.onCloseMenu then w:onCloseMenu() else UIManager:close(w) end
    for k, val in pairs(view) do if val == w then view[k] = nil end end
    UIManager.refreshes = {}
end

-- open a sheet `n` times: its build time, a paint of it where it can paint
-- itself (the full-screen grids), what it refreshed, and closing it
local function sheet(name, open, n)
    for r = 1, n or 6 do
        local before = UIManager.shown
        UIManager.refreshes = {}
        local t = now_us()
        local ok, err = pcall(open)
        local w = UIManager.shown
        if ok and w and w ~= before and w.paintTo and w.dimen and w.dimen.w == Screen:getWidth() then
            pcall(w.paintTo, w, Screen.bb, 0, 0)   -- a full-screen grid paints its cards
        end
        local dt = now_us() - t
        if not ok or w == before or not w then
            rec("sheet." .. name .. ".error", 1)
            if not ok then io.stderr:write(name .. ": " .. tostring(err) .. "\n") end
            return
        end
        rec("sheet." .. name .. (r == 1 and ".open_first" or ".open"), dt)
        if r == 1 then
            local a, fl = refreshStats()
            rec("refresh.sheet." .. name .. ".area", a); rec("refresh.sheet." .. name .. ".flashes", fl)
        end
        UIManager.refreshes = {}
        t = now_us(); closeShown(w); paint(); rec("sheet." .. name .. ".close", now_us() - t)
        if r == 1 then
            local a, fl = refreshStats()
            rec("refresh.sheet." .. name .. ".close.area", a); rec("refresh.sheet." .. name .. ".close.flashes", fl)
        end
        UIManager.refreshes = {}
    end
end

local function fileSize(p) return real_lfs.attributes(p, "size") or 0 end

-- start a notebook on lined paper, in either version
-- (the old version also has a newNotebook, but it asks first; the new one
-- creates the notebook, saving the open document)
local NEW = view.saveDocument ~= nil
rec("version.is_branch", NEW and 1 or 0)
local function startNotebook()
    if NEW then view:newNotebook("lines")
    else   -- the same paper the new version's newNotebook makes
        view:startNotebook({ style = "lines", size = view.nb_size or view.grid_size or 40,
            strength = view.nb_strength or view.grid_strength or 45 })
    end
    v = view.view
    assert(view.notebook, "no notebook started")
end

------------------------------------------------------------------------------
-- Part "ui": drawing, editing, sheets, a small notebook
------------------------------------------------------------------------------

if PART == "ui" then
    view:setTool("pen")
    strokes("pen.solid", 14, 120, 30)
    view.pen_style = "pencil"; strokes("pen.pencil", 6, 120, 30); view.pen_style = nil
    view.pen_color = { 220, 40, 40 }; strokes("pen.colour", 6, 120, 30); view.pen_color = { 0, 0, 0 }
    view.pen_alpha = 128; strokes("pen.translucent", 4, 120, 30); view.pen_alpha = 255
    view.symmetry = "quad"; strokes("pen.quad", 4, 80, 20); view.symmetry = "off"
    mem("drawn")
    -- refreshes of one ordinary stroke
    do
        local ax, ay, aw = area()
        local pts = wave(ax + 50, ay + 300, ax + aw * 0.7, 120, 30, 1)
        UIManager.refreshes = {}
        view:onIaTouch(nil, P(pts[1], pts[2])); paint()
        for i = 3, #pts, 2 do view:onIaPan(nil, P(pts[i], pts[i + 1])); paint() end
        view:onIaPanRelease(nil, P(pts[#pts - 1], pts[#pts])); paint()
        view:flushPending(); paint()
        local a, fl, n = refreshStats()
        rec("refresh.stroke.area", a); rec("refresh.stroke.flashes", fl); rec("refresh.stroke.requests", n)
        UIManager.fireScheduled(); UIManager.refreshes = {}
    end

    view.shape_assist = true
    do
        local ax, ay = area()
        for k = 1, 4 do
            local x0, y0 = ax + 100 + k * 30, ay + 150 + k * 40
            local pts = {}
            local function line(x1, y1, x2, y2, n)
                for i = 0, n - 1 do
                    local u = i / n
                    pts[#pts + 1] = x1 + (x2 - x1) * u + math.sin(i) * 2
                    pts[#pts + 1] = y1 + (y2 - y1) * u + math.cos(i) * 2
                end
            end
            line(x0, y0, x0 + 300, y0, 30); line(x0 + 300, y0, x0 + 300, y0 + 200, 20)
            line(x0 + 300, y0 + 200, x0, y0 + 200, 30); line(x0, y0 + 200, x0, y0 + 4, 20)
            stroke("pen.assist", pts)
        end
    end
    view.shape_assist = false

    view:setTool("erase")
    strokes("erase.soft", 6, 100, 25)
    if view.erase_whole ~= nil or view.setEraseWhole then end

    view:setTool("pen")
    do
        local ax, ay, aw = area()
        local slot = { slot = 0 }
        local clock = 1700000000 * 1000000
        for k = 1, 6 do
            local pts = wave(ax + 60, ay + 200 + k * 90, ax + 60 + aw * 0.7, 100, 25, k)
            for i = 1, #pts, 2 do
                clock = clock + 10000
                slot.id, slot.x, slot.y, slot.timev = 20 + k, pts[i], pts[i + 1], clock
                timed(i == 1 and "raw.down" or "raw.move", function() gd:feedEvent({ slot }) end)
            end
            clock = clock + 10000
            slot.id, slot.timev = -1, clock
            timed("raw.lift", function() gd:feedEvent({ slot }) end)
            timed("raw.commit", function() view:flushPending() end)
            UIManager.fireScheduled()
        end
    end

    view:setTool("shape")
    for k = 1, 6 do
        view.shape = (k % 2 == 0) and "ellipse" or "rect"
        view.shape_fill = (k % 3 == 0)
        local ax, ay = area()
        local x0, y0 = ax + 80 + k * 40, ay + 120 + k * 60
        timed("shape.down", function() view:onIaTouch(nil, P(x0, y0)) end)
        for i = 1, 30 do
            timed("shape.move", function() view:onIaPan(nil, P(x0 + i * 10, y0 + i * 6)) end)
        end
        timed("shape.commit", function() view:onIaPanRelease(nil, P(x0 + 300, y0 + 180)) end)
    end

    view:setTool("fill")
    do
        local ax, ay = area()
        timed("fill.tap", function() view:onIaTouch(nil, P(ax + 80 + 5 * 40 + 60, ay + 120 + 5 * 60 + 40)) end, true)
    end

    view:setTool("lasso")
    do
        local ax, ay, aw, ah = area()
        local cx, cy = ax + aw / 2, ay + ah / 3
        local loop = {}
        for i = 0, 40 do
            local a = i / 40 * 2 * math.pi
            loop[#loop + 1] = cx + math.cos(a) * aw * 0.35
            loop[#loop + 1] = cy + math.sin(a) * ah * 0.12
        end
        timed("lasso.down", function() view:onIaTouch(nil, P(loop[1], loop[2])) end)
        for i = 3, #loop, 2 do timed("lasso.move", function() view:onIaPan(nil, P(loop[i], loop[i + 1])) end) end
        timed("lasso.close", function() view:onIaPanRelease(nil, P(loop[#loop - 1], loop[#loop])) end)
        if view.selection then
            timed("lasso.grab", function() view:onIaTouch(nil, P(cx, cy)) end)
            for i = 1, 20 do timed("lasso.drag", function() view:onIaPan(nil, P(cx + i * 4, cy + i * 3)) end) end
            timed("lasso.drop", function() view:onIaPanRelease(nil, P(cx + 80, cy + 60)) end)
            UIManager.fireScheduled()
            -- the clipboard (new version only)
            if view.selCopy then
                timed("clip.copy", function() view:selCopy(false) end)
            end
        end
        view:clearSelection()
    end

    view:setTool("pen")
    timed("image.insert", function() view:insertImage("fake.png") end)
    do
        -- (the selection replaced the picture's own frame and menu in the newer
        -- versions; either is driven the same way)
        local icx, icy
        if view.selFrame then
            local f = view:selFrame()
            icx, icy = (f.x0 + f.x1) / 2, (f.y0 + f.y1) / 2
        else
            local ir = view:imageScreenRect()
            icx, icy = ir.x + ir.w / 2, ir.y + ir.h / 2
        end
        timed("image.grab", function() view:onIaTouch(nil, P(icx, icy)) end)
        for i = 1, 20 do timed("image.drag", function() view:onIaPan(nil, P(icx + i * 3, icy + i * 2)) end) end
        timed("image.drop", function() view:onIaPanRelease(nil, P(icx + 60, icy + 40)) end)
        timed("image.rotate90", function()
            if view.selTurn90 then view:selTurn90() else view:rotateImage90(view.active_image) end
        end)
        timed("image.finish", function()
            if view.dropSelection then view:dropSelection() else view:finishImageEdit() end
        end)
    end

    view:setTool("pen")
    do
        local ax, ay, aw, ah = area()
        local cx, cy = ax + aw / 2, ay + ah / 2
        timed("zoom.in", function() view:setZoom(2, cx, cy) end, true)
        for i = 1, 20 do timed("pan.step", function() view:panByScreen((i % 2 == 0) and -40 or 30, -25) end) end
        stroke("pen.zoomed", wave(cx - 150, cy, cx + 150, 60, 25))
        timed("zoom.out", function() view:setZoom(view.zoom_min, cx, cy) end)
        timed("zoom.reset", function() view:setZoom(1, cx, cy) end)
    end

    for i = 1, 8 do timed("undo", function() view:undo() end, i == 1) end
    for _ = 1, 8 do timed("redo", function() view:redo() end) end
    rec("ops.count", #view.canvas.ops)

    local tools = { "erase", "shape", "pen", "text", "pan", "lasso", "fill", "pen" }
    for i, t in ipairs(tools) do timed("tool.switch", function() view:setTool(t) end, i == 1) end
    for _ = 1, 3 do
        timed("toolbar.hide", function() view:setToolbarHidden(true) end)
        timed("toolbar.show", function() view:setToolbarHidden(false) end)
    end

    -- sheets: the same ones in both, then the ones only one version has
    local SHEETS = {
        { "pen", function() view:openPenSettings() end },
        { "eraser", function() view:openEraserSettings() end },
        { "shapes", function() view:openShapePicker() end },
        { "fill", function() view:openFillColor() end },
        { "text", function() view:openTextSettings() end },
        { "settings", function() view:openSettings() end },
        { "grid", function() view:openGridSettings() end },
        { "image", function() view:chooseImage() end },
        { "brushmaker", function() view:openBrushMaker() end },
        { "colorwheel", function() view:openColorPicker() end },
    }
    if view.onSave then SHEETS[#SHEETS + 1] = { "save(main)", function() view:onSave() end } end
    if view.openDocumentSheet then
        SHEETS[#SHEETS + 1] = { "file", function() view:openDocumentSheet() end }
        SHEETS[#SHEETS + 1] = { "export", function() view:openExport() end }
        SHEETS[#SHEETS + 1] = { "newnotebook.paper", function() view:openNotebookPaper() end }
    end
    for _, s in ipairs(SHEETS) do sheet(s[1], s[2], 6) end
    if view.openLibrary then sheet("library(small)", function() view:openLibrary() end, 4) end

    -- a small notebook
    view:setTool("pen")
    timed("nb.start", startNotebook, true)
    strokes("nb.pen", 8, 120, 20)
    view:setTool("erase")
    strokes("nb.erase", 4, 100, 15)
    view.erase_bg = true; strokes("nb.harderase", 3, 100, 15); view.erase_bg = false
    view:setTool("pen")
    for i = 1, 3 do timed("nb.addpage", function() view:nbAddPage() end, i == 1); strokes("nb.pen.more", 2, 80, 20) end
    for i = 1, 12 do timed("nb.turn", function() view:nbGo((i % 2 == 0) and 1 or -1) end, i == 1) end
    mem("notebook")
    sheet("pagemenu", function() view:openPageMenu() end, 4)
    if view.openOverview then sheet("overview(4p)", function() view:openOverview() end, 3)
    else sheet("pagegrid(4p)", function() view:openPageGrid() end, 3) end
    -- clipboard paste on another page (new version only)
    if view.pasteAt and require("ink/clipboard").count() > 0 then
        view:setTool("lasso")
        local ax, ay, aw, ah = area()
        timed("clip.paste", function() view:pasteAt({ x = ax + aw / 2, y = ay + ah / 2 }) end, true)
        view:clearSelection()
    end
end

------------------------------------------------------------------------------
-- Part "io": a big notebook on disk (save, open, turn, overview, export), and
-- the library and folders (new version only)
------------------------------------------------------------------------------

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, x in pairs(t) do c[k] = deepcopy(x) end
    return c
end

-- Run scheduled steps until none are left (an export job steps on the
-- scheduler); returns how many rounds it took.
local function drain(limit)
    local n = 0
    while UIManager.pendingCount() > 0 and n < (limit or 100000) do
        UIManager.fireScheduled(); n = n + 1
    end
    return n
end

-- A notebook of `pages` pages, each a copy of one page of handwriting drawn
-- with the pen (so the ops are what drawing really makes).
local NB_STROKES = 30
local function buildNotebook(pages)
    startNotebook()
    view:setTool("pen")
    local ax, ay, aw, ah = area()
    for k = 1, NB_STROKES do
        local y = ay + 40 + (k - 1) * (ah - 80) / NB_STROKES
        local pts = wave(ax + 40, y, ax + 40 + aw * 0.8, 60, 8, k)
        view:onIaTouch(nil, P(pts[1], pts[2]))
        for i = 3, #pts, 2 do view:onIaPan(nil, P(pts[i], pts[i + 1])) end
        view:onIaPanRelease(nil, P(pts[#pts - 1], pts[#pts]))
        view:flushPending()
    end
    view:nbSyncOut()
    local nb = view.notebook
    local base = deepcopy(nb.pages[1].ops)
    for _ = 2, pages do view:nbAddPage() end
    view:nbSyncOut()
    for i = 2, pages do nb.pages[i].ops = deepcopy(base) end
    view:nbGoTo(1)
    UIManager.fireScheduled(); UIManager.refreshes = {}
    return nb
end

-- One stroke on the page shown.
local function oneStroke(k)
    local ax, ay, aw = area()
    local pts = wave(ax + 60, ay + 100 + k * 13, ax + aw * 0.6, 60, 10, k)
    view:onIaTouch(nil, P(pts[1], pts[2]))
    for i = 3, #pts, 2 do view:onIaPan(nil, P(pts[i], pts[i + 1])) end
    view:onIaPanRelease(nil, P(pts[#pts - 1], pts[#pts]))
    view:flushPending()
end

if PART == "io" then
    local Project = require("ink/project")
    local PAGES = tonumber(os.getenv("BENCH_PAGES") or "40")
    local nb = buildNotebook(PAGES)
    rec("io.pages", PAGES)
    rec("io.ops_per_page", #nb.pages[1].ops)
    mem("bignb_built")

    -- the first full save, and the file it makes
    local path
    if view.saveDocument then
        local t = now_us(); view:saveDocument(true); rec("io.save_first", now_us() - t)
        path = view.doc_path
    else
        path = TMP .. "/lib/bench-notebook.inkaway"
        view:nbSyncOut()
        local t = now_us(); Project.saveNotebook(view.notebook, path); rec("io.save_first", now_us() - t)
    end
    rec("io.file_kb", fileSize(path) / 1024)

    -- the save that follows an edit: the new version autosaves (only the
    -- changed page is serialized again, then a synced write through a temporary
    -- file); the old one saves the session file whole, on exit by default or
    -- every 3 minutes
    for k = 1, 6 do
        view:nbGoTo(1 + (k * 7) % PAGES)
        oneStroke(k)
        UIManager.fireScheduled(); UIManager.refreshes = {}
        local t = now_us()
        if view.saveDocument then view:saveDocument() else view:saveSession() end
        rec("io.save_after_edit", now_us() - t)
    end
    if view.saveSession then rec("io.session_kb", fileSize(view:sessionPath()) / 1024) end
    if view.saveDocument then rec("io.saved_kb", fileSize(view.doc_path) / 1024) end
    -- serializing alone, all pages vs only one changed (the new version's cache)
    do
        view:nbSyncOut()
        local t = now_us(); local s = Project.serializeNotebook(view.notebook); rec("io.serialize_all", now_us() - t)
        rec("io.serialized_kb", #s / 1024)
        if view._page_cache then
            local cache = view._page_cache
            Project.serializeNotebook(view.notebook, cache)
            cache[view.notebook.pages[2]] = nil
            t = now_us(); Project.serializeNotebook(view.notebook, cache); rec("io.serialize_one_changed", now_us() - t)
        end
    end

    -- page turns in the big notebook
    for i = 1, 12 do timed("io.turn", function() view:nbGo((i % 2 == 0) and 1 or -1) end, i == 1) end

    -- reading the file
    for _ = 1, 3 do
        local t = now_us(); local data = Project.load(path); rec("io.parse", now_us() - t)
        data = nil
    end
    -- opening it: leave it, then open it again as the user would
    local function openIt()
        if view.openDocument then
            view:newDrawing()
            UIManager.fireScheduled()
            local t = now_us(); view:openDocument(path); paint(); rec("io.open_notebook", now_us() - t)
        else
            view:exitNotebook(); view:loadOps({})
            UIManager.fireScheduled()
            local t = now_us()
            view:openNotebookData(Project.load(path)); paint()
            rec("io.open_notebook", now_us() - t)
        end
        v = view.view
        UIManager.fireScheduled(); UIManager.refreshes = {}
    end
    for _ = 1, 3 do openIt() end
    mem("bignb_open")

    -- the page overview of the big notebook (first grid page of thumbnails)
    if view.openOverview then sheet("io.overview", function() view:openOverview() end, 3)
    else sheet("io.pagegrid", function() view:openPageGrid() end, 3) end
    do  -- memory held while it is open
        if view.openOverview then view:openOverview() else view:openPageGrid() end
        local w = UIManager.shown
        pcall(w.paintTo, w, Screen.bb, 0, 0)
        mem("overview_open")
        closeShown(w); paint()
    end

    -- PDF export of every page, run to the end
    do
        local out = TMP .. "/export-" .. PAGES .. ".pdf"
        local t = now_us()
        if view.writePDF then view:writePDF(out) else view:doNotebookExport(out) end
        local steps = drain()
        local dt = now_us() - t
        rec("io.pdf_export_total", dt)
        rec("io.pdf_export_per_page", dt / PAGES)
        rec("io.pdf_kb", fileSize(out) / 1024)
        rec("io.pdf_steps", steps)
        if os.getenv("BENCH_KEEP") then os.execute("cp '" .. out .. "' '" .. os.getenv("BENCH_KEEP") .. "'") end
        UIManager.refreshes = {}
        for _, w in ipairs(UIManager._window_stack) do if w.widget ~= view then UIManager:close(w.widget) end end
        paint()
    end
    -- a PNG of the page shown, with the new version's defaults (on white, with
    -- the paper's ruling) and, for a like-for-like number, as the old one makes
    -- it (transparent, ink only)
    if NEW then
        local o = view:exportOptions()
        local saved = { o.transparent, o.include_bg }
        o.transparent, o.include_bg = true, false
        local out = TMP .. "/page-plain.png"
        local t = now_us()
        view:writePNG(out)
        rec("io.png_export_as_main", now_us() - t)
        rec("io.png_as_main_kb", fileSize(out) / 1024)
        for _, w in ipairs(UIManager._window_stack) do if w.widget ~= view then UIManager:close(w.widget) end end
        o.transparent, o.include_bg = saved[1], saved[2]
    end
    do
        local out = TMP .. "/page.png"
        local t = now_us()
        if view.writePNG then view:writePNG(out) else view:writeFile("png", TMP, "page", "png") end
        drain()
        rec("io.png_export", now_us() - t)
        rec("io.png_kb", fileSize(out) / 1024)
        for _, w in ipairs(UIManager._window_stack) do if w.widget ~= view then UIManager:close(w.widget) end end
    end

    -- reopening Ink Away straight into the big notebook: the old version
    -- restores its session file (when autosave keeps one), the new one the
    -- last document
    do
        if view.saveSession then view:saveSession() else view:saveDocument(true) end
        UIManager:close(view)
        UIManager.reset()
        collectgarbage("collect")
        if not view.saveDocument then settings.inkaway_autosave = "periodic" end
        settings.inkaway_last_doc = path
        local t = now_us()
        view = View:new{}
        UIManager:show(view)
        view.nowMs = function() return 0 end
        paint()
        rec("io.reopen_with_notebook", now_us() - t)
        rec("io.reopen_pages", view.notebook and view.notebook:count() or 0)
        v = view.view
        UIManager.fireScheduled(); UIManager.refreshes = {}
    end

    -- the library and folders: new version only
    if view.openLibrary then
        local Storage = require("ink/storage")
        local lib = TMP .. "/lib"
        -- 24 documents in the library and 6 in a subfolder: drawings and
        -- notebooks of 5 pages
        local function writeDocs(dir, n, tag)
            os.execute("mkdir -p '" .. dir .. "'")
            for i = 1, n do
                local p = dir .. string.format("/%s %02d.%s", tag, i, Project.EXT)
                if i % 3 == 0 then
                    Project.save({ w = nb.w, h = nb.h, ops = deepcopy(nb.pages[1].ops) }, p)
                else
                    local small = { w = nb.w, h = nb.h, template = nb.template, pages = {} }
                    for j = 1, 5 do small.pages[j] = { ops = deepcopy(nb.pages[1].ops), id = j } end
                    Project.saveNotebook(small, p)
                end
            end
        end
        writeDocs(lib, 24, "Doc")
        writeDocs(lib .. "/School/Math", 6, "Math")
        writeDocs(lib .. "/School/Physics", 4, "Phys")
        local cache = Storage.cacheDir()
        os.execute("rm -rf '" .. cache .. "'")
        -- cold: every thumbnail on the first grid page drawn from its file
        UIManager.refreshes = {}
        local t = now_us()
        view:openLibrary(lib)
        local L = view._library
        L:paintTo(Screen.bb, 0, 0)
        rec("lib.open_cold", now_us() - t)
        local a, fl = refreshStats()
        rec("refresh.lib.open.area", a); rec("refresh.lib.open.flashes", fl)
        mem("library_open")
        rec("lib.first_page_thumbs", (function() local n = 0; for _, bb in pairs(L.cache) do if bb then n = n + 1 end end; return n end)())
        local step = (L.gpage > 0) and -1 or 1   -- it opens on the page of the open document
        t = now_us(); L:gridGo(step); L:paintTo(Screen.bb, 0, 0); rec("lib.next_page_cold", now_us() - t)
        local drawn = 0
        for _, bb in pairs(L.cache) do if bb then drawn = drawn + 1 end end
        rec("lib.next_page_thumbs", drawn)
        L:close(); paint()
        local n = 0
        for _ in real_lfs.dir(cache) do n = n + 1 end
        rec("lib.thumb_files", n - 2)
        -- warm: the same, from the cached thumbnails
        for _ = 1, 3 do
            t = now_us()
            view:openLibrary(lib)
            view._library:paintTo(Screen.bb, 0, 0)
            rec("lib.open_warm", now_us() - t)
            view._library:close(); paint()
        end
        view:openLibrary(lib)
        t = now_us(); view:libraryGo(lib .. "/School/Math"); view._library:paintTo(Screen.bb, 0, 0)
        rec("lib.into_folder_cold", now_us() - t)
        view._library:close(); paint()

        -- the overview's tabs and folders, with the big notebook open
        view:openDocument(path)
        UIManager.fireScheduled()
        t = now_us(); view:openOverview(); view._overview:paintTo(Screen.bb, 0, 0); rec("ov.open_with_tabs", now_us() - t)
        local ov = view._overview
        local other
        for _, tab in ipairs(ov.tabs) do if not tab.folder and tab.path ~= path then other = tab end end
        if other then
            t = now_us(); view:overviewShowTab(other.path); ov:paintTo(Screen.bb, 0, 0); rec("ov.tab_switch_cold", now_us() - t)
            t = now_us(); view:overviewShowTab(path); ov:paintTo(Screen.bb, 0, 0); rec("ov.tab_back_open_nb", now_us() - t)
            t = now_us(); view:overviewShowTab(other.path); ov:paintTo(Screen.bb, 0, 0); rec("ov.tab_switch_warm", now_us() - t)
        end
        rec("ov.tabs", #ov.tabs)
        if view.overviewGo then
            t = now_us(); view:overviewGo(lib .. "/School"); ov:paintTo(Screen.bb, 0, 0); rec("ov.into_folder", now_us() - t)
            t = now_us(); view:overviewGo(lib .. "/School/Math"); ov:paintTo(Screen.bb, 0, 0); rec("ov.into_subfolder_cold", now_us() - t)
            t = now_us(); view:overviewGo(lib .. "/School"); ov:paintTo(Screen.bb, 0, 0); rec("ov.up_folder", now_us() - t)
            t = now_us(); view:overviewGo(lib .. "/School/Math"); ov:paintTo(Screen.bb, 0, 0); rec("ov.into_subfolder_warm", now_us() - t)
            -- telling notebooks from drawings by peeking at 24 files
            local LibraryMod = require("ink/library")
            t = now_us()
            for e in real_lfs.dir(lib) do
                if e:find("%.inkaway$") then LibraryMod.isNotebookFile(lib .. "/" .. e) end
            end
            rec("ov.peek_24_files", now_us() - t)
        end
        mem("overview_tabs_open")
        ov:close(); paint()

        -- a folder (with its subfolders) as one PDF
        if view.collectFolderPages then
            local Export = require("ink/export")
            local acc = { pages = {}, templates = {}, sources = {} }
            t = now_us(); local outline = view:collectFolderPages(lib .. "/School", acc)
            rec("folder.collect", now_us() - t)
            rec("folder.pages", #acc.pages)
            local out = TMP .. "/school.pdf"
            t = now_us()
            view:runPdfJob(out, { pages = acc.pages, w = view.view.canvas_w, h = view.view.canvas_h,
                template = function(j) return acc.templates[j] end, outline = outline })
            drain()
            rec("folder.pdf_total", now_us() - t)
            rec("folder.pdf_per_page", (now_us() - t) / math.max(1, #acc.pages))
            rec("folder.pdf_kb", fileSize(out) / 1024)
            for _, w in ipairs(UIManager._window_stack) do if w.widget ~= view then UIManager:close(w.widget) end end
        end

        -- templates: save the page as one, then add a page from it
        if view.nbSaveTemplate then
            local Templates = require("ink/templates")
            t = now_us()
            Templates.save(view:libraryDir(), "Bench", view.notebook.pages[view.notebook.index], view.notebook:pageTemplate(), view.notebook.w, view.notebook.h)
            rec("tpl.save", now_us() - t)
            t = now_us(); view:nbAddFromTemplate("Bench"); paint(); rec("tpl.add_page", now_us() - t)
        end
    end
end

t0 = now_us(); view:onCloseWidget(); rec("close", now_us() - t0)
local jit_flushes, jit_traces = H.jit()
rec("jit.flushes", jit_flushes)
rec("jit.traces", jit_traces)

local f = assert(io.open(OUT, "a"))
for _, m in ipairs(order) do
    local t = samples[m]
    local parts = {}
    for i = 1, #t do parts[i] = string.format("%.3f", t[i]) end
    f:write(m, "\t", table.concat(parts, ","), "\n")
end
f:close()
os.execute("rm -rf '" .. TMP .. "'")
