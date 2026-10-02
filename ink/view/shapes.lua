--[[
The shape tool (drag to place, a second drag to bend a curve), editing a placed
shape from its menu, and the paint bucket.
Part of InkAwayView (see ink/view.lua).
]]

local ButtonDialog = require("ui/widget/buttondialog")
local GeomUI = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Canvas = require("ink/canvas")
local Export = require("ink/export")
local Fill = require("ink/fill")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Palette = require("ink/palette")
local Shapes = require("ink/shapes")
local Symmetry = require("ink/symmetry")

local SHADES = Palette.SHADES
local COLORS = Palette.COLORS
local translateOp = Canvas.translateOp
local displayColor = Paint.displayColor

local InkAwayView = {}

------------------------------------------------------------------------------
-- Shapes: rubber-band placement (drag to stretch, like a paint program). The
-- committed drawing in canvas_bb is never touched while stretching; the shape
-- is drawn on top in paintTo and only its changed rectangle is refreshed, so it
-- stays snappy. On release the shape is stamped into the master and folded in.
------------------------------------------------------------------------------

-- Screen-coordinate op for the current drag, drawn as the live preview.
local function screenShapeOp(self, shape, fill, x0, y0, x1, y1, cx, cy)
    local arrow, head
    if (shape == "line" or shape == "curve") and self.shape_arrow then
        arrow = self.shape_arrow
        head = self.arrow_head * self.view.zoom
    end
    return {
        kind = "shape", shape = shape, fill = fill, arrow = arrow, head = head,
        width = math.max(1, self.pen_width * self.view.zoom),
        color = self.pen_color, alpha = self.pen_alpha,
        pts = cx and { x0, y0, x1, y1, cx, cy } or { x0, y0, x1, y1 },
    }
end

-- Show the curve bending towards its control point.
local function previewCurve(self)
    local p0, p1, c = self.curve_p0, self.curve_p1, self.curve_ctrl
    self.shape_preview = screenShapeOp(self, "curve", false, p0.x, p0.y, p1.x, p1.y, c.x, c.y)
    self:refreshPreview()
end

-- Padded screen rect touched by a preview op.
function InkAwayView:previewRect(op)
    local x0, y0, x1, y1 = Shapes.bounds(op)
    local pad = op.width + 4
    return { x = math.floor(x0 - pad), y = math.floor(y0 - pad),
             x2 = math.ceil(x1 + pad), y2 = math.ceil(y1 + pad) }
end

-- Refresh the union of the previous and current preview rectangles, so the old
-- outline is wiped (from the untouched base) and the new one drawn.
function InkAwayView:refreshPreview()
    local r = self.shape_preview and self:previewRect(self.shape_preview) or nil
    local u = r
    local prev = self._preview_rect
    if prev then
        if u then
            u = { x = math.min(u.x, prev.x), y = math.min(u.y, prev.y),
                  x2 = math.max(u.x2, prev.x2), y2 = math.max(u.y2, prev.y2) }
        else
            u = prev
        end
    end
    self._preview_rect = r
    if not u then return end
    local x0, y0, x1, y1 = self:refreshAreaBox("fast", u.x, u.y, u.x2, u.y2)
    -- Region fast-path (see paintTo): while CREATING a shape (a live drag or the
    -- curve's bend stage) with no symmetry mirror to track, re-blit only this
    -- region instead of the whole surface + toolbar on every touch sample -- the
    -- full-repaint branch was why shape creation felt much slower than freehand,
    -- especially on a rotated landscape screen. Accumulate into any pending rect
    -- (u already unions the previous preview) so a skipped paint never strands an
    -- un-erased outline. Restricted to shape CREATION (not moving/rotating an
    -- existing shape, which can carry selection chrome outside this rect) and to
    -- symmetry off (previewRect covers only the un-mirrored shape).
    if x0 and (self.shape_drag or self.curve_stage) and self.symmetry == "off" then
        local v = self.view
        self._blit_rect = InkGeom.growRect(self._blit_rect,
            x0 - v.area_x, y0 - v.area_y, x1 - v.area_x, y1 - v.area_y)
    end
end

function InkAwayView:shapeTouch(pos)
    if self.curve_stage == "bend" then
        self.curve_ctrl = { x = pos.x, y = pos.y }
        previewCurve(self)
        return true
    end
    -- If a previous shape never got its release (a dropped lift event), place it
    -- now instead of silently losing it when this new drag begins.
    if self.shape_drag then
        if self.shape == "curve" then self:cancelShape() else self:commitShape() end
    end
    local x0, y0 = self:snapScreen(pos.x, pos.y)
    -- Snapshot the settings this shape is being drawn with, so a deferred commit
    -- (a missed lift, or a tool change) still places the shape it started as.
    self.shape_drag = { x0 = x0, y0 = y0, x1 = x0, y1 = y0,
        shape = self.shape, fill = self.shape_fill, arrow = self.shape_arrow,
        head = self.arrow_head, sym = self.symmetry,
        width = self.pen_width, alpha = self.pen_alpha, color = self.pen_color }
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, x0, y0, x0, y0)
    self:refreshPreview()
    return true
end

function InkAwayView:shapeMove(pos)
    if not pos then return true end
    if self.curve_stage == "bend" then
        local c = self.curve_ctrl
        if c and c.x == pos.x and c.y == pos.y then return true end   -- no change, skip
        self.curve_ctrl = { x = pos.x, y = pos.y }
        previewCurve(self)
        return true
    end
    if not self.shape_drag then return false end
    local d = self.shape_drag
    local nx, ny = self:shapeEndPoint(pos)
    if nx == d.x1 and ny == d.y1 then return true end   -- endpoint unchanged, skip the flash
    d.x1, d.y1 = nx, ny
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, d.x0, d.y0, d.x1, d.y1)
    self:refreshPreview()
    return true
end

-- Snap the drag's end point: to the grid (if on), and to 45-degree steps for a
-- line or curve (if angle snapping is on). Rectangles and ellipses are NOT
-- forced square, so you can draw any proportion.
function InkAwayView:shapeEndPoint(pos)
    local d = self.shape_drag
    local x1, y1 = self:snapScreen(pos.x, pos.y)
    if self.snap_angle and (self.shape == "line" or self.shape == "curve") then
        x1, y1 = InkGeom.snapAngle(d.x0, d.y0, x1, y1)
    end
    return x1, y1
end

function InkAwayView:shapeRelease(pos)
    if self.curve_stage == "bend" then
        if pos then self.curve_ctrl = { x = pos.x, y = pos.y } end
        self:commitCurve()
        return true
    end
    if not self.shape_drag then return false end
    if pos then self.shape_drag.x1, self.shape_drag.y1 = self:shapeEndPoint(pos) end
    local d = self.shape_drag
    local dx, dy = d.x1 - d.x0, d.y1 - d.y0
    if dx * dx + dy * dy < 9 then      -- basically a tap: nothing to place
        self:cancelShape()
        return true
    end
    if (d.shape or self.shape) == "curve" then
        -- keep the straight segment on screen and wait for a bend drag; carry
        -- the draw-time settings over to the eventual commit
        self.curve_p0 = { x = d.x0, y = d.y0 }
        self.curve_p1 = { x = d.x1, y = d.y1 }
        self.curve_ctrl = { x = (d.x0 + d.x1) / 2, y = (d.y0 + d.y1) / 2 }
        self.curve_snap = { arrow = d.arrow, head = d.head, sym = d.sym,
            width = d.width, alpha = d.alpha, color = d.color }
        self.curve_stage = "bend"
        self.shape_drag = nil
        return true
    end
    self:commitShape()
    return true
end

-- Give a freshly placed shape op its symmetry mode and, for a line or curve,
-- any arrowheads, before it is stamped in. `snap` is the settings captured when
-- the shape was started (see shapeTouch); it is used in preference to the live
-- settings so a shape always commits as it was drawn, even if the tool changed
-- between the draw and a deferred commit.
function InkAwayView:decorateShapeOp(op, snap)
    local sym = (snap and snap.sym) or self.symmetry
    if sym ~= "off" then op.sym = sym end
    local arrow = snap and snap.arrow
    if arrow == nil and not snap then arrow = self.shape_arrow end
    if (op.shape == "line" or op.shape == "curve") and arrow then
        op.arrow = arrow
        op.head = (snap and snap.head) or self.arrow_head
    end
end

function InkAwayView:commitShape()
    local d = self.shape_drag
    local c0x, c0y = self:toCanvasClamped(d.x0, d.y0)
    local c1x, c1y = self:toCanvasClamped(d.x1, d.y1)
    -- Use the settings snapshotted when the drag began, not the live ones: a
    -- finished shape whose lift was missed can be committed later, after the
    -- tool or shape type has changed, and it must still commit as what it was.
    local shape = d.shape or self.shape
    local fill = d.fill; if fill == nil then fill = self.shape_fill end
    local op = self.canvas:addShape(shape, fill,
        { c0x, c0y, c1x, c1y }, d.width or self.pen_width,
        d.alpha or self.pen_alpha, d.color or self.pen_color)
    self:decorateShapeOp(op, d)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    local sx0, sy0, sx1, sy1 = d.x0, d.y0, d.x1, d.y1
    self.shape_drag = nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderCommittedOp(op, sx0, sy0, sx1, sy1)   -- re-render only the shape's rect
    self:afterCommit()
end

function InkAwayView:commitCurve()
    local c0x, c0y = self:toCanvasClamped(self.curve_p0.x, self.curve_p0.y)
    local c1x, c1y = self:toCanvasClamped(self.curve_p1.x, self.curve_p1.y)
    local ccx, ccy = self:toCanvasClamped(self.curve_ctrl.x, self.curve_ctrl.y)
    local snap = self.curve_snap
    local op = self.canvas:addShape("curve", false,
        { c0x, c0y, c1x, c1y, ccx, ccy }, (snap and snap.width) or self.pen_width,
        (snap and snap.alpha) or self.pen_alpha, (snap and snap.color) or self.pen_color)
    self:decorateShapeOp(op, snap)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    -- the curve's screen extent = its two ends + control point (before they're cleared)
    local sx0 = math.min(self.curve_p0.x, self.curve_p1.x, self.curve_ctrl.x)
    local sy0 = math.min(self.curve_p0.y, self.curve_p1.y, self.curve_ctrl.y)
    local sx1 = math.max(self.curve_p0.x, self.curve_p1.x, self.curve_ctrl.x)
    local sy1 = math.max(self.curve_p0.y, self.curve_p1.y, self.curve_ctrl.y)
    self.curve_stage = nil
    self.curve_snap = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderCommittedOp(op, sx0, sy0, sx1, sy1)   -- re-render only the curve's rect
    self:afterCommit()
end

-- Drop any in-progress shape and wipe its preview.
function InkAwayView:cancelShape()
    if not (self.shape_drag or self.curve_stage or self.shape_preview) then return end
    self.shape_drag = nil
    self.curve_stage = nil
    self.curve_snap = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self:refreshPreview()   -- clears the old preview region from the base
end

-- Place a shape that is finished but still pending -- typically because its lift
-- event was missed on the touch panel -- before the tool or shape type changes
-- under it. A curve waiting for its bend is placed straight; a pending drag too
-- small to be a shape is dropped. Call this at every transition (tool switch,
-- opening the shape picker, changing the shape type) so a drawn shape is never
-- left as a stray preview to be dropped, nor re-typed into a different shape.
function InkAwayView:flushShape()
    if self.curve_stage == "bend" then
        self:commitCurve()
    elseif self.shape_drag then
        local d = self.shape_drag
        local dx, dy = d.x1 - d.x0, d.y1 - d.y0
        if dx * dx + dy * dy < 9 then self:cancelShape() else self:commitShape() end
    end
end

------------------------------------------------------------------------------
-- Paint bucket: flood fill an enclosed area on tap.
------------------------------------------------------------------------------

-- The top-most CLOSED shape whose interior contains a canvas point, or nil.
function InkAwayView:shapeUnderPoint(cx, cy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" and Shapes.contains(op, cx, cy) then
            return { op = op, idx = i }
        end
    end
    return nil
end

function InkAwayView:doFill(pos)
    self:flushPending()
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    -- Tapping inside a shape paints THAT shape's interior: the colour is stored on
    -- the shape itself (under its outline), so it moves, rotates, duplicates and
    -- deletes with the shape instead of being left behind. Copy-on-write, so a
    -- single Undo right after lifts just the fill and restores the empty shape.
    local shp = self:shapeUnderPoint(cx, cy)
    if shp then
        self:editOp(shp.idx, shp.op, function(o)
            o.fill_color = { self.fill_color[1], self.fill_color[2], self.fill_color[3] }
            o.fill_alpha = self.fill_alpha
        end)
        self:recompose()
        self:afterCommit()
        return
    end
    local gray = Export.buildGray(self.canvas)
    local runs = Fill.compute(gray, self.view.canvas_w, self.view.canvas_h,
        math.floor(cx), math.floor(cy), 40)
    if not runs or #runs == 0 then return end
    local op = self.canvas:addFillOp(runs, self.fill_color, self.fill_alpha)
    if self.symmetry ~= "off" then op.sym = self.symmetry end
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self:redraw()
    self:afterCommit()
end

------------------------------------------------------------------------------
-- Editing a placed shape: hold one to pick it, then rotate / recolour / resize
-- / delete it from a small menu anchored beside it.
------------------------------------------------------------------------------

-- Edit the op at `idx` as one undo step: it is copied, mutate(copy) changes the
-- copy, and the copy takes its place, so history snapshots keep the original.
-- Returns the copy.
function InkAwayView:editOp(idx, op, mutate)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(op)
    if mutate then mutate(clone) end
    self.canvas:replaceOp(idx, clone)
    self.dirty = true
    return clone
end

-- Move the op in `sel` to the top of the stack, so later marks no longer cover
-- it. Reordering the list is safe for history snapshots (the op is untouched).
function InkAwayView:opToFront(sel)
    local ops = self.canvas.ops
    if sel.idx >= #ops then return end
    self.canvas:pushHistory()
    local op = table.remove(ops, sel.idx)
    ops[#ops + 1] = op
    sel.idx = #ops
    self.dirty = true
    self:recompose()
end

-- Add a copy of the op in `sel`, offset a little down and right (a grid step
-- when the grid is on). Returns the selection for the copy.
function InkAwayView:duplicateOp(sel)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    local d = self.grid_on and self.grid_size or 14
    translateOp(clone, d, d)
    self.canvas.ops[#self.canvas.ops + 1] = clone
    self.dirty = true
    return { op = clone, idx = #self.canvas.ops }
end

-- Find the top-most shape op under a screen point. Returns {op, idx} or nil.
function InkAwayView:hitTestShape(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" then
            local tol = (op.width or 6) / 2 + 8 / self.view.zoom
            if Shapes.hit(op, cx, cy, tol) then return { op = op, idx = i } end
        end
    end
    return nil
end

-- A screen-coordinate copy of a shape op (for the rotate preview overlay).
function InkAwayView:screenShapeFromOp(op, angle)
    local v = self.view
    local sp = {}
    for i = 1, #op.pts, 2 do
        local sx, sy = InkGeom.toScreen(v, op.pts[i], op.pts[i + 1])
        sp[#sp + 1] = sx
        sp[#sp + 1] = sy
    end
    return {
        kind = "shape", shape = op.shape, fill = op.fill, angle = angle,
        closed = op.closed,
        width = math.max(1, (op.width or 2) * v.zoom),
        arrow = op.arrow, head = op.head and op.head * v.zoom or nil,
        color = op.color, alpha = op.alpha,
        fill_color = op.fill_color, fill_alpha = op.fill_alpha, pts = sp,
    }
end

-- Deselect the shape: close the menu, stop the canvas grabbing extra gestures,
-- and clear the selection. Called on a tap outside the menu (and by Done).
function InkAwayView:deselectShape()
    if self._shape_menu then
        local m = self._shape_menu; self._shape_menu = nil
        pcall(function() UIManager:close(m) end)
    end
    -- if a drag was somehow cut short, never leave the shape hidden from the master
    if self.selected and self.selected.op and self.selected.op.hidden then
        self.selected.op.hidden = nil
        self.shape_preview = nil; self._preview_rect = nil
        self:composeCanvas(); self:renderView()
    end
    self:setSelectionActive(false)
    self.selected = nil
    self.shape_move = nil
end

function InkAwayView:openShapeMenu(sel)
    self:closeSheet("_shape_menu")
    self:setSelectionActive(true)   -- keep the shape draggable while the menu is up
    local op = sel.op
    local dlg
    local function close() if dlg then UIManager:close(dlg) end end
    dlg = ButtonDialog:new{
        shrink_unneeded_width = true,
        tap_close_callback = function() self:deselectShape() end,
        anchor = function()
            local x0, y0, x1, y1 = Shapes.bounds(sel.op)
            local sx0, sy0 = InkGeom.toScreen(self.view, x0, y0)
            local sx1, sy1 = InkGeom.toScreen(self.view, x1, y1)
            return GeomUI:new{ x = math.floor(sx0), y = math.floor(sy0),
                               w = math.ceil(sx1 - sx0), h = math.ceil(sy1 - sy0) }
        end,
        buttons = {
            {
                { text = "\u{27F3} " .. _("Rotate"),  callback = function() close(); self:beginRotate(sel) end },
                { text = "\u{21BB} " .. _("90\u{00B0}"), callback = function() close(); self:rotateShape90(sel) end },
            },
            {
                { text = "\u{2194} " .. _("Flip H"),  callback = function() close(); self:flipShape(sel, "h") end },
                { text = "\u{2195} " .. _("Flip V"),  callback = function() close(); self:flipShape(sel, "v") end },
            },
            {
                { text = "\u{25B2} " .. _("To front"),  callback = function() close(); self:shapeToFront(sel) end },
                { text = "\u{29C9} " .. _("Duplicate"), callback = function() close(); self:duplicateSelected(sel) end },
            },
            {
                { text = "\u{25D1} " .. _("Colour"),  callback = function() close(); self:editSelectedColour(sel) end },
                { text = "\u{25A9} " .. _("Opacity"), callback = function() close(); self:editSelectedOpacity(sel) end },
                { text = "\u{25CF} " .. _("Size"),    callback = function() close(); self:editSelectedSize(sel) end },
            },
            {
                { text = "\u{2715} " .. _("Delete"), callback = function() close(); self:deleteSelected(sel) end },
                { text = _("Done"), callback = function() close(); self:deselectShape() end },
            },
        },
    }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

-- Rotate the selected shape a quarter turn about its centre (a handy preset next
-- to the free-rotate drag). Shapes carry op.angle in radians.
function InkAwayView:rotateShape90(sel)
    self:applyEdit(sel, function(o) o.angle = ((o.angle or 0) + math.pi / 2) end)
    self:openShapeMenu(sel)
end

-- Is a screen point on the given shape op (for picking it up to drag)?
function InkAwayView:pointOnShape(op, sx, sy)
    if not (op and op.kind == "shape") then return false end
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    local tol = (op.width or 6) / 2 + 12 / self.view.zoom
    return Shapes.hit(op, cx, cy, tol)
end

-- Drag a selected shape freely, like an image. The move is copy-on-write (a clone
-- is edited from the first movement) so undo restores the original position.
function InkAwayView:shapeMoveTouch(pos)
    self.shape_move = { sx = pos.x, sy = pos.y, began = false }
    return true
end

function InkAwayView:shapeMovePan(pos)
    local d = self.shape_move
    if not d then return true end
    local sel = self.selected
    if not sel then self.shape_move = nil; return true end
    if not d.began then
        -- First real movement: snapshot for undo, edit a clone, and drop it from the
        -- master ONCE. From here the drag is a cheap screen-space preview (a single
        -- Shapes.render into the changed rect), so recomposing every ops in the
        -- canvas per frame -- the old, frozen path -- never happens.
        sel.op = self:editOp(sel.idx, sel.op, function(o) o.hidden = true end)
        d.began = true
        d.lastx, d.lasty = d.sx, d.sy
        self:composeCanvas(); self:renderView()   -- once: the master, minus the shape
        self._preview_rect = nil
    end
    local v = self.view
    local dx = (pos.x - d.lastx) / v.zoom
    local dy = (pos.y - d.lasty) / v.zoom
    d.lastx, d.lasty = pos.x, pos.y
    translateOp(sel.op, dx, dy)
    self.shape_preview = self:screenShapeFromOp(sel.op, sel.op.angle or 0)
    self:refreshPreview()   -- only the old+new preview rects repaint
    return true
end

function InkAwayView:shapeMoveRelease()
    if self.shape_move then
        local moved = self.shape_move.began
        self.shape_move = nil
        if moved then
            local sel = self.selected
            if sel and sel.op then sel.op.hidden = nil end   -- bake it back into the master
            self.shape_preview = nil
            self._preview_rect = nil
            self:composeCanvas(); self:renderView()
        end
        if self._shape_menu then self:openShapeMenu(self.selected) end   -- re-anchor the menu
        self:refreshArea()
    end
    return true
end

-- Apply an edit to the selected op through copy-on-write, so undo/redo work.
function InkAwayView:applyEdit(sel, mutate)
    local clone = self:editOp(sel.idx, sel.op, mutate)
    sel.op = clone
    if self.selected then self.selected.op = clone end
    self:recompose()
end

function InkAwayView:deleteSelected(sel)
    self.canvas:pushHistory()
    self.canvas:removeOp(sel.idx)
    self.selected = nil
    self.shape_move = nil
    self:setSelectionActive(false)
    self:resetLasso()
    self.dirty = true
    self:recompose()
end

-- Duplicate the selected shape, offset a little, and select the copy.
function InkAwayView:duplicateSelected(sel)
    self.selected = self:duplicateOp(sel)
    self:recompose()
    self:openShapeMenu(self.selected)
end

-- Flip the selected shape across the middle of its own bounding box (mirrors the
-- image Flip H / Flip V). Reflecting the defining points and negating the rotation
-- angle mirrors the shape exactly, whatever its rotation.
function InkAwayView:flipShape(sel, axis)
    self:applyEdit(sel, function(o)
        local p = o.pts
        local start = axis == "h" and 1 or 2   -- x's are odd indices, y's even
        local lo, hi = p[start], p[start]
        for i = start, #p, 2 do
            if p[i] < lo then lo = p[i] elseif p[i] > hi then hi = p[i] end
        end
        local s = lo + hi
        for i = start, #p, 2 do p[i] = s - p[i] end
        o.angle = -(o.angle or 0)
    end)
    self:openShapeMenu(sel)
end

-- Move the selected shape to the top of the stack, so later marks no longer cover
-- it (mirrors the image To front). Reordering the array is snapshot-safe.
function InkAwayView:shapeToFront(sel)
    self:opToFront(sel)
    self:openShapeMenu(sel)
end

function InkAwayView:editSelectedColour(sel)
    local dlg
    local function pick(rgb)
        self:applyEdit(sel, function(o) o.color = { rgb[1], rgb[2], rgb[3] } end)
        UIManager:close(dlg)
        self:editSelectedColour(sel)   -- reopen to move the selection border
    end
    local buttons = { self:swatchRowFor(SHADES, sel.op.color, pick) }
    if self:colorScreen() then
        buttons[#buttons + 1] = self:swatchRowFor(COLORS, sel.op.color, pick)
    end
    buttons[#buttons + 1] = {{ text = _("Done"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = _("Shape colour"), title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

function InkAwayView:editSelectedSize(sel)
    local op = sel.op
    UIManager:show(SpinWidget:new{
        title_text = _("Shape line size"),
        value = op.width, value_min = 1, value_max = 60, value_step = 1, value_hold_step = 6,
        unit = _("px"),
        callback = function(spin)
            self:applyEdit(sel, function(o) o.width = math.max(1, math.floor(spin.value)) end)
        end,
    })
end

function InkAwayView:editSelectedOpacity(sel)
    local op = sel.op
    UIManager:show(SpinWidget:new{
        title_text = _("Shape opacity"),
        value = math.floor((op.alpha or 255) / 255 * 100 + 0.5),
        value_min = 5, value_max = 100, value_step = 5, value_hold_step = 20,
        unit = "%",
        callback = function(spin)
            self:applyEdit(sel, function(o)
                o.alpha = math.max(1, math.min(255, math.floor(spin.value / 100 * 255 + 0.5)))
            end)
        end,
    })
end

-- Rotation: hide the shape from the master, show it as a preview, and let a drag
-- spin it freely about its centre. Cheap per frame (only the preview redraws).
function InkAwayView:beginRotate(sel)
    local op = sel.op
    self:setSelectionActive(false)   -- the menu is gone; rotate routes at the top
    self.shape_move = nil
    op.hidden = true
    self.rotating = { op = op, idx = sel.idx, base = op.angle or 0, cur = op.angle or 0 }
    self:composeCanvas(); self:renderView()
    self.shape_preview = self:screenShapeFromOp(op, op.angle or 0)
    self._preview_rect = nil
    self:refreshPreview()
    self:refreshArea()
    UIManager:show(InfoMessage:new{
        text = _("Drag anywhere to rotate the shape; lift to finish."), timeout = 2 })
end

function InkAwayView:rotateCentreScreen(op)
    if op.shape == "poly" then
        local minx, miny, maxx, maxy = InkGeom.bounds(op.pts)
        return InkGeom.toScreen(self.view, (minx + maxx) / 2, (miny + maxy) / 2)
    end
    local x0, y0, x1, y1 = op.pts[1], op.pts[2], op.pts[3], op.pts[4]
    return InkGeom.toScreen(self.view, (x0 + x1) / 2, (y0 + y1) / 2)
end

function InkAwayView:rotateTouch(pos)
    local r = self.rotating
    local cx, cy = self:rotateCentreScreen(r.op)
    r.cx, r.cy = cx, cy
    r.grab = math.atan2(pos.y - cy, pos.x - cx)
    return true
end

function InkAwayView:rotateMove(pos)
    local r = self.rotating
    if not r.grab then return self:rotateTouch(pos) end
    local a = math.atan2(pos.y - r.cy, pos.x - r.cx)
    r.cur = r.base + (a - r.grab)
    self.shape_preview = self:screenShapeFromOp(r.op, r.cur)
    self:refreshPreview()
    return true
end

function InkAwayView:rotateEnd()
    local r = self.rotating
    if not r then return true end
    r.op.hidden = nil
    self.rotating = nil
    self.shape_preview = nil
    self._preview_rect = nil
    if math.abs((r.cur or r.base) - r.base) > 1e-4 then
        -- commit the new angle through copy-on-write so it can be undone
        local clone = self:editOp(r.idx, r.op, function(o) o.angle = r.cur end)
        if self.selected then self.selected.op = clone end
    end
    self:recompose()
    return true
end

-- The shape being placed, over the drawing and clipped to the area.
function InkAwayView:paintShapePreview(bb, x, y)
    local v = self.view
    local sw = self.screen_w
    local cy0, cy1 = y + v.area_y, y + v.area_y + v.area_h
    local mirror = self.symmetry ~= "off"
    local axsx, axsy
    if mirror then
        axsx = v.area_x + (v.canvas_w / 2 - v.pan_x) * v.zoom
        axsy = v.area_y + (v.canvas_h / 2 - v.pan_y) * v.zoom
    end
    local function makePut(color)
        local put = function(px, py, len)
            py = py + y
            if py < cy0 or py >= cy1 then return end
            px = px + x
            if px < x then len = len + (px - x); px = x end
            if px + len > x + sw then len = x + sw - px end
            if len > 0 then bb:paintRect(px, py, len, 1, color) end
        end
        -- mirror the preview too, so a symmetric shape shows before it is placed
        if mirror then
            put = Symmetry.wrap(put, self.symmetry,
                function(px, len) return 2 * axsx - px - len end,
                function(py) return 2 * axsy - py end)
        end
        return put
    end
    local sp = self.shape_preview
    if sp.fill_color and not sp.fill then
        Shapes.fill(sp, makePut(displayColor(sp.fill_color, sp.fill_alpha)))
    end
    Shapes.render(sp, makePut(displayColor(sp.color, sp.alpha)))
end

return InkAwayView
