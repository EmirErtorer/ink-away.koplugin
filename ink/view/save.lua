--[[
Saving: the Save sheet, choosing an export area, PNG and JPEG files, bookshelf
ornaments, and exporting a notebook to PDF.
Part of InkAwayView (see ink/view.lua).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Export = require("ink/export")
local ImageProc = require("ink/imageproc")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local PAPERS = Palette.PAPERS
local existingDir = Storage.existingDir
local strengthToLevel = Paint.strengthToLevel
local bbToRGBA = ImageProc.bbToRGBA

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

------------------------------------------------------------------------------
-- Export area selection: drag a rectangle to export just part of the page.
------------------------------------------------------------------------------

function InkAwayView:cropTouch(pos)
    self._crop_screen = { x0 = pos.x, y0 = pos.y, x1 = pos.x, y1 = pos.y }
    self:refreshArea()
    return true
end

function InkAwayView:cropMove(pos)
    if not (pos and self._crop_screen) then return true end
    local c = self._crop_screen
    local ox0, oy0, ox1, oy1 = c.x0, c.y0, c.x1, c.y1   -- previous box
    c.x1, c.y1 = pos.x, pos.y
    -- refresh only the union of the old and new selection boxes, and use a fast
    -- (non-flashing) refresh so dragging stays smooth instead of queueing full
    -- grayscale updates
    self:refreshAreaBox("fast", math.min(ox0, ox1, c.x0, c.x1) - 3, math.min(oy0, oy1, c.y0, c.y1) - 3,
        math.max(ox0, ox1, c.x0, c.x1) + 3, math.max(oy0, oy1, c.y0, c.y1) + 3)
    return true
end

function InkAwayView:cropRelease(pos)
    if pos and self._crop_screen then self._crop_screen.x1, self._crop_screen.y1 = pos.x, pos.y end
    self.selecting_crop = false
    local c = self._crop_screen
    self._crop_screen = nil
    if c then
        local ax0, ay0 = self:toCanvasClamped(c.x0, c.y0)
        local ax1, ay1 = self:toCanvasClamped(c.x1, c.y1)
        local x0, x1 = math.min(ax0, ax1), math.max(ax0, ax1)
        local y0, y1 = math.min(ay0, ay1), math.max(ay0, ay1)
        local w, h = math.floor(x1 - x0), math.floor(y1 - y0)
        self.save_area = (w >= 8 and h >= 8)
            and { x = math.floor(x0), y = math.floor(y0), w = w, h = h } or nil
    end
    self:refresh(self, "full")
    self:onSave()   -- return to the save dialog with the area now chosen
    return true
end

------------------------------------------------------------------------------
-- Save workflow: format -> destination folder -> filename -> encode
------------------------------------------------------------------------------

-- One compact dialog for the whole save: pick the format, optionally the area,
-- and (when a background is loaded) whether to include it, then Save. The rows
-- are toggles so it never turns into a wizard.
function InkAwayView:onSave()
    self:flushPending()
    if self.active_image then self:finishImageEdit() end   -- bake it so the export includes it
    if self.notebook then return self:exportNotebookPDF() end
    if self.canvas:isEmpty() and not self.bg_bb then
        UIManager:show(InfoMessage:new{ text = _("The canvas is empty."), timeout = 2 })
        return
    end
    self.save_fmt = self.save_fmt or "png"
    self:closeSheet("_save_dialog")
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_save_dialog") end
    local area_label = self.save_area
        and string.format(_("Area: %d\u{00D7}%d (tap for whole page)"), self.save_area.w, self.save_area.h)
        or _("Area: whole page (tap to choose)")
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Save drawing"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:sheetLabel(_("Format"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "png", _("PNG (transparent)") }, { "jpg", _("JPEG (white)") } },
            self.save_fmt, content_w, function(v) self.save_fmt = v; self:onSave() end))
        add(vspan(12))
        add(self:actionButton(area_label, content_w, function()
            if self.save_area then self.save_area = nil; self:onSave()
            else closeSelf(); self:beginCropSelect() end
        end))
        if self.bg_bb then
            add(vspan(12))
            add(ToggleRow:new{ label = _("Include background"), is_on = self.export_bg,
                width = content_w, parent = menu,
                callback = function(on) self.export_bg = on end })
        end
        add(vspan(16))
        add(self:actionButton(_("Save"), content_w, function()
            closeSelf(); self:chooseDestination(self.save_fmt) end, true))
        -- One-tap save straight into the bookshelf plugin's ornament folder, only
        -- when that plugin is in use. Always a transparent PNG (an ornament needs
        -- its transparency), so it ignores the format toggle above.
        if self:ornamentsDir() then
            add(vspan(10))
            add(self:actionButton(_("Save as bookshelf ornament"), content_w, function()
                closeSelf(); self:saveOrnament() end))
        end
        return content
    end
    self:showSheet("_save_dialog", build)
end

-- Enter the area-selection mode: the next drag marks the export rectangle.
function InkAwayView:beginCropSelect()
    self.selecting_crop = true
    self._crop_screen = nil
    UIManager:show(InfoMessage:new{
        text = _("Drag a box around the part to export. A single tap keeps the whole page."), timeout = 3 })
    self:refreshArea()
end

-- The notebook page indices chosen by the current export scope: all pages,
-- only pages that have ink, or a page range.
function InkAwayView:selectedNotebookPages()
    local nb = self.notebook
    local sel = {}
    if self.nb_scope == "ink" then
        for i = 1, nb:count() do
            if nb.pages[i].ops and #nb.pages[i].ops > 0 then sel[#sel + 1] = i end
        end
    elseif self.nb_scope == "range" and self.nb_range then
        local a = math.max(1, math.min(nb:count(), self.nb_range.from or 1))
        local b = math.max(a, math.min(nb:count(), self.nb_range.to or nb:count()))
        for i = a, b do sel[#sel + 1] = i end
    else
        for i = 1, nb:count() do sel[#sel + 1] = i end
    end
    return sel
end

-- Export the notebook to a single PDF, with paper colour, page-scope, page
-- numbers and (for imported PDFs) a sharp-text option, then offer to open it.
function InkAwayView:exportNotebookPDF()
    self:nbSyncOut()
    local nb = self.notebook
    local is_pdf = nb.template and nb.template.pdf_path
    self.nb_paper = self.nb_paper or "white"
    self.nb_scope = self.nb_scope or "all"
    self:closeSheet("_save_dialog")
    local content_w = self:sheetWidth()
    local SCOPE_LABEL = { all = _("All pages"), ink = _("Pages with ink"), range = _("Range") }
    local closeSelf = function() self:closeSheet("_save_dialog") end
    local reopen = function() self:exportNotebookPDF() end   -- rebuild after a choice changes the layout
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Export notebook"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:sheetLabel(_("Paper"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "white", _("White") }, { "sand", _("Sandpaper") } },
            self.nb_paper, content_w, function(v) self.nb_paper = v; reopen() end))
        if self.bg_bb and not is_pdf then   -- an imported PDF always prints its own pages
            add(vspan(12))
            add(ToggleRow:new{ label = _("Include background"), is_on = self.export_bg,
                width = content_w, parent = menu, callback = function(on) self.export_bg = on end })
        end
        add(vspan(12))
        add(self:sheetLabel(_("Pages"), true))
        add(vspan(6))
        add(self:actionButton(_("Pages: ") .. (SCOPE_LABEL[self.nb_scope] or SCOPE_LABEL.all), content_w, function()
            self.nb_scope = (self.nb_scope == "all" and "ink") or (self.nb_scope == "ink" and "range") or "all"
            if self.nb_scope == "range" and not self.nb_range then self.nb_range = { from = 1, to = nb:count() } end
            reopen()
        end))
        if self.nb_scope == "range" then
            add(vspan(8))
            add(self:actionButton(string.format(_("Range: %d\u{2013}%d (tap to set)"),
                (self.nb_range and self.nb_range.from) or 1, (self.nb_range and self.nb_range.to) or nb:count()),
                content_w, function() closeSelf(); self:promptExportRange() end))
        end
        add(vspan(12))
        add(ToggleRow:new{ label = _("Page numbers"), is_on = self.nb_numbers and true or false,
            width = content_w, parent = menu, callback = function(on) self.nb_numbers = on end })
        add(vspan(16))
        local n = #self:selectedNotebookPages()
        add(self:actionButton(string.format(_("Export %d page(s) to PDF"), n), content_w, function()
            if n > 0 then closeSelf(); self:chooseNotebookDestination() end
        end, true))
        return content
    end
    self:showSheet("_save_dialog", build)
end

-- Ask for the first and last page of the export range.
function InkAwayView:promptExportRange()
    local nb = self.notebook
    self:promptText{
        title = string.format(_("Page range (1\u{2013}%d), e.g. 3-8"), nb:count()),
        input = string.format("%d-%d", self.nb_range.from or 1, self.nb_range.to or nb:count()),
        ok_text = _("Set"),
        on_ok = function(text)
            local s = text or ""
            local a, b = s:match("(%d+)%s*[%-\u{2013}to,%s]+(%d+)")
            if not a then a = s:match("(%d+)"); b = a end
            if a then self.nb_range = { from = tonumber(a), to = tonumber(b) } end
            self:exportNotebookPDF()
        end,
        on_cancel = function() self:exportNotebookPDF() end,
    }
end

function InkAwayView:chooseNotebookDestination()
    local start = existingDir(self:getSetting("inkaway_last_notebook_dir"))
        or self.notebooks_dir or self.default_dir or "/"
    self:pickFolder(start, function(dir)
        self:setSetting("inkaway_last_notebook_dir", dir)
        self:promptNotebookFilename(dir)
    end)
end

function InkAwayView:promptNotebookFilename(dir)
    local name = os.date("notebook-%Y%m%d-%H%M%S")
    self:promptText{ title = _("PDF name"), input = name, default = name, ok_text = _("Export"),
        on_ok = function(text)
            self:doNotebookExport(Storage.join(dir, Storage.fileName(text, "pdf")))
        end }
end

function InkAwayView:doNotebookExport(path)
    local nb = self.notebook
    self:nbSyncOut()
    -- copy the template so the export tint/strength never sticks to the working
    -- notebook, and bake the ruling grey from the paper strength
    local template = {}
    for k, v in pairs(nb.template) do template[k] = v end
    template.paper = PAPERS[self.nb_paper or "white"] or PAPERS.white
    template.gray = strengthToLevel(template.strength)
    local tmp_dir = Storage.settingsDir()

    -- resolve the export scope to a concrete list of notebook pages
    local sel = self:selectedNotebookPages()
    if #sel == 0 then
        UIManager:show(InfoMessage:new{ text = _("No pages match the chosen range."), timeout = 3 })
        return
    end
    local pages_ops = {}
    for j = 1, #sel do pages_ops[j] = nb.pages[sel[j]].ops end

    local is_pdf = template.pdf_path
    local scale = 1
    local quality = is_pdf and 90 or 85

    -- background per selected page: a PDF-backed notebook renders each source
    -- page on the fly at the export resolution (one at a time, so memory stays
    -- flat); otherwise a single loaded picture is shared by every page.
    local bg
    if is_pdf then
        self:ensureNotebookPDF()
        local doc = self._nb_pdf_doc
        bg = function(j, s)
            s = s or 1
            local src = nb.pages[sel[j]] and nb.pages[sel[j]].src
            local img = src and self:renderPdfPage(doc, src, nb.w * s, nb.h * s) or nil
            if not img then return nil end
            local rgba = bbToRGBA(img, nb.w * s, nb.h * s)
            img:free()
            return rgba
        end
    elseif self.export_bg and self.bg_bb then
        bg = self.bg_rgba or self:buildBgRGBA()
    end

    -- Export one page per UI step, with a progress bar and a way to stop. Doing it
    -- in one go froze the reader for minutes on a long imported PDF and built the
    -- whole file in memory, which could crash it; the job streams each page to
    -- disk and frees it before the next.
    local job, jerr = Export.notebookPDFJob(pages_ops, nb.w, nb.h, template, path, quality, tmp_dir, bg,
        { footer = self.nb_numbers and true or nil, scale = scale,
          bg_opaque = is_pdf and true or nil })   -- rendered PDF pages are drawn on white
    if not job then
        UIManager:show(InfoMessage:new{ text = _("Could not export PDF.\n") .. tostring(jerr) })
        return
    end
    self._export_job = job
    local progress
    local pok, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if pok and ProgressbarDialog then
        progress = ProgressbarDialog:new{
            title = string.format(_("Exporting %d page(s) to PDF"), #sel),
            subtitle = _("Tap to stop"),
            progress_max = #sel,
            refresh_time_seconds = 1,
            dismissable = true,
            dismiss_text = _("Stop exporting? The PDF will not be saved."),
            dismiss_callback = function()   -- closed by the reader (stop), not by us
                if self._export_job == job and not job.over then
                    job.cancel()
                    self._export_job = nil
                    UIManager:show(InfoMessage:new{ text = _("Export stopped."), timeout = 2 })
                end
            end,
        }
        progress:show()
    else
        progress = InfoMessage:new{ text = string.format(_("Exporting %d page(s)\u{2026}"), #sel) }
        UIManager:show(progress)
    end
    local function closeProgress()
        if progress then
            local p = progress
            progress = nil
            if p.close then p:close() else UIManager:close(p) end
        end
    end
    local function finished()
        self._export_job = nil
        closeProgress()
        -- Also keep the editable notebook: save a project with the same name in
        -- the projects folder, so closing right after exporting never loses the
        -- work (people export the PDF and may not think to also "Save project").
        local proj_saved = self:autoSaveNotebookProject(path)
        -- make the PDF open as a full page with no auto-crop the first time
        self:seedPdfView(path)
        local msg = string.format(_("Notebook exported:\n%s"), path)
        if proj_saved then msg = msg .. string.format(_("\n\nEditable copy kept in:\n%s"), proj_saved) end
        UIManager:show(ConfirmBox:new{
            text = msg .. _("\n\nOpen the PDF now?"),
            ok_text = _("Open"),
            ok_callback = function() self:openExportedPDF(path) end,
        })
    end
    local step
    step = function()
        if self._export_job ~= job or job.over and job.i < job.n then return end   -- stopped
        local ok, state, a = pcall(job.step)
        if not ok or not state then
            job.cancel()
            self._export_job = nil
            closeProgress()
            UIManager:show(InfoMessage:new{ text = _("Could not export PDF.\n") .. tostring(ok and a or state) })
            return
        end
        if state == "done" then
            if progress and progress.reportProgress then pcall(progress.reportProgress, progress, #sel) end
            finished()
            return
        end
        if progress and progress.reportProgress then pcall(progress.reportProgress, progress, a) end
        UIManager:scheduleIn(0.05, step)   -- let the screen update and taps through
    end
    UIManager:scheduleIn(0.2, step)        -- let the progress bar paint first
end

-- Save the current notebook as an editable .inkaway project in the notebook
-- projects folder, using the PDF's base name. Returns the path or nil.
function InkAwayView:autoSaveNotebookProject(pdf_path)
    if not self.notebook then return nil end
    local base = pdf_path:match("([^/\\]+)%.[Pp][Dd][Ff]$") or pdf_path:match("([^/\\]+)$") or "notebook"
    local dir = self.nproj_dir or self.default_dir
    if not dir then return nil end
    local proj = Storage.join(dir, base .. "." .. Project.EXT)
    self:nbSyncOut()
    local ok = Project.saveNotebook(self.notebook, proj)
    return ok and proj or nil
end

-- Pre-seed a freshly exported PDF's sidecar so KOReader opens it as a whole
-- page with no margin auto-crop (its defaults are page-width + auto-crop, which
-- would zoom into the ink and clip it). Best effort; harmless if it fails.
function InkAwayView:seedPdfView(path)
    local dok, DocSettings = pcall(require, "docsettings")
    if not (dok and DocSettings) then return end
    pcall(function()
        local ds = DocSettings:open(path)
        if not ds then return end
        ds:saveSetting("kopt_trim_page", 3)         -- 3 = "none": no margin cropping at all
        ds:saveSetting("kopt_zoom_mode_genus", 4)   -- 4 = "page"
        ds:saveSetting("kopt_zoom_mode_type", 2)    -- 2 = full (not width/height)
        ds:flush()
    end)
end

-- Hand a freshly exported PDF to KOReader's reader, closing the plugin view.
function InkAwayView:openExportedPDF(path)
    local rok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not (rok and ReaderUI) then
        UIManager:show(InfoMessage:new{ text = _("Saved. Open it from your library."), timeout = 3 })
        return
    end
    self.closing = true
    self:saveSession()
    UIManager:close(self)
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
end

function InkAwayView:chooseDestination(fmt)
    self:pickFolder(self:defaultDir(), function(dir)
        self:rememberDir(dir)
        self:promptFilename(fmt, dir)
    end)
end

function InkAwayView:promptFilename(fmt, dir)
    local ext = (fmt == "png") and "png" or "jpg"
    local default_name = os.date("ink-%Y%m%d-%H%M%S")
    self:promptText{
        title = _("File name"), input = default_name, hint = default_name, default = default_name,
        description = string.format(_("Saving to:\n%s\n\nExtension .%s will be added."), dir, ext),
        ok_text = _("Save"),
        on_ok = function(name) self:writeFile(fmt, dir, name, ext) end,
    }
end

function InkAwayView:writeFile(fmt, dir, name, ext)
    name = Storage.fileName(name, ext)
    local path = Storage.join(dir, name)

    local opts = {
        rect = self.save_area,
        bg = (self.export_bg and self.bg_rgba) or nil,
    }
    local ok, err
    if fmt == "png" then
        ok, err = Export.savePNG(self.canvas, path, opts)
    else
        ok, err = Export.saveJPEG(self.canvas, path, 90, opts)
    end

    local ow = self.save_area and self.save_area.w or self.canvas.w
    local oh = self.save_area and self.save_area.h or self.canvas.h
    if ok then
        -- also keep an editable project of the same name, so people who never
        -- find the "Save project" button can still come back to this drawing
        local proj = self:autoSaveDrawingProject(name)
        local msg = string.format(_("Saved %d × %d image:\n%s"), ow, oh, path)
        if proj then msg = msg .. string.format(_("\n\nEditable copy kept in:\n%s"), proj) end
        UIManager:show(InfoMessage:new{ text = msg })
    else
        logger.warn("InkAway: save failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not save the image.\n%s"), tostring(err)),
            icon = "notice-warning",
        })
    end
end

-- Is the bookshelf plugin present? Prefer KOReader's loaded-plugin registry (so
-- it is found wherever it is installed), then fall back to a directory probe next
-- to this plugin and in the user plugins folder. Cached for the session.
function InkAwayView:bookshelfInstalled()
    if self._bookshelf_seen ~= nil then return self._bookshelf_seen end
    local seen = false
    pcall(function()
        local PluginLoader = require("pluginloader")
        local groups = { PluginLoader.enabled_plugins }
        for _, group in ipairs(groups) do
            if type(group) == "table" then
                for _, p in ipairs(group) do
                    local path = type(p) == "table" and p.path
                    if type(path) == "string" and path:lower():find("bookshelf%.koplugin") then
                        seen = true; return
                    end
                end
            end
        end
    end)
    if not seen then
        local cand = { self:pluginDir() .. "../bookshelf.koplugin" }
        local data = Storage.dataDir()
        if data then cand[#cand + 1] = data .. "/plugins/bookshelf.koplugin" end
        for _, d in ipairs(cand) do
            if Storage.isDir(d) then seen = true; break end
        end
    end
    self._bookshelf_seen = seen
    return seen
end

-- The bookshelf plugin's ornament folder (koreader/icons/bookshelf.ornaments),
-- or nil when the bookshelf plugin isn't in use. A saved ornament is just a
-- transparent PNG dropped in here -- the bookshelf plugin picks up any *.png or
-- *.svg it finds. KOReader never creates icons/ itself, so callers make the tree.
-- "In use" means the folder already exists (the user keeps ornaments there) or
-- the bookshelf plugin is installed, so the option also shows before the first
-- ornament is saved.
function InkAwayView:ornamentsDir()
    local data = Storage.dataDir()
    if not data then return nil end
    local dir = data .. "/icons/bookshelf.ornaments"
    if Storage.isDir(dir) or self:bookshelfInstalled() then return dir end
    return nil
end

-- Save the canvas straight into the bookshelf ornament folder as a transparent
-- PNG. The destination is fixed, so this skips the folder chooser and only asks
-- for a name; it makes icons/ and the ornaments folder if they aren't there yet.
function InkAwayView:saveOrnament()
    local dir = self:ornamentsDir()
    if not dir then return end
    Storage.ensureDir(dir:match("^(.*)/"))   -- icons/
    if not Storage.ensureDir(dir) then
        UIManager:show(InfoMessage:new{
            text = _("Could not create the bookshelf ornaments folder."),
            icon = "notice-warning" })
        return
    end
    self:promptOrnamentName(dir)
end

-- Ask for an ornament name, then write it. A trailing ".invert" is kept (the
-- bookshelf plugin reads name.invert.png as the dark-mode variant); the ".png"
-- extension is added when the name doesn't already end in it.
function InkAwayView:promptOrnamentName(dir)
    local default_name = os.date("ornament-%Y%m%d-%H%M%S")
    self:promptText{
        title = _("Ornament name"), input = default_name, hint = default_name, default = default_name,
        description = _("Saved as a transparent PNG in the bookshelf ornaments folder.\nEnd the name with .invert for a dark-mode version."),
        ok_text = _("Save"),
        on_ok = function(name) self:writeOrnament(dir, name) end,
    }
end

function InkAwayView:writeOrnament(dir, name)
    local path = Storage.join(dir, Storage.fileName(name, "png"))
    local opts = { rect = self.save_area, bg = (self.export_bg and self.bg_rgba) or nil }
    local ok, err = Export.savePNG(self.canvas, path, opts)
    if ok then
        UIManager:show(InfoMessage:new{ text = string.format(_("Saved bookshelf ornament:\n%s"), path) })
    else
        logger.warn("InkAway: ornament save failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not save the ornament.\n%s"), tostring(err)),
            icon = "notice-warning" })
    end
end

-- Save the current canvas as an editable .inkaway project in the drawing
-- projects folder, using the image's base name. Returns the path or nil (and
-- skips a blank canvas, since there is nothing to come back to).
function InkAwayView:autoSaveDrawingProject(image_name)
    if self.canvas:isEmpty() then return nil end
    local base = image_name:gsub("%.[^.]+$", "")
    if base == "" then base = "ink" end
    local dir = self.dproj_dir or self.default_dir
    if not dir then return nil end
    local proj = Storage.join(dir, base .. "." .. Project.EXT)
    local ok = Project.save(self.canvas, proj)
    return ok and proj or nil
end

return InkAwayView
