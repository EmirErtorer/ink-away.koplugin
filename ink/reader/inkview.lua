--[[
Annotating a book: the Ink Away canvas laid over the page being read. It is the
canvas itself (every pen, the eraser, shapes, text, pictures, the lasso, palm
rejection, gestures), started lean and laid out for a book:

  * its page is the screen at 1:1, its background the book's page as the reader
    draws it, and its ops the ink already on that page (ink/reader/book.lua);
  * a narrow toolbar runs down the left side, with the highlighter as a tool of
    its own and the book's page turns;
  * no zoom or pan: the book's own zoom is used;
  * the eraser takes whole strokes away (ink on a book is kept as separate
    strokes anchored to its words, so there is nothing under it to rub out to);
  * saving puts the page's ink back into the book, anchored (the canvas's
    autosave does it every few seconds of rest, a page turn and closing too).
Closing it leaves nothing running: the canvas's own close frees its buffers,
timers and input hooks.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Accent = require("ink/accent")
local Canvas = require("ink/canvas")
local InkAwayView = require("ink/view")
local Paint = require("ink/paint")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen

local ReaderInkView = InkAwayView:extend{
    name = "inkaway_reader_view",
    reader_mode = true,
    book = nil,          -- ink/reader/book.lua
}

------------------------------------------------------------------------------
-- Start and layout
------------------------------------------------------------------------------

-- The reader decides the orientation.
function ReaderInkView:applyStartupOrientation() end
function ReaderInkView:orientationSupported() return false end

-- The toolbar down the left, the area beside it, the page at 1:1 under it: a
-- canvas point is the screen point, so ink lands exactly on the book's words.
function ReaderInkView:initLayout(W, H)
    self:buildToolbar()
    local tw = self.toolbar:getSize().w
    self.view = {
        area_x = tw, area_y = 0, area_w = W - tw, area_h = H,
        canvas_w = W, canvas_h = H,
        zoom = 1, pan_x = tw, pan_y = 0,
    }
    self.zoom_min = 1
    self[1] = self.toolbar
    -- hidden last time: start hidden
    if self:getSetting("inkaway_book_toolbar_hidden", false) then
        self._toolbar_hidden = true
        self.view.area_x, self.view.area_w, self.view.pan_x = 0, W, 0
        self[1] = nil
    end
end

-- What the canvas would open (the last document) is the book's page here.
function ReaderInkView:openStartDocument()
    self.erase_whole = true      -- see the file comment
    self.symmetry = "off"
    self.grid_on = false
    if self.pen_style == "smudge" then self:choosePenType("solid") end
    self:loadBookPage()
end

-- The page shown by the reader, and its ink.
function ReaderInkView:loadBookPage()
    local W, H = self.view.canvas_w, self.view.canvas_h
    if not self.bg_bb then self.bg_bb = Blitbuffer.new(W, H, Screen.bb:getType()) end
    self.book:snapshot(self.bg_bb)
    local placed = self.book:pageOps()
    local ops, from = {}, {}
    for i, op in ipairs(placed and placed.ops or {}) do
        local c = Canvas.cloneOp(nil, op)
        ops[i] = c
        from[c] = placed.items[i]
    end
    self._came_from = from
    self.canvas:setOps(ops)
    self._committed_rev = self.canvas.rev
    self.dirty = false
end

------------------------------------------------------------------------------
-- Saving into the book
------------------------------------------------------------------------------

function ReaderInkView:docChanged()
    return self.canvas ~= nil and self.canvas.rev ~= self._committed_rev
end

function ReaderInkView:saveDocument()
    if not (self.book and self.canvas) or not self:docChanged() then return true end
    local ok, err = pcall(function()
        self._came_from = self.book:setPageOps(self.canvas.ops, self._came_from)
        self.book:save()
    end)
    if not ok then logger.warn("Ink Away: could not keep the page's ink:", err) end
    self._committed_rev = self.canvas.rev
    self.dirty = false
    return ok
end

------------------------------------------------------------------------------
-- Turning the book's pages
------------------------------------------------------------------------------

function ReaderInkView:turnPage(dir)
    self:flushPending()
    self:cancelShape()
    if self.editing_text then self:finishTextEdit(true) end
    self:resetLasso()
    self:saveDocument()
    self.book:turn(dir)
    self:loadBookPage()
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "partial")
end

-- The canvas's page turns (a finger swipe with Finger on the page set to
-- Navigate, a two-finger swipe, the gestures) turn the book's pages.
function ReaderInkView:nbGo(dir) self:turnPage(dir) end
function ReaderInkView:pageSwipes() return true end
function ReaderInkView:sidewaysRoom() return false end

-- No zoom or pan over a book: the reader's own zoom is used.
function ReaderInkView:setZoom() return false end
function ReaderInkView:pinchZoom() end
function ReaderInkView:panByScreen() end

-- Gestures that mean pages or documents act on the book.
function ReaderInkView:runAction(id)
    if id == "next_page" then self:turnPage(1); return true end
    if id == "prev_page" then self:turnPage(-1); return true end
    if id == "browse" or id == "library" then self:openBookNotes(); return true end
    if id == "pan" or id == "fit" or id == "toolbar" then return false end
    return InkAwayView.runAction(self, id)
end

-- The book's notes (see ink/reader/booknotes.lua): leave the book's ink saved
-- and open them over the book.
function ReaderInkView:openBookNotes()
    local book = self.book
    self:closeCanvas()
    if book and book.openNotes then book:openNotes() end
end

-- A turned screen lays the book out again: keep the ink and leave.
function ReaderInkView:onSetDimensions()
    self:closeCanvas()
end

function ReaderInkView:onCloseWidget()
    InkAwayView.onCloseWidget(self)
    if self.book then
        self.book._view = nil
        self.book:repaint()
    end
end

------------------------------------------------------------------------------
-- The toolbar, down the left side
------------------------------------------------------------------------------

-- The highlighter is a tool of its own here: the pen with the highlighter's
-- settings. The Pen goes back to the pen in hand before it.
function ReaderInkView:highlighterActive()
    return self.tool == "pen" and self.pen_style == "highlighter"
end

function ReaderInkView:buildToolbar()
    local specs = {
        { id = "pen", icon = "pen", tool = true, cb = function()
            if self:highlighterActive() then
                if not self:swapPen() then self:choosePenType("solid") end
                self:setTool("pen"); self:refreshToolLabels()
            elseif self.tool == "pen" then self:openPenSettings()
            else self:setTool("pen") end
        end },
        { id = "highlight", icon = "highlighter", tool = true, cb = function()
            if self:highlighterActive() then self:openPenSettings()
            else self:choosePenType("highlighter"); self:setTool("pen"); self:refreshToolLabels() end
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
        { id = "prev", icon = "nav_prev", cb = function() self:turnPage(-1) end },
        { id = "next", icon = "nav_next", cb = function() self:turnPage(1) end },
        { id = "notes", icon = "booknotes", cb = function() self:openBookNotes() end },
        { id = "menu", icon = "menu", cb = function() self:openReaderSettings() end },
        { id = "exit", icon = "exit", cb = function() self:closeCanvas() end },
    }
    self:ensureUserIcons()
    local H = Screen:getHeight()
    local n = #specs
    local btn_h = math.floor(H / n)
    local bar_w = math.max(Screen:scaleBySize(36), math.min(Screen:scaleBySize(50), math.floor(btn_h * 1.15)))
    local isz = math.max(18, math.min(math.floor(bar_w * 0.6), math.floor(btn_h * 0.62)))
    self._btn_h, self._bar_w, self._icon_sz = btn_h, bar_w, isz
    self.tool_buttons, self._toolbar_icons = {}, {}
    local col = VerticalGroup:new{ align = "center" }
    for i, s in ipairs(specs) do
        local h = (i == n) and (H - btn_h * (n - 1)) or btn_h
        local raw = s.cb
        local b = Button:new{ icon = "inkaway." .. s.icon, icon_width = isz, icon_height = isz,
            callback = function()
                local ok, err = xpcall(raw, debug.traceback)
                if not ok then logger.warn("Ink Away book toolbar '" .. s.id .. "' failed: " .. tostring(err)) end
            end,
            width = bar_w, height = h, bordersize = 0, radius = 0, background = nil,
            margin = 0, padding = 0, show_parent = self }
        local path = self:pluginDir() .. "ink/icons/" .. s.icon .. ".svg"
        local ok_icon, icon = pcall(function() return IconWidget:new{ file = path, width = isz, height = isz } end)
        if ok_icon and icon then self:setButtonLabel(b, icon) end
        if b.frame then b.frame.background = nil end
        if s.tool then self.tool_buttons[s.id] = { button = b } end
        self._toolbar_icons[i] = { button = b, id = s.id, tool = s.tool == true,
            icon = ok_icon and icon or nil, path = path, size = isz }
        table.insert(col, b)
    end
    self.toolbar = FrameContainer:new{ background = nil, bordersize = 0, padding = 0, margin = 0, col }
    self._bar_h = nil        -- the canvas's horizontal-bar measures do not apply
    self:updateToolbarActive()
end

function ReaderInkView:updateToolbarActive()
    if not self._toolbar_icons then return end
    local active = (self.tool == "fill") and "shape" or self.tool
    if self:highlighterActive() then active = "highlight" end
    self._active_btn_idx = nil
    for i, e in ipairs(self._toolbar_icons) do
        if e.tool and e.button then
            local on = (e.id == active)
            if on then self._active_btn_idx = i end
            local tinted = on and e.path and Accent.icon(e.path, e.size)
            if tinted then
                self:setButtonLabel(e.button, ImageWidget:new{ image = tinted, width = e.size, height = e.size,
                    image_disposable = false })
            elseif e.icon then
                if e.button.label_widget ~= e.icon then self:setButtonLabel(e.button, e.icon) end
                e.icon.invert = on
            end
        end
    end
end

function ReaderInkView:drawActiveToolPill(bb, ox, oy)
    if not (self._active_btn_idx and self._btn_h and self._bar_w) then return end
    local m = Screen:scaleBySize(5)
    local cy = oy + self._btn_h * (self._active_btn_idx - 1)
    Accent.paintRounded(bb, ox + m, cy + m, self._bar_w - 2 * m, self._btn_h - 2 * m, Screen:scaleBySize(9))
end

-- The hairline between the toolbar and the page.
function ReaderInkView:drawToolbarIcons(bb)
    if not self._bar_w then return end
    bb:paintRect(self._bar_w - 1, 0, 1, self.screen_h, Paint.HAIRLINE)
end

------------------------------------------------------------------------------
-- Hiding the toolbar
------------------------------------------------------------------------------

-- Over a book the only floating control is the toolbar's tab: a small chevron
-- at the top, beside the toolbar (it slides the toolbar away) or at the left
-- edge once it is hidden (it brings it back). No zoom or Pan buttons.
function ReaderInkView:fabRect(which)
    if which ~= "bar" or not self.view then return nil end
    local w, h = Screen:scaleBySize(24), Screen:scaleBySize(40)
    local x = self._toolbar_hidden and Screen:scaleBySize(2) or (self._bar_w or 0) + Screen:scaleBySize(2)
    return { x = x, y = Screen:scaleBySize(8), w = w, h = h }
end

function ReaderInkView:fabHit(px, py)
    if self._bar_toggle_hidden or self.editing_text then return nil end
    local r = self:fabRect("bar")
    if r and px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h then return "bar" end
    return nil
end

-- The tab: a light rounded tab with a chevron pointing where the toolbar goes.
function ReaderInkView:drawFabs(bb)
    if self._bar_toggle_hidden or self.editing_text then return end
    local r = self:fabRect("bar")
    if not r then return end
    local fill, edge = Blitbuffer.Color8(0xF0), Blitbuffer.Color8(0xB4)
    bb:paintRoundedRect(r.x, r.y, r.w, r.h, edge, Screen:scaleBySize(8))
    local b = Screen:scaleBySize(1)
    bb:paintRoundedRect(r.x + b, r.y + b, r.w - 2 * b, r.h - 2 * b, fill, Screen:scaleBySize(7))
    -- the chevron: two short strokes, < when shown (hide), > when hidden (show)
    local cx, cy = r.x + math.floor(r.w / 2), r.y + math.floor(r.h / 2)
    local s = Screen:scaleBySize(6)
    local t = math.max(2, Screen:scaleBySize(2))
    local dir = self._toolbar_hidden and 1 or -1
    for i = 0, s do
        local x = cx - dir * math.floor(s / 2) + dir * i
        bb:paintRect(x, cy - s + i, t, t, Blitbuffer.COLOR_BLACK)
        bb:paintRect(x, cy + s - i - t + 1, t, t, Blitbuffer.COLOR_BLACK)
    end
end

-- Slide the toolbar away (or back): the page then fills the screen's width.
function ReaderInkView:setToolbarHidden(hidden)
    if (self._toolbar_hidden or false) == hidden then return end
    self:flushPending()
    self._toolbar_hidden = hidden
    self:setSetting("inkaway_book_toolbar_hidden", hidden)
    self._area_only = false
    local v = self.view
    local tw = hidden and 0 or self.toolbar:getSize().w
    v.area_x, v.area_w, v.pan_x = tw, self.screen_w - tw, tw
    if hidden then self[1] = nil else self[1] = self.toolbar end
    if self.area_bb then self.area_bb:free() end
    self.area_bb = self:newAreaBuffer()
    self:renderView()
    UIManager:setDirty(self, "ui")
end

------------------------------------------------------------------------------
-- The book's settings
------------------------------------------------------------------------------

function ReaderInkView:openReaderSettings()
    if self:rebuildSheet("_settings_dialog") then return end
    self:ensureUserIcons()
    local content_w = self:sheetWidth()
    local function closeSelf() self:closeSheet("_settings_dialog") end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Book ink"), content_w, _("Done"), closeSelf))
        add(VerticalSpan:new{ width = Screen:scaleBySize(12) })
        add(ToggleRow:new{ label = _("Show ink while reading"), is_on = self:getSetting("inkaway_book_ink", true) ~= false,
            width = content_w, parent = menu,
            callback = function(on) self:setSetting("inkaway_book_ink", on) end })
        add(VerticalSpan:new{ width = Screen:scaleBySize(10) })
        add(ToggleRow:new{ label = _("Highlighter snaps to the text"),
            is_on = self:getSetting("inkaway_snap_text", true) ~= false,
            width = content_w, parent = menu,
            callback = function(on) self:setSetting("inkaway_snap_text", on) end })
        add(VerticalSpan:new{ width = Screen:scaleBySize(4) })
        add(self:sheetHint(_("A highlighter stroke along lines of text becomes a highlight of that text, which stays with it at any font size."), content_w))
        add(VerticalSpan:new{ width = Screen:scaleBySize(14) })
        add(self:actionButton(_("Pen and input"), content_w, function() closeSelf(); self:openPenInput() end))
        add(VerticalSpan:new{ width = Screen:scaleBySize(8) })
        add(self:actionButton(_("Gestures and pen buttons"), content_w, function()
            closeSelf(); self:openGestureSettings() end))
        return content
    end
    self:showSheet("_settings_dialog", build)
end

-- The gear in the canvas's sheets opens these over a book.
function ReaderInkView:openSettings() self:openReaderSettings() end

return ReaderInkView
