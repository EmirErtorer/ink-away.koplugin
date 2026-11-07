-- Default viewer. KOReaderSurface KOReader behavior is kept here, including reflowing books.
local Device = require("device")
local UIManager = require("ui/uimanager")
local Screen = Device.screen
local KOReaderSurface = {}
KOReaderSurface.__index = KOReaderSurface

function KOReaderSurface.new(ui) return setmetatable({ ui = ui }, KOReaderSurface) end

-- The adapter between place.lua and KOReader's document and view.
function KOReaderSurface:doc()
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
    end
    self._doc = d
    return d
end

-- The page shown now (the first, when more than one is).
function KOReaderSurface:currentPage()
    local ui = self.ui
    if ui.paging then return ui.view.state and ui.view.state.page or ui.paging.current_page end
    local ok, p = pcall(ui.document.getCurrentPage, ui.document)
    return ok and p or nil
end

-- Every page on the screen: one, or two side by side, or the pages a
-- continuous scroll shows.
function KOReaderSurface:pages()
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
function KOReaderSurface:key()
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

function KOReaderSurface:readingDirection()
    return self.ui.view and self.ui.view.inverse_reading_order and "rtl" or "ltr"
end

function KOReaderSurface:turn(dir, done)
    self.ui:handleEvent(require("ui/event"):new("GotoViewRel", dir))
    done()
end

function KOReaderSurface:snapshot(bb) self.ui.view:paintTo(bb, 0, 0) end
function KOReaderSurface:repaint() UIManager:setDirty(self.ui.dialog or "all", "ui") end

return KOReaderSurface
