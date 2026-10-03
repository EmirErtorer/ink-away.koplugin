--[[
Exporting: one sheet for drawings and notebooks, a PNG of the page (or a part
of it) or a PDF of some or all pages, then a file name in the export folder.
Titled pages become the PDF's bookmarks. Also a whole folder as one PDF, and
bookshelf ornaments.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local RenderImage = require("ui/renderimage")
local Export = require("ink/export")
local Folder = require("ink/folder")
local ImageProc = require("ink/imageproc")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
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
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

------------------------------------------------------------------------------
-- Export area: drag a rectangle to export just part of the page
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
    -- refresh only the union of the old and new boxes, with the fast waveform,
    -- so dragging stays smooth
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
    self:openExport()   -- back to the export sheet with the area now chosen
    return true
end

------------------------------------------------------------------------------
-- The export sheet
------------------------------------------------------------------------------

-- The open document's export settings, kept in its file: format, pages, paper,
-- whether the background or paper and page numbers are included, and the last
-- name (and folder, when one was picked) it was exported under.
function InkAwayView:exportOptions()
    if not self.export_opts then
        local nb = self.notebook
        self.export_opts = { fmt = nb and "pdf" or "png", scope = "all", transparent = not nb,
            include_bg = true, paper = "white", numbers = false }
    end
    return self.export_opts
end

-- The folder exports go to: the one picked for this document, else the export
-- folder from the settings, else "ink away/exports".
function InkAwayView:exportDir()
    local o = self:exportOptions()
    return existingDir(o.dir) or self:defaultExportDir()
end

function InkAwayView:defaultExportDir()
    local chosen = self:getSetting("inkaway_export_dir")
    if chosen and Storage.isDir(chosen) then return chosen end
    return Storage.appDir("exports") or self:libraryDir()
end

-- The notebook page indices the export covers: the page shown, all pages, only
-- pages that have ink, or a page range.
function InkAwayView:selectedNotebookPages()
    local nb = self.notebook
    local o = self:exportOptions()
    local sel = {}
    if o.scope == "page" then
        sel[1] = nb.index
    elseif o.scope == "ink" then
        for i = 1, nb:count() do
            if nb.pages[i].ops and #nb.pages[i].ops > 0 then sel[#sel + 1] = i end
        end
    elseif o.scope == "range" and o.range then
        local a = math.max(1, math.min(nb:count(), o.range.from or 1))
        local b = math.max(a, math.min(nb:count(), o.range.to or nb:count()))
        for i = a, b do sel[#sel + 1] = i end
    else
        for i = 1, nb:count() do sel[#sel + 1] = i end
    end
    return sel
end

-- One sheet for every export: PNG or PDF, then what goes in it, then Export.
-- A PNG holds the page shown (or the area chosen on it); a notebook's PDF can
-- hold that page, all of them, the ones with ink, or a range.
function InkAwayView:openExport()
    self:flushPending()
    if self.active_image then self:finishImageEdit() end   -- bake it so the export includes it
    if self.notebook then self:nbSyncOut() end
    if not self:docHasContent() then
        UIManager:show(InfoMessage:new{ text = _("There is nothing to export yet."), timeout = 2 })
        return
    end
    local o = self:exportOptions()
    local nb = self.notebook
    local is_pdf_nb = nb and nb.template.pdf_path
    self:closeSheet("_save_dialog")
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_save_dialog") end
    local reopen = function() self:openExport() end   -- rebuild after a choice changes the layout
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function toggle(label, key)
            add(vspan(10))
            add(ToggleRow:new{ label = label, is_on = o[key] and true or false, width = content_w, parent = menu,
                callback = function(on) o[key] = on end })
        end
        add(self:sheetTitle(_("Export"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:sheetLabel(_("Format"), true))
        add(vspan(6))
        add(self:segmentedRow({ { "png", _("PNG image") }, { "pdf", _("PDF") } }, o.fmt, content_w,
            function(v) o.fmt = v; reopen() end))
        if o.fmt == "pdf" and nb then
            add(vspan(12))
            add(self:sheetLabel(_("Pages"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "page", _("This page") }, { "all", _("All") }, { "ink", _("With ink") },
                    { "range", _("Range") } }, o.scope, content_w,
                function(v)
                    o.scope = v
                    if v == "range" and not o.range then o.range = { from = 1, to = nb:count() } end
                    reopen()
                end))
            if o.scope == "range" then
                add(vspan(8))
                add(self:actionButton(string.format(_("Pages %d\u{2013}%d (tap to change)"),
                    o.range.from or 1, o.range.to or nb:count()), content_w,
                    function() closeSelf(); self:promptExportRange() end))
            end
        end
        if o.fmt == "png" then
            add(vspan(12))
            local area = self.save_area
                and string.format(_("Area: %d\u{00D7}%d (tap for the whole page)"), self.save_area.w, self.save_area.h)
                or _("Area: the whole page (tap to choose)")
            add(self:actionButton(area, content_w, function()
                if self.save_area then self.save_area = nil; reopen()
                else closeSelf(); self:beginCropSelect() end
            end))
            if nb and nb:count() > 1 then
                add(vspan(4))
                add(self:sheetHint(string.format(_("A PNG holds the page shown, page %d."), nb.index), content_w))
            end
        else
            add(vspan(12))
            add(self:sheetLabel(_("Paper"), true))
            add(vspan(6))
            add(self:segmentedRow({ { "white", _("White") }, { "sand", _("Sandpaper") } }, o.paper, content_w,
                function(v) o.paper = v; reopen() end))
        end
        if nb then
            -- an imported PDF always prints its own pages into a PDF
            if not (is_pdf_nb and o.fmt == "pdf") then
                toggle(is_pdf_nb and _("Include the PDF page") or _("Include the paper"), "include_bg")
            end
        elseif self.bg_bb then
            toggle(_("Include the background"), "include_bg")
        end
        if o.fmt == "png" then toggle(_("Transparent"), "transparent") end
        if o.fmt == "pdf" then toggle(_("Page numbers"), "numbers") end
        add(vspan(16))
        local label = _("Export PNG")
        if o.fmt == "pdf" then
            label = nb and string.format(_("Export %d page(s) to PDF"), #self:selectedNotebookPages())
                or _("Export PDF")
        end
        add(self:actionButton(label, content_w, function()
            if o.fmt == "pdf" and nb and #self:selectedNotebookPages() == 0 then
                UIManager:show(InfoMessage:new{ text = _("No pages match the chosen range."), timeout = 3 })
                return
            end
            closeSelf(); self:promptExportName()
        end, true))
        -- save straight into the bookshelf plugin's ornament folder, when that
        -- plugin is in use; always a transparent PNG
        if o.fmt == "png" and self:ornamentsDir() then
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

-- Ask for the first and last page of the export range.
function InkAwayView:promptExportRange()
    local nb = self.notebook
    local o = self:exportOptions()
    self:promptText{
        title = string.format(_("Page range (1\u{2013}%d), e.g. 3-8"), nb:count()),
        input = string.format("%d-%d", o.range.from or 1, o.range.to or nb:count()),
        ok_text = _("Set"),
        on_ok = function(text)
            local s = text or ""
            local a, b = s:match("(%d+)%s*[%-\u{2013}to,%s]+(%d+)")
            if not a then a = s:match("(%d+)"); b = a end
            if a then o.range = { from = tonumber(a), to = tonumber(b) } end
            self:openExport()
        end,
        on_cancel = function() self:openExport() end,
    }
end

-- Ask for an export file name in folder o.dir, with a Folder button to pick
-- another, then call o.on_path(path) once writing there is fine (asking first
-- if it would replace a file). `o` holds title, name, default, dir, ext, and
-- on_dir(dir) for a folder picked on the way.
function InkAwayView:askExportPath(o)
    self:promptText{
        title = o.title, input = o.name, default = o.default,
        description = string.format(_("Into %s"), Storage.shortPath(o.dir)),
        ok_text = _("Export"),
        extra = { text = _("Folder\u{2026}"), callback = function(text)
            self:pickFolder(o.dir, function(d)
                if o.on_dir then o.on_dir(d) end
                o.dir, o.name = d, text
                self:askExportPath(o)
            end)
        end },
        on_ok = function(text)
            local path = Storage.join(o.dir, Storage.fileName(text, o.ext))
            self:confirmReplace(path, function() o.on_path(path) end)
        end,
    }
end

-- Ask for the file name, starting from the last export's name (else the
-- document's), in the export folder; Folder... picks another folder for this
-- document. Then write it.
function InkAwayView:promptExportName(name, dir)
    local o = self:exportOptions()
    local ext = o.fmt
    self:askExportPath{
        title = ext == "pdf" and _("Export as PDF") or _("Export as PNG"),
        name = name or o.name or self:docName(), default = self:docName(),
        dir = dir or self:exportDir(), ext = ext,
        on_dir = function(d) o.dir = d end,
        on_path = function(path)
            o.name = Storage.stem(path)
            if ext == "pdf" then self:writePDF(path) else self:writePNG(path) end
        end,
    }
end

------------------------------------------------------------------------------
-- Writing the files
------------------------------------------------------------------------------

-- The template an export draws notebook page i with: the page's ruling, the
-- paper colour and ruling grey worked out, or no ruling when the paper is left
-- out. A copy, so nothing sticks to the notebook.
function InkAwayView:exportTemplate(i)
    local o = self:exportOptions()
    return self:pageExportTemplate(self.notebook, i, o.paper, o.include_bg)
end

-- The export template of page i of notebook nb, on paper colour `paper`, with or
-- without its ruling (`ruled`).
function InkAwayView:pageExportTemplate(nb, i, paper, ruled)
    local template = {}
    for k, v in pairs(nb.template) do template[k] = v end
    template.style = nb:pageTemplate(i).style
    template.paper = PAPERS[paper or "white"] or PAPERS.white
    template.gray = strengthToLevel(template.strength)
    if not ruled and not template.pdf_path then template.style = "blank" end
    return template
end

-- Bookmarks for the titled pages among `pages` (notebook pages, in export
-- order): { title, page } each.
local function titledPages(pages)
    local out = {}
    for j, page in ipairs(pages) do
        if page.title then out[#out + 1] = { title = page.title, page = j } end
    end
    return out
end

-- Export.savePNG options for the page shown: the area, the paper or background
-- when included, and white unless transparent.
function InkAwayView:pngOptions()
    local o = self:exportOptions()
    local opts = { rect = self.save_area, white = not o.transparent or nil }
    if o.include_bg then
        if self.notebook then opts.template = self:exportTemplate(self.notebook.index) end
        if self.bg_bb then opts.bg = self.bg_rgba or self:buildBgRGBA() end
    end
    return opts
end

function InkAwayView:writePNG(path)
    local ok, err = Export.savePNG(self.canvas, path, self:pngOptions())
    if ok then
        self:markDirty()   -- keep the export settings with the document
        local ow = self.save_area and self.save_area.w or self.canvas.w
        local oh = self.save_area and self.save_area.h or self.canvas.h
        UIManager:show(InfoMessage:new{ text = string.format(_("Saved %d × %d image:\n%s"), ow, oh, path) })
    else
        logger.warn("InkAway: export failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not save the image.\n%s"), tostring(err)),
            icon = "notice-warning",
        })
    end
end

-- Write the chosen pages (a drawing is one page) to a PDF.
function InkAwayView:writePDF(path)
    local o = self:exportOptions()
    local nb = self.notebook
    local pages_ops, template, bg, w, h, outline
    local bg_opaque, quality = false, 85
    if nb then
        self:nbSyncOut()
        local sel = self:selectedNotebookPages()
        local pages = {}
        pages_ops = {}
        for j = 1, #sel do pages[j] = nb.pages[sel[j]]; pages_ops[j] = pages[j].ops end
        outline = titledPages(pages)
        w, h = nb.w, nb.h
        template = function(j) return self:exportTemplate(sel[j]) end
        if nb.template.pdf_path then
            -- each source page is rendered when its page is written, one at a
            -- time, so memory stays flat however long the PDF
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
            bg_opaque, quality = true, 90   -- rendered PDF pages are drawn on white
        end
    else
        pages_ops = { self.canvas.ops }
        w, h = self.canvas.w, self.canvas.h
        template = { style = "blank", paper = PAPERS[o.paper or "white"] or PAPERS.white }
        if o.include_bg and self.bg_bb then bg = self.bg_rgba or self:buildBgRGBA() end
    end
    self:runPdfJob(path, { pages = pages_ops, w = w, h = h, template = template, bg = bg,
        bg_opaque = bg_opaque, numbers = o.numbers, quality = quality, outline = outline })
end

-- Export every document of folder `dir`, in the overview's tab order, as one
-- PDF: each notebook's pages on their own paper, each drawing a page, and a
-- bookmark per document with its titled pages under it.
function InkAwayView:exportFolderPDF(dir)
    self:leaveDocument()   -- so the open document's latest changes are in its file
    local docs = Folder.arrange(Folder.load(dir), select(2, Library.list(dir, self:libraryDir())))
    local W, H = self.view.canvas_w, self.view.canvas_h
    local pages, templates, sources, outline = {}, {}, {}, {}
    for _, d in ipairs(docs) do
        local data = Project.load(d.path)
        if data then
            local item = { title = Storage.stem(d.name), page = #pages + 1, kids = {} }
            if Project.isNotebook(data) then
                local nb = Notebook.fromData(data)
                for i, page in ipairs(nb.pages) do
                    pages[#pages + 1] = page.ops
                    templates[#pages] = self:pageExportTemplate(nb, i, "white", true)
                    if nb.template.pdf_path and page.src then
                        sources[#pages] = { pdf = nb.template.pdf_path, src = page.src }
                    end
                    if page.title then item.kids[#item.kids + 1] = { title = page.title, page = #pages } end
                end
            else
                pages[#pages + 1] = data.ops or {}
                templates[#pages] = { style = "blank", paper = PAPERS.white }
                if type(data.bg) == "string" and Storage.exists(data.bg) then sources[#pages] = { image = data.bg } end
            end
            outline[#outline + 1] = item
        end
    end
    if #pages == 0 then
        UIManager:show(InfoMessage:new{ text = _("There is nothing to export in this folder."), timeout = 3 })
        return
    end
    -- page backgrounds are rendered as each page is written: a PDF page from its
    -- document (kept open until the export ends) or a drawing's picture
    local docs_open = {}
    local function bg(j, s)
        local b = sources[j]
        if not b then return nil end
        s = s or 1
        local img
        if b.pdf then
            if docs_open[b.pdf] == nil then
                local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(b.pdf) end)
                docs_open[b.pdf] = ok and doc or false
            end
            img = docs_open[b.pdf] and self:renderPdfPage(docs_open[b.pdf], b.src, W * s, H * s)
        else
            local ok, raw = pcall(function() return RenderImage:renderImageFile(b.image, false) end)
            img = ok and raw and fitIntoCanvasBB(raw, W * s, H * s) or nil
        end
        if not img then return nil end
        local rgba = bbToRGBA(img, W * s, H * s)
        img:free()
        return rgba
    end
    local function closeDocs()
        for _, doc in pairs(docs_open) do if doc then pcall(function() doc:close() end) end end
        docs_open = {}
    end
    self:askExportPath{
        title = _("Export the folder as PDF"), name = Storage.baseName(dir), default = Storage.baseName(dir),
        dir = self:defaultExportDir(), ext = "pdf",
        on_path = function(path)
            self:runPdfJob(path, { pages = pages, w = W, h = H, bg = bg, outline = outline,
                template = function(j) return templates[j] end, done = closeDocs })
        end,
    }
end

-- Write a PDF one page per UI step, with a progress bar and a way to stop, then
-- offer to open it. `spec` holds pages (op lists), w, h, template (one, or a
-- function of the page), bg (one RGBA buffer, or a function rendering each
-- page's own), bg_opaque, numbers, quality, outline and done(), called when the
-- job ends however it ends (see Export.notebookPDFJob).
function InkAwayView:runPdfJob(path, spec)
    local pages_ops = spec.pages
    -- each page streams to disk and is freed before the next, so a long
    -- imported PDF neither freezes the reader nor builds the whole file in memory
    local job, jerr = Export.notebookPDFJob(pages_ops, spec.w, spec.h, spec.template, path, spec.quality or 85,
        Storage.settingsDir(), spec.bg,
        { footer = spec.numbers or nil, bg_opaque = spec.bg_opaque or nil, outline = spec.outline })
    if not job then
        if spec.done then spec.done() end
        UIManager:show(InfoMessage:new{ text = _("Could not export PDF.\n") .. tostring(jerr) })
        return
    end
    self._export_job = job
    local progress
    local pok, ProgressbarDialog = pcall(require, "ui/widget/progressbardialog")
    if pok and ProgressbarDialog then
        progress = ProgressbarDialog:new{
            title = string.format(_("Exporting %d page(s) to PDF"), #pages_ops),
            subtitle = _("Tap to stop"),
            progress_max = #pages_ops,
            refresh_time_seconds = 1,
            dismissable = true,
            dismiss_text = _("Stop exporting? The PDF will not be saved."),
            dismiss_callback = function()   -- closed by the reader (stop), not by us
                if self._export_job == job and not job.over then
                    job.cancel()
                    if spec.done then spec.done() end
                    self._export_job = nil
                    UIManager:show(InfoMessage:new{ text = _("Export stopped."), timeout = 2 })
                end
            end,
        }
        progress:show()
    else
        progress = InfoMessage:new{ text = string.format(_("Exporting %d page(s)\u{2026}"), #pages_ops) }
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
        if spec.done then spec.done() end
        -- make the PDF open as a full page with no auto-crop the first time
        self:seedPdfView(path)
        self:markDirty()   -- keep the export settings with the document
        local msg = string.format(_("PDF saved:\n%s"), path)
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
            if spec.done then spec.done() end
            self._export_job = nil
            closeProgress()
            UIManager:show(InfoMessage:new{ text = _("Could not export PDF.\n") .. tostring(ok and a or state) })
            return
        end
        if state == "done" then
            if progress and progress.reportProgress then pcall(progress.reportProgress, progress, #pages_ops) end
            finished()
            return
        end
        if progress and progress.reportProgress then pcall(progress.reportProgress, progress, a) end
        UIManager:scheduleIn(0.05, step)   -- let the screen update and taps through
    end
    UIManager:scheduleIn(0.2, step)        -- let the progress bar paint first
end

-- Seed a freshly exported PDF's sidecar so KOReader opens it as a whole page
-- with no margin cropping (its defaults would zoom into the ink and clip it).
-- Best effort.
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
    self:leaveDocument()
    self.closing = true
    UIManager:close(self)
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
end

-- Is the bookshelf plugin present? Checks KOReader's loaded-plugin registry (found
-- wherever it is installed), then the folders next to this plugin and in the user
-- plugins folder. Cached for the session.
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

-- The bookshelf plugin's ornament folder (koreader/icons/bookshelf.ornaments), or
-- nil when that plugin is not in use (neither the folder nor the plugin exists).
-- An ornament is a transparent PNG dropped in here. KOReader never creates icons/
-- itself, so callers create the folders.
function InkAwayView:ornamentsDir()
    local data = Storage.dataDir()
    if not data then return nil end
    local dir = data .. "/icons/bookshelf.ornaments"
    if Storage.isDir(dir) or self:bookshelfInstalled() then return dir end
    return nil
end

-- Save the canvas into the bookshelf ornament folder as a transparent PNG. The
-- folder is fixed, so this only asks for a name; it creates the folders if needed.
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
-- bookshelf plugin reads name.invert.png as the dark-mode variant); ".png" is
-- added when the name does not already end in it.
function InkAwayView:promptOrnamentName(dir)
    local default_name = os.date("ornament-%Y%m%d-%H%M%S")
    self:promptText{
        title = _("Ornament name"), input = default_name, hint = default_name, default = default_name,
        description = _("Saved as a transparent PNG in the bookshelf ornaments folder.\nEnd the name with .invert for a dark-mode version."),
        ok_text = _("Save"),
        on_ok = function(name)
            self:confirmReplace(Storage.join(dir, Storage.fileName(name, "png")),
                function() self:writeOrnament(dir, name) end)
        end,
    }
end

function InkAwayView:writeOrnament(dir, name)
    local path = Storage.join(dir, Storage.fileName(name, "png"))
    local opts = self:pngOptions()
    opts.white = nil   -- an ornament is always transparent
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

-- The export area being chosen.
function InkAwayView:paintCropOverlay(bb, x, y)
    local v = self.view
    local c = self._crop_screen
    local cx0 = math.max(x + v.area_x, math.min(x + v.area_x + v.area_w, c.x0))
    local cy0 = math.max(y + v.area_y, math.min(y + v.area_y + v.area_h, c.y0))
    local cx1 = math.max(x + v.area_x, math.min(x + v.area_x + v.area_w, c.x1))
    local cy1 = math.max(y + v.area_y, math.min(y + v.area_y + v.area_h, c.y1))
    if cx1 < cx0 then cx0, cx1 = cx1, cx0 end
    if cy1 < cy0 then cy0, cy1 = cy1, cy0 end
    Paint.outline(bb, cx0, cy0, cx1 - cx0, cy1 - cy0, Blitbuffer.COLOR_BLACK, 2)
end

return InkAwayView
