--[[
Book notes: the book's notebook (ink/reader/booknotes.lua) in a window over the
page being read, with the book still showing around it. It is the canvas
itself, laid out small:

  * the page is the notebook's real page (the size of the screen, as every Ink
    Away page), shown whole at about two thirds of its size, so what is written
    in the window is the same page the app shows; Fullscreen turns this same
    view into the normal app, with nothing reopened;
  * the narrow toolbar down the left (ink/reader/vbar.lua), a strip with the
    chapter and the page number above the page;
  * opening it in a chapter goes to that chapter's last page, or to a new page
    titled with the chapter, put where the chapter comes in the book; a new
    page left empty is taken out again on closing;
  * a tap outside the window closes it, saved.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local BookNotes = require("ink/reader/booknotes")
local InkAwayView = require("ink/view")
local InkGeom = require("ink/geom")
local Project = require("ink/project")
local Storage = require("ink/storage")
local VBar = require("ink/reader/vbar")

local Screen = Device.screen

local NotesView = InkAwayView:extend{
    name = "inkaway_booknotes",
    over_book = true,    -- the reader keeps its orientation; no start sheets
    floating = true,     -- a window over the book, until Fullscreen
    book = nil,          -- ink/reader/book.lua
    behind_bb = nil,     -- the book's page as it was, shown around the window
}

-- The window uses the narrow toolbar; once full screen, the canvas's own.
NotesView.buildVBar = VBar.buildVBar
NotesView.vbarActive = VBar.vbarActive
NotesView.vbarHas = VBar.vbarHas
NotesView.vbarCell = VBar.vbarCell
for _i, k in ipairs({ "updateToolbarActive", "drawActiveToolPill", "drawToolbarIcons" }) do
    NotesView[k] = function(self, ...)
        if self.floating then return VBar[k](self, ...) end
        return InkAwayView[k](self, ...)
    end
end

local SCALE = 0.70        -- the page in the window, of its full size at most

function NotesView:init()
    InkAwayView.init(self)
    -- over a book the notes are what opens, never the library
    self._library_on_show, self._overview_on_show = nil, nil
end

-- The reader decides the orientation.
function NotesView:applyStartupOrientation() end
function NotesView:orientationSupported() return false end

------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------

function NotesView:initLayout(W, H)
    if not self.floating then return InkAwayView.initLayout(self, W, H) end
    self:layoutWindow()
end

-- The window: the toolbar, then the strip over the page shown whole, centred
-- on the screen.
function NotesView:layoutWindow()
    local W, H = self.screen_w, self.screen_h
    local strip = Screen:scaleBySize(30)
    local z = math.min(SCALE, (H * 0.94 - strip) / H)
    for _pass = 1, 2 do
        self._panel_h = math.floor(H * z) + strip
        self:buildToolbar()
        local room = (W * 0.96 - self._bar_w) / W   -- the toolbar beside the page must fit too
        if z <= room then break end
        z = room
    end
    local aw, ah = math.floor(W * z), math.floor(H * z)
    local pw, ph = self._bar_w + aw, strip + ah
    local px, py = math.floor((W - pw) / 2), math.floor((H - ph) / 2)
    self._panel = { x = px, y = py, w = pw, h = ph }
    self._strip = { x = px + self._bar_w, y = py, w = aw, h = strip }
    self._bar_x, self._bar_y = px, py
    self.view = {
        area_x = px + self._bar_w, area_y = py + strip, area_w = aw, area_h = ah,
        canvas_w = W, canvas_h = H,
        zoom = math.min(aw / W, ah / H), pan_x = 0, pan_y = 0,
    }
    self.zoom_min = self.view.zoom
    InkGeom.clampPan(self.view)
    self[1] = self.toolbar
end

function NotesView:buildToolbar()
    if not self.floating then return InkAwayView.buildToolbar(self) end
    local specs = {
        { id = "pen", icon = "pen", tool = true, cb = function()
            if self.tool == "pen" then self:openPenSettings() else self:setTool("pen") end
        end },
        { id = "erase", icon = "eraser", tool = true, cb = function()
            if self.tool == "erase" then self:openEraserSettings() else self:setTool("erase") end
        end },
        { id = "lasso", icon = "lasso", tool = true, cb = function() self:setTool("lasso") end },
        { id = "shape", icon = "shape", tool = true, cb = function()
            if self.tool == "shape" then self:openShapePicker() else self:setTool("shape") end
        end },
        { id = "text", icon = "text", tool = true, cb = function()
            if self.editing_text then self:finishTextEdit(true)
            elseif self.tool == "text" then self:openTextSettings()
            else self:setTool("text") end
        end },
        { id = "image", icon = "image", cb = function() self:chooseImage() end },
        { id = "undo", icon = "undo", cb = function() self:undo() end },
        { id = "redo", icon = "redo", cb = function() self:redo() end },
        { id = "prev", icon = "nav_prev", cb = function() self:nbGo(-1) end },
        { id = "next", icon = "nav_next", cb = function() self:nbGo(1) end },
        { id = "add", icon = "newpage", cb = function() self:nbAddPage() end },
        { id = "full", icon = "fullscreen", cb = function() self:expand() end },
        { id = "exit", icon = "exit", cb = function() self:closeCanvas() end },
    }
    self:buildVBar(specs, self._panel_h or self.screen_h)
end

-- In the window there is no page bar (the toolbar turns the pages) and no zoom.
function NotesView:nbBarHeight()
    if self.floating then return 0 end
    return InkAwayView.nbBarHeight(self)
end

function NotesView:recomputeArea()
    if not self.floating then return InkAwayView.recomputeArea(self) end
    self:layoutWindow()
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
end

function NotesView:relayout()
    if not self.floating then return InkAwayView.relayout(self) end
    self:recomputeArea()
    self:renderView()
    self._area_only = false
end

function NotesView:setToolbarHidden(hidden)
    if not self.floating then return InkAwayView.setToolbarHidden(self, hidden) end
end

function NotesView:setNbBarHidden(hidden)
    if not self.floating then return InkAwayView.setNbBarHidden(self, hidden) end
end

function NotesView:setZoom(...)
    if self.floating then return false end
    return InkAwayView.setZoom(self, ...)
end

function NotesView:pinchZoom(...)
    if not self.floating then return InkAwayView.pinchZoom(self, ...) end
end

function NotesView:panByScreen(...)
    if not self.floating then return InkAwayView.panByScreen(self, ...) end
end

-- No floating buttons in the window.
function NotesView:fabRect(which)
    if self.floating then return nil end
    return InkAwayView.fabRect(self, which)
end

function NotesView:fabHit(px, py)
    if self.floating then return nil end
    return InkAwayView.fabHit(self, px, py)
end

function NotesView:drawFabs(...)
    if not self.floating then return InkAwayView.drawFabs(self, ...) end
end

-- A turned screen lays the book out again: keep the notes and leave.
function NotesView:onSetDimensions()
    self:closeCanvas()
end

------------------------------------------------------------------------------
-- Painting the window
------------------------------------------------------------------------------

-- The book around the window, the window's frame, and the strip with the
-- chapter and the page number.
function NotesView:paintSurround(bb, x, y)
    if not self.floating then return InkAwayView.paintSurround(self, bb, x, y) end
    local W, H = self.screen_w, self.screen_h
    if self.behind_bb then bb:blitFrom(self.behind_bb, x, y, 0, 0, W, H)
    else bb:paintRect(x, y, W, H, Blitbuffer.COLOR_WHITE) end
    local p = self._panel
    local b = Screen:scaleBySize(2)
    bb:paintRect(x + p.x - b, y + p.y - b, p.w + 2 * b, p.h + 2 * b, Blitbuffer.COLOR_BLACK)
    bb:paintRect(x + p.x, y + p.y, p.w, p.h, Blitbuffer.COLOR_WHITE)
    local s = self._strip
    local tw = self:stripText()
    if tw then
        local sz = tw:getSize()
        tw:paintTo(bb, x + s.x + Screen:scaleBySize(8), y + s.y + math.floor((s.h - sz.h) / 2))
    end
    bb:paintRect(x + s.x, y + s.y + s.h - 1, s.w, 1, Blitbuffer.COLOR_GRAY_9)
end

-- "Chapter · 2/5", made again only when it changes.
function NotesView:stripText()
    local nb = self.notebook
    if not nb then return nil end
    local page = nb.pages[nb.index]
    local name = (page and page.title and page.title ~= "") and page.title or self:docName()
    local text = string.format("%s \u{00B7} %d/%d", name, nb.index, nb:count())
    if self._strip_w and self._strip_text == text then return self._strip_w end
    if self._strip_w then self._strip_w:free() end
    self._strip_text = text
    self._strip_w = TextWidget:new{ text = text, face = Font:getFace("smallinfofont"),
        max_width = self._strip.w - Screen:scaleBySize(16) }
    return self._strip_w
end

-- A page turn changes the strip, which is chrome: paint it all.
function NotesView:nbLoad(...)
    InkAwayView.nbLoad(self, ...)
    if self.floating then self._paint_all = true; UIManager:setDirty(self, "ui") end
end

------------------------------------------------------------------------------
-- Touch
------------------------------------------------------------------------------

local function inRect(pos, r)
    return pos and r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

-- A tap outside the window closes it.
function NotesView:onIaTap(arg, ges)
    if self.floating and ges and ges.pos and not inRect(ges.pos, self._panel) then
        self:closeCanvas()
        return true
    end
    return InkAwayView.onIaTap(self, arg, ges)
end

-- A swipe that starts on the book around the window does nothing.
function NotesView:onIaSwipe(arg, ges)
    if self.floating and ges and ges.pos and not inRect(ges.pos, self._panel) then return true end
    return InkAwayView.onIaSwipe(self, arg, ges)
end

------------------------------------------------------------------------------
-- The book's notebook
------------------------------------------------------------------------------

-- The notebook the book's notes are in: the one it was last saved as, else one
-- named after the book in the "Book notes" folder (with the author when
-- another book of that name has it).
function NotesView:notesPathFor(info)
    local linked = self.book:notesPath()
    if linked and Storage.exists(linked) then return linked end
    local dir = Storage.join(self:libraryDir(), BookNotes.FOLDER)
    local path = Storage.join(dir, BookNotes.fileName(info.title) .. "." .. Project.EXT)
    if Storage.exists(path) then
        local data = Project.load(path)
        if data and BookNotes.otherBook(data.pages, info.md5) then
            local name = BookNotes.fileName(info.author and (info.title .. " (" .. info.author .. ")") or info.title)
            path = Storage.join(dir, name .. "." .. Project.EXT)
            if Storage.exists(path) then
                local d2 = Project.load(path)
                if d2 and BookNotes.otherBook(d2.pages, info.md5) then
                    path = Storage.uniquePath(dir, name, Project.EXT)
                end
            end
        end
    end
    return path
end

function NotesView:openStartDocument()
    local info = self.book:notesInfo()
    local path = self:notesPathFor(info)
    if not (Storage.exists(path) and self:openDocument(path)) then
        self:startNotebook({ style = self.nb_style,
            size = self.nb_size or self.grid_size or 40,
            strength = self.nb_strength or self.grid_strength or 45 })
        self.doc_path, self.doc_written = path, false
        self:resetSaveState()
    end
    if self.notebook then self:goToChapter(info) end
end

-- The chapter's last page, or a new page for it in the book's order.
function NotesView:goToChapter(info)
    local nb = self.notebook
    local place = BookNotes.placeFor(nb.pages, info.key)
    local tag = info.key and { toc = info.key, md5 = info.md5 } or nil
    local title = info.chapter and info.chapter ~= "" and info.chapter or nil
    if place.claim then
        local p = nb.pages[1]
        p.book, p.title = tag, p.title or title
        self:nbLoad()
    elseif place.insert then
        local page = nb:newPage()
        page.title, page.book = title, tag
        local at = nb:insertPage(page, place.insert)
        self._fresh_page = page
        self:markDirty()
        self:nbGoTo(at)
    else
        self:nbGoTo(place.index)
    end
end

-- A chapter page opened for this visit and left empty goes again.
function NotesView:pruneFreshPage()
    local nb, page = self.notebook, self._fresh_page
    self._fresh_page = nil
    if not (nb and page) or nb:count() <= 1 then return end
    if nb.pages[nb.index] == page then self:nbSyncOut() end
    if #(page.ops or {}) > 0 then return end
    for i, p in ipairs(nb.pages) do
        if p == page then
            table.remove(nb.pages, i)
            if nb.index >= i then nb.index = math.max(1, nb.index - 1) end
            nb.index = math.min(nb.index, #nb.pages)
            self.dirty = true
            return
        end
    end
end

-- The "Book notes" folder is made with the notebook's first save.
function NotesView:saveDocument(force)
    if self.doc_path and not self.doc_written then Storage.ensureDir(Storage.dirName(self.doc_path)) end
    return InkAwayView.saveDocument(self, force)
end

-- In the window the notes are not the app's last document; full screen they are.
function NotesView:rememberDoc(path)
    if not self.floating then return InkAwayView.rememberDoc(self, path) end
end

------------------------------------------------------------------------------
-- Full screen, and closing
------------------------------------------------------------------------------

-- The same view, now the normal app over the whole screen: its toolbar, page
-- bar and zoom, the same page.
function NotesView:expand()
    if not self.floating then return end
    self:flushPending()
    self:resetLasso()
    self.floating = false
    self._bar_x, self._bar_y = nil, nil
    if self.behind_bb then self.behind_bb:free(); self.behind_bb = nil end
    if self._strip_w then self._strip_w:free(); self._strip_w = nil end
    InkAwayView.initLayout(self, self.screen_w, self.screen_h)
    self.nb_bar_h = self:nbBarHeight()
    InkAwayView.recomputeArea(self)
    self:renderView()
    self:updateToolbarActive()
    if self.doc_written then InkAwayView.rememberDoc(self, self.doc_path) end
    self._paint_all = true
    UIManager:setDirty(self, "full")
end

function NotesView:onCloseWidget()
    local book = self.book
    if book and book._notes_view == self then book._notes_view = nil end   -- first (see ReaderInkView)
    self:pruneFreshPage()
    InkAwayView.onCloseWidget(self)
    if book and self.doc_written and self.doc_path then book:setNotesPath(self.doc_path) end
end

function NotesView:free()
    if self.behind_bb then self.behind_bb:free(); self.behind_bb = nil end
    if self._strip_w then self._strip_w:free(); self._strip_w = nil end
    InkAwayView.free(self)
end

return NotesView
