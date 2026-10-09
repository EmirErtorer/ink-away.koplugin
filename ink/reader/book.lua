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
local Canvas = require("ink/canvas")
local Place = require("ink/reader/place")
local Snap = require("ink/reader/snap")

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
    self.has_file = kept ~= nil and (#data.items > 0 or data.notes ~= nil)
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
        -- the page's place on the screen, as the reader draws it (its own
        -- transform gives nothing for a point just off the screen, which
        -- would hide a stroke that starts above the visible part)
        function d.toScreen(_, page, px, py)
            if view.page_scroll then
                local y = 0
                for _i, st in ipairs(view.page_states or {}) do
                    if st.page == page then
                        return st.offset.x + px * st.zoom - st.visible_area.x,
                            y + st.offset.y + py * st.zoom - st.visible_area.y, st.zoom
                    end
                    y = y + st.visible_area.h + (view.page_gap and view.page_gap.height or 0)
                end
                return nil
            end
            local st = view.state
            if not (st and st.page == page and view.visible_area) then return nil end
            return st.offset.x + px * st.zoom - view.visible_area.x,
                st.offset.y + py * st.zoom - view.visible_area.y, st.zoom
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

-- The page shown now (the first, when more than one is).
function Book:currentPage()
    local ui = self.ui
    if ui.paging then return ui.view.state and ui.view.state.page or ui.paging.current_page end
    local ok, p = pcall(ui.document.getCurrentPage, ui.document)
    return ok and p or nil
end

-- Every page on the screen: one, or two side by side, or the pages a
-- continuous scroll shows.
function Book:visiblePages()
    local ui = self.ui
    if ui.paging then
        local view = ui.view
        if view.page_scroll and view.page_states and #view.page_states > 0 then
            local pages = {}
            for _i, st in ipairs(view.page_states) do pages[#pages + 1] = st.page end
            return pages
        end
        return { self:currentPage() }
    end
    local p = self:currentPage()
    if not p then return {} end
    local doc = ui.document
    local two = (ui.view and ui.view.view_mode == "scroll")
        or (doc.getVisiblePageCount and doc:getVisiblePageCount() == 2)
    if two and p < (doc:getPageCount() or p) then return { p, p + 1 } end
    return { p }
end

-- What changes where a page's ink goes: for a reflowing book its layout (font,
-- margins, size...), for a fixed-page one its zoom and position on the screen.
function Book:layoutKey()
    local ui = self.ui
    if ui.paging then
        local view = ui.view
        local parts = { "p", Screen:getWidth(), Screen:getHeight() }
        local states = view.page_scroll and view.page_states or { view.state or {} }
        for _i, st in ipairs(states) do
            local va = view.page_scroll and st.visible_area or view.visible_area or {}
            local off = st.offset or {}
            parts[#parts + 1] = table.concat({ st.page or 0, st.zoom or 0, st.rotation or 0,
                va.x or 0, va.y or 0, off.x or 0, off.y or 0 }, ",")
        end
        return table.concat(parts, "|")
    end
    local ok, hash = pcall(ui.document.getDocumentRenderingHash, ui.document, false)
    local top = ui.view and ui.view.view_mode == "scroll" and ui.document:getCurrentPos() or ""
    return table.concat({ "r", ok and tostring(hash) or "", ui.document:getPageCount() or 0,
        Screen:getWidth(), Screen:getHeight(), top }, "|")
end

-- The items on the pages shown, as screen ops with the item each came from:
-- { ops = {...}, items = {...} }. Cached until the page, the layout or the ink
-- changes.
function Book:pageOps()
    if not self:hasInk() then return nil end
    local data = self:data()
    local pages = self:visiblePages()
    local layout = self:layoutKey()
    local key = table.concat({ table.concat(pages, ","), layout, self.rev }, "#")
    local c = self._placed
    if c and c.key == key then return c end
    local doc = self:doc()
    -- the page index is built once per layout (for a fixed-page book it is just
    -- the page numbers, so it does not depend on the zoom; for a reflowing one
    -- the scroll position, the layout key's last part, does not count)
    if layout ~= self._layout_last then
        self._layout_last = layout
        self._ikey_base = doc.kind == "paging" and "paging" or (layout:gsub("|[^|]*$", ""))
    end
    local ikey = self._ikey_base .. "#" .. self.rev
    if not (self._index and self._index_key == ikey) then
        self._index = Place.index(data.items, doc)
        self._index_key = ikey
    end
    local out = { key = key, pages = pages, ops = {}, items = {} }
    local W, H = Screen:getWidth(), Screen:getHeight()
    for _p, page in ipairs(pages) do
        for _i, item in ipairs(self._index[page] or {}) do
            local ok, op = pcall(Place.place, item, doc)
            if ok and op and op.kind == "image" then op.path = BookInk.picturePath(self.sidecar, op.path) end
            -- only what reaches the screen (a page scrolled half away keeps
            -- the rest of its ink out of the way, untouched)
            local x0, y0, x1, y1
            if ok and op then x0, y0, x1, y1 = Canvas.opBox(op) end
            if x0 and x1 >= 0 and y1 >= 0 and x0 < W and y0 < H then
                out.ops[#out.ops + 1] = op
                out.items[#out.items + 1] = item
            end
        end
    end
    self._placed = out
    return out
end

-- Replace the ink shown (`shown`, the items the annotation mode was given) with
-- `ops` (screen ops). An op that came back unchanged keeps its item (and its
-- anchor), so ink never drifts from being opened and closed again; ink that
-- was not shown is never touched. Returns the item of each op and the items
-- now shown, for the next time the page is saved.
function Book:setPageOps(ops, came_from, shown)
    local data = self:data()
    local doc = self:doc()
    local keep, map = {}, {}
    local shape_anchor = {}   -- a cut shape's anchor, shared by its pieces
    for _i, op in ipairs(ops) do
        -- (an eraser stroke, a link or a smudge is never kept over a book: the
        -- eraser cuts strokes instead, see ink/cut.lua)
        local k = op.kind
        local src = op.cut_of
        if src then op.cut_of = nil end   -- a passing note, never saved
        local item = came_from and came_from[op]
        if not item and (k == "erase" or k == "link" or k == "smudge") then item = false end
        if item == nil and src then
            local a = shape_anchor[src]
            if not a then
                local base = (came_from and came_from[src]) or Place.anchor(src, doc)
                a = base and base.a or false
                shape_anchor[src] = a
            end
            if a then item = Place.anchorWith(op, doc, a) end
        end
        if item == nil then
            item = Place.anchor(op, doc)
            -- a picture is kept in the book's folder, so the book's ink never
            -- loses it (see ink/reader/bookink.lua)
            if item and item.op.kind == "image" then item.op.path = BookInk.keepPicture(self.sidecar, item.op.path) end
        end
        if item then keep[#keep + 1] = item; map[op] = item end
    end
    local old, n_old = {}, 0
    for _i, item in ipairs(shown or {}) do
        if not old[item] then old[item] = true; n_old = n_old + 1 end
    end
    local items = {}
    for _i, item in ipairs(data.items) do if not old[item] then items[#items + 1] = item end end
    for _i, item in ipairs(keep) do items[#items + 1] = item end
    data.items = items
    -- the page index follows, changed only on the pages shown, so it is not
    -- built again for the whole book after every stroke (it is when an old
    -- item is not where it was expected)
    local idx = self._index
    if idx then
        local page_of, found = {}, 0
        for _p, p in ipairs(self:visiblePages()) do
            local l = idx[p]
            if l then
                local rest = {}
                for _i, it in ipairs(l) do
                    if old[it] then page_of[it] = p; found = found + 1 else rest[#rest + 1] = it end
                end
                idx[p] = rest
            end
        end
        if found < n_old then
            idx = nil
        else
            for _i, it in ipairs(keep) do
                local p = page_of[it] or Place.pageOf(it, doc)
                if p then
                    local l = idx[p]
                    if not l then l = {}; idx[p] = l end
                    l[#l + 1] = it
                end
            end
        end
    end
    self.rev = self.rev + 1
    self._index = idx
    if idx and self._ikey_base then self._index_key = self._ikey_base .. "#" .. self.rev end
    self._placed = nil
    return map, keep
end

------------------------------------------------------------------------------
-- The smart highlighter: the reader's own highlights
------------------------------------------------------------------------------

-- A highlighter stroke along a line of text, made the reader's own highlight of
-- that text (in the reader's highlight style, in the colour nearest the pen's).
-- Returns the highlight, or nil when it is not along text (it stays ink).
function Book:highlight(op)
    local ui = self.ui
    local hl, document = ui.highlight, ui.document
    if not (hl and hl.saveHighlight and ui.annotation and document.getTextFromPositions) then return nil end
    local line = Snap.lineOf(op)
    if not line then return nil end
    local sel, boxes
    if ui.paging then
        -- the text is found on the page, in page units
        local a = ui.view:screenToPageTransform({ x = line.x0, y = line.y })
        local b = ui.view:screenToPageTransform({ x = line.x1, y = line.y })
        if not (a and b and a.page and a.page == b.page) then return nil end
        local ok, r = pcall(document.getTextFromPositions, document, a, b)
        sel = ok and r or nil
        boxes = sel and sel.pboxes
        line = { x0 = a.x, x1 = b.x, y = a.y, h = line.h / (a.zoom or 1) }
    else
        local ok, r = pcall(document.getTextFromPositions, document,
            { x = line.x0, y = line.y }, { x = line.x1, y = line.y }, true)
        sel = ok and r or nil
        boxes = sel and sel.sboxes
    end
    if not (sel and sel.pos0 and sel.pos1 and type(sel.text) == "string" and sel.text:match("%S")) then return nil end
    if not Snap.covers(boxes, line) then return nil end
    local hv = ui.view.highlight or {}
    local Blitbuffer = require("ffi/blitbuffer")
    return self:addHighlight({
        text = sel.text, pos0 = sel.pos0, pos1 = sel.pos1, pboxes = sel.pboxes, ext = sel.ext,
        drawer = hv.saved_drawer,
        color = Snap.colourName(op.color, hv.saved_color, Blitbuffer.HIGHLIGHT_COLORS),
    })
end

-- Save a highlight as the reader does (in its list, written into a PDF when the
-- reader is set to): `sel` is the selection. Returns the highlight.
function Book:addHighlight(sel)
    local ui = self.ui
    local hl = ui.highlight
    hl.selected_text = sel
    local ok, index = pcall(hl.saveHighlight, hl)
    hl.selected_text = nil
    if ui.rolling then pcall(ui.document.clearSelection, ui.document) end
    if not (ok and index) then
        if not ok then logger.warn("Ink Away: could not save the highlight:", index) end
        return nil
    end
    return ui.annotation.annotations[index]
end

-- Take a highlight away again (undo).
function Book:removeHighlight(item)
    local ui = self.ui
    for i, it in ipairs(ui.annotation and ui.annotation.annotations or {}) do
        if it == item then
            pcall(ui.highlight.deleteHighlight, ui.highlight, i)
            return true
        end
    end
    return false
end

-- Put a removed highlight back (redo). Returns it as saved now.
function Book:restoreHighlight(item)
    return self:addHighlight({ text = item.text, pos0 = item.pos0, pos1 = item.pos1, pboxes = item.pboxes,
        ext = item.ext, drawer = item.drawer, color = item.color, note = item.note })
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

-- Close what Ink Away has open over the book (keeping everything): the screen
-- turned, and they were laid out for the old one.
function Book:closeViews()
    if self._view then pcall(function() self._view:closeCanvas() end) end
    if self._notes_view then pcall(function() self._notes_view:closeCanvas() end) end
end

-- The book is closing: close the annotation mode (keeping its ink) and let go.
function Book:close()
    if self._view then pcall(function() self._view:closeCanvas() end) end
    if self._notes_view then pcall(function() self._notes_view:closeCanvas() end) end
    self._view, self._notes_view = nil, nil
    -- pictures no longer shown go now (not at each save, so an undo could still
    -- bring one back while the book was open)
    if self._data and not self._data.read_only then pcall(BookInk.prunePictures, self.sidecar, self._data.items) end
    self._placed, self._index, self._painter = nil, nil, nil
    require("ink/wash").clearCache()
end

-- Turn the book's page (dir 1 forward, -1 back), as KOReader does.
function Book:turn(dir)
    local Event = require("ui/event")
    self.ui:handleEvent(Event:new("GotoViewRel", dir))
end

-- Paint the page shown into `bb` (screen-sized), without the ink unless
-- `with_ink`.
function Book:snapshot(bb, with_ink)
    local ov = self:overlay()
    ov.hidden = not with_ink
    local ok, err = pcall(self.ui.view.paintTo, self.ui.view, bb, 0, 0)
    ov.hidden = false
    if not ok then logger.warn("Ink Away: could not draw the page:", err) end
end

------------------------------------------------------------------------------
-- Book notes (ink/reader/notesview.lua)
------------------------------------------------------------------------------

-- What the notes need to know: the book's title and author, its checksum, and
-- the chapter shown ({ key = its place in the contents, chapter = its title }).
function Book:notesInfo()
    local ui = self.ui
    local props = ui.doc_props or {}
    local file = ui.document and ui.document.file or ""
    local title = props.display_title or props.title
    if not title or title == "" then title = file:match("([^/]+)%.[^./]*$") or file:match("[^/]+$") or "Book" end
    local md5
    pcall(function() md5 = ui.doc_settings:readSetting("partial_md5_checksum") end)
    local info = { title = title, author = props.authors, md5 = md5 }
    local toc = ui.toc
    if toc and toc.getTocIndexByPage then
        local pos = ui.rolling and ui.document:getXPointer() or self:currentPage()
        local ok, idx = pcall(toc.getTocIndexByPage, toc, pos, toc.toc_chapter_title_bind_to_ticks)
        if ok and idx and toc.toc and toc.toc[idx] then
            info.key = idx
            local t = toc.toc[idx].title
            info.chapter = toc.cleanUpTocTitle and toc:cleanUpTocTitle(t) or t
        end
    end
    return info
end

-- The book's notebook, as last saved (nil before it has one).
function Book:notesPath()
    return self:data().notes
end

function Book:setNotesPath(path)
    local data = self:data()
    if data.notes == path or data.read_only then return end
    data.notes = path
    self:save()
end

-- Open the book's notes in a window over the page (once: a second call while
-- they are open does nothing).
function Book:openNotes()
    if self._notes_view then return end
    local ok, NotesView = pcall(require, "ink/reader/notesview")
    if not ok then logger.warn("Ink Away: book notes unavailable:", NotesView); return end
    -- the page as it is, to show around the window
    local Blitbuffer = require("ffi/blitbuffer")
    local behind = Blitbuffer.new(Screen:getWidth(), Screen:getHeight(), Screen.bb:getType())
    self:snapshot(behind, true)
    local view = NotesView:new{ book = self, behind_bb = behind }
    self._notes_view = view
    UIManager:show(view)
end

------------------------------------------------------------------------------
-- Deleting the book's annotations
------------------------------------------------------------------------------

-- Move the book's annotations (its ink file and pictures) to the trash of the
-- Ink Away library `root` (see Trash.putBookInk), and show the book without
-- them at once. The link to the book's notes stays. Returns the trash item, or
-- nil, err.
function Book:trashInk(root)
    local data = self:data()
    if data.read_only then return nil, "saved by a newer Ink Away" end
    if #data.items > 0 then self:save() end      -- what is in memory goes too
    if not (self.sidecar and BookInk.exists(self.sidecar)) then return nil, "no annotations" end
    local Trash = require("ink/trash")
    local item, err = Trash.putBookInk(root, self.sidecar,
        { name = self:notesInfo().title, book = self.ui.document and self.ui.document.file })
    if not item then return nil, err end
    local notes = data.notes
    self._data = BookInk.new()
    self.has_file = false
    if notes then
        self._data.notes = notes
        self:save()
    end
    self:reload(true)
    return item
end

-- Read the book's ink again (it came back from the trash), or with `keep` just
-- show what is in memory now.
function Book:reload(keep)
    if not keep then
        self._data = nil
        self.has_file = self.sidecar ~= nil and BookInk.exists(self.sidecar)
    end
    self.rev = self.rev + 1
    self._placed, self._index, self._index_key = nil, nil, nil
    self:repaint()
end

-- Repaint the reader (after the ink changed).
function Book:repaint()
    UIManager:setDirty(self.ui.dialog or "all", "ui")
end

return Book
