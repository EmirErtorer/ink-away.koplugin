--[[
The library: a full-screen grid of the folders and documents in the library
folder. Tap to open, hold for rename, duplicate, move and delete; new folders,
importing a PDF and sorting from its menu. Thumbnails are rendered from the files
and cached, so the grid only draws a document once per change.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ImageProc = require("ink/imageproc")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Project = require("ink/project")
local Storage = require("ink/storage")
local ThumbGrid = require("ink/ui/thumbgrid")

local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB

local InkAwayView = {}

------------------------------------------------------------------------------
-- The library grid
------------------------------------------------------------------------------

-- The title for library folder `dir`: "Library" at the top, else its name.
function InkAwayView:libraryTitle(dir)
    if dir == self:libraryDir() then return _("Library") end
    return Storage.baseName(dir)
end

-- The cards for library folder `dir`: its folders, then its documents.
function InkAwayView:libraryItems(dir)
    local folders, docs = Library.list(dir, self:libraryDir(), self:getSetting("inkaway_library_sort"))
    local items = {}
    for _, f in ipairs(folders) do
        items[#items + 1] = { label = f.name, path = f.path, folder = true }
    end
    for _, d in ipairs(docs) do
        items[#items + 1] = { label = Storage.stem(d.name), path = d.path, mtime = d.mtime,
            selected = (d.path == self.doc_path) }
    end
    return items
end

-- Open the library at folder `dir` (the open document's folder by default). The
-- open document is saved first, so the library shows it as it is.
function InkAwayView:openLibrary(dir)
    self:leaveDocument()
    local root = self:libraryDir()
    dir = dir or self:docDir()
    if not Storage.within(dir, root) or not Storage.isDir(dir) then dir = root end
    self:closeSheet("_library")
    self._lib_dir = dir
    local start = 1
    local items = self:libraryItems(dir)
    for i, it in ipairs(items) do if it.selected then start = i end end
    self._library = ThumbGrid:new{
        title = self:libraryTitle(dir),
        items = items,
        start = start,
        folder_icon = self:iconPath("folder"),
        empty_text = _("Nothing here yet. Tap New to start a drawing or a notebook."),
        close_label = _("Close"),
        actions = {
            { _("New"), function() self:openNewSheet(self._lib_dir) end, true },
            { "\u{22EF}", function() self:libraryMenu() end },
        },
        on_back = (dir ~= root) and function() self:libraryGo(Storage.dirName(self._lib_dir)) end or nil,
        render = function(it, w, h) return self:docThumb(it.path, w, h) end,
        on_pick = function(it) self:libraryPick(it) end,
        on_hold = function(it) self:libraryItemMenu(it) end,
        on_close = function() self._library = nil end,
    }
    UIManager:show(self._library)
end

-- Show folder `dir` in the open library.
function InkAwayView:libraryGo(dir)
    local lib = self._library
    if not lib then return self:openLibrary(dir) end
    self._lib_dir = dir
    lib.gpage = 0
    lib.on_back = (dir ~= self:libraryDir()) and function() self:libraryGo(Storage.dirName(self._lib_dir)) end or nil
    lib:setItems(self:libraryItems(dir), self:libraryTitle(dir))
end

-- Show the open library's folder again, after something in it changed.
function InkAwayView:refreshLibrary()
    if self._library then self._library:setItems(self:libraryItems(self._lib_dir)) end
end

-- A tap on a card: into a folder, or open a document and close the library.
function InkAwayView:libraryPick(it)
    if it.folder then return self:libraryGo(it.path) end
    if self._library then self._library:close() end
    self:openDocument(it.path)
end

-- The library's menu: new folder, import a PDF, and the sort order.
function InkAwayView:libraryMenu()
    local dialog
    local by_name = self:getSetting("inkaway_library_sort") == "name"
    dialog = ButtonDialog:new{ buttons = {
        { { text = _("New folder"), callback = function()
            UIManager:close(dialog); self:promptNewFolder(self._lib_dir, function() self:refreshLibrary() end) end } },
        { { text = _("Import a PDF\u{2026}"), callback = function()
            UIManager:close(dialog); self:openPdfAsNotebook(self._lib_dir) end } },
        { { text = by_name and _("Sort by date") or _("Sort by name"), callback = function()
            UIManager:close(dialog)
            self:setSetting("inkaway_library_sort", by_name and "recent" or "name")
            self:refreshLibrary()
        end } },
    } }
    UIManager:show(dialog)
end

-- The menu of one card, from a hold.
function InkAwayView:libraryItemMenu(it)
    local dialog
    local function act(text, fn)
        return { text = text, callback = function() UIManager:close(dialog); fn() end }
    end
    local rows = {
        { act(_("Open"), function() self:libraryPick(it) end) },
        { act(_("Rename\u{2026}"), function() self:promptRenameItem(it) end),
          act(_("Move to\u{2026}"), function() self:moveItem(it) end) },
    }
    if it.folder then
        rows[#rows + 1] = { act(_("Delete\u{2026}"), function() self:confirmDeleteItem(it) end) }
    else
        rows[#rows + 1] = { act(_("Duplicate"), function() self:duplicateItem(it) end),
            act(_("Delete\u{2026}"), function() self:confirmDeleteItem(it) end) }
    end
    dialog = ButtonDialog:new{ title = it.label, buttons = rows }
    UIManager:show(dialog)
end

------------------------------------------------------------------------------
-- Folders and files
------------------------------------------------------------------------------

-- Ask for a name and make that folder in `dir`; `after(path)` runs once it is made.
function InkAwayView:promptNewFolder(dir, after)
    self:promptText{ title = _("New folder"), hint = _("Folder name"), ok_text = _("Create"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" or name:sub(1, 1) == "." then return end
            local path = Storage.join(dir, name)
            if Storage.exists(path) then
                UIManager:show(InfoMessage:new{ text = string.format(
                    _("There is already something called \u{201C}%s\u{201D} here."), name) })
                return
            end
            if not Storage.ensureDir(path) then
                UIManager:show(InfoMessage:new{ text = _("Could not create the folder.") })
                return
            end
            if after then after(path) end
        end }
end

-- The open document moved from `old` to `new` (or a folder holding it did).
function InkAwayView:pathMoved(old, new)
    if self.doc_path and Storage.within(self.doc_path, old) then
        self.doc_path = new .. self.doc_path:sub(#old + 1)
        if self.doc_written then self:setSetting("inkaway_last_doc", self.doc_path) end
    end
end

-- Drop the open document without saving it (its file was deleted), and start a
-- new drawing in `dir`.
function InkAwayView:discardDocument(dir)
    self.doc_path, self.doc_written = nil, false
    self:setSetting("inkaway_last_doc", nil)
    self:newDrawing(dir)
end

function InkAwayView:promptRenameItem(it)
    self:promptText{ title = _("Rename"), input = it.label, ok_text = _("Rename"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" or name == it.label then return end
            local dir = Storage.dirName(it.path)
            local new = it.folder and Storage.join(dir, name) or Storage.join(dir, Storage.fileName(name, Project.EXT))
            if Storage.exists(new) and new:lower() ~= it.path:lower() then
                UIManager:show(InfoMessage:new{ text = string.format(
                    _("There is already something called \u{201C}%s\u{201D} here."), name) })
                return
            end
            local ok, err = os.rename(it.path, new)
            if not ok then
                UIManager:show(InfoMessage:new{ text = _("Could not rename.\n") .. tostring(err) })
                return
            end
            self:pathMoved(it.path, new)
            self:refreshLibrary()
        end }
end

function InkAwayView:duplicateItem(it)
    local copy, err = Library.duplicate(it.path)
    if not copy then
        UIManager:show(InfoMessage:new{ text = _("Could not duplicate.\n") .. tostring(err) })
        return
    end
    self:refreshLibrary()
end

function InkAwayView:confirmDeleteItem(it)
    local text = it.folder
        and string.format(_("Delete the folder \u{201C}%s\u{201D} and everything in it?"), it.label)
        or string.format(_("Delete \u{201C}%s\u{201D}?"), it.label)
    UIManager:show(ConfirmBox:new{ text = text, ok_text = _("Delete"), ok_callback = function()
        local holds_open = self.doc_path and Storage.within(self.doc_path, it.path)
        if not Storage.removeTree(it.path) then
            UIManager:show(InfoMessage:new{ text = _("Could not delete it.") })
            return
        end
        if not it.folder then self:dropThumbs(it.path) end
        if holds_open then self:discardDocument(self._lib_dir) end
        self:refreshLibrary()
    end })
end

-- Pick a destination folder in the library and move the card's file or folder
-- there.
function InkAwayView:moveItem(it)
    self:chooseLibraryFolder(it.path, function(dir)
        local new, err = Library.move(it.path, dir)
        if not new then
            UIManager:show(InfoMessage:new{ text = _("Could not move it.\n") .. tostring(err) })
            return
        end
        self:pathMoved(it.path, new)
        self:refreshLibrary()
    end)
end

-- A folder chooser inside the library: browse folders, make new ones, and pick
-- the one shown with the dark button. `moving` (a path) is left out, so a folder
-- cannot be moved into itself. The title names the folder shown.
function InkAwayView:chooseLibraryFolder(moving, on_pick)
    local root = self:libraryDir()
    local grid
    local cur = root
    local function items()
        local folders = Library.list(cur, root)
        local out = {}
        for _, f in ipairs(folders) do
            if not (moving and Storage.within(f.path, moving)) then
                out[#out + 1] = { label = f.name, path = f.path, folder = true }
            end
        end
        return out
    end
    local function go(dir)
        cur = dir
        grid.gpage = 0
        grid.on_back = (dir ~= root) and function() go(Storage.dirName(cur)) end or nil
        grid:setItems(items(), string.format(_("Move to %s"), self:libraryTitle(dir)))
    end
    grid = ThumbGrid:new{
        items = {},
        folder_icon = self:iconPath("folder"),
        close_label = _("Cancel"),
        empty_text = _("No folders here."),
        actions = {
            { _("New folder"), function() self:promptNewFolder(cur, function() go(cur) end) end },
            { _("Move here"), function() grid:close(); on_pick(cur) end, true },
        },
        on_pick = function(it) go(it.path) end,
    }
    go(root)
    UIManager:show(grid)
end

------------------------------------------------------------------------------
-- Thumbnails
------------------------------------------------------------------------------

-- Run fn with an empty placed-image cache, freeing whatever it decodes, so a
-- thumbnail of another document leaves the open one's images alone.
function InkAwayView:withOwnImageCache(fn)
    local saved = { self._img_bb, self._img_scaled, self._img_render, self._img_disp }
    self._img_bb, self._img_scaled, self._img_render, self._img_disp = nil, nil, nil, nil
    local ok, err = pcall(fn)
    self:freeImageCache()
    self._img_bb, self._img_scaled, self._img_render, self._img_disp = saved[1], saved[2], saved[3], saved[4]
    if not ok then error(err) end
end

-- Draw the document at `path` (a drawing, or a notebook's first page) the size
-- of the page, then shrink it to fit maxw x maxh. Returns a BlitBuffer or nil.
function InkAwayView:renderDocThumb(path, maxw, maxh)
    local data = Project.load(path)
    if not data then return nil end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local scratch = Blitbuffer.new(W, H, self.canvas_bb and self.canvas_bb:getType() or Blitbuffer.TYPE_BBRGB32)
    local ops, bg, template
    if Project.isNotebook(data) then
        local nb = Notebook.fromData(data)
        local page = nb.pages[1]
        ops, template = page.ops, nb.template
        if template.pdf_path and page.src then
            local doc = (self._nb_pdf_path == template.pdf_path) and self._nb_pdf_doc
            local own
            if not doc then
                local ok, d = pcall(function()
                    return require("document/documentregistry"):openDocument(template.pdf_path)
                end)
                doc, own = ok and d or nil, true
            end
            bg = doc and self:renderPdfPage(doc, page.src, W, H)
            if own and doc then pcall(function() doc:close() end) end
        end
    else
        ops = data.ops
        if type(data.bg) == "string" and Storage.exists(data.bg) then
            local ok, img = pcall(function() return RenderImage:renderImageFile(data.bg, false) end)
            if ok and img then bg = fitIntoCanvasBB(img, W, H) end
        end
    end
    self:withOwnImageCache(function() self:composeInto(scratch, ops, bg, template) end)
    if bg then bg:free() end
    local scale = math.min(maxw / W, maxh / H)
    local thumb = RenderImage:scaleBlitBuffer(scratch, math.max(1, math.floor(W * scale)),
        math.max(1, math.floor(H * scale)), false)
    if thumb ~= scratch then scratch:free() end
    return thumb
end

-- The thumbnail of the document at `path`, from the cache when the file has not
-- changed since it was drawn, else drawn now and cached.
function InkAwayView:docThumb(path, maxw, maxh)
    local dir = Storage.cacheDir()
    local file = Storage.join(dir, Library.thumbName(path, Storage.mtime(path), maxw, maxh))
    if Storage.exists(file) then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(file, false) end)
        if ok and bb then return bb end
    end
    local thumb = self:renderDocThumb(path, maxw, maxh)
    if thumb then
        self:dropThumbs(path)
        pcall(function() thumb:writePNG(file) end)
    end
    return thumb
end

-- Delete every cached thumbnail of the document at `path`.
function InkAwayView:dropThumbs(path)
    local code = Library.pathCode(path) .. "-"
    local dir = Storage.cacheDir()
    for _, e in ipairs(Storage.list(dir)) do
        if e.name:sub(1, #code) == code then os.remove(e.path) end
    end
end

return InkAwayView
