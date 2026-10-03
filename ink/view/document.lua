--[[
The open document. Every drawing and notebook is a file in the library that
saves itself: a few seconds after a change, and whenever it is left (another
document, closing, the reader going to sleep). Also the File and New sheets,
rename and duplicate, and the folders files are offered in.
Part of InkAwayView (see ink/view.lua).
]]

local Device = require("device")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Library = require("ink/library")
local Project = require("ink/project")
local Storage = require("ink/storage")

local Screen = Device.screen
local existingDir = Storage.existingDir

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

-- Seconds without a change before the document saves itself, and the longest a
-- save waits while changes keep coming.
local SAVE_IDLE = 8
local SAVE_MAX_WAIT = 60

local InkAwayView = {}

------------------------------------------------------------------------------
-- The document and its state
------------------------------------------------------------------------------

-- The name shown for a kind of document.
function InkAwayView:docKindLabel(kind)
    return kind == "notebook" and _("Notebook") or _("Drawing")
end

-- The open document's name: its file name without the extension.
function InkAwayView:docName()
    return self.doc_path and Storage.stem(self.doc_path) or ""
end

-- The library folder (see Library.root).
function InkAwayView:libraryDir()
    return Library.root(self:getSetting("inkaway_library_dir"))
end

-- The folder new documents go in: the open document's, else the library.
function InkAwayView:docDir()
    local dir = self.doc_path and existingDir(Storage.dirName(self.doc_path))
    return dir or self:libraryDir()
end

-- Is there anything in the document worth a file: ink, a background picture,
-- more than one page, or pages over an imported PDF?
function InkAwayView:docHasContent()
    local nb = self.notebook
    if nb then
        return (nb.template and nb.template.pdf_path) ~= nil or nb:count() > 1
            or nb:hasInk() or not self.canvas:isEmpty()
    end
    return not self.canvas:isEmpty() or self.bg_path ~= nil
end

-- Has the document changed since it was last saved? Ops changes are counted by
-- the canvas; everything else (pages, paper, background) marks it dirty.
function InkAwayView:docChanged()
    return self.dirty or self.canvas.rev ~= self._page_rev
end

-- Note a change the canvas does not count, and make sure a save follows.
function InkAwayView:markDirty()
    self.dirty = true
    self:wakeAutosave()
end

-- Drop what the last save remembered about each page, for a document just
-- started or opened.
function InkAwayView:resetSaveState()
    self._page_cache = setmetatable({}, { __mode = "k" })
    self._page_rev = self.canvas.rev
    self.dirty = false
end

------------------------------------------------------------------------------
-- Saving
------------------------------------------------------------------------------

-- Schedule the save check, unless one is already waiting.
function InkAwayView:wakeAutosave()
    if self._autosave_pending or self.closing then return end
    self._autosave_pending = true
    UIManager:scheduleIn(SAVE_IDLE, self._autosave_tick)
end

-- Save once the document has been left alone for a moment. Never while a stroke
-- or text box is in progress; changes that keep coming delay the save, but only
-- up to SAVE_MAX_WAIT. Stops checking once everything is saved.
function InkAwayView:autosaveTick()
    self._autosave_pending = false
    if self.closing or not self:docChanged() then
        self._save_waited = 0
        return
    end
    local busy = self.capturing or (self._pen_state and self._pen_state.down)
        or self.editing_text or self._export_job
    local active = self.canvas.rev ~= self._tick_rev
    self._tick_rev = self.canvas.rev
    self._save_waited = (self._save_waited or 0) + SAVE_IDLE
    if not busy and (not active or self._save_waited >= SAVE_MAX_WAIT) then
        self:saveDocument()
    end
    if self:docChanged() then self:wakeAutosave() end
end

-- Save the open document if it changed, or always with `force`. A document with
-- nothing in it gets no file until it has something, so an untouched new one
-- leaves nothing behind. Returns false only when the write failed.
function InkAwayView:saveDocument(force)
    if not self.doc_path then return true end
    if self.notebook then self:nbSyncOut() end
    if not (force or self:docChanged()) then return true end
    if not self.doc_written and not self:docHasContent() then return true end
    local path = self.doc_path
    if not self.doc_written and Storage.exists(path) then
        -- the name it was started with has been taken since
        path = Storage.uniquePath(Storage.dirName(path), Storage.stem(path), Project.EXT)
    end
    local ok, err
    if self.notebook then
        ok, err = Project.saveNotebook(self.notebook, path, self._page_cache)
    else
        ok, err = Project.save(self.canvas, path, { bg = self.bg_path })
    end
    if not ok then
        logger.warn("InkAway: saving failed:", path, err)
        if not self._save_failed then   -- once, not on every retry
            self._save_failed = true
            UIManager:show(InfoMessage:new{ icon = "notice-warning",
                text = string.format(_("Could not save:\n%s\n\n%s"), path, tostring(err)) })
        end
        return false
    end
    self._save_failed = nil
    self.doc_path, self.doc_written = path, true
    self.dirty = false
    self._page_rev = self.canvas.rev
    self._save_waited = 0
    self:setSetting("inkaway_last_doc", path)
    return true
end

-- KOReader asks every widget to save before the reader sleeps and before a
-- widget closes.
function InkAwayView:onFlushSettings()
    if self.closing then return end
    self:flushPending()
    self:saveDocument()
end

------------------------------------------------------------------------------
-- New, open and rename
------------------------------------------------------------------------------

-- Settle anything half-done (a stroke, a text box, a selected image) and save
-- the open document, before another one replaces it.
function InkAwayView:leaveDocument()
    self:flushPending()
    if self.editing_text then self:finishTextEdit(true) end
    if self.active_image then self:finishImageEdit() end
    self:saveDocument()
end

-- Start a new, empty document of `kind` in folder `dir` (the open document's by
-- default), named `name` (a dated default when nil). `setup` builds it: it
-- clears the canvas or enters notebook mode.
function InkAwayView:beginDocument(kind, name, setup, dir)
    dir = dir or self:docDir()
    self:leaveDocument()
    self.doc_path = Storage.uniquePath(dir, name or Library.defaultName(self:docKindLabel(kind)), Project.EXT)
    self.doc_written = false
    self.save_area = nil
    setup()
    self:resetSaveState()
end

-- Replace the drawing with `ops`, dropping every selection and cached image.
function InkAwayView:loadOps(ops)
    self.canvas:setOps(ops)
    self.selected, self.rotating = nil, nil
    self.active_image, self._img_drag = nil, nil
    self:freeImageCache()
    self:resetLasso()
end

-- Load a project's ops into the canvas. Returns false when there are none.
function InkAwayView:loadProjectData(data)
    if not data or not data.ops then return false end
    self:loadOps(data.ops)
    return true
end

-- Put a saved drawing's background picture back, if the file is still there.
function InkAwayView:restoreBackground(path)
    if Storage.exists(path) then
        self:loadBackground(path)
    else
        UIManager:show(InfoMessage:new{ text = string.format(
            _("The background picture could not be found:\n%s"), path) })
    end
end

-- Open the document at `path`, saving the open one first. Returns whether it
-- opened; on failure the open document stays as it was.
function InkAwayView:openDocument(path)
    if path == self.doc_path and self.doc_written then return true end
    local data, err = Project.load(path)
    if not data then
        UIManager:show(InfoMessage:new{
            text = _("Could not open that file.\n") .. tostring(err) })
        return false
    end
    self:leaveDocument()
    self.save_area = nil
    if Project.isNotebook(data) then
        self:openNotebookData(data)
    else
        self:exitNotebook()
        self:clearBackground()
        self:loadProjectData(data)
        if type(data.bg) == "string" then self:restoreBackground(data.bg) end
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()
        UIManager:setDirty(self, "full")
    end
    self.doc_path, self.doc_written = path, true
    self:resetSaveState()
    self:setSetting("inkaway_last_doc", path)
    return true
end

-- The document to show when Ink Away opens: the old session file of an earlier
-- version (once), else the last document, else a new drawing.
function InkAwayView:openStartDocument()
    local path = self:adoptOldSession() or self:getSetting("inkaway_last_doc")
    if path and Storage.exists(path) and self:openDocument(path) then return end
    self.doc_path = Storage.uniquePath(self:libraryDir(), Library.defaultName(self:docKindLabel("drawing")), Project.EXT)
    self.doc_written = false
    self:resetSaveState()
end

-- Earlier versions kept the work in one "last session" file and could autosave
-- it or not. That file becomes a library document of its own, the first time
-- this version runs. Returns its path, or nil.
function InkAwayView:adoptOldSession()
    if self:getSetting("inkaway_session_migrated") then return nil end
    self:setSetting("inkaway_session_migrated", true)
    for _, key in ipairs({ "inkaway_autosave", "inkaway_last_dproj_dir", "inkaway_last_nproj_dir" }) do
        self:setSetting(key, nil)
    end
    local old = Storage.join(Storage.settingsDir(), "inkaway_session." .. Project.EXT)
    if not Storage.exists(old) then return nil end
    return Library.adoptSession(old, self:libraryDir(), Library.defaultName(_("Recovered")))
end

-- Start a new drawing in folder `dir` (the open document's by default).
function InkAwayView:newDrawing(dir)
    self:beginDocument("drawing", nil, function()
        self:exitNotebook()
        self:clearBackground()
        self:loadOps({})
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()     -- reclaim the previous document's memory now
        UIManager:setDirty(self, "full")
    end, dir)
end

-- Start a new notebook with paper `style` in folder `dir`, ruled like the last
-- notebook (else like the drawing grid), so a new notebook matches the last one.
function InkAwayView:newNotebook(style, dir)
    self.nb_style = style
    self:setSetting("inkaway_nb_style", style)
    self:beginDocument("notebook", nil, function()
        self:startNotebook({ style = style,
            size = self.nb_size or self.grid_size or 40,
            strength = self.nb_strength or self.grid_strength or 45 })
    end, dir)
end

-- Pick a picture and start a drawing over it, named after it and saved at once.
function InkAwayView:newFromImage(dir)
    self:pickFile(self:homeDir(), function(path)
        local lower = path:lower()
        if not (lower:match("%.png$") or lower:match("%.jpe?g$")) then
            UIManager:show(InfoMessage:new{ text = _("Please choose a PNG or JPEG image.") })
            return
        end
        self:beginDocument("drawing", Storage.stem(path), function()
            self:exitNotebook()
            self:clearBackground()
            self:loadOps({})
            self:loadBackground(path)
            self:resetTransientMemory()
        end, dir)
        self:saveDocument(true)
    end)
end

-- Where pictures and PDFs are picked from: KOReader's home folder.
function InkAwayView:homeDir()
    local home = self:getSetting("home_dir")
    if home and Storage.isDir(home) then return home end
    local ok, util = pcall(require, "apps/filemanager/filemanagerutil")
    return ok and util.getDefaultDir and util.getDefaultDir() or "/"
end

-- Copy the open document next to it and carry on in the copy.
function InkAwayView:duplicateDocument()
    self:leaveDocument()
    if not self.doc_written then
        UIManager:show(InfoMessage:new{ text = _("There is nothing to copy yet."), timeout = 2 })
        return
    end
    local copy, err = Library.duplicate(self.doc_path)
    if not copy then
        UIManager:show(InfoMessage:new{ text = _("Could not duplicate.\n") .. tostring(err) })
        return
    end
    if self:openDocument(copy) then
        self:showNotice(string.format(_("Now in the copy, \u{201C}%s\u{201D}"), Storage.stem(copy)))
    end
end

function InkAwayView:promptRename()
    self:promptText{ title = _("Rename"), input = self:docName(), ok_text = _("Rename"),
        on_ok = function(text) self:renameDocument(text) end }
end

-- Rename the open document within its folder. Its file is renamed now if it has
-- one, else it is simply written under the new name.
function InkAwayView:renameDocument(name)
    name = (name or ""):match("^%s*(.-)%s*$")
    if name == "" or not self.doc_path then return end
    local new = Storage.join(Storage.dirName(self.doc_path), Storage.fileName(name, Project.EXT))
    if new == self.doc_path then return end
    -- a change of case only is the same file on a case-blind file system
    if Storage.exists(new) and new:lower() ~= self.doc_path:lower() then
        UIManager:show(InfoMessage:new{ text = string.format(
            _("There is already a file called \u{201C}%s\u{201D} here."), Storage.baseName(new)) })
        return
    end
    if self.doc_written then
        local ok, err = os.rename(self.doc_path, new)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Could not rename.\n") .. tostring(err) })
            return
        end
        self:setSetting("inkaway_last_doc", new)
    end
    self.doc_path = new
end

------------------------------------------------------------------------------
-- The File and New sheets
------------------------------------------------------------------------------

-- Where the open document is, as the library shows it: "Library / School".
function InkAwayView:docPlace()
    local root = self:libraryDir()
    local dir = self.doc_path and Storage.dirName(self.doc_path) or root
    if not Storage.within(dir, root) then return dir end
    local place = _("Library")
    local rest = dir:sub(#root + 2)
    for part in rest:gmatch("[^/]+") do place = place .. " / " .. part end
    return place
end

-- The File sheet (toolbar): the document's name and where it is kept, rename,
-- the library, new, duplicate and export.
function InkAwayView:openDocumentSheet()
    self:flushPending()
    if self.active_image then self:finishImageEdit() end
    self:closeSheet("_doc_dialog")
    local content_w, gap = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local closeSelf = function() self:closeSheet("_doc_dialog") end
    local function act(label, w, cb, dark)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark)
    end
    local function row2(a, b)
        return HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b }
    end
    local status = self.doc_written
        and string.format(_("Saved automatically in %s"), self:docPlace())
        or string.format(_("Saved in %s once there is something in it"), self:docPlace())
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(self:docName(), content_w, _("Done"), closeSelf))
        add(vspan(4))
        add(self:sheetHint(status, content_w, 15))
        add(vspan(16))
        add(row2(act(_("Rename\u{2026}"), halfW, function() self:promptRename() end),
                 act(_("Library"), halfW, function() self:openLibrary() end)))
        add(vspan(8))
        add(row2(act(_("New\u{2026}"), halfW, function() self:openNewSheet() end),
                 act(_("Duplicate"), halfW, function() self:duplicateDocument() end)))
        add(vspan(8))
        add(act(_("Export\u{2026}"), content_w, function() self:onSave() end, true))
        return content
    end
    self:showSheet("_doc_dialog", build)
end

-- The New sheet: a drawing, a notebook on one of the papers, or one made from a
-- PDF or a picture, in folder `dir` (the open document's by default).
function InkAwayView:openNewSheet(dir)
    self:closeSheet("_new_dialog")
    local content_w, gap = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local closeSelf = function() self:closeSheet("_new_dialog") end
    -- every choice closes this sheet and the library under it, then starts
    local function start(fn)
        return function(...)
            closeSelf()
            if self._library then self._library:close() end
            fn(...)
        end
    end
    local styles = self:notebookStyles()
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("New"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Drawing"), content_w, start(function() self:newDrawing(dir) end), false, true))
        add(vspan(16))
        add(self:sheetLabel(_("Notebook"), true))
        add(vspan(6))
        local pick = start(function(style) self:newNotebook(style, dir) end)
        add(self:segmentedRow({ styles[1], styles[2], styles[3] }, nil, content_w, pick))
        add(vspan(8))
        add(self:segmentedRow({ styles[4], styles[5], styles[6] }, nil, content_w, pick))
        add(vspan(16))
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("From PDF\u{2026}"), halfW, start(function() self:openPdfAsNotebook(dir) end)),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("From image\u{2026}"), halfW, start(function() self:newFromImage(dir) end)) })
        return content
    end
    self:showSheet("_new_dialog", build)
end

------------------------------------------------------------------------------
-- Folders
------------------------------------------------------------------------------

-- The export folders under "ink away/": drawings (PNG and JPEG images) and
-- notebooks (exported PDFs). Returns the images path.
function InkAwayView:ensureDefaultDir()
    local base = Storage.dataDir() or "/"
    self.notebooks_dir = Storage.appDir("notebooks") or base
    return Storage.appDir("drawings") or base
end

-- Where the image save dialog starts: last image folder used, else drawings.
function InkAwayView:defaultDir()
    return existingDir(self:getSetting("inkaway_last_dir")) or self.default_dir or "/"
end

-- Remember the last image folder used, for next time.
function InkAwayView:rememberDir(dir)
    self:setSetting("inkaway_last_dir", dir)
end

return InkAwayView
