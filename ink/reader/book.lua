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
local Rooms = require("ink/reader/rooms")
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
            local _ = require("ink/l10n")
            require("ink/view").tellAnywhere(_("Ink Away could not save this book's ink: its folder can't be written to."))
        end
    end
    self.has_file = kept ~= nil and not BookInk.empty(data)
    if kept then
        local ok, Sync = pcall(require, "ink/sync/manager")   -- (cloud sync: a change is waiting to be sent)
        if ok then pcall(Sync.bookSaved) end
    end
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
        function d.size() return Screen:getWidth(), Screen:getHeight() end
        function d.pageCount()
            local ok, n = pcall(document.getPageCount, document)
            return ok and n or nil
        end
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
        -- a word a hyphen splits over two lines comes with the box of both
        -- lines together: the part nearest (x, y) instead, and which it is
        function d.partOf(_, w, x, y)
            local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, w.xp0, w.xp1, true)
            if not (ok and boxes and #boxes > 1) then return w end
            local best, bd
            for k, b in ipairs(boxes) do
                local dx = math.max(b.x - x, 0, x - (b.x + b.w))
                local dy = math.max(b.y - y, 0, y - (b.y + b.h))
                local dd = dx * dx + dy * dy
                if not bd or dd < bd then best, bd = k, dd end
            end
            return { xp0 = w.xp0, xp1 = w.xp1, box = boxes[best], seg = best }
        end
        -- the word's box (part `seg` of a split word; the whole word, or what
        -- of it is on the screen, when it is not split now)
        function d.boxOf(_, xp0, xp1, seg)
            local ok, boxes = pcall(document.getScreenBoxesFromPositions, document, xp0, xp1, true)
            if not (ok and boxes and #boxes > 0) then return nil end
            return boxes[math.min(seg or 1, #boxes)]
        end
        -- room made in the text (see "Room" below)
        function d.roomAt(_, x0, y0, x1, y1) return self:roomAt(x0, y0, x1, y1) end
        function d.roomBox(_, id) return self:roomBox(id) end
        function d.roomPage(_, id) return self:roomPage(id) end
        function d.roomX(_, id) return self:roomX(id) end
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

-- Can what is drawn be pinned to its page (kept at its spot on that page number
-- whatever the text does)? Only in a reflowing book showing one page at a time.
function Book:canPin()
    local ui = self.ui
    if ui.paging then return false end
    if ui.view and ui.view.view_mode == "scroll" then return false end
    return #self:visiblePages() == 1
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
        if item == nil and op.pin and self:canPin() then
            item = Place.pinned(op, doc, self:visiblePages()[1])   -- pinned: it keeps this page number
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
-- Room made in the text (see ink/reader/rooms.lua)
------------------------------------------------------------------------------

-- The rooms made in this book (none in a fixed-page one).
function Book:rooms()
    if self.ui.paging or not (self.has_file or self._data) then return {} end
    return self:data().rooms or {}
end

-- Are the rooms shown (they can all be hidden for plain reading)?
function Book:roomsShown()
    if not (self.has_file or self._data) then return true end
    return not self:data().rooms_off
end

-- The room with this id, if it is shown.
function Book:roomById(id)
    if not self:roomsShown() then return nil end
    for _i, r in ipairs(self:rooms()) do if r.id == id then return r end end
end

-- CSS pixels per screen pixel: KOReader's "Zoom (dpi)" scales the book's pixels
-- (1 at its default of 96, or when it is off).
function Book:cssScale()
    local c = self.ui.document and self.ui.document.configurable
    local dpi = tonumber(c and c.render_dpi)
    if not dpi or dpi <= 0 or dpi == 96 then return 1 end
    return 96 / dpi
end

-- The style rules that make the rooms, for KOReader's style tweaks (main.lua
-- adds them), or nil. Reads the book's ink file only when there is one.
function Book:roomsCss()
    if self.ui.paging or not (self.has_file or self._data) then return nil end
    local data = self:data()
    if data.rooms_off or not data.rooms or #data.rooms == 0 then return nil end
    local css = Rooms.css(data.rooms, self:cssScale())
    return css ~= "" and css or nil
end

-- Can room be made here? In a reflowing book showing one page at a time (as
-- pinning).
function Book:canRoom()
    return not self.ui.paging and self:canPin()
end

-- The page's text area on the screen: { x0, y0, x1, y1 }.
function Book:textArea()
    local document = self.ui.document
    local W, H = Screen:getWidth(), Screen:getHeight()
    local ok, m = pcall(document.getPageMargins, document)
    m = ok and type(m) == "table" and m or {}
    local hok, header = pcall(document.getHeaderHeight, document)
    header = hok and tonumber(header) or 0
    return { x0 = m.left or 0, y0 = (m.top or 0) + header, x1 = W - (m.right or 0), y1 = H - (m.bottom or 0) }
end

-- Where a paragraph's text starts (its first word), as an xpointer. The same
-- in any layout, so it is kept.
function Book:textStartOf(elem)
    self._text_starts = self._text_starts or {}
    local c = self._text_starts[elem]
    if c ~= nil then return c or nil end
    local document = self.ui.document
    local found
    local ok, x = pcall(document.getNextVisibleWordStart, document, elem)
    if ok and type(x) == "string" and x:sub(1, #elem + 1) == elem .. "/" then found = x end
    if not found then
        local cand = elem .. "/text().0"
        local iok, inside = pcall(document.isXPointerInDocument, document, cand)
        if iok and inside then found = cand end
    end
    self._text_starts[elem] = found or false
    return found
end

-- The paragraphs on the page shown, top to bottom (Rooms.blocksFromWords), found
-- once per page and layout from its words.
function Book:pageBlocks()
    local page = self:currentPage()
    if not page or self.ui.paging then return {} end
    local key = self:layoutKey() .. "#" .. page
    local c = self._blocks
    if c and c.key == key then return c.list end
    local document = self.ui.document
    local area = self:textArea()
    local words = {}
    pcall(function()
        local start = document:getPageXPointer(page)
        local stop = page < document:getPageCount() and document:getPageXPointer(page + 1) or nil
        -- (the page may begin inside a word: from that word's start)
        local xp = document:getNextVisibleWordStart(start)
        local before = xp and document:getPrevVisibleWordStart(xp)
        if before then xp = before end
        local lh
        for _n = 1, 4000 do
            if not xp then break end
            if stop and (document:compareXPointers(xp, stop) or 0) <= 0 then break end
            local y = document:getScreenPositionFromXPointer(xp)
            if y and y > area.y1 then break end
            if y and y >= area.y0 - 2 then
                if not lh then
                    local bok, boxes = pcall(document.getScreenBoxesFromPositions, document, xp,
                        document:getNextVisibleWordEnd(xp), false)
                    lh = bok and boxes and boxes[1] and boxes[1].h or nil
                end
                words[#words + 1] = { xp = xp, y = y, h = lh or 0 }
            end
            local nxt = document:getNextVisibleWordStart(xp)
            if not nxt or nxt == xp then break end
            xp = nxt
        end
    end)
    local list = Rooms.blocksFromWords(words, function(elem, first)
        -- the page's first paragraph began here if its first word is the page's first
        return self:textStartOf(elem) == first
    end)
    self._blocks = { key = key, list = list }
    return list
end

-- The page a room is on (its first paragraph's), or nil when it is hidden.
function Book:roomPage(id)
    local r = self:roomById(id)
    if not r then return nil end
    local ts = self:textStartOf(r.xp)
    if not ts then return nil end
    local ok, p = pcall(self.ui.document.getPageFromXPointer, self.ui.document, ts)
    return ok and p or nil
end

-- The left edge of a side room on the screen (the band's too).
function Book:roomX(id)
    local r = self:roomById(id)
    if not r then return nil end
    local a = self:textArea()
    if r.kind == "side" and r.side == "right" then return a.x1 - r.w end
    return a.x0
end

-- A room's box on the page shown: { x, y, w, h }, or nil when it is not on it.
-- Side space shows beside the paragraphs it covers on this page.
function Book:roomBox(id)
    local r = self:roomById(id)
    if not r then return nil end
    local a = self:textArea()
    if r.kind == "band" then
        local ts = self:textStartOf(r.xp)
        if not ts then return nil end
        local document = self.ui.document
        local ok, p = pcall(document.getPageFromXPointer, document, ts)
        if not (ok and p) then return nil end
        local shown = false
        for _i, v in ipairs(self:visiblePages()) do if v == p then shown = true end end
        if not shown then return nil end
        local yok, y = pcall(document.getScreenPositionFromXPointer, document, ts)
        if not (yok and y) then return nil end
        return { x = a.x0, y = y - r.h, w = a.x1 - a.x0, h = r.h }
    end
    local want = {}
    for _i, x in ipairs(r.xps or { r.xp }) do want[x] = true end
    local y0, y1
    for _i, b in ipairs(self:pageBlocks()) do
        if want[b.xp] then
            y0 = y0 and math.min(y0, b.y0) or b.y0
            y1 = y1 and math.max(y1, b.y1) or b.y1
        end
    end
    if not y0 then return nil end
    return { x = self:roomX(id), y = y0, w = r.w, h = y1 - y0 }
end

-- The boxes of the rooms on the page shown: { { room, box }, ... }.
function Book:roomBoxes()
    local out = {}
    if not self:roomsShown() then return out end
    for _i, r in ipairs(self:rooms()) do
        local b = self:roomBox(r.id)
        if b then out[#out + 1] = { room = r, box = b } end
    end
    return out
end

-- The room whose box holds the middle of the box (x0, y0)-(x1, y1), and that box.
function Book:roomAt(x0, y0, x1, y1)
    local rooms = self:rooms()
    if #rooms == 0 or not self:roomsShown() then return nil end
    local cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    for _i, e in ipairs(self:roomBoxes()) do
        local b = e.box
        if e.room.id ~= self._no_rooms and cx >= b.x and cx <= b.x + b.w and cy >= b.y and cy <= b.y + b.h then return e.room, b end
    end
end

-- Lay the book out again with the rooms as they are now (KOReader keeps the
-- reading position), and forget what was placed for the old layout.
function Book:relayout()
    self._blocks, self._index, self._placed = nil, nil, nil
    self.rev = self.rev + 1
    local Event = require("ui/event")
    self.ui:handleEvent(Event:new("ApplyStyleSheet"))
    pcall(self.ui.document.getPageCount, self.ui.document)
end

-- Keep `rooms` (and whether they are hidden) and lay the book out with them.
function Book:setRooms(rooms, off)
    local data = self:data()
    if data.read_only then return false end
    data.rooms = rooms and #rooms > 0 and rooms or nil
    data.rooms_off = data.rooms and off or nil
    self:save()
    self:relayout()
    return true
end

-- Where a room's first paragraph is now: the gap above its text (to the word
-- before it, in the book's own pixels) and its first line's right end.
function Book:roomProbe(r)
    local document = self.ui.document
    local ts = self:textStartOf(r.xp)
    if not ts then return nil end
    local out = {}
    pcall(function()
        local y, x = document:getPosFromXPointer(ts)
        local prev = document:getPrevVisibleWordStart(ts)
        local py = prev and document:getPosFromXPointer(prev)
        out.gap = py and (y - py) or nil
        out.x = x
        local stop = ts
        for _n = 1, 12 do stop = document:getNextVisibleWordEnd(stop) or stop end
        local boxes = document:getScreenBoxesFromPositions(ts, stop, false)
        local b = boxes and boxes[1]
        out.right = b and (b.x + b.w) or nil
    end)
    return out
end

-- Did room `r` take, from before (Book:roomProbe) to now? A band moves its
-- paragraph down by its height; side space narrows its first line (or moves it
-- along, on the left). A paragraph too short to tell counts as taken.
local function took(r, before, after, area)
    if not (before and after) then return false end
    if r.kind == "band" then
        return before.gap and after.gap and after.gap - before.gap >= r.h * 0.9 - 2
    end
    if r.side == "left" then
        return before.x and after.x and after.x - before.x >= r.w * 0.9 - 2
    end
    if not (before.right and after.right) then return true end
    if before.right < area.x1 - r.w then return true end   -- (a short first line)
    return after.right <= area.x1 - r.w * 0.9 + 2
end

-- Add room `r` (from Rooms.plan), or change the room with its id, and lay the
-- book out with it (the rooms shown, if they were hidden). A band before a
-- paragraph that already has one takes its place. A room on a paragraph it was
-- not on is checked: if the book's layout did not take it, everything is put back.
-- Returns the room, or nil and why ("failed", "read_only").
function Book:putRoom(r)
    r.id = r.id or Rooms.newId()
    local rooms, was = {}, nil
    for _i, o in ipairs(self:rooms()) do
        if o.id == r.id then was = o
        elseif not (r.kind == "band" and o.kind == "band" and o.xp == r.xp) then rooms[#rooms + 1] = o end
    end
    -- (a new paragraph is checked; the same one resized needs not be)
    local check = not (was and was.xp == r.xp and was.kind == r.kind)
    local area = self:textArea()
    local before = check and self:roomProbe(r)
    -- in its old place in the list, or last
    local placed = false
    if was then
        for i, o in ipairs(self:rooms()) do
            if o.id == r.id then table.insert(rooms, math.min(i, #rooms + 1), r); placed = true; break end
        end
    end
    if not placed then rooms[#rooms + 1] = r end
    local old, old_off = self:data().rooms, self:data().rooms_off
    if not self:setRooms(rooms, nil) then return nil, "read_only" end
    if check and not took(r, before, self:roomProbe(r), area) then
        logger.warn("Ink Away: the room did not take in this book:", r.xp)
        self:setRooms(old, old_off)
        return nil, "failed"
    end
    return r
end
Book.addRoom = Book.putRoom

-- Go to page `p` of the book.
function Book:gotoPage(p)
    local Event = require("ui/event")
    self.ui:handleEvent(Event:new("GotoPage", p))
end

-- Show or hide every room (hidden, the book reads as it was made, and the ink
-- in the rooms hides with them).
function Book:showRooms(on)
    local rooms = self:rooms()
    if #rooms == 0 then return end
    self:setRooms(rooms, not on or nil)
end

-- The items kept in room `id`.
function Book:roomItems(id)
    local out = {}
    for _i, it in ipairs(self:hasInk() and self:data().items or {}) do
        if it.a and it.a.room == id then out[#out + 1] = it end
    end
    return out
end

-- Remove room `id`. What is in it goes (`ink` "delete") or stays where it is on
-- the page now and follows the text from there ("follow").
function Book:removeRoom(id, ink)
    local data = self:data()
    local doc = self:doc()
    local items = {}
    for _i, it in ipairs(data.items) do
        local a = it.a
        if a and a.room == id then
            if ink ~= "delete" then
                local ok, op = pcall(Place.place, it, doc)
                local kept
                if ok and op then
                    local saved = self._no_rooms
                    self._no_rooms = id
                    local aok, item = pcall(Place.anchor, op, doc)
                    self._no_rooms = saved
                    if aok and item then kept = item end
                end
                if not kept and a.xp0 then
                    -- (not on this page: side space ink keeps its word, in the margin it was in)
                    local na = {}
                    for k, v in pairs(a) do na[k] = v end
                    na.room, na.rx = nil, nil
                    local x = (self:roomX(id) or 0) + (a.rx or 0)
                    if x > Screen:getWidth() / 2 then na.mr = Screen:getWidth() - x else na.ml = x end
                    kept = { op = it.op, a = na }
                end
                if kept then items[#items + 1] = kept end
            end
        else
            items[#items + 1] = it
        end
    end
    data.items = items
    local rooms = {}
    for _i, o in ipairs(self:rooms()) do if o.id ~= id then rooms[#rooms + 1] = o end end
    return self:setRooms(rooms, data.rooms_off)
end

-- Are there pinned items on pages from `page` on (a room before them changes the
-- text under them)?
function Book:pinnedFrom(page)
    for _i, it in ipairs(self:hasInk() and self:data().items or {}) do
        if it.a and it.a.pg and it.a.pg >= (page or 1) then return true end
    end
    return false
end

------------------------------------------------------------------------------
-- The smart highlighter: the reader's own highlights
------------------------------------------------------------------------------

-- A highlighter stroke over text, made the reader's own highlight of that text
-- (in the reader's highlight style, in the pen's colour as the reader names it).
-- Returns the highlight, or nil when it is not over text (it stays ink).
function Book:highlight(op)
    local ui = self.ui
    local hl, document = ui.highlight, ui.document
    if not (hl and hl.saveHighlight and ui.annotation and document.getTextFromPositions) then return nil end
    if not (op and op.kind == "ink" and op.pts) then return nil end
    -- a word just above or below the stroke's centre counts: the highlighter is thick
    local reach = math.max(4, (op.width or 8) * 0.5)
    local sel
    if ui.paging then sel = self:pageSelection(op, reach) else sel = self:flowSelection(op, reach) end
    if not sel then return nil end
    local hv = ui.view.highlight or {}
    local Blitbuffer = require("ffi/blitbuffer")
    sel.drawer = hv.saved_drawer
    sel.color = Snap.colourName(op.color, hv.saved_color, Blitbuffer.HIGHLIGHT_COLORS)
    return self:addHighlight(sel)
end

-- The text a highlighter stroke snaps to in a reflowing book (see
-- ink/reader/snap.lua): { text, pos0, pos1 } from the first word it ran over to
-- the last, or nil.
function Book:flowSelection(op, reach)
    local document = self.ui.document
    local doc = self:doc()
    local words, share = Snap.hits(op, function(x, y) return doc:wordAt(x, y) end, reach,
        function(w) return w.xp0 end)
    if not Snap.snaps(words, share) then return nil end
    local first, last = Snap.ends(words, function(a, b)
        local ok, c = pcall(document.compareXPointers, document, a.xp0, b.xp0)
        return ok and c == 1
    end)
    local ok, text = pcall(document.getTextFromXPointers, document, first.xp0, last.xp1)
    if ok and type(text) == "string" and text:match("%S") then
        return { text = text, pos0 = first.xp0, pos1 = last.xp1 }
    end
    -- else the text between the two words' boxes
    local a, b = first.box, last.box
    local ok2, r = pcall(document.getTextFromPositions, document, { x = a.x + 1, y = a.y + a.h / 2 },
        { x = b.x + b.w - 1, y = b.y + b.h / 2 }, true)
    if ok2 and r and r.pos0 and r.pos1 and type(r.text) == "string" and r.text:match("%S") then
        return { text = r.text, pos0 = r.pos0, pos1 = r.pos1 }
    end
end

-- The same on a fixed page (a PDF): { text, pos0, pos1, pboxes, ext } on the
-- page most of the stroke's words are on, or nil. The reader gives the nearest
-- word to any point, so a word only counts where the stroke is on it.
function Book:pageSelection(op, reach)
    local document, view = self.ui.document, self.ui.view
    local doc = self:doc()
    local function wordAt(x, y)
        local pos = view:screenToPageTransform({ x = x, y = y })
        if not (pos and pos.page) then return nil end
        local ok, w = pcall(document.getWordFromPosition, document, pos)
        local pb = ok and w and w.pbox
        if not (pb and type(w.word) == "string" and w.word:match("%S")) then return nil end
        local sx, sy, zoom = doc:toScreen(pos.page, pb.x, pb.y)
        if not sx then return nil end
        return { page = pos.page, pbox = pb, box = { x = sx, y = sy, w = pb.w * zoom, h = pb.h * zoom } }
    end
    local words, share = Snap.hits(op, wordAt, reach,
        function(w) return w.page .. ":" .. w.pbox.x .. ":" .. w.pbox.y end)
    if not Snap.snaps(words, share) then return nil end
    local count, page = {}, nil
    for _i, w in ipairs(words) do
        count[w.page] = (count[w.page] or 0) + 1
        if not page or count[w.page] > count[page] then page = w.page end
    end
    local on = {}
    for _i, w in ipairs(words) do if w.page == page then on[#on + 1] = w end end
    local first, last = Snap.ends(on, Snap.pageBefore)
    local a = { page = page, x = first.pbox.x + 1, y = first.pbox.y + first.pbox.h / 2 }
    local b = { page = page, x = last.pbox.x + last.pbox.w - 1, y = last.pbox.y + last.pbox.h / 2 }
    local ok, sel = pcall(document.getTextFromPositions, document, a, b)
    if not (ok and sel and sel.pos0 and sel.pos1 and type(sel.text) == "string" and sel.text:match("%S")) then return nil end
    return { text = sel.text, pos0 = sel.pos0, pos1 = sel.pos1, pboxes = sel.pboxes, ext = sel.ext }
end

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

-- The reader's custom highlight colours (name -> { code }), or nil where the
-- reader has none (an older one).
function Book:customColours()
    local hl = self.ui and self.ui.highlight
    local t = hl and hl.custom_colors
    return type(t) == "table" and t or nil
end

-- Is `item` still one of the book's highlights (it is not once deleted).
function Book:hasHighlight(item)
    for _i, it in ipairs(self.ui and self.ui.annotation and self.ui.annotation.annotations or {}) do
        if it == item then return true end
    end
    return false
end

-- Give a highlight another colour, as the reader's own colour menu does: the
-- PDF's annotation is written again (a PDF keeps its highlights in the file),
-- the boxes the reader drew are dropped, and the reader is told the item
-- changed. `name` is a colour name the reader knows (nil, with `clear`, puts back
-- a highlight that had none). Returns whether it was set.
function Book:setHighlightColour(item, name, clear)
    local ui = self.ui
    if not (item and (name or clear) and ui and ui.highlight and self:hasHighlight(item)) then return false end
    local hl = ui.highlight
    local pdf = ui.paging and hl.writePdfAnnotation
    local ok, err = pcall(function()
        if pdf then hl:writePdfAnnotation("delete", item) end
        item.color = name
        if pdf then
            hl:writePdfAnnotation("save", item)
            if item.note then hl:writePdfAnnotation("content", item, item.note) end
        end
    end)
    if not ok then
        logger.warn("Ink Away: could not recolour the highlight:", err)
        return false
    end
    -- (each of these is the reader's own, and an older one may not have it)
    if ui.view and ui.view.resetHighlightBoxesCache then pcall(ui.view.resetHighlightBoxesCache, ui.view) end
    local Event = require("ui/event")
    pcall(ui.handleEvent, ui, Event:new("AnnotationsModified", { item }))
    return true
end

-- The highlights the path `pts` (flat x, y, ... on the screen, the canvas's own
-- points in annotation mode) comes within `r` px of: their annotation items,
-- each once. It uses what KOReader drew on the page shown and its own tap test
-- (view.highlight.visible_boxes, in page coordinates on a fixed page), walking
-- each segment in small steps so a short highlight between two points counts.
function Book:highlightsAt(pts, r)
    local out = {}
    local ui = self.ui
    local view = ui and ui.view
    local vis = view and view.highlight and view.highlight.visible_boxes
    local anns = ui and ui.annotation and ui.annotation.annotations
    if not (vis and anns and #vis > 0 and view.screenToPageTransform and pts and #pts >= 2) then return out end
    local zoom = (ui.paging and view.state and view.state.zoom) or 1
    local rr = (r or 0) / zoom
    local seen = {}
    local function at(x, y)
        local ok, pos = pcall(view.screenToPageTransform, view, { x = x, y = y })
        if not (ok and pos and pos.x) then return end
        for _k, box in ipairs(vis) do
            local b = box.rect
            if b and not seen[box.index] and pos.x >= b.x - rr and pos.x <= b.x + b.w + rr
                    and pos.y >= b.y - rr and pos.y <= b.y + b.h + rr then
                seen[box.index] = true
                local it = anns[box.index]
                if it then out[#out + 1] = it end
            end
        end
    end
    local step = math.max(2, r or 0)
    at(pts[1], pts[2])
    for i = 3, #pts - 1, 2 do
        local x0, y0, x1, y1 = pts[i - 2], pts[i - 1], pts[i], pts[i + 1]
        local n = math.max(1, math.ceil(math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2) / step))
        for k = 1, n do at(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n) end
    end
    return out
end

-- Erase along the screen path `pts` with radius `r`, while reading (the pen's
-- eraser end, see ink/reader/penhighlight.lua): the highlights it reaches go,
-- and the book's ink it crosses is cut as the annotation mode's eraser cuts it,
-- with that mode's eraser settings. Returns how many highlights and strokes went
-- or changed.
function Book:eraseAlong(pts, r)
    if not (pts and #pts >= 2) then return 0 end
    local n = 0
    for _i, it in ipairs(self:highlightsAt(pts, r)) do
        if self:removeHighlight(it) then n = n + 1 end
    end
    local placed = self:pageOps()
    if placed and #placed.ops > 0 then
        local G = rawget(_G, "G_reader_settings")
        local function get(k, d)
            local v = G and G.readSetting and G:readSetting(k)
            if v == nil then return d end
            return v
        end
        local Cut = require("ink/cut")
        local opts = { text = not get("inkaway_text_erase_protect", true), pictures = get("inkaway_erase_bg", false) }
        local ops, changed = Cut.ops(placed.ops, pts, r, opts)
        if changed and get("inkaway_erase_whole", false) then
            -- the whole-stroke eraser: what it reached goes entirely
            ops = {}
            for _i, op in ipairs(placed.ops) do
                local _o, hit = Cut.ops({ op }, pts, r, opts)
                if not hit then ops[#ops + 1] = op end
            end
        end
        if changed then
            local came_from = {}
            for i, op in ipairs(placed.ops) do came_from[op] = placed.items[i] end
            for _i, op in ipairs(ops) do if not came_from[op] then n = n + 1 end end
            self:setPageOps(ops, came_from, placed.items)
            self:save()
            if n == 0 then n = 1 end
        end
    end
    return n
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
-- Is `w` still shown?
local function shown(w)
    for _i, e in ipairs(UIManager._window_stack or {}) do if e.widget == w then return true end end
    return false
end

function Book:annotate()
    if self._view and shown(self._view) then return end
    self._view = nil
    if self:data().read_only then
        local _ = require("ink/l10n")
        require("ink/view").tellAnywhere(_("This book's ink was saved by a newer Ink Away. Update Ink Away to change it."))
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
    if self._capture then self._capture:onCancel() end
    if self._view then pcall(function() self._view:closeCanvas() end) end
    if self._notes_view then pcall(function() self._notes_view:closeCanvas() end) end
end

-- The book is closing: close the annotation mode (keeping its ink) and let go.
function Book:close()
    if self._capture then self._capture:onCancel() end
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
    return ok
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
    local path = self:data().notes
    -- a notebook path from another reader (the ink came with the cloud sync) is found again
    local ok, Portable = pcall(require, "ink/sync/portable")
    local root = ok and Portable.root and Portable.root()
    if path and root then return Portable.resolve(path, root) end
    return path
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
    if self._notes_view and shown(self._notes_view) then return end
    self._notes_view = nil
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
    local css = self:roomsCss() or false
    self._data = BookInk.new()
    self.has_file = false
    if notes then
        self._data.notes = notes
        self:save()
    end
    self:reload(true, css)
    return item
end

-- Read the book's ink again (it came back from the trash, or from the cloud), or
-- with `keep` just show what is in memory now. When that changes the rooms made
-- in the text, the book is laid out again.
function Book:reload(keep, css_before)
    local before = css_before
    if before == nil then before = self:roomsCss() or false end
    if not keep then
        self._data = nil
        self.has_file = self.sidecar ~= nil and BookInk.exists(self.sidecar)
    end
    self.rev = self.rev + 1
    self._placed, self._index, self._index_key = nil, nil, nil
    if (self:roomsCss() or false) ~= before then self:relayout() end
    self:repaint()
end

-- Repaint the reader (after the ink changed).
function Book:repaint()
    UIManager:setDirty(self.ui.dialog or "all", "ui")
end

return Book
