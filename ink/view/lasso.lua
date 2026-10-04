--[[
Lasso selection: loop around ink, shapes and fills to select them, then move,
duplicate, delete, cut or copy the group; a lasso tap pastes what was cut or
copied, on any page of any document.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local GeomUI = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Device = require("device")
local _ = require("gettext")
local Canvas = require("ink/canvas")
local Clipboard = require("ink/clipboard")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")

local opInPoly = Canvas.opInPoly
local accumBounds = Canvas.accumBounds
local translateOp = Canvas.translateOp

local Screen = Device.screen

local InkAwayView = {}

------------------------------------------------------------------------------
-- Lasso select. A drawing and a notebook page are both op lists, so it works the
-- same on either.
------------------------------------------------------------------------------

-- Forget the selection and any loop in progress, without repainting.
function InkAwayView:resetLasso()
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
end

function InkAwayView:clearSelection()
    if self._sel_refresh_tick then self:stopSelRefresh() end
    self:resetLasso()
    self:redraw()
end

-- Recompute the selection's bounding box (canvas coords) from its ops.
function InkAwayView:recomputeSelectionBBox()
    if not self.selection then return end
    local x0, y0, x1, y1
    for _, idx in ipairs(self.selection.idxs) do
        local op = self.canvas.ops[idx]
        if op then x0, y0, x1, y1 = accumBounds(op, x0, y0, x1, y1) end
    end
    self.selection.bbox = x0 and { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } or nil
end

-- Is a screen point inside the selection box (with a little slack for the finger)?
function InkAwayView:inSelBBoxScreen(sx, sy)
    local b = self.selection and self.selection.bbox
    if not b then return false end
    local x0, y0 = InkGeom.toScreen(self.view, b.x0, b.y0)
    local x1, y1 = InkGeom.toScreen(self.view, b.x1, b.y1)
    local pad = 24
    return sx >= x0 - pad and sx <= x1 + pad and sy >= y0 - pad and sy <= y1 + pad
end

-- How close (canvas px) to the lasso's line writing still counts as inside it:
-- about 2.5 mm on screen, whatever the zoom.
function InkAwayView:lassoSlop()
    return Screen:scaleBySize(16) / ((self.view and self.view.zoom) or 1)
end

-- Pick every op the lasso loop holds (canvas coords; see Canvas.opInPoly).
function InkAwayView:computeSelection(poly)
    local idxs = {}
    local slop = self:lassoSlop()
    for i, op in ipairs(self.canvas.ops) do
        if op.kind ~= "erase" and opInPoly(op, poly, slop) then idxs[#idxs + 1] = i end
    end
    if #idxs == 0 then self.selection = nil; return false end
    self.selection = { idxs = idxs }
    self:recomputeSelectionBBox()
    return true
end

-- Close the lasso loop, select what it encircled, and show the box.
function InkAwayView:lassoFinish()
    self.lassoing = false
    local scr = self.lasso_scr
    self.lasso_scr = nil
    if not scr or #scr < 6 then    -- need at least 3 points for an area
        self:redraw()
        return
    end
    local poly = {}
    for i = 1, #scr, 2 do
        local cx, cy = InkGeom.toCanvas(self.view, scr[i], scr[i + 1])
        poly[#poly + 1] = cx; poly[#poly + 1] = cy
    end
    local got = self:computeSelection(poly)
    self:redraw()
    if not got then
        UIManager:show(InfoMessage:new{ text = _("Nothing inside the loop."), timeout = 2 })
    end
end

-- Commit a move of the selected ops by a screen delta.
function InkAwayView:selMoveCommit(sdx, sdy)
    if not self.selection then return end
    local dx = sdx / self.view.zoom
    local dy = sdy / self.view.zoom
    if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then
        self:redraw(); return
    end
    self.canvas:pushHistory()
    for _, idx in ipairs(self.selection.idxs) do
        local op = self.canvas.ops[idx]
        if op then
            -- move a copy, so the undo snapshot keeps the op where it was
            local moved = self.canvas:cloneOp(op)
            translateOp(moved, dx, dy)
            self.canvas:replaceOp(idx, moved)
        end
    end
    self:markDirty()
    self:recomputeSelectionBBox()
    self:recompose()
end

-- Duplicate or delete the current selection, from its menu.
function InkAwayView:selDuplicate()
    if not self.selection then return end
    self.canvas:pushHistory()
    local off = math.floor(24 / self.view.zoom + 0.5)
    local new_idxs = {}
    for _, idx in ipairs(self.selection.idxs) do
        local op = self.canvas.ops[idx]
        if op then
            local c = self.canvas:cloneOp(op)
            translateOp(c, off, off)
            self.canvas.ops[#self.canvas.ops + 1] = c
            new_idxs[#new_idxs + 1] = #self.canvas.ops
        end
    end
    self.selection = { idxs = new_idxs }   -- the copies become the selection
    self:recomputeSelectionBBox()
    self:markDirty()
    self:recompose()
end

function InkAwayView:selDelete()
    if not self.selection then return end
    self.canvas:pushHistory()
    table.sort(self.selection.idxs, function(a, b) return a > b end)  -- remove high-to-low
    for _, idx in ipairs(self.selection.idxs) do self.canvas:removeOp(idx) end
    self.selection = nil
    self:markDirty()
    self:composeCanvas(); self:renderView()
    self:refresh(self, "full")
end

-- Put the selection on the clipboard; `cut` also deletes it.
function InkAwayView:selCopy(cut)
    if not (self.selection and self.selection.bbox) then return end
    local ops = {}
    table.sort(self.selection.idxs)   -- keep their drawing order
    for _, idx in ipairs(self.selection.idxs) do ops[#ops + 1] = self.canvas.ops[idx] end
    Clipboard.put(ops, self.selection.bbox)
    if cut then self:selDelete() end
    self:showNotice(string.format(cut and _("Cut %d item(s). Tap with the lasso to paste.")
        or _("Copied %d item(s). Tap with the lasso to paste."), #ops))
end

-- Paste the clipboard: centred on screen point `pos`, or where it was cut from.
-- The pasted ops become the selection, ready to be dragged into place.
function InkAwayView:pasteAt(pos)
    if Clipboard.count() == 0 then return end
    local cx, cy
    if pos then cx, cy = InkGeom.toCanvas(self.view, pos.x, pos.y) end
    self:flushPending()
    self.canvas:pushHistory()
    local idxs = {}
    for _, op in ipairs(Clipboard.take(cx, cy)) do
        self.canvas.ops[#self.canvas.ops + 1] = op
        idxs[#idxs + 1] = #self.canvas.ops
    end
    if self.tool ~= "lasso" then self.tool = "lasso"; self:refreshToolLabels() end
    self.selection = { idxs = idxs }
    self:recomputeSelectionBBox()
    self:markDirty()
    self:composeCanvas(); self:renderView()
    self:refresh(self, "full")
end

-- A lasso tap on empty canvas with something on the clipboard: offer to paste
-- it there.
function InkAwayView:openPasteMenu(pos)
    local dlg
    dlg = ButtonDialog:new{ title = string.format(_("%d item(s) on the clipboard"), Clipboard.count()),
        title_align = "center", buttons = {
            {{ text = _("Paste here"), callback = function() UIManager:close(dlg); self:pasteAt(pos) end }},
            {{ text = _("Paste where it was"), callback = function() UIManager:close(dlg); self:pasteAt(nil) end }},
            {{ text = _("Cancel"), callback = function() UIManager:close(dlg) end }},
        } }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

function InkAwayView:openSelectionMenu()
    if not self.selection then return end
    local dlg
    local n = #self.selection.idxs
    local buttons = {
        {{ text = string.format(_("%d item(s) selected"), n), enabled = false }},
        {{ text = _("Cut"), callback = function() UIManager:close(dlg); self:selCopy(true) end },
         { text = _("Copy"), callback = function() UIManager:close(dlg); self:selCopy(false) end }},
        {{ text = _("Duplicate"), callback = function() UIManager:close(dlg); self:selDuplicate() end }},
        {{ text = _("Delete"), callback = function() UIManager:close(dlg); self:selDelete() end }},
        {{ text = _("Deselect"), callback = function() UIManager:close(dlg); self:clearSelection() end }},
        {{ text = _("Keep selection"), callback = function() UIManager:close(dlg) end }},
    }
    -- printed handwriting can become text (see view/handwriting.lua)
    if self:selectionHasWriting() then
        table.insert(buttons, 2, {{ text = _("Convert to text"), callback = function()
            UIManager:close(dlg); self:convertSelectionToText()
        end }})
    end
    dlg = ButtonDialog:new{ title = _("Selection"), title_align = "center", buttons = buttons }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

-- The selection box as a screen rect at drag offset (dx, dy), padded, or nil.
function InkAwayView:selBoxScreenRect(dx, dy)
    local b = self.selection and self.selection.bbox
    if not b then return nil end
    local v = self.view
    local x0, y0 = InkGeom.toScreen(v, b.x0, b.y0)
    local x1, y1 = InkGeom.toScreen(v, b.x1, b.y1)
    local pad = 8
    return { x = math.floor(math.min(x0, x1) + dx) - pad,
             y = math.floor(math.min(y0, y1) + dy) - pad,
             w = math.floor(math.abs(x1 - x0)) + pad * 2,
             h = math.floor(math.abs(y1 - y0)) + pad * 2 }
end

-- Refresh just the box's old and new footprints, far cheaper than the whole
-- area.
function InkAwayView:selRefreshNow()
    self._sel_refresh_pending = false
    if not (self.sel_press and self.selection) then return end
    local cur = self:selBoxScreenRect(self.sel_press.dx, self.sel_press.dy)
    if not cur then return end
    local last = self._sel_last_rect or cur
    self._sel_last_rect = cur
    -- "ui" rather than the fast waveform leaves no smear behind the moving box;
    -- the region is small, so it never floods the panel
    self:refreshRectUnion(cur, last, 0, "ui")
end

function InkAwayView:scheduleSelRefresh()
    if self._sel_refresh_pending then return end
    self._sel_refresh_pending = true
    UIManager:scheduleIn(0.15, self._sel_refresh_tick)   -- at most ~6 refreshes/sec
end

function InkAwayView:stopSelRefresh()
    UIManager:unschedule(self._sel_refresh_tick)
    self._sel_refresh_pending = false
    self._sel_last_rect = nil
end

-- Gesture entry points for the lasso tool, dispatched from the main handlers.
function InkAwayView:lassoTouch(pos)
    if self.selection and self:inSelBBoxScreen(pos.x, pos.y) then
        self.sel_press = { x = pos.x, y = pos.y, dx = 0, dy = 0, moved = false }
        self._sel_last_rect = self:selBoxScreenRect(0, 0)   -- seed for the union refresh
        return true
    end
    self:clearSelection()
    self.lassoing = true
    self.lasso_scr = { pos.x, pos.y }
    return true
end

function InkAwayView:lassoPan(pos)
    if self.sel_press then
        self.sel_press.moved = true
        self.sel_press.dx = pos.x - self.sel_press.x
        self.sel_press.dy = pos.y - self.sel_press.y
        self:scheduleSelRefresh()      -- throttled small refresh; never floods e-ink
        return true
    end
    if self.lassoing and self.lasso_scr then
        self.lasso_scr[#self.lasso_scr + 1] = pos.x
        self.lasso_scr[#self.lasso_scr + 1] = pos.y
        -- refresh only a small box around the new point (a whole segment of a
        -- fast stroke is huge and floods the panel); earlier points stay shown
        UIManager:setDirty(self, "fast", GeomUI:new{ x = pos.x - 14, y = pos.y - 14, w = 28, h = 28 })
        return true
    end
    return true
end

function InkAwayView:lassoRelease(pos)
    if self.sel_press then
        local moved = self.sel_press.moved
        local dx, dy = self.sel_press.dx, self.sel_press.dy
        self.sel_press = nil
        self:stopSelRefresh()
        if moved then self:selMoveCommit(dx, dy) end
        return true
    end
    if self.lassoing then
        if pos then self.lasso_scr[#self.lasso_scr + 1] = pos.x; self.lasso_scr[#self.lasso_scr + 1] = pos.y end
        self:lassoFinish()
        return true
    end
    return true
end

function InkAwayView:lassoTap(pos)
    self.sel_press = nil
    self:stopSelRefresh()
    if self.lassoing then self:lassoFinish(); return true end
    if self.selection then
        if pos and self:inSelBBoxScreen(pos.x, pos.y) then self:openSelectionMenu()
        else self:clearSelection() end
    elseif pos and Clipboard.count() > 0 then
        self:openPasteMenu(pos)
    end
    return true
end

-- The lasso loop being drawn, and the box around a live selection.
function InkAwayView:paintLassoOverlay(bb, x, y)
    local v = self.view
    local BLACKC = Blitbuffer.COLOR_BLACK
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    if self.lassoing and self.lasso_scr then
        local pts = self.lasso_scr
        local function dot(px, py)
            if px >= ax0 and px < ax1 - 3 and py >= ay0 and py < ay1 - 3 then
                bb:paintRect(px, py, 3, 3, BLACKC)
            end
        end
        dot(pts[1], pts[2])
        for i = 3, #pts, 2 do           -- draw each segment as a connected line
            local x0s, y0s = pts[i - 2], pts[i - 1]
            local dxs, dys = pts[i] - x0s, pts[i + 1] - y0s
            local steps = math.max(1, math.floor(math.max(math.abs(dxs), math.abs(dys)) / 3))
            for s = 1, steps do
                dot(math.floor(x0s + dxs * s / steps), math.floor(y0s + dys * s / steps))
            end
        end
    end
    if self.selection and self.selection.bbox then
        local b = self.selection.bbox
        local odx = (self.sel_press and self.sel_press.dx) or 0
        local ody = (self.sel_press and self.sel_press.dy) or 0
        local s0x, s0y = InkGeom.toScreen(v, b.x0, b.y0)
        local s1x, s1y = InkGeom.toScreen(v, b.x1, b.y1)
        local bx0 = math.max(ax0, math.min(ax1, x + s0x + odx))
        local by0 = math.max(ay0, math.min(ay1, y + s0y + ody))
        local bx1 = math.max(ax0, math.min(ax1, x + s1x + odx))
        local by1 = math.max(ay0, math.min(ay1, y + s1y + ody))
        if bx1 > bx0 and by1 > by0 then Paint.outline(bb, bx0, by0, bx1 - bx0, by1 - by0, BLACKC, 2) end
    end
end

return InkAwayView
