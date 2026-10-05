-- Refresh audit: for each user action, what reaches the e-ink panel (after
-- UIManager merges requests) and how long the repaint takes on the CPU. Run by
-- refresh.sh; works on versions before and after the library (features one
-- lacks are skipped).
-- Records, per action: refresh count, flashing ones (full / flashui /
-- flashpartial), screen share covered (sum over refreshes), and CPU ms of the
-- action plus its repaint. The window present is skipped (as in perfemu.lua).
-- Writes refresh.txt: action \t refreshes \t flashes \t area \t cpu_ms \t modes
local H = ...
local ffi = require("ffi")
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
pcall(ffi.cdef, "uint64_t clock_gettime_nsec_np(int clock_id);")
local function now() return tonumber(ffi.C.clock_gettime_nsec_np(8)) / 1000 end
local Screen = require("device").screen
local real_render = Screen._render
local SW, SH = Screen:getWidth(), Screen:getHeight()

local log = {}
local IMPS = { refreshFullImp = "full", refreshPartialImp = "partial", refreshNoMergePartialImp = "partial",
    refreshFlashPartialImp = "flashpartial", refreshUIImp = "ui", refreshNoMergeUIImp = "ui",
    refreshFlashUIImp = "flashui", refreshFastImp = "fast", refreshA2Imp = "a2" }
-- the emulator implements one refresh type by calling another (ui -> partial ->
-- full), so only the outermost call is the refresh UIManager asked for
local depth = 0
for name, mode in pairs(IMPS) do
    local orig = Screen[name]
    if orig then
        Screen[name] = function(self, x, y, w, h, d)
            if depth == 0 then
                log[#log + 1] = { mode = mode, area = ((w or SW) * (h or SH)) / (SW * SH) }
            end
            depth = depth + 1
            local r = orig(self, x, y, w, h, d)
            depth = depth - 1
            return r
        end
    end
end

local rows = {}
local v, NEW
-- run an action and settle it: its paint and refreshes
local function act(name, fn)
    log = {}
    local t = now()
    local ok, err = pcall(fn)
    UIManager:forceRePaint()
    local cpu = (now() - t) / 1000
    if not ok then rows[#rows + 1] = "#err\t" .. name .. "\t" .. tostring(err); return end
    local flashes, area, modes = 0, 0, {}
    for _, r in ipairs(log) do
        if r.mode == "full" or r.mode:find("^flash") then flashes = flashes + 1 end
        area = area + r.area
        modes[#modes + 1] = string.format("%s:%.2f", r.mode, r.area)
    end
    rows[#rows + 1] = string.format("%s\t%d\t%d\t%.2f\t%.2f\t%s", name, #log, flashes, area, cpu, table.concat(modes, " "))
end
local function P(x, y) return { pos = Geom:new{ x = math.floor(x), y = math.floor(y) } } end
local function closeTop()
    local st = UIManager._window_stack
    local w = st[#st] and st[#st].widget
    if w and w ~= v then
        if w.onCloseMenu then w:onCloseMenu() elseif w.close then w:close() else UIManager:close(w) end
        for k, val in pairs(v) do if val == w then v[k] = nil end end
    end
end
local function stroke(y)
    local view = v.view
    v:onIaTouch(nil, P(view.area_x + 40, view.area_y + y))
    for i = 1, 30 do v:onIaPan(nil, P(view.area_x + 40 + i * 12, view.area_y + y + math.sin(i / 4) * 10)) end
    v:onIaPanRelease(nil, P(view.area_x + 400, view.area_y + y))
    v:flushPending()
end

H.step(0, function() H.open() end)
H.step(2.5, function()
    v = H.view()
    NEW = v.saveDocument ~= nil
    Screen._render = function() end
    UIManager:forceRePaint()
    for k = 1, 4 do stroke(80 + k * 90) end
    UIManager:forceRePaint()

    -- the canvas and its toolbar
    local function tb(id)
        for _, t in ipairs(v._toolbar_icons) do if t.id == id then return t.button end end
    end
    act("tool: tap Eraser", function() tb("erase").callback() end)
    act("tool: back to Pen", function() tb("pen").callback() end)
    act("undo", function() v:undo() end)
    act("redo", function() v:redo() end)

    -- sheets
    act("pen sheet: open", function() v:openPenSettings() end)
    act("pen sheet: flip a switch", function()
        local function find(w, seen)
            seen = seen or {}
            if type(w) ~= "table" or seen[w] then return nil end
            seen[w] = true
            if w.is_on ~= nil and w.onTap then return w end
            for k, x in pairs(w) do if k ~= "parent" and k ~= "show_parent" then
                local f = find(x, seen); if f then return f end end end
        end
        local t = find(v._pen_dialog); if t then t:onTap() end
    end)
    act("pen sheet: pick a brush (rebuild)", function() v.pen_style = "hatch"; v:openPenSettings() end)
    v.pen_style = nil
    act("pen sheet: close", function() v:closeSheet("_pen_dialog") end)
    act("settings: open", function() v:openSettings() end)
    act("settings: pick Symmetry (rebuild)", function() v.symmetry = "vert"; v:openSettings() end)
    v.symmetry = "off"
    if NEW and v:colorScreen() then
        act("settings: tap a theme colour (rebuild)", function() v:setAccent({ 0x24, 0x57, 0xD6 }); v:openSettings() end)
        act("settings: back to black (rebuild)", function() v:setAccent(nil); v:openSettings() end)
    end
    act("settings: close", function() v:closeSheet("_settings_dialog") end)
    act("shapes sheet: open", function() v:openShapePicker() end)
    act("shapes sheet: close", function() v:closeSheet("_shape_dialog") end)
    if NEW then
        act("File sheet: open", function() v:openDocumentSheet() end)
        act("File sheet: close", function() v:closeSheet("_doc_dialog") end)
        act("Export sheet: open", function() v:openExport() end)
        act("Export sheet: close", function() v:closeSheet("_save_dialog") end)
    else
        act("Save sheet: open", function() v:onSave() end)
        act("Save sheet: close", function() closeTop() end)
    end

    -- a notebook
    if NEW then act("notebook: start", function() v:newNotebook("lines") end)
    else act("notebook: start", function() v:startNotebook({ style = "lines", size = v.nb_size or 40, strength = 45 }) end) end
    for k = 1, 3 do stroke(80 + k * 120) end
    UIManager:forceRePaint()
    act("notebook: add page", function() v:nbAddPage() end)
    stroke(150); UIManager:forceRePaint()
    for i = 1, 3 do act("notebook: page turn", function() v:nbGo((i % 2 == 1) and -1 or 1) end) end
    act("page menu: open", function() v:openPageMenu() end)
    act("page menu: close", function() closeTop() end)
    for _ = 1, 10 do v:nbAddPage() end
    UIManager:forceRePaint()

    -- the page thumbnails (page grid on main, overview here)
    if NEW then act("pages view: open", function() v:openOverview() end)
    else act("pages view: open", function() v:openPageGrid() end) end
    local grid = v._overview or (function()
        local st = UIManager._window_stack; return st[#st].widget end)()
    act("pages view: next page of thumbnails", function() grid:gridGo(1) end)
    act("pages view: previous page", function() grid:gridGo(-1) end)
    if NEW then
        act("overview: Star filter", function() v:overviewToggleStarred() end)
        act("overview: Star filter off", function() v:overviewToggleStarred() end)
    end
    act("pages view: close", function() if grid.close then grid:close() else UIManager:close(grid) end end)
    for i = 1, 2 do
        if NEW then act("pages view: open again", function() v:openOverview() end)
        else act("pages view: open again", function() v:openPageGrid() end) end
        local g = v._overview or (function() local st = UIManager._window_stack; return st[#st].widget end)()
        act("pages view: close again", function() if g.close then g:close() else UIManager:close(g) end end)
    end

    -- this branch: the library, the overview's tabs and folders, new notebook
    if NEW then
        local Project = require("ink/project")
        local lib = v:libraryDir()
        os.execute("mkdir -p '" .. lib .. "/School'")
        local nb = v.notebook
        for i = 1, 14 do
            Project.saveNotebook({ w = nb.w, h = nb.h, template = nb.template,
                pages = { { ops = nb.pages[1].ops, id = 1 } } }, lib .. string.format("/Doc %02d.inkaway", i))
        end
        v:saveDocument(true)
        act("library: open (toolbar)", function() v:openLibrary() end)
        local L = v._library
        act("library: next page", function() L:gridGo(1) end)
        act("library: previous page", function() L:gridGo(-1) end)
        act("library: into a folder", function() v:libraryGo(lib .. "/School") end)
        act("library: back up", function() v:libraryGo(lib) end)
        act("library: close", function() L:close() end)
        act("library: open again", function() v:openLibrary() end)
        local item
        for _, it in ipairs(v._library.items) do if not it.folder and it.path ~= v.doc_path then item = it end end
        act("library: tap a document (opens it)", function() v:libraryPick(item) end)
        act("overview: open", function() v:openOverview() end)
        local ov = v._overview
        local other
        for _, t in ipairs(ov.tabs) do if not t.folder and t.path ~= v.doc_path then other = t end end
        act("overview: tap another tab", function() v:overviewShowTab(other.path) end)
        act("overview: tap a folder tab", function() v:overviewGo(lib .. "/School") end)
        act("overview: back arrow", function() v:overviewGo(lib) end)
        act("overview: Library button", function() ov.actions[2][2]() end)
        act("library: close", function() v._library:close() end)
        act("new notebook: paper sheet open", function() v:openNotebookPaper() end)
        act("new notebook: tap a paper", function() v:closeSheet("_new_dialog"); v:newNotebook("grid") end)
    end
    Screen._render = real_render
    local f = io.open(H.out .. "/refresh.txt", "w")
    f:write(table.concat(rows, "\n"), "\n")
    f:close()
    H.check(true, "audit written")
    if v.closeCanvas then v:closeCanvas() else UIManager:close(v) end
end)
