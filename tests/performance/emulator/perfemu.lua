-- Latency with KOReader's real widgets in the SDL emulator, for either version
-- of the plugin: opening the canvas, strokes through the real repaint, every
-- sheet (build, paint, close), a notebook, and the library and overview where
-- the version has them. Writes perf.txt in the run's folder. Run by run.sh.
local H = ...
local ffi = require("ffi")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
pcall(ffi.cdef, "uint64_t clock_gettime_nsec_np(int clock_id);")
local function now_us() return tonumber(ffi.C.clock_gettime_nsec_np(8)) / 1000 end
local rows = {}
local function rec(m, us) rows[#rows + 1] = m .. "\t" .. string.format("%.1f", us) end
local view

local function top()
    local st = UIManager._window_stack
    return st[#st] and st[#st].widget
end
local function P(x, y) return { pos = Geom:new{ x = math.floor(x), y = math.floor(y) } } end
local function step(metric, fn)
    local t0 = now_us(); fn(); UIManager:forceRePaint(); rec(metric, now_us() - t0)
end
local function closeTop(w)
    if w.onCloseMenu then w:onCloseMenu() elseif w.close then w:close() else UIManager:close(w) end
    for k, val in pairs(view) do if val == w then view[k] = nil end end
end
local function sheet(name, open, n)
    for r = 1, n do
        local before = top()
        local t0 = now_us()
        local ok, err = pcall(open)
        local dt = now_us() - t0
        local w = top()
        if not ok or w == before or w == view then
            rec("sheet." .. name .. ".error", 1)
            if not ok then rows[#rows + 1] = "#err\t" .. name .. ": " .. tostring(err) end
            return
        end
        t0 = now_us(); UIManager:forceRePaint(); local paint = now_us() - t0
        rec("sheet." .. name .. (r == 1 and ".open_first" or ".open"), dt + paint)
        t0 = now_us(); closeTop(w); UIManager:forceRePaint(); rec("sheet." .. name .. ".close", now_us() - t0)
    end
end

-- Every present to the SDL window waits for the Mac's display refresh, which
-- rounds each timing up to a 60 Hz frame. On a reader that step is the e-ink
-- refresh, hardware time outside the plugin, so it is left out: widgets are
-- still built and painted into the framebuffer, just not shown in the window.
local Screen = require("device").screen
local real_render = Screen._render
Screen._render = function() end
rec("emu.present_skipped", 1)

H.step(0, function()
    local t = now_us()
    H.open()
    UIManager:forceRePaint()
    rec("open.canvas", now_us() - t)
end)

H.step(2, function()
    view = H.view()
    local NEW = view.saveDocument ~= nil
    rec("version.is_branch", NEW and 1 or 0)
    local v = view.view
    -- strokes through the real repaint path
    for k = 1, 6 do
        local y = v.area_y + 80 + k * (v.area_h - 160) / 7
        local x0, x1 = v.area_x + 30, v.area_x + v.area_w - 30
        step("pen.down", function() view:onIaTouch(nil, P(x0, y)) end)
        for i = 1, 80 do
            local u = i / 80
            step("pen.move", function() view:onIaPan(nil, P(x0 + (x1 - x0) * u, y + math.sin(u * 9) * 18)) end)
        end
        step("pen.lift", function() view:onIaPanRelease(nil, P(x1, y)) end)
        step("pen.commit", function() view:flushPending() end)
    end
    step("tool.switch", function() view:setTool("erase") end)
    step("tool.switch", function() view:setTool("pen") end)
    step("undo", function() view:undo() end)
    step("redo", function() view:redo() end)

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
    if NEW then
        SHEETS[#SHEETS + 1] = { "file", function() view:openDocumentSheet() end }
        SHEETS[#SHEETS + 1] = { "export", function() view:openExport() end }
        SHEETS[#SHEETS + 1] = { "newnotebook.paper", function() view:openNotebookPaper() end }
    else
        SHEETS[#SHEETS + 1] = { "save(main)", function() view:onSave() end }
    end
    for _, s in ipairs(SHEETS) do sheet(s[1], s[2], 5) end

    -- a notebook
    step("nb.start", function()
        if NEW then view:newNotebook("lines")
        else view:startNotebook({ style = "lines", size = view.nb_size or view.grid_size or 40,
            strength = view.nb_strength or view.grid_strength or 45 }) end
    end)
    v = view.view
    for k = 1, 3 do
        local y = v.area_y + 100 + k * 120
        step("nb.pen.down", function() view:onIaTouch(nil, P(v.area_x + 40, y)) end)
        for i = 1, 60 do
            step("nb.pen.move", function() view:onIaPan(nil, P(v.area_x + 40 + i * 9, y + math.sin(i / 6) * 12)) end)
        end
        step("nb.pen.lift", function() view:onIaPanRelease(nil, P(v.area_x + 580, y)) end)
        step("nb.pen.commit", function() view:flushPending() end)
    end
    for _ = 1, 3 do step("nb.addpage", function() view:nbAddPage() end) end
    for i = 1, 10 do step("nb.turn", function() view:nbGo((i % 2 == 0) and 1 or -1) end) end
    sheet("pagemenu", function() view:openPageMenu() end, 4)
    if NEW then sheet("overview", function() view:openOverview() end, 3)
    else sheet("pagegrid", function() view:openPageGrid() end, 3) end

    -- the library with a couple of dozen documents (new version only)
    if NEW then
        local Project = require("ink/project")
        view:saveDocument(true)
        local nb = view.notebook
        local lib = view:libraryDir()
        for i = 1, 20 do
            local p = lib .. string.format("/Doc %02d.%s", i, Project.EXT)
            if i % 3 == 0 then
                Project.save({ w = nb.w, h = nb.h, ops = nb.pages[1].ops }, p)
            else
                Project.saveNotebook({ w = nb.w, h = nb.h, template = nb.template,
                    pages = { { ops = nb.pages[1].ops, id = 1 }, { ops = nb.pages[1].ops, id = 2 } } }, p)
            end
        end
        sheet("library.cold", function() view:openLibrary() end, 1)
        sheet("library.warm", function() view:openLibrary() end, 4)
        sheet("overview.tabs", function() view:openOverview() end, 3)
        view:openOverview()
        local ov = view._overview
        local other
        for _, tab in ipairs(ov.tabs) do if not tab.folder and tab.path ~= view.doc_path then other = tab end end
        if other then
            step("overview.tab_switch", function() view:overviewShowTab(other.path) end)
            step("overview.tab_back", function() view:overviewShowTab(view.doc_path) end)
        end
        closeTop(ov); UIManager:forceRePaint()
    end
    local t = now_us(); if view.closeCanvas then view:closeCanvas() else UIManager:close(view) end; UIManager:forceRePaint(); rec("close", now_us() - t)
    Screen._render = real_render
    local f = io.open(H.out .. "/perf.txt", "w")
    f:write(table.concat(rows, "\n"), "\n")
    f:close()
    H.check(true, "perf written")
end)
