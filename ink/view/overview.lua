--[[
The overview: the pages of a notebook as thumbnails, with the notebooks of its
folder as tabs down the side, like dividers in a binder (drawings stay in the
library). Tap a tab to see its pages and a page to open it; hold either for its
menu; the back arrow goes up to the folder in the library. Pages can be renamed,
starred, moved or copied to another notebook of the folder, and the tabs put in
order and given colours.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Folder = require("ink/folder")
local Library = require("ink/library")
local Notebook = require("ink/notebook")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Project = require("ink/project")
local Storage = require("ink/storage")
local ThumbGrid = require("ink/ui/thumbgrid")

local uiFill = Paint.uiFill

local InkAwayView = {}

------------------------------------------------------------------------------
-- What the overview shows
------------------------------------------------------------------------------

-- Is the document at `path` (with modification time `mtime`) a notebook? Asked
-- of the file once per change.
function InkAwayView:isNotebookPath(path, mtime)
    if path == self.doc_path then return self.notebook ~= nil end
    self._nb_files = self._nb_files or {}
    local known = self._nb_files[path]
    if not (known and known.mtime == mtime) then
        known = { mtime = mtime, nb = Library.isNotebookFile(path) }
        self._nb_files[path] = known
    end
    return known.nb
end

-- The tabs of folder `dir`: its notebooks in binder order, the one at `sel_path`
-- marked. An open notebook with no file yet is a tab too, at the end. Also
-- returns the binder data and all the folder's documents in order.
function InkAwayView:overviewTabs(dir, sel_path)
    local data = Folder.load(dir)
    local docs = select(2, Library.list(dir, self:libraryDir()))
    local arranged = Folder.arrange(data, docs)
    -- documents met for the first time keep the place they got from now on
    if not Folder.knows(data, arranged) then
        Folder.setOrder(data, arranged)
        Folder.save(dir, data)
    end
    local tabs = {}
    local seen
    for _, d in ipairs(arranged) do
        if self:isNotebookPath(d.path, d.mtime) then
            local rgb = data.colors[d.name]
            tabs[#tabs + 1] = { label = Storage.stem(d.name), name = d.name, path = d.path,
                color = rgb and uiFill(rgb) or nil, selected = (d.path == sel_path) }
        end
        if d.path == self.doc_path then seen = true end
    end
    if not seen and self.notebook and self.doc_path and Storage.dirName(self.doc_path) == dir then
        tabs[#tabs + 1] = { label = self:docName(), name = Storage.baseName(self.doc_path), path = self.doc_path,
            selected = (self.doc_path == sel_path) }
    end
    return tabs, data, arranged
end

-- The notebook a tab shows: the open one as it is in memory, any other loaded
-- from its file (kept while the overview is open). Returns { nb, open, data };
-- nb is nil when the file holds no notebook.
function InkAwayView:overviewDoc(path)
    if path == self.doc_path and self.notebook then
        self:nbSyncOut()
        return { nb = self.notebook, open = true }
    end
    local ov = self._ov
    if ov.docs[path] then return ov.docs[path] end
    local data = Project.load(path)
    local doc = { data = data }
    if data and Project.isNotebook(data) then
        doc.nb = Notebook.fromData(data)
        doc.nb.w, doc.nb.h = self.screen_w, self.screen_h
    end
    ov.docs[path] = doc
    return doc
end

-- The cards for the selected tab: its pages, or only the starred ones.
function InkAwayView:overviewItems()
    local ov = self._ov
    local nb = ov.path and self:overviewDoc(ov.path).nb
    local items = {}
    if not nb then return items end
    local here = ov.path == self.doc_path and nb.index
    for i, page in ipairs(nb.pages) do
        if not ov.starred or page.star then
            items[#items + 1] = { label = page.title and string.format("%d  %s", i, page.title) or tostring(i),
                index = i, star = page.star, selected = (i == here), page = page }
        end
    end
    return items
end

-- The title: the selected notebook's whole name (its tab may be cut short).
function InkAwayView:overviewTitle()
    local ov = self._ov
    if ov.starred then return _("Starred pages") end
    if not ov.path then return "" end
    return ov.path == self.doc_path and self:docName() or Storage.stem(ov.path)
end

------------------------------------------------------------------------------
-- The overview
------------------------------------------------------------------------------

-- Open the overview on the open notebook, with its folder's notebooks as tabs.
function InkAwayView:openOverview()
    self:flushPending()
    if self.active_image then self:finishImageEdit() end
    if self.notebook then self:nbSyncOut() end
    local dir = self:docDir()
    self._ov = { dir = dir, path = self.doc_path, docs = {}, starred = false }
    local tabs = self:overviewTabs(dir, self.doc_path)
    local items = self:overviewItems()
    local start = 1
    for i, it in ipairs(items) do if it.selected then start = i end end
    local grid
    grid = ThumbGrid:new{
        title = self:overviewTitle(),
        items = items,
        start = start,
        tabs = tabs,
        empty_text = _("No starred pages here."),
        actions = { { "\u{2605}", function() self:overviewToggleStarred() end } },
        on_back = function() local dir = self._ov.dir; grid:close(); self:openLibrary(dir) end,
        render = function(it, w, h) return self:overviewThumb(it, w, h) end,
        on_pick = function(it) self:overviewPick(it) end,
        on_hold = function(it) self:overviewPageMenu(it) end,
        on_tab = function(tab) self:overviewShowTab(tab.path) end,
        on_tab_hold = function(tab) self:overviewTabMenu(tab) end,
        tab_footer = { "+ " .. _("Notebook"), function() self:openNotebookPaper(self._ov.dir) end },
        on_close = function() self:closeOverviewDocs(); self._ov, self._overview = nil, nil end,
    }
    self._overview = grid
    UIManager:show(grid)
end

-- Show the pages of the tab at `path`.
function InkAwayView:overviewShowTab(path)
    local ov = self._ov
    if not ov then return end
    ov.path = path
    self:refreshOverview(true)
end

-- Rebuild the tabs and cards after a change; `top` goes back to the first page
-- of cards.
function InkAwayView:refreshOverview(top)
    local ov, grid = self._ov, self._overview
    if not (ov and grid) then return end
    local tabs = self:overviewTabs(ov.dir, ov.path)
    if top then grid.gpage = 0 end
    grid:setItems(self:overviewItems(), self:overviewTitle(), tabs)
    grid.actions[1][3] = ov.starred or nil   -- the star pill is dark while filtering
end

function InkAwayView:overviewToggleStarred()
    local ov = self._ov
    if not ov then return end
    ov.starred = not ov.starred
    self:refreshOverview(true)
end

-- A tap on a page: open it (switching document if it belongs to another tab).
function InkAwayView:overviewPick(it)
    local ov = self._ov
    local path, index = ov.path, it.index
    self._overview:close()
    if path ~= self.doc_path and not self:openDocument(path) then return end
    if self.notebook then self:nbGoTo(index) end
end

-- Close the PDFs opened to draw other tabs' thumbnails.
function InkAwayView:closeOverviewDocs()
    local ov = self._ov
    if not ov then return end
    for _, d in pairs(ov.pdfs or {}) do pcall(function() d:close() end) end
    ov.pdfs = nil
end

------------------------------------------------------------------------------
-- Thumbnails
------------------------------------------------------------------------------

-- A PDF page as a background, from the open notebook's document or one opened
-- for the overview (kept until it closes).
function InkAwayView:overviewPdfPage(pdf_path, src, W, H)
    local doc
    if pdf_path == self._nb_pdf_path and self._nb_pdf_doc then
        doc = self._nb_pdf_doc
    else
        local ov = self._ov
        ov.pdfs = ov.pdfs or {}
        doc = ov.pdfs[pdf_path]
        if not doc then
            local ok, d = pcall(function() return require("document/documentregistry"):openDocument(pdf_path) end)
            doc = ok and d or nil
            ov.pdfs[pdf_path] = doc
        end
    end
    return doc and self:renderPdfPage(doc, src, W, H) or nil
end

-- Draw one page of a notebook that is not open, the size of the page, shrunk to
-- fit maxw x maxh.
function InkAwayView:renderOtherPage(nb, i, maxw, maxh)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local page = nb.pages[i]
    local scratch = Blitbuffer.new(W, H, self.canvas_bb and self.canvas_bb:getType() or Blitbuffer.TYPE_BBRGB32)
    local bg = nb.template.pdf_path and page.src and self:overviewPdfPage(nb.template.pdf_path, page.src, W, H)
    self:withOwnImageCache(function() self:composeInto(scratch, page.ops, bg, nb:pageTemplate(i)) end)
    if bg then bg:free() end
    local scale = math.min(maxw / W, maxh / H)
    local thumb = RenderImage:scaleBlitBuffer(scratch, math.max(1, math.floor(W * scale)),
        math.max(1, math.floor(H * scale)), false)
    if thumb ~= scratch then scratch:free() end
    return thumb
end

-- The thumbnail of a card: a page of the open notebook is drawn live; a page of
-- another notebook is cached by its id and when it last changed, with the paper
-- it is on.
function InkAwayView:overviewThumb(it, maxw, maxh)
    local ov = self._ov
    local doc = self:overviewDoc(ov.path)
    if not doc.nb then return nil end
    if doc.open then return self:renderPageThumb(it.index, maxw, maxh) end
    local page = it.page
    local t = doc.nb:pageTemplate(it.index)
    local name = string.format("%s-p%s-%d-%s%s%s-%dx%d.png", Library.pathCode(ov.path), tostring(page.id),
        page.modified or 0, tostring(t.style), tostring(t.size), tostring(t.strength), maxw, maxh)
    local file = Storage.join(Storage.cacheDir(), name)
    if Storage.exists(file) then
        local ok, bb = pcall(function() return RenderImage:renderImageFile(file, false) end)
        if ok and bb then return bb end
    end
    local thumb = self:renderOtherPage(doc.nb, it.index, maxw, maxh)
    if thumb then pcall(function() thumb:writePNG(file) end) end
    return thumb
end

------------------------------------------------------------------------------
-- Page menu
------------------------------------------------------------------------------

-- Change the notebook at `path`: fn(nb) edits it, and it is saved at once, so a
-- page moving between notebooks is always in a file. The open notebook is
-- changed in memory and saved (`page`, when its own fields change, is written
-- out again); another one is changed in its file. Returns whether it worked.
function InkAwayView:editNotebookAt(path, fn, page)
    if path == self.doc_path and self.notebook then
        self:nbSyncOut()
        local before = self.notebook.pages[self.notebook.index]
        fn(self.notebook)
        if page and self._page_cache then self._page_cache[page] = nil end
        if self.notebook.pages[self.notebook.index] ~= before then self:nbLoad() end
        self:markDirty()
        return self:saveDocument()
    end
    local doc = self:overviewDoc(path)
    if not doc.nb then return false end
    fn(doc.nb)
    local ok, err = Project.saveNotebook(doc.nb, path, nil, { export = doc.data and doc.data.export })
    if not ok then
        UIManager:show(InfoMessage:new{ text = _("Could not save.\n") .. tostring(err) })
        return false
    end
    self:dropThumbs(path)
    return true
end

-- The notebooks in the overview's folder other than `path`, as tabs.
function InkAwayView:overviewOtherNotebooks(path)
    local out = {}
    for _, tab in ipairs((self:overviewTabs(self._ov.dir))) do
        if tab.path ~= path and self:overviewDoc(tab.path).nb then out[#out + 1] = tab end
    end
    return out
end

-- Hold on a page: rename, star, move or copy to another notebook, delete.
function InkAwayView:overviewPageMenu(it)
    local ov = self._ov
    local path = ov.path
    local doc = self:overviewDoc(path)
    if not doc.nb then return end
    local page = it.page
    local dialog
    local function act(text, fn)
        return { text = text, callback = function() UIManager:close(dialog); fn() end }
    end
    dialog = ButtonDialog:new{ title = page.title or string.format(_("Page %d"), it.index), buttons = {
        { act(_("Rename\u{2026}"), function() self:overviewRenamePage(path, page) end),
          act(page.star and _("Unstar") or _("Star"), function()
              self:editNotebookAt(path, function() page.star = (not page.star) or nil end, page)
              self:refreshOverview()
          end) },
        { act(_("Move to\u{2026}"), function() self:overviewSendPage(path, page, true) end),
          act(_("Copy to\u{2026}"), function() self:overviewSendPage(path, page, false) end) },
        { act(_("Delete\u{2026}"), function() self:overviewDeletePage(path, page) end) },
    } }
    UIManager:show(dialog)
end

function InkAwayView:overviewRenamePage(path, page)
    self:promptText{ title = _("Page title"), input = page.title or "", hint = _("Untitled"), ok_text = _("Rename"),
        on_ok = function(text)
            local title = (text or ""):match("^%s*(.-)%s*$")
            self:editNotebookAt(path, function() page.title = (title ~= "") and title or nil end, page)
            self:refreshOverview()
        end }
end

-- The index of `page` in notebook nb.
local function indexOf(nb, page)
    for i, p in ipairs(nb.pages) do if p == page then return i end end
end

function InkAwayView:overviewDeletePage(path, page)
    local nb = self:overviewDoc(path).nb
    if nb:count() <= 1 then
        UIManager:show(InfoMessage:new{ text = _("A notebook keeps at least one page."), timeout = 2 })
        return
    end
    UIManager:show(ConfirmBox:new{ text = _("Delete this page?"), ok_text = _("Delete"), ok_callback = function()
        self:editNotebookAt(path, function(n) n:takePage(indexOf(n, page)) end)
        self:refreshOverview()
    end })
end

-- Move (or copy) a page to the end of another notebook in the folder, chosen
-- from a list.
function InkAwayView:overviewSendPage(path, page, move)
    local targets = self:overviewOtherNotebooks(path)
    if #targets == 0 then
        UIManager:show(InfoMessage:new{ text = _("There is no other notebook in this folder."), timeout = 3 })
        return
    end
    local src_nb = self:overviewDoc(path).nb
    if move and src_nb:count() <= 1 then
        UIManager:show(InfoMessage:new{ text = _("A notebook keeps at least one page."), timeout = 2 })
        return
    end
    local dialog
    local rows = {}
    for t = 1, #targets do
        local tab = targets[t]
        rows[#rows + 1] = { { text = tab.label, callback = function()
            UIManager:close(dialog)
            local same_pdf = src_nb.template.pdf_path ~= nil
                and src_nb.template.pdf_path == self:overviewDoc(tab.path).nb.template.pdf_path
            local style = src_nb:pageTemplate(indexOf(src_nb, page)).style
            if not self:editNotebookAt(tab.path, function(n) n:putPage(page, same_pdf, style) end) then return end
            if move then self:editNotebookAt(path, function(n) n:takePage(indexOf(n, page)) end) end
            self:refreshOverview()
            self:showNotice(string.format(move and _("Moved to \u{201C}%s\u{201D}") or _("Copied to \u{201C}%s\u{201D}"),
                tab.label))
        end } }
    end
    dialog = ButtonDialog:new{ title = move and _("Move the page to") or _("Copy the page to"), buttons = rows }
    UIManager:show(dialog)
end

------------------------------------------------------------------------------
-- Tab menu
------------------------------------------------------------------------------

-- Hold on a tab: open, rename, colour, move up or down, export, delete.
function InkAwayView:overviewTabMenu(tab)
    local dialog
    local function act(text, fn)
        return { text = text, callback = function() UIManager:close(dialog); fn() end }
    end
    local it = { label = tab.label, path = tab.path }
    dialog = ButtonDialog:new{ title = tab.label, buttons = {
        { act(_("Open"), function() self._overview:close(); self:openDocument(tab.path) end),
          act(_("Export\u{2026}"), function()
              self._overview:close()
              if tab.path == self.doc_path or self:openDocument(tab.path) then self:openExport() end
          end) },
        { act(_("Rename\u{2026}"), function() self:overviewRenameTab(it) end),
          act(_("Colour\u{2026}"), function() self:overviewTabColour(tab) end) },
        { act(_("Move up"), function() self:overviewMoveTab(tab, -1) end),
          act(_("Move down"), function() self:overviewMoveTab(tab, 1) end) },
        { act(_("Delete\u{2026}"), function() self:overviewDeleteTab(it) end) },
    } }
    UIManager:show(dialog)
end

function InkAwayView:overviewMoveTab(tab, delta)
    local dir = self._ov.dir
    local tabs, data, arranged = self:overviewTabs(dir)
    local is_tab = {}
    for i = 1, #tabs do is_tab[tabs[i].name] = true end
    if Folder.move(data, arranged, tab.name, delta, function(d) return is_tab[d.name] end) then
        Folder.save(dir, data)
        self:refreshOverview()
    end
end

-- The colours a tab can take: none and the greys, and on a colour screen the
-- colours too.
function InkAwayView:tabColours()
    local out = { { "none", _("No colour") } }
    for i = 2, 4 do out[#out + 1] = { Palette.SHADES[i].name, Palette.SHADES[i].name, Palette.SHADES[i].rgb } end
    if self:colorScreen() then
        for _, c in ipairs(Palette.COLORS) do out[#out + 1] = { c.name, c.name, c.rgb } end
    end
    return out
end

function InkAwayView:overviewTabColour(tab)
    local dir = self._ov.dir
    local options = self:tabColours()
    local data = Folder.load(dir)
    local current = "none"
    for _, o in ipairs(options) do
        if o[3] and Palette.sameColor(o[3], data.colors[tab.name]) then current = o[1] end
    end
    self:openChooserSheet(_("Tab colour"), options, current, function(v)
        local rgb
        for _, o in ipairs(options) do if o[1] == v then rgb = o[3] end end
        local d = Folder.load(dir)
        d.colors[tab.name] = rgb and { rgb[1], rgb[2], rgb[3] } or nil
        Folder.save(dir, d)
        self:refreshOverview()
    end)
end

-- Rename a tab's document, keeping its place and colour in the binder.
function InkAwayView:overviewRenameTab(it)
    local dir = self._ov.dir
    self:promptText{ title = _("Rename"), input = it.label, ok_text = _("Rename"),
        on_ok = function(text)
            local name = (text or ""):gsub("[/\\]", "_"):match("^%s*(.-)%s*$")
            if name == "" or name == it.label then return end
            local new = Storage.join(dir, Storage.fileName(name, Project.EXT))
            if it.path == self.doc_path then
                self:renameDocument(name)
                if self.doc_path ~= new then return end
            else
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
            end
            if it.path ~= self.doc_path then   -- renameDocument keeps the open one in place
                Folder.update(dir, function(d) Folder.rename(d, Storage.baseName(it.path), Storage.baseName(new)) end)
            end
            if self._ov.path == it.path then self._ov.path = new end
            self._ov.docs[new], self._ov.docs[it.path] = self._ov.docs[it.path], nil
            self:refreshOverview()
        end }
end

function InkAwayView:overviewDeleteTab(it)
    local dir = self._ov.dir
    UIManager:show(ConfirmBox:new{ text = string.format(_("Delete \u{201C}%s\u{201D}?"), it.label),
        ok_text = _("Delete"), ok_callback = function()
            local open = (it.path == self.doc_path)
            if self.doc_written or not open then
                if not Storage.removeTree(it.path) then
                    UIManager:show(InfoMessage:new{ text = _("Could not delete it.") })
                    return
                end
            end
            self:dropThumbs(it.path)
            Folder.update(dir, function(d) Folder.forget(d, Storage.baseName(it.path)) end)
            if open then self:discardDocument(dir) end
            self._ov.docs[it.path] = nil
            if self._ov.path == it.path then
                -- show the first notebook left, or the folder when none is
                local first = (self:overviewTabs(dir))[1]
                if not first then
                    self._overview:close()
                    return self:openLibrary(dir)
                end
                self._ov.path = first.path
            end
            self:refreshOverview(true)
        end })
end

return InkAwayView
