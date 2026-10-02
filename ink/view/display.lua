--[[
Getting the page onto the screen: the on-screen buffer and the master mirror kept
in the panel's pixel order, rendering, refresh helpers and pacing, and the grid.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local GeomUI = require("ui/geometry")
local RenderImage = require("ui/renderimage")
local UIManager = require("ui/uimanager")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Symmetry = require("ink/symmetry")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local FRAME = Blitbuffer.COLOR_GRAY
local strengthToLevel = Paint.strengthToLevel
local growRect = InkGeom.growRect

-- A w x h buffer stored in the panel's pixel order: physically turned by `rot`
-- quarter turns, so drawing into it still uses ordinary (logical) coordinates.
local function panelBuffer(w, h, rot, inv, typ)
    if rot % 2 == 1 then w, h = h, w end
    local bb = Blitbuffer.new(w, h, typ)
    if bb.setRotation then bb:setRotation(rot) end
    if bb.setInverse then bb:setInverse(inv) end
    return bb
end

-- Live-ink pacing on colour (Kaleido) panels, where each refresh costs the driver
-- far more than on grey e-ink. The fast black-and-white waveform is sent at most
-- every LIVE_FAST_MS and the grey-capable one (which blocks until the driver takes
-- it) every LIVE_UI_MS; the last samples of a burst follow within LIVE_TAIL_MS.
-- The true colours settle in one refresh RECONCILE_SEC after the pen rests.
local LIVE_FAST_MS = 20
local LIVE_UI_MS = 80
local LIVE_TAIL_MS = 35
local RECONCILE_SEC = 0.8

local InkAwayView = {}

------------------------------------------------------------------------------
-- On-screen buffer in the panel's pixel order
--
-- A device that shows landscape by rotating its framebuffer in software (many
-- Kindles) makes every plain blit onto Screen.bb a per-pixel rotated copy, about
-- ten times slower than the row copies of portrait. So area_bb is built in the
-- screen's own pixel order: it has the panel's dimensions and the screen's
-- rotation, so drawing into it uses ordinary area coordinates while its bytes are
-- already turned. Copying it onto the screen is then a row copy between unrotated
-- views of both buffers. Where Screen.bb is not rotated (hardware rotation, the
-- SDL emulator) this is just the ordinary blit.
------------------------------------------------------------------------------

function InkAwayView:screenBBRot() return Screen.bb.getRotation and Screen.bb:getRotation() or 0 end
function InkAwayView:screenBBInv() return Screen.bb.getInverse and Screen.bb:getInverse() or 0 end

-- Allocate area_bb in the panel's pixel order, recording the rotation, inversion
-- and type it was built for. Turning from one landscape to the other keeps the
-- screen size (so no relayout) but flips the pixel order; matchAreaTarget notices.
function InkAwayView:newAreaBuffer()
    local v = self.view
    local rot, inv, typ = self:screenBBRot(), self:screenBBInv(), Screen.bb:getType()
    self._area_rot, self._area_inv, self._area_type = rot, inv, typ
    return panelBuffer(v.area_w, v.area_h, rot, inv, typ)
end

-- Rebuild and re-render area_bb if the screen's rotation, inversion or buffer type
-- changed since it was made. Runs at the start of every paint; cheap otherwise.
function InkAwayView:matchAreaTarget()
    if not self.area_bb then return end
    if self:screenBBRot() ~= self._area_rot or self:screenBBInv() ~= self._area_inv
            or Screen.bb:getType() ~= self._area_type then
        self.area_bb:free()
        self.area_bb = self:newAreaBuffer()
        self:renderView()
    end
end

-- A rotation-0 view over another buffer's raw bytes, so a blit through it is a
-- plain row copy rather than a rotated per-pixel one.
function InkAwayView:physView(bb)
    local p = Blitbuffer.new(bb.w, bb.h, bb:getType(), bb.data, bb.stride, bb.pixel_stride)
    if p.setInverse then p:setInverse(bb:getInverse()) end
    return p
end

-- Copy the logical rect (sx, sy, w, h) of area_bb to screen (dstx, dsty). With a
-- rotated screen it copies between the physical views of both buffers, which is
-- byte-identical to the rotated blit and 40-60 times faster; that keeps a live
-- stroke's growing region from lagging behind the pen in landscape.
function InkAwayView:blitAreaRect(bb, dstx, dsty, sx, sy, w, h)
    local area = self.area_bb
    if self._area_rot == 0 then
        bb:blitFrom(area, dstx, dsty, sx, sy, w, h)
        return
    end
    local dpx, dpy, dpw, dph = bb:getPhysicalRect(dstx, dsty, w, h)
    local apx, apy = area:getPhysicalRect(sx, sy, w, h)
    self:physView(bb):blitFrom(self:physView(area), dpx, dpy, apx, apy, dpw, dph)
end

-- Copy the whole area_bb onto the screen at (dstx, dsty).
function InkAwayView:blitAreaFull(bb, dstx, dsty)
    local v = self.view
    self:blitAreaRect(bb, dstx, dsty, 0, 0, v.area_w, v.area_h)
end

------------------------------------------------------------------------------
-- Master mirror in the panel's pixel order
--
-- On a rotated screen, rendering would otherwise scale the master (canvas_bb) and
-- write it into area_bb with a rotated per-pixel copy on every pan, zoom or
-- redraw. canvas_panel_bb mirrors canvas_bb in the screen's pixel order, so a
-- crop of it scales straight into area_bb through physical views. The rotation
-- is paid only when the mirror is synced: in full after a compose or a rotation
-- change, and over just the changed rect after a commit. Portrait keeps no mirror.
-- canvas_bb and the export stay in logical coordinates; a landscape downscale can
-- differ from a portrait one by a grey level on a few pixels, on screen only.
------------------------------------------------------------------------------

-- Allocate the mirror at the canvas size with area_bb's rotation and type (they
-- must agree for the physical copies to line up).
function InkAwayView:newCanvasPanelBuffer()
    local v = self.view
    local cw, ch = v.canvas_w, v.canvas_h
    local rot = self._area_rot or 0
    local typ = self._area_type or Screen.bb:getType()
    -- The mirror holds canvas_bb's bytes, which are never inverted, so it takes
    -- area_bb's rotation but not its inverse: night mode is applied only by the
    -- final copy into area_bb.
    local inv = (self.canvas_bb and self.canvas_bb.getInverse and self.canvas_bb:getInverse()) or 0
    self._cpanel_rot, self._cpanel_type = rot, typ
    self._cpanel_cw, self._cpanel_ch = cw, ch
    return panelBuffer(cw, ch, rot, inv, typ)
end

-- Make sure the mirror exists and matches the current rotation and size (in
-- portrait there is none). A rebuilt mirror is synced with one full copy.
function InkAwayView:ensureCanvasPanel()
    if not self.canvas_bb then return end
    local rot = self._area_rot or 0
    if rot % 2 == 0 then
        if self.canvas_panel_bb then self.canvas_panel_bb:free(); self.canvas_panel_bb = nil end
        self._cpanel_dirty = nil
        return
    end
    local v = self.view
    local typ = self._area_type or Screen.bb:getType()
    -- inverse is left out on purpose: a night-mode change only rebuilds area_bb
    local stale = (not self.canvas_panel_bb)
        or self._cpanel_rot ~= rot or self._cpanel_type ~= typ
        or self._cpanel_cw ~= v.canvas_w or self._cpanel_ch ~= v.canvas_h
    if stale then
        if self.canvas_panel_bb then self.canvas_panel_bb:free() end
        self.canvas_panel_bb = self:newCanvasPanelBuffer()
        self.canvas_panel_bb:blitFrom(self.canvas_bb, 0, 0, 0, 0, v.canvas_w, v.canvas_h)
        self._cpanel_dirty = nil   -- the full copy synced everything
    end
end

-- Note a canvas rect whose pixels changed in canvas_bb, so the next render
-- resyncs just that part of the mirror.
function InkAwayView:markCanvasDirty(x0, y0, x1, y1)
    if x1 <= x0 or y1 <= y0 then return end
    self._cpanel_dirty = growRect(self._cpanel_dirty, x0, y0, x1, y1)
end

-- The same, from a span writer's acc table ({x0, y0, x1, y1}, empty when x1 < x0).
function InkAwayView:markCanvasDirtyAcc(acc)
    if acc and acc.x1 >= acc.x0 and acc.y1 >= acc.y0 then
        self:markCanvasDirty(acc.x0, acc.y0, acc.x1, acc.y1)
    end
end

-- Copy the pending changed rect from canvas_bb into the mirror. Called before
-- any render reads the mirror.
function InkAwayView:flushCanvasPanel()
    local d = self._cpanel_dirty
    if not (d and self.canvas_panel_bb and self.canvas_bb) then self._cpanel_dirty = nil; return end
    self._cpanel_dirty = nil
    local v = self.view
    local x0 = math.max(0, math.floor(d.x0)); local y0 = math.max(0, math.floor(d.y0))
    local x1 = math.min(v.canvas_w, math.ceil(d.x1)); local y1 = math.min(v.canvas_h, math.ceil(d.y1))
    local w, h = x1 - x0, y1 - y0
    if w < 1 or h < 1 then return end
    self.canvas_panel_bb:blitFrom(self.canvas_bb, x0, y0, x0, y0, w, h)
end

-- Scale the canvas crop (scx, scy, sw, sh) to dw x dh and put bw x bh of it into
-- area_bb at (dx, dy). In landscape this scales a physical view of the mirror and
-- copies into area_bb's physical bytes, so nothing is rotated per pixel.
function InkAwayView:blitScaledPanel(scx, scy, sw, sh, dw, dh, dx, dy, bw, bh)
    if bw < 1 or bh < 1 or sw < 1 or sh < 1 then return end
    local area = self.area_bb
    local rot = self._area_rot or 0
    if rot == 0 then
        local sub = self.canvas_bb:viewport(scx, scy, sw, sh)
        local scaled = RenderImage:scaleBlitBuffer(sub, dw, dh, false)
        area:blitFrom(scaled, dx, dy, 0, 0, bw, bh)
        if scaled ~= sub and scaled.free then scaled:free() end
        return
    end
    local cp = self.canvas_panel_bb
    if not cp then return end
    local px, py, pw, ph = cp:getPhysicalRect(scx, scy, sw, sh)
    local sub = self:physView(cp):viewport(px, py, pw, ph)
    local fdw, fdh = dw, dh
    if rot % 2 == 1 then fdw, fdh = dh, dw end
    local scaled = RenderImage:scaleBlitBuffer(sub, fdw, fdh, false)
    if scaled.setRotation then scaled:setRotation(rot) end
    local sx2, sy2 = scaled:getPhysicalRect(0, 0, bw, bh)
    local ax, ay, aw2, ah2 = area:getPhysicalRect(dx, dy, bw, bh)
    self:physView(area):blitFrom(self:physView(scaled), ax, ay, sx2, sy2, aw2, ah2)
    if scaled ~= sub and scaled.free then scaled:free() end
end

------------------------------------------------------------------------------
-- Refreshing
------------------------------------------------------------------------------

-- The drawing area as a screen rect (a fresh Geom each call: setDirty keeps the
-- region by reference).
function InkAwayView:areaScreenRect()
    local v = self.view
    -- Callers use this as a setDirty region, which never covers the toolbar or the
    -- notebook bar, so the next paintTo may skip repainting that chrome (slow on a
    -- rotated screen). Chrome changes (tool switch, relayout, hiding a bar) clear
    -- the flag so their own refresh is never skipped.
    self._area_only = true
    return GeomUI:new{ x = v.area_x, y = v.area_y, w = v.area_w, h = v.area_h }
end

-- Refresh the drawing area.
function InkAwayView:refreshArea()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Re-render the on-screen buffer from the master and refresh the drawing area.
function InkAwayView:redraw()
    self:renderView()
    self:refreshArea()
end

-- Rebuild the master from the ops, then redraw.
function InkAwayView:recompose()
    self:composeCanvas()
    self:redraw()
end

-- Refresh the screen box (x0, y0)-(x1, y1) clipped to the drawing area. Returns the
-- clipped box, or nil when none of it is on the area.
function InkAwayView:refreshAreaBox(mode, x0, y0, x1, y1)
    local v = self.view
    x0, y0 = math.max(v.area_x, x0), math.max(v.area_y, y0)
    x1, y1 = math.min(v.area_x + v.area_w, x1), math.min(v.area_y + v.area_h, y1)
    if x1 <= x0 or y1 <= y0 then return nil end
    UIManager:setDirty(self, mode, GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    return x0, y0, x1, y1
end

-- Refresh the union of two screen rects ({x, y, w, h}), each grown by `pad`.
function InkAwayView:refreshRectUnion(a, b, pad, mode)
    return self:refreshAreaBox(mode, math.min(a.x, b.x) - pad, math.min(a.y, b.y) - pad,
        math.max(a.x + a.w, b.x + b.w) + pad, math.max(a.y + a.h, b.y + b.h) + pad)
end

-- Is this a colour (Kaleido) panel? A full-screen flash is cheap on grey e-ink but
-- costs a second or two of colour waveform there, so colour gets lighter refreshes.
function InkAwayView:colourPanel()
    if self._is_colour == nil then self._is_colour = self:colorScreen() end
    return self._is_colour
end

-- setDirty, except that on a colour panel a "full" refresh becomes a non-flashing
-- "ui" one over the same region. Use it where only the pixels need updating (tool
-- switches, bar toggles, page turns, committing a text box); keep a plain "full"
-- setDirty for the flashes that clear ghosting (open, close, rotation, the
-- periodic clean-up, page-wide content swaps).
function InkAwayView:refresh(target, mode, region)
    if self:colourPanel() and mode == "full" then mode = "ui" end
    UIManager:setDirty(target, mode, region)
end

-- A stroke's changed rect (area-local) and one rect per mirror image of the current
-- symmetry, so a symmetric stroke refreshes a few small rects instead of one box
-- spanning all of them. Runs for every drawn point, so it returns a reused pool:
-- read each rect before the next call.
function InkAwayView:symAreaRects(acc)
    local p = self._sar_pool
    if not p then p = { {}, {}, {}, {} }; self._sar_pool = p end
    local v = self.view
    return Symmetry.mirrorRects(acc, self.symmetry, (v.canvas_w - 2 * v.pan_x) * v.zoom,
        (v.canvas_h - 2 * v.pan_y) * v.zoom, p)
end

-- An area-local rect padded by `pad`, rounded outward and clipped to the drawing
-- area; nil when nothing is left.
local function clipToArea(v, r, pad)
    pad = pad or 0
    local x0 = math.max(0, math.floor(r.x0) - pad)
    local y0 = math.max(0, math.floor(r.y0) - pad)
    local x1 = math.min(v.area_w, math.ceil(r.x1) + pad)
    local y1 = math.min(v.area_h, math.ceil(r.y1) + pad)
    if x1 <= x0 or y1 <= y0 then return nil end
    return x0, y0, x1, y1
end

-- Refresh one area-local rect, clipped to the drawing area, at `mode`.
function InkAwayView:dirtyAreaRect(mode, r, pad)
    local v = self.view
    local x0, y0, x1, y1 = clipToArea(v, r, pad)
    if not x0 then return end
    -- during a live stroke only these rects of area_bb change, so paintTo blits
    -- just their union (area-local) instead of the whole drawing area
    if self.capturing then self._blit_rect = growRect(self._blit_rect, x0, y0, x1, y1) end
    UIManager:setDirty(self, mode, GeomUI:new{
        x = v.area_x + x0, y = v.area_y + y0, w = x1 - x0, h = y1 - y0 })
end

-- Milliseconds on a monotonic clock (KOReader's ui/time), for refresh pacing.
local TimeMod
function InkAwayView:nowMs()
    if TimeMod == nil then
        local ok, t = pcall(require, "ui/time")
        TimeMod = ok and t or false
    end
    if TimeMod then return TimeMod.to_ms(TimeMod.now()) end
    return os.time() * 1000
end

-- Refresh a live-drawing rect. On grey e-ink this is dirtyAreaRect. On a colour
-- panel the rect joins the pending one, which is sent at a bounded pace (see
-- LIVE_*_MS): the first sample shows at once, later ones go with the next update.
function InkAwayView:liveDirty(mode, r, pad)
    if not self:colourPanel() then return self:dirtyAreaRect(mode, r, pad) end
    local x0, y0, x1, y1 = clipToArea(self.view, r, pad)
    if not x0 then return end
    if self.capturing then self._blit_rect = growRect(self._blit_rect, x0, y0, x1, y1) end
    local fresh = not self._live_pend
    local p = growRect(self._live_pend, x0, y0, x1, y1)
    self._live_pend = p
    if fresh or mode ~= "fast" then p.mode = mode end
    local gap = (p.mode == "fast") and LIVE_FAST_MS or LIVE_UI_MS
    local elapsed = self:nowMs() - (self._live_last or -math.huge)
    if elapsed >= gap then
        self:liveFlush()
    elseif not self._live_flush_armed then
        self._live_flush_armed = true
        UIManager:scheduleIn(math.max(LIVE_TAIL_MS, gap - elapsed) / 1000, self._live_flush_cb)
    end
end

-- Send the pending live rect now, if there is one.
function InkAwayView:liveFlush()
    if self._live_flush_armed then
        UIManager:unschedule(self._live_flush_cb)
        self._live_flush_armed = false
    end
    local p = self._live_pend
    if not p or self.closing then self._live_pend = nil; return end
    self._live_pend = nil
    self._live_last = self:nowMs()
    local v = self.view
    UIManager:setDirty(self, p.mode, GeomUI:new{
        x = v.area_x + p.x0, y = v.area_y + p.y0, w = p.x1 - p.x0, h = p.y1 - p.y0 })
end

-- Colour panels: remember an area-local rect whose true colours still need a
-- grey-capable refresh, and restart the settle timer. Each new stroke pushes it
-- back, so a slow refresh never runs under the next letter.
function InkAwayView:queueReconcile(r, pad)
    pad = pad or 0
    self._reconcile = growRect(self._reconcile, r.x0 - pad, r.y0 - pad, r.x1 + pad, r.y1 + pad)
    UIManager:unschedule(self._reconcile_cb)
    UIManager:scheduleIn(RECONCILE_SEC, self._reconcile_cb)
end

function InkAwayView:runReconcile()
    UIManager:unschedule(self._reconcile_cb)
    if self.closing then self._reconcile = nil; return end
    if self.capturing or (self._pen_state and self._pen_state.down) then
        UIManager:scheduleIn(RECONCILE_SEC, self._reconcile_cb)   -- still writing
        return
    end
    local q = self._reconcile
    self._reconcile = nil
    if q then
        self._area_only = true          -- only drawing-area pixels changed
        self:dirtyAreaRect("ui", q, 0)
    end
end

------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------

-- Rebuild the on-screen buffer from the master: scale the visible crop of
-- canvas_bb into area_bb with mupdf's C scaler. One scale of one screenful,
-- however far zoomed and however much is drawn, is what keeps zoom and pan cheap.
function InkAwayView:renderView()
    if not (self.area_bb and self.canvas_bb) then return end
    self._blit_rect = nil   -- the whole area_bb is rebuilt, so paintTo must blit it all,
    -- even if a stroke starts before that paint (a page turn and a pen landing in
    -- the same input batch): its small rect must not replace the full blit
    self._full_blit = true
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    -- sync the mirror before scaling from it (in portrait canvas_bb is used directly)
    self:ensureCanvasPanel()
    self:flushCanvasPanel()

    -- visible crop of the canvas, clamped inside it
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local sw = math.max(1, math.min(W - sx, math.ceil(v.area_w / v.zoom)))
    local sh = math.max(1, math.min(H - sy, math.ceil(v.area_h / v.zoom)))

    local dw = math.max(1, math.floor(sw * v.zoom))
    local dh = math.max(1, math.floor(sh * v.zoom))
    -- where the crop lands: a margin when the whole page fits, or a sub-pixel nudge
    -- when zoomed in, clamped and trimmed so the blit stays inside the area
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    local bw = math.min(dw, v.area_w - ox)
    local bh = math.min(dh, v.area_h - oy)
    -- clear to white only when the blit leaves part of the area uncovered, which
    -- saves a screenful of fill per frame while panning zoomed in
    if ox > 0 or oy > 0 or bw < v.area_w or bh < v.area_h then
        self.area_bb:paintRect(0, 0, v.area_w, v.area_h, WHITE)
    end
    if bw < 1 or bh < 1 then return end

    self:blitScaledPanel(sx, sy, sw, sh, dw, dh, ox, oy, bw, bh)
    -- the grid is painted over the screen in paintTo (see drawGrid), never into
    -- area_bb, so the eraser cannot remove it and the export never contains it
end

-- Re-render just an area-local rect from the master, the way renderView does the
-- whole area. The soft eraser updates the screen along its path with this.
function InkAwayView:renderViewRect(cx0, cy0, cx1, cy1)
    if not (self.area_bb and self.canvas_bb) then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    self:ensureCanvasPanel()
    self:flushCanvasPanel()
    cx0 = math.max(0, math.floor(cx0)); cy0 = math.max(0, math.floor(cy0))
    cx1 = math.min(v.area_w, math.ceil(cx1)); cy1 = math.min(v.area_h, math.ceil(cy1))
    if cx1 <= cx0 or cy1 <= cy0 then return end
    -- the same crop origin and landing offset as renderView
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    -- the canvas pixels behind the requested area rect
    local scx0 = math.max(0, math.min(W, sx + math.floor((cx0 - ox) / v.zoom)))
    local scy0 = math.max(0, math.min(H, sy + math.floor((cy0 - oy) / v.zoom)))
    local scx1 = math.max(0, math.min(W, sx + math.ceil((cx1 - ox) / v.zoom)))
    local scy1 = math.max(0, math.min(H, sy + math.ceil((cy1 - oy) / v.zoom)))
    local sw, sh = scx1 - scx0, scy1 - scy0
    if sw < 1 or sh < 1 then return end
    -- where those pixels land in the area
    local dx = ox + math.floor((scx0 - sx) * v.zoom)
    local dy = oy + math.floor((scy0 - sy) * v.zoom)
    local dw = math.max(1, math.floor(sw * v.zoom))
    local dh = math.max(1, math.floor(sh * v.zoom))
    local bw = math.min(dw, v.area_w - dx)
    local bh = math.min(dh, v.area_h - dy)
    if bw < 1 or bh < 1 then return end
    self.area_bb:paintRect(dx, dy, bw, bh, WHITE)
    self:blitScaledPanel(scx0, scy0, sw, sh, dw, dh, dx, dy, bw, bh)
end

-- A one-pixel line into `bb` at screen offset (ox, oy), clipped to the box
-- (bx0, by0)-(bx1, by1), the whole area by default.
function InkAwayView:gridLine(bb, ox, oy, x0, y0, x1, y1, color, bx0, by0, bx1, by1)
    local aw, ah = self.view.area_w, self.view.area_h
    bx0 = bx0 or 0; by0 = by0 or 0; bx1 = bx1 or aw; by1 = by1 or ah
    -- skip a segment whose bounding box misses the clip box
    if math.max(x0, x1) < bx0 or math.min(x0, x1) > bx1
        or math.max(y0, y1) < by0 or math.min(y0, y1) > by1 then return end
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then return end
    local ix, iy = dx / steps, dy / steps
    local x, y = x0, y0
    for _ = 0, steps do
        local px, py = math.floor(x + 0.5), math.floor(y + 0.5)
        if px >= bx0 and px < bx1 and py >= by0 and py < by1 then bb:paintRect(ox + px, oy + py, 1, 1, color) end
        x = x + ix; y = y + iy
    end
end

-- Draw the grid into `bb` at screen offset (ox, oy). It is painted over the screen
-- each frame and never into area_bb, so the eraser leaves it alone and the export
-- never contains it. `clip` (area-local {x0, y0, x1, y1}) limits it to the region
-- a live stroke re-blits, so a fine grid costs nothing per point while drawing.
function InkAwayView:drawGrid(bb, ox, oy, clip)
    local v = self.view
    local aw, ah = v.area_w, v.area_h
    local g = self.grid_size
    local style = self.grid_style or "square"
    -- strength 1..100 maps to a grey, from a faint guide to as dark as ink
    local lvl = strengthToLevel(self.grid_strength)
    local col = Blitbuffer.ColorRGB32(lvl, lvl, lvl, 0xFF)
    -- clip box in area coords (the whole area without a clip)
    local bx0 = clip and math.max(0, math.floor(clip.x0)) or 0
    local by0 = clip and math.max(0, math.floor(clip.y0)) or 0
    local bx1 = clip and math.min(aw, math.ceil(clip.x1)) or aw
    local by1 = clip and math.min(ah, math.ceil(clip.y1)) or ah
    if bx1 <= bx0 or by1 <= by0 then return end
    local function ax(cx) return (cx - v.pan_x) * v.zoom end
    local function ay(cy) return (cy - v.pan_y) * v.zoom end
    -- a rect in area coords, clipped to the clip box and offset onto bb
    local function rect(px, py, w, h, c)
        local x0 = math.max(px, bx0); local y0 = math.max(py, by0)
        local x1 = math.min(px + w, bx1); local y1 = math.min(py + h, by1)
        if x1 > x0 and y1 > y0 then bb:paintRect(ox + x0, oy + y0, x1 - x0, y1 - y0, c) end
    end
    -- the canvas span behind the clip box, so the loops below visit only the lines
    -- that can land inside it
    local cxA = math.max(0, bx0 / v.zoom + v.pan_x)
    local cxB = math.min(v.canvas_w, bx1 / v.zoom + v.pan_x)
    local cyA = math.max(0, by0 / v.zoom + v.pan_y)
    local cyB = math.min(v.canvas_h, by1 / v.zoom + v.pan_y)

    if style == "thirds" then
        -- rule of thirds over the page
        for i = 1, 2 do
            local x = ax(v.canvas_w * i / 3)
            if x >= 0 and x < aw then rect(math.floor(x), 0, 1, ah, col) end
            local y = ay(v.canvas_h * i / 3)
            if y >= 0 and y < ah then rect(0, math.floor(y), aw, 1, col) end
        end
        return
    end

    if not g or g <= 0 then return end

    if style == "lines" then                       -- ruled horizontal lines
        local cy = math.floor(cyA / g) * g
        while cy <= cyB do
            local y = math.floor(ay(cy))
            if y >= 0 and y < ah then rect(0, y, aw, 1, col) end
            cy = cy + g
        end
    elseif style == "dots" then                     -- a dot at each intersection
        local dot = math.max(3, math.floor(Screen:scaleBySize(3)))
        local dcol = col
        local cxStart = math.floor(cxA / g) * g
        local cy = math.floor(cyA / g) * g
        while cy <= cyB do
            local y = math.floor(ay(cy)) - math.floor(dot / 2)
            if y + dot >= 0 and y < ah then
                local cx = cxStart
                while cx <= cxB do
                    local x = math.floor(ax(cx)) - math.floor(dot / 2)
                    if x >= 0 and x + dot <= aw and y >= 0 and y + dot <= ah then
                        rect(x, y, dot, dot, dcol)
                    end
                    cx = cx + g
                end
            end
            cy = cy + g
        end
    elseif style == "iso" then                      -- isometric: verticals and 30-degree diagonals
        local cx = math.floor(cxA / g) * g
        while cx <= cxB do
            local x = ax(cx)
            if x >= 0 and x < aw then rect(math.floor(x), 0, 1, ah, col) end
            cx = cx + g
        end
        local slope = math.tan(math.rad(30))
        local spacing = g / math.cos(math.rad(30))
        -- two diagonal families, started far enough left to cover the whole area
        -- (gridLine skips the ones that miss the clip box)
        local start = -math.ceil(ah * slope / spacing) * spacing
        local b = start
        while b <= v.canvas_w * v.zoom + ah do
            self:gridLine(bb, ox, oy, ax(0) + b, 0, ax(0) + b + ah * slope, ah, col, bx0, by0, bx1, by1)   -- down-right
            self:gridLine(bb, ox, oy, ax(0) + b, ah, ax(0) + b + ah * slope, 0, col, bx0, by0, bx1, by1)   -- up-right
            b = b + spacing * v.zoom
        end
    else                                            -- "square"
        local cx = math.floor(cxA / g) * g
        while cx <= cxB do
            local x = math.floor(ax(cx))
            if x >= 0 and x < aw then rect(x, 0, 1, ah, col) end
            cx = cx + g
        end
        local cy = math.floor(cyA / g) * g
        while cy <= cyB do
            local y = math.floor(ay(cy))
            if y >= 0 and y < ah then rect(0, y, aw, 1, col) end
            cy = cy + g
        end
    end
end

-- The page edges that fall inside the drawing area (when zoomed out past cover).
function InkAwayView:paintPageEdges(bb, x, y)
    local v = self.view
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    local fx0, fy0 = InkGeom.toScreen(v, 0, 0)
    local fx1, fy1 = InkGeom.toScreen(v, v.canvas_w, v.canvas_h)
    fx0, fy0 = math.floor(fx0 + x), math.floor(fy0 + y)
    fx1, fy1 = math.floor(fx1 + x), math.floor(fy1 + y)
    local top = math.max(fy0, ay0)
    local bot = math.min(fy1, ay1)
    if fx0 > ax0 and fx0 < ax1 and bot > top then bb:paintRect(fx0, top, 1, bot - top, FRAME) end
    if fx1 < ax1 and fx1 > ax0 and bot > top then bb:paintRect(fx1, top, 1, bot - top, FRAME) end
    local lft = math.max(fx0, ax0)
    local rgt = math.min(fx1, ax1)
    if fy0 > ay0 and fy0 < ay1 and rgt > lft then bb:paintRect(lft, fy0, rgt - lft, 1, FRAME) end
    if fy1 < ay1 and fy1 > ay0 and rgt > lft then bb:paintRect(lft, fy1, rgt - lft, 1, FRAME) end
end

return InkAwayView
