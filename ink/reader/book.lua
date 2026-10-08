--[[
Ink Away in the book being read: one of these per open book (made by main.lua
in KOReader's reader). It keeps the book's ink (ink/reader/bookink.lua), knows
where it goes on the page shown (ink/reader/place.lua), paints it over the page
while reading (a KOReader view module), and opens the annotation mode
(ink/reader/inkview.lua).

It costs nothing on a book without ink: opening the book only checks whether
the ink file exists, and painting a page then returns at once. With ink, the
items of the page shown are found from an index built once per layout, and
placed once per page.
]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local BookInk = require("ink/reader/bookink")
local Place = require("ink/reader/place")

local Screen = Device.screen

local Book = {}
Book.__index = Book

function Book.new(ui)
    local self = setmetatable({ ui = ui, rev = 0 }, Book)
    -- the book's KOReader folder (see ink/reader/bookink.lua for where)
    local file = ui.document and ui.document.file
    local ok, where = pcall(BookInk.locate, file)
    if ok and where then self.sidecar, self.dirs = where.dir, where.dirs
    else logger.warn("Ink Away: could not find the book's folder:", where) end
    self.has_file = self.sidecar ~= nil and BookInk.exists(self.sidecar)
    return self
end

-- The book's ink, read the first time it is needed.
function Book:data()
    if not self._data then
        self._data = self.has_file and BookInk.load(self.sidecar) or BookInk.new()
    end
    return self._data
end

function Book:hasInk()
    if self._data then return #self._data.items > 0 end
    return self.has_file
end

function Book:save()
    local data = self:data()
    if data.read_only then return end
    local dirs = { self.sidecar }
    for _i, d in ipairs(self.dirs or {}) do if d ~= self.sidecar then dirs[#dirs + 1] = d end end
    local kept = BookInk.saveAny(dirs, data)
    if kept then self.sidecar = kept
    else
        logger.warn("Ink Away: could not save the book's ink in", self.sidecar)
        if not self._save_warned then
            self._save_warned = true
            local InfoMessage = require("ui/widget/infomessage")
            local _ = require("gettext")
            UIManager:show(InfoMessage:new{ icon = "notice-warning",
                text = _("Ink Away could not save this book's ink: its folder can't be written to.") })
        end
    end
    self.has_file = kept ~= nil and #data.items > 0
    return kept ~= nil
end

------------------------------------------------------------------------------
-- The book, as place.lua asks about it
------------------------------------------------------------------------------

-- The adapter between place.lua and KOReader's document and view.
function Book:doc()
    if self._doc then return self._doc end
    local ui = self.ui
    local document, view = ui.document, ui.view
    local d = {}
    if ui.paging then
        d.kind = "paging"
        function d.toPage(_, x, y)
            local pos = view:screenToPageTransform({ x = x, y = y })
            if not (pos and pos.page) then return nil end
            local zoom = view.state and view.state.zoom or 1
            return pos.page, pos.x, pos.y, zoom
        end
        function d.toScreen(_, page, px, py)
            local Geom = require("ui/geometry")
            local ok, r = pcall(view.pageToScreenTransform, view, page, Geom:new{ x = px, y = py, w = 1, h = 1 })
            if not ok or not r then return nil end
            return r.x, r.y, view.state and view.state.zoom or 1
        end
    else
        d.kind = "rolling"
        function d.width() return Screen:getWidth() end
        function d.wordAt(_, x, y)
            local ok, w = pcall(document.getWordFromPosition, document, { x = x, y = y }, true)
            if ok and w and w.sbox and w.pos0 then return { xp0 = w.pos0, xp1 = w.pos1, box = w.sbox } end
        end
        function d.nearestWord(_, x, y)
            if not document.getNearestWordAndBoxFromPosition then return nil end
            local ok, w = pcall(document.getNearestWordAndBoxFromPosition, document, { x = x, y = y })
            if ok and w and w.sbox and w.pos0 then return { xp0 = w.pos0, xp1 = w.pos1, box = w.sbox } end
        end
        function d.pageTop() return document:getXPointer() end
        function d.pageOf(_, xp)
            local ok, p = pcall(document.getPageFromXPointer, document, xp)
            return ok and p or nil
        end
        function d.boxOf(_, xp0, xp1)
            local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, xp0, xp1, true)
            return ok and boxes and boxes[1] or nil
        end
    end
    self._doc = d
    return d
end

-- The page shown now.
function Book:currentPage()
    local ui = self.ui
    if ui.paging then return ui.view.state and ui.view.state.page or ui.paging.current_page end
    local ok, p = pcall(ui.document.getCurrentPage, ui.document)
    return ok and p or nil
end

-- What changes where a page's ink goes: for a reflowing book its layout (font,
-- margins, size...), for a fixed-page one its zoom and position on the screen.
function Book:layoutKey()
    local ui = self.ui
    if ui.paging then
        local s = ui.view.state or {}
        local va = ui.view.visible_area or {}
        return table.concat({ "p", s.page or 0, s.zoom or 0, s.rotation or 0, va.x or 0, va.y or 0,
            Screen:getWidth(), Screen:getHeight() }, "|")
    end
    local ok, hash = pcall(ui.document.getDocumentRenderingHash, ui.document, false)
    return table.concat({ "r", ok and tostring(hash) or "", ui.document:getPageCount() or 0,
        Screen:getWidth(), Screen:getHeight() }, "|")
end

-- The items on the page shown, as screen ops with the item each came from:
-- { ops = {...}, items = {...} }. Cached until the page, the layout or the ink
-- changes.
function Book:pageOps()
    if not self:hasInk() then return nil end
    local data = self:data()
    local page = self:currentPage()
    local layout = self:layoutKey()
    local key = table.concat({ page or "", layout, self.rev }, "#")
    local c = self._placed
    if c and c.key == key then return c end
    local doc = self:doc()
    -- the page index is built once per layout (for a fixed-page book it is just
    -- the page numbers, so it does not depend on the zoom)
    local ikey = (doc.kind == "paging" and "paging" or layout) .. "#" .. self.rev
    if not (self._index and self._index_key == ikey) then
        self._index = Place.index(data.items, doc)
        self._index_key = ikey
    end
    local out = { key = key, page = page, ops = {}, items = {} }
    for _i, idx in ipairs(self._index[page] or {}) do
        local item = data.items[idx]
        local ok, op = pcall(Place.place, item, doc)
        if ok and op then
            out.ops[#out.ops + 1] = op
            out.items[#out.items + 1] = item
        end
    end
    self._placed = out
    return out
end

-- Replace the ink of the page shown with `ops` (screen ops, from the
-- annotation mode). An op that came back unchanged keeps its item (and its
-- anchor), so ink never drifts from being opened and closed again. Returns the
-- item of each op, for the next time the page is saved.
function Book:setPageOps(ops, came_from)
    local data = self:data()
    local doc = self:doc()
    local page = self:currentPage()
    local keep, map = {}, {}
    for _i, op in ipairs(ops) do
        local item = came_from and came_from[op]
        if not item then item = Place.anchor(op, doc) end
        if item then keep[#keep + 1] = item; map[op] = item end
    end
    -- drop the page's old items, then add these
    local old = {}
    for _i, idx in ipairs((self._index or Place.index(data.items, doc))[page] or {}) do old[data.items[idx]] = true end
    local items = {}
    for _i, item in ipairs(data.items) do if not old[item] then items[#items + 1] = item end end
    for _i, item in ipairs(keep) do items[#items + 1] = item end
    data.items = items
    self.rev = self.rev + 1
    self._placed, self._index = nil, nil
    return map
end

------------------------------------------------------------------------------
-- Painting the ink while reading
------------------------------------------------------------------------------

-- The view module KOReader paints after each page. Returns its widget.
function Book:overlay()
    if self._overlay then return self._overlay end
    local book = self
    self._overlay = {
        hidden = false,
        paintTo = function(this, bb, x, y)
            if this.hidden or not book:hasInk() then return end
            local G = rawget(_G, "G_reader_settings")
            if G and G.readSetting and G:readSetting("inkaway_book_ink") == false then return end
            local ok, err = pcall(book.paintInk, book, bb, x, y)
            if not ok then logger.warn("Ink Away: could not paint the book's ink:", err) end
        end,
    }
    return self._overlay
end

function Book:paintInk(bb, x, y)
    local placed = self:pageOps()
    if not (placed and #placed.ops > 0) then return end
    require("ink/reader/paint").ops(bb, placed.ops, x, y, self)
end

-- Open the annotation mode over the page shown (once: a second call while it is
-- open does nothing).
function Book:annotate()
    if self._view then return end
    if self:data().read_only then
        local InfoMessage = require("ui/widget/infomessage")
        local _ = require("gettext")
        UIManager:show(InfoMessage:new{
            text = _("This book's ink was saved by a newer Ink Away. Update Ink Away to change it.") })
        return
    end
    local ok, ReaderInkView = pcall(require, "ink/reader/inkview")
    if not ok then logger.warn("Ink Away: annotation mode unavailable:", ReaderInkView); return end
    local view = ReaderInkView:new{ book = self }
    self._view = view
    UIManager:show(view)
end

-- The book is closing: close the annotation mode (keeping its ink) and let go.
function Book:close()
    if self._view then pcall(function() self._view:closeCanvas() end) end
    self._view = nil
    self._placed, self._index, self._painter = nil, nil, nil
    require("ink/wash").clearCache()
end

-- Turn the book's page (dir 1 forward, -1 back), as KOReader does.
function Book:turn(dir)
    local Event = require("ui/event")
    self.ui:handleEvent(Event:new("GotoViewRel", dir))
end

-- Paint the page shown into `bb` (screen-sized), without the ink.
function Book:snapshot(bb)
    local ov = self:overlay()
    ov.hidden = true
    local ok, err = pcall(self.ui.view.paintTo, self.ui.view, bb, 0, 0)
    ov.hidden = false
    if not ok then logger.warn("Ink Away: could not draw the page:", err) end
end

-- Repaint the reader (after the ink changed).
function Book:repaint()
    UIManager:setDirty(self.ui.dialog or "all", "ui")
end

return Book
