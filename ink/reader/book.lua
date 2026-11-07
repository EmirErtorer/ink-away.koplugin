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
local IntegrationAPI = require("ink/IntegrationAPI")
local KOReaderSurface = require("ink/reader/KOReaderSurface")

local Screen = Device.screen

---@class InkBook
---@field ui table
---@field extensions IntegrationAPI
---@field surface InkSurface?
---@field _native KOReaderSurface
---@field _surface_doc InkPlacementDocument?
---@field dirs string[]?
---@field plugin table?
local Book = {}
Book.__index = Book

---@param ui table
---@param extensions IntegrationAPI?
---@return InkBook
function Book.new(ui, extensions)
    local self = setmetatable({ ui = ui, rev = 0, _native = KOReaderSurface.new(ui),
        extensions = extensions or IntegrationAPI.new() }, Book)
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
    self.has_file = kept ~= nil and (#data.items > 0 or data.notes ~= nil)
    return kept ~= nil
end

------------------------------------------------------------------------------
-- The book, as place.lua asks about it
------------------------------------------------------------------------------

--- Native and external viewers expose the same pages/key/snapshot contract.
---@return InkViewer
function Book:viewer() return self.surface or self._native end

---@return InkPlacementDocument
function Book:doc()
    if not self.surface then return self._native:doc() end
    if not self._surface_doc then self._surface_doc = require("ink/reader/surface").doc(self.surface) end
    return self._surface_doc
end

---@return integer? page
function Book:currentPage()
    if self.surface then return self.surface:pages()[1] end
    return self._native:currentPage()
end

---@return integer[]
function Book:visiblePages() return self:viewer():pages() end

--- Include viewer identity so equal keys from different surfaces cannot reuse ink.
---@return string
function Book:layoutKey()
    local viewer = self:viewer()
    return self.surface and tostring(viewer) .. "|" .. viewer:key() or viewer:key()
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
    local document = self.ui.document
    local doc = self:doc()
    local function wordAt(x, y)
        local page, px, py = doc:toPage(x, y)
        if not page then return nil end
        local pos = { page = page, x = px, y = py }
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

-- The highlights the path `pts` (flat x, y, ... on the screen, the canvas's own
-- points in annotation mode) comes within `r` px of: their annotation items,
-- each once. It uses what KOReader drew on the page shown and its own tap test
-- (view.highlight.visible_boxes, in page coordinates on a fixed page), walking
-- each segment in small steps so a short highlight between two points counts.
function Book:highlightsAt(pts, r)
    local out = {}
    local ui = self.ui
    local view = ui and ui.view
    -- The normal reader's hit boxes describe its own viewport. Never erase
    -- an unrelated native highlight through stale boxes in an external view.
    if self.surface then return out end
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
            local ok, err = pcall(book.paintOnSurface, book, nil, bb, x, y)
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

--- Invalidate screen placement when geometry ownership changes.
---@param surface InkSurface?
function Book:setSurface(surface)
    if self.surface == surface then return end
    self.surface = surface
    self._native._doc = nil
    self._placed, self._surface_doc, self._layout_last = nil, nil, nil
end

-- A render must not change the context of an open annotation session.
---@param surface InkSurface?
---@param bb table
---@param x number
---@param y number
function Book:paintOnSurface(surface, bb, x, y)
    local previous = self.surface
    self:setSurface(surface)
    local ok, err = pcall(self.paintInk, self, bb, x, y)
    self:setSurface(previous)
    if not ok then error(err) end
end

---@param surface InkSurface
---@param bb table
---@param force_ink boolean?
function Book:paintSurface(surface, bb, force_ink)
    local G = rawget(_G, "G_reader_settings")
    if not self:hasInk() or (not force_ink and G and G:readSetting("inkaway_book_ink") == false) then return end
    if self._snapshotting then return end
    -- Paint in screen coordinates, then copy only the surface's content area:
    -- ink outside a crop must not cover its viewer's controls or letterboxing.
    for _, region in ipairs(surface.regions and surface:regions() or { surface }) do
        local clip = region:clip()
        if clip and clip.w > 0 and clip.h > 0 then
            local work = bb:copy()
            local ok, err = pcall(self.paintOnSurface, self, region, work, 0, 0)
            if ok then bb:blitFrom(work, clip.x, clip.y, clip.x, clip.y, clip.w, clip.h) end
            work:free()
            if not ok then
                self.extensions:report(surface, err)
                logger.warn("Ink Away: could not paint the document surface:", err)
            end
        end
    end
end

-- Open the annotation mode over the page shown (once: a second call while it is
-- open does nothing).
-- Is `w` still shown?
local function shown(w)
    for _i, e in ipairs(UIManager._window_stack or {}) do if e.widget == w then return true end end
    return false
end

--- Acquire the selected surface and emit opened only after editor creation/show succeeds.
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
    local surface = self.extensions:select(self.ui)
    if surface and surface.begin then
        local begun, err = pcall(surface.begin, surface)
        if not begun then
            self.extensions:report(surface, err)
            if surface.finish then pcall(surface.finish, surface) end
            surface = nil
        end
    end
    self:setSurface(surface)
    local created, view = pcall(ReaderInkView.new, ReaderInkView, { book = self, modal = surface and true or nil })
    if not created then
        self:setSurface(nil)
        if surface and surface.finish then pcall(surface.finish, surface) end
        self.extensions:report(surface, view)
        logger.warn("Ink Away: annotation mode unavailable:", view)
        return
    end
    self._view = view
    local shown_ok, err = pcall(UIManager.show, UIManager, view)
    if not shown_ok then
        pcall(view.closeCanvas, view)
        self._view = nil
        self:finishAnnotation()
        self.extensions:report(surface, err)
        return
    end
    if self._view == view then
        self._annotation_session = true
        self.extensions:emit("opened", self.ui.document, self.surface)
    end
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
---@return InkReadingDirection
function Book:readingDirection()
    local viewer = self:viewer()
    if viewer.readingDirection then return viewer:readingDirection() end
    return self._native:readingDirection()
end

---@param dir integer
---@param done fun()? Called after geometry handoff; ignored once the session closes.
---@param frame fun()? Request a live animation frame.
function Book:turn(dir, done, frame)
    local view, source, completed = self._view, self.surface, false
    local viewer = self:viewer()
    local function completedTurn(surface)
        if completed or self._view ~= view or (view and view.closing) then return end
        completed = true
        surface = self.extensions:handoff(source, surface, self.ui.document)
        self:setSurface(surface)
        if surface and surface.begin then surface:begin() end
        if done then done() end
    end
    -- Navigation is optional for an external surface; absent means stay here.
    local ok, err = pcall(function()
        if viewer.turn then viewer:turn(dir, completedTurn, frame)
        else completedTurn(self.surface) end
    end)
    if not ok then self.extensions:report(source, err); error(err) end
end

-- Called after editor saving/cleanup, including native-reader sessions.
--- Release the active surface once, then notify close observers after editor cleanup.
function Book:finishAnnotation()
    local surface = self.surface
    self:setSurface(nil)
    if surface and surface.finish then
        local ok, err = pcall(surface.finish, surface)
        if not ok then self.extensions:report(surface, err) end
    end
    if self._annotation_session then
        self._annotation_session = nil
        self.extensions:emit("closed", self.ui.document, surface)
    end
end

-- Paint the page shown into `bb` (screen-sized), without the ink unless
-- `with_ink`.
---@param bb table
---@param with_ink boolean?
---@param force_ink boolean?
function Book:snapshot(bb, with_ink, force_ink)
    local ov = self:overlay()
    ov.hidden = not with_ink
    self._snapshotting = true
    local viewer = self:viewer()
    local ok, err = pcall(viewer.snapshot, viewer, bb)
    self._snapshotting = nil
    ov.hidden = false
    if ok and with_ink and self.surface then self:paintSurface(self.surface, bb, force_ink) end
    if not ok then
        self.extensions:report(self.surface, err)
        logger.warn("Ink Away: could not draw the page:", err)
    end
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
    self:viewer():repaint()
    if self.surface then self._native:repaint() end
end

return Book
