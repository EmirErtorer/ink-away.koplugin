--[[
Getting the page onto the screen: the on-screen buffer and the master kept in the
panel's pixel order (so a software-rotated landscape blit is a memcpy),
renderView, the grid overlay, and the e-ink refresh policy.
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

local InkAwayView = {}

-- Live-ink pacing on colour (Kaleido) panels, where every refresh costs the driver
-- a lot more than on grey e-ink: the fast (black/white) waveform at most every
-- LIVE_FAST_MS, the grey-capable one -- which blocks until the driver has taken it
-- -- at most every LIVE_UI_MS, and the last samples of a burst still within
-- LIVE_TAIL_MS. The real colours and greys settle in ONE refresh RECONCILE_SEC
-- after the pen rests, instead of a blocking refresh on every lift.
local LIVE_FAST_MS = 20
local LIVE_UI_MS = 80
local LIVE_TAIL_MS = 35
local RECONCILE_SEC = 0.8

------------------------------------------------------------------------------
-- On-screen buffer in the screen's panel pixel order (landscape speed)
--
-- When a device shows landscape by rotating its framebuffer in software (many
-- Kindles), copying a plain top-left buffer onto Screen.bb goes pixel-by-pixel
-- through that rotation -- about 10x slower than the row copies portrait gets, and
-- what made menus / undo / placing text feel sluggish in landscape. So area_bb is
-- built in the SCREEN's own pixel order: allocated with the panel's dimensions and
-- given the screen's rotation, so all the drawing into it still uses ordinary area
-- coordinates, but the finished bytes are already turned. Copying it onto the
-- screen is then a plain memcpy through an unrotated view of the screen memory at
-- the buffer's physical position (blitAreaFull), byte-identical to the rotated
-- blit. This mirrors backgammon.koplugin's buildBoardBuffer / blitBoard. On the SDL
-- emulator (which rotates its window, not the framebuffer) and on hardware-rotation
-- devices Screen.bb's rotation is 0, so all of this collapses to the ordinary blit.

function InkAwayView:screenBBRot() return Screen.bb.getRotation and Screen.bb:getRotation() or 0 end
function InkAwayView:screenBBInv() return Screen.bb.getInverse and Screen.bb:getInverse() or 0 end

-- Allocate area_bb in the screen's panel order (see the note above). Records the
-- rotation / inversion / type it was built for, so matchAreaTarget can spot a later
-- change (turning landscape one way to the other keeps the screen size, so no
-- relayout fires, but the pixel order flips).
function InkAwayView:newAreaBuffer()
    local v = self.view
    local rot, inv, typ = self:screenBBRot(), self:screenBBInv(), Screen.bb:getType()
    self._area_rot, self._area_inv, self._area_type = rot, inv, typ
    return panelBuffer(v.area_w, v.area_h, rot, inv, typ)
end

-- Rebuild area_bb (and re-render it) if the screen's rotation, inversion or buffer
-- type has changed since it was made. Called at the top of every paint, cheap when
-- nothing changed.
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

-- Copy a sub-rect of area_bb -- logical (sx,sy,w,h) -- onto the screen so its
-- logical (sx,sy) lands at screen (dstx,dsty). Unrotated: a plain blit. Software-
-- rotated (landscape): go through UNROTATED views of BOTH buffers at their physical
-- positions, so it is a row-copy memcpy instead of a per-pixel rotated blit. That
-- rotated blit is ~40-60x slower and its cost grows with the rect, so using it for a
-- live stroke's (growing) changed region made the pen "trail behind" in landscape.
-- Byte-identical to the naive rotated blit in all rotations (verified against the
-- real C blitter).
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
-- Panel-order master mirror (landscape render without a per-frame rotation)
--
-- On a software-rotated (landscape) screen, the per-frame cost used to be
-- renderView scaling the logical master canvas_bb and blitting it into the
-- panel-order area_bb: that final blit is a per-pixel rotated write, redone on
-- every pan / zoom / redraw. canvas_panel_bb is a mirror of canvas_bb stored in
-- the SCREEN's pixel order, so renderView can scale a crop of IT through
-- unrotated physical views straight into area_bb -- a memcpy, no rotation. The
-- rotation is paid only when the mirror is (re)synced from canvas_bb, which is
-- sparse: once on a full compose / rotation flip, and only over a changed op's
-- rectangle on a commit. In portrait (rotation 0) no mirror is kept and
-- rendering sources canvas_bb directly, exactly as before -- zero change there.
--
-- The master (canvas_bb) and the export path stay in logical coordinates, so
-- input mapping and the saved PNG/JPEG/PDF are untouched. The mirror is a
-- display buffer only; a downscale in landscape can differ from the old render
-- by at most ~1 grey level on a few pixels (mupdf's scaler rounds slightly
-- differently on a transposed image) -- invisible, and never in the export.
------------------------------------------------------------------------------

-- Allocate the panel-order mirror at the CANVAS size, matching area_bb's rotation /
-- inversion / type (they must agree for the physical-view copy to line up).
function InkAwayView:newCanvasPanelBuffer()
    local v = self.view
    local cw, ch = v.canvas_w, v.canvas_h
    local rot = self._area_rot or 0
    local typ = self._area_type or Screen.bb:getType()
    -- The mirror holds the SAME (non-inverted) bytes as canvas_bb, just in panel
    -- order: it matches area_bb's ROTATION (for the physical-view alignment) but
    -- NOT its inverse. Screen inverse (e.g. night mode) is applied only by the
    -- final copy into area_bb -- exactly as the old scaled->area_bb blit did -- so
    -- copying canvas_bb (inverse 0) in here must not flip the bytes.
    local inv = (self.canvas_bb and self.canvas_bb.getInverse and self.canvas_bb:getInverse()) or 0
    self._cpanel_rot, self._cpanel_type = rot, typ
    self._cpanel_cw, self._cpanel_ch = cw, ch
    return panelBuffer(cw, ch, rot, inv, typ)
end

-- Ensure the mirror exists and matches the current rotation / size. In portrait
-- (even rotation) there is no mirror. When it must be (re)built, do one full
-- rotated copy from canvas_bb, which resyncs it completely.
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
    -- inverse is deliberately NOT part of the match: the mirror mirrors canvas_bb's
    -- bytes (never inverted), and a screen-inverse change only rebuilds area_bb.
    local stale = (not self.canvas_panel_bb)
        or self._cpanel_rot ~= rot or self._cpanel_type ~= typ
        or self._cpanel_cw ~= v.canvas_w or self._cpanel_ch ~= v.canvas_h
    if stale then
        if self.canvas_panel_bb then self.canvas_panel_bb:free() end
        self.canvas_panel_bb = self:newCanvasPanelBuffer()
        self.canvas_panel_bb:blitFrom(self.canvas_bb, 0, 0, 0, 0, v.canvas_w, v.canvas_h)
        self._cpanel_dirty = nil   -- a full copy just synced everything
    end
end

-- Note a canvas-space rectangle whose pixels changed in canvas_bb, so the next
-- render resyncs just that region of the mirror instead of the whole buffer.
function InkAwayView:markCanvasDirty(x0, y0, x1, y1)
    if x1 <= x0 or y1 <= y0 then return end
    self._cpanel_dirty = growRect(self._cpanel_dirty, x0, y0, x1, y1)
end

-- Same, from a spanWriter acc table ({x0,y0,x1,y1}, empty when x1 < x0).
function InkAwayView:markCanvasDirtyAcc(acc)
    if acc and acc.x1 >= acc.x0 and acc.y1 >= acc.y0 then
        self:markCanvasDirty(acc.x0, acc.y0, acc.x1, acc.y1)
    end
end

-- Copy the pending dirty rectangle from canvas_bb into the mirror (a small rotated
-- copy), clearing it. Called right before any render reads the mirror.
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

-- Scale a canvas-space crop (scx,scy,sw,sh) up/down to dw x dh and place it into
-- area_bb at (dx,dy), copying bw x bh. In portrait this is exactly the old scale +
-- blit from canvas_bb. In landscape it scales a physical view of the panel-order
-- mirror and copies into area_bb's physical bytes -- no per-pixel rotation.
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
-- Rendering
------------------------------------------------------------------------------

-- The drawing area as a screen rect. A fresh Geom every call, because setDirty
-- keeps the region by reference rather than copying it.
function InkAwayView:areaScreenRect()
    local v = self.view
    -- Every caller passes this as a setDirty region, i.e. "refresh only the drawing
    -- area" -- which never covers the toolbar strip (above) or the notebook bar
    -- (below). Flag it so the next paintTo can skip repainting that chrome (see
    -- paintTo): the expensive part on a software-rotated landscape screen. Chrome
    -- changes (setTool/relayout/hide) clear this so a pending chrome refresh is
    -- never skipped.
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

-- True only on a colour (Kaleido) panel. Cached once: on grey e-ink a full-screen
-- flash is cheap, but on a colour panel it costs ~1-2s of colour waveform whether
-- or not any pixel changed, so colour needs a lighter refresh policy.
function InkAwayView:colourPanel()
    if self._is_colour == nil then self._is_colour = self:colorScreen() end
    return self._is_colour
end

-- Colour-aware refresh. On grey e-ink this is a byte-for-byte pass-through to
-- UIManager:setDirty (zero Kindle change). On a colour panel it turns an AVOIDABLE
-- full-screen flash ("full") into a non-flashing partial update ("ui"), which
-- covers the same region without the ~1-2s colour flash. Other modes are passed
-- through unchanged. Use this for repaints that only need the pixels updated (tool
-- switches, bar toggles, page turns, text-box commit); keep a literal
-- setDirty(..., "full", ...) for the deliberate flashes that must clear ghosting
-- (open/close, rotation, the periodic de-ghost, and big page-wide content swaps).
function InkAwayView:refresh(target, mode, region)
    if self:colourPanel() and mode == "full" then mode = "ui" end
    UIManager:setDirty(target, mode, region)
end

-- Given a changed rectangle of the base (un-mirrored) stroke in area-local
-- coordinates, return that rectangle plus one for each mirror image the current
-- symmetry produces. This keeps refreshes to a few small rectangles instead of
-- one huge box spanning the drawn side and all its mirrors (which would make
-- every stroke a near full-screen refresh, the symmetry slowdown).
-- Returns a REUSED pool of rects and a count (base rect + one per mirror). The
-- pool and the arithmetic (no per-call closures) keep this allocation-free, since
-- it runs once per drawn point under symmetry. Callers must read each rect within
-- the loop before the next call -- which they do, consuming it immediately.
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

-- Refresh one area-local rectangle (clipped to the drawing area) at `mode`.
function InkAwayView:dirtyAreaRect(mode, r, pad)
    local v = self.view
    local x0, y0, x1, y1 = clipToArea(v, r, pad)
    if not x0 then return end
    -- While a live stroke is drawing, only these sub-rects of area_bb change, so
    -- accumulate them and let paintTo blit ONLY this region instead of the whole
    -- drawing surface every point (see paintTo). Area-local coords.
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

-- Refresh a live-drawing rect. On grey e-ink this is dirtyAreaRect, exactly as
-- before. On a colour panel the rect is merged with the pending ones and sent at a
-- bounded pace (see LIVE_*_MS): the first sample shows at once, later ones ride
-- along with the next update. paintTo blits the union (_blit_rect) either way.
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

-- Send the pending live rect now (if any).
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

-- Colour panels: remember an area-local rect whose true colours/greys still need
-- a grey-capable refresh, and (re)start the settle timer. Each new stroke pushes
-- it back, so handwriting never has a slow refresh running under the next letter.
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

-- Rebuild what is on screen from the master bitmap: take the visible crop of
-- canvas_bb (a zero-copy viewport) and scale it into area_bb with mupdf's fast
-- C scaler. This is the whole reason zoom and pan are cheap: the work is a
-- single scale of one screenful, whatever the zoom or the amount of ink.
function InkAwayView:renderView()
    if not (self.area_bb and self.canvas_bb) then return end
    self._blit_rect = nil   -- the whole area_bb is rebuilt; paintTo must blit it all
    -- ...even if a stroke starts before that paint happens (a page turn and a pen
    -- landing in the same input batch): the stroke's small rect must not replace
    -- the full blit, or only the strip under the pen shows the new page.
    self._full_blit = true
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    -- keep the panel-order mirror allocated and in sync with canvas_bb before we
    -- scale a crop of it (a no-op in portrait, where we source canvas_bb directly)
    self:ensureCanvasPanel()
    self:flushCanvasPanel()

    -- visible crop of the canvas, clamped inside it
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local sw = math.max(1, math.min(W - sx, math.ceil(v.area_w / v.zoom)))
    local sh = math.max(1, math.min(H - sy, math.ceil(v.area_h / v.zoom)))

    local dw = math.max(1, math.floor(sw * v.zoom))
    local dh = math.max(1, math.floor(sh * v.zoom))
    -- where that crop lands in the area: a positive margin when the whole page
    -- fits (letterbox), or a sub-pixel nudge when zoomed in, which we clamp to
    -- the area and trim so the blit always stays in bounds
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    local bw = math.min(dw, v.area_w - ox)
    local bh = math.min(dh, v.area_h - oy)
    -- Clear to white only what the blit will NOT cover: the letterbox margin when
    -- the whole page fits, or a trimmed edge. When the blit fills the area (the
    -- common case when zoomed in and panning), skip the full-area clear entirely
    -- -- that saves one screenful memset per pan frame.
    if ox > 0 or oy > 0 or bw < v.area_w or bh < v.area_h then
        self.area_bb:paintRect(0, 0, v.area_w, v.area_h, WHITE)
    end
    if bw < 1 or bh < 1 then return end

    self:blitScaledPanel(sx, sy, sw, sh, dw, dh, ox, oy, bw, bh)
    -- The grid is NOT drawn here: it is a paint-time overlay (see drawGrid), so
    -- it never lives in area_bb, the eraser can never rub it out, and it never
    -- reaches the export (which is rebuilt from the ops, not from any buffer).
end

-- Re-render just an area-local sub-rectangle from the master, the same way
-- renderView does for the whole screen but scaling ONLY the touched region. The
-- soft eraser uses this so it can update the screen along its path without a
-- full-screen crop-scale on every point (which made erasing heavy).
function InkAwayView:renderViewRect(cx0, cy0, cx1, cy1)
    if not (self.area_bb and self.canvas_bb) then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    self:ensureCanvasPanel()
    self:flushCanvasPanel()
    cx0 = math.max(0, math.floor(cx0)); cy0 = math.max(0, math.floor(cy0))
    cx1 = math.min(v.area_w, math.ceil(cx1)); cy1 = math.min(v.area_h, math.ceil(cy1))
    if cx1 <= cx0 or cy1 <= cy0 then return end
    -- same visible-crop origin + landing offset as renderView
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    -- map the requested area rect back to canvas source pixels
    local scx0 = math.max(0, math.min(W, sx + math.floor((cx0 - ox) / v.zoom)))
    local scy0 = math.max(0, math.min(H, sy + math.floor((cy0 - oy) / v.zoom)))
    local scx1 = math.max(0, math.min(W, sx + math.ceil((cx1 - ox) / v.zoom)))
    local scy1 = math.max(0, math.min(H, sy + math.ceil((cy1 - oy) / v.zoom)))
    local sw, sh = scx1 - scx0, scy1 - scy0
    if sw < 1 or sh < 1 then return end
    -- destination aligned to the canvas source we grabbed
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

-- A thin line into `bb` at screen offset (ox,oy), clipped to the drawing area.
function InkAwayView:gridLine(bb, ox, oy, x0, y0, x1, y1, color, bx0, by0, bx1, by1)
    local aw, ah = self.view.area_w, self.view.area_h
    bx0 = bx0 or 0; by0 = by0 or 0; bx1 = bx1 or aw; by1 = by1 or ah
    -- cheap bbox reject: the segment cannot touch the clip window
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

-- Draw the current grid style into `bb` at screen offset (ox,oy). Display only:
-- painted onto the screen buffer each frame, never baked into area_bb, so the
-- eraser leaves it alone and it stays out of the saved PNG or JPEG.
-- `clip` (optional, area-local {x0,y0,x1,y1}) confines the redraw to a sub-rect.
-- While a stroke is drawing, paintTo only re-blits the small changed region, so we
-- pass that region here too: without it the WHOLE grid was repainted on every
-- touch point, which at a small grid size (thousands of cells, dots worst of all)
-- made grid-on drawing crawl -- even plain finger drawing. Clipping keeps grid-on
-- drawing as fast as grid-off. With no clip (a full paint) it covers the area.
function InkAwayView:drawGrid(bb, ox, oy, clip)
    local v = self.view
    local aw, ah = v.area_w, v.area_h
    local g = self.grid_size
    local style = self.grid_style or "square"
    -- strength 1..100 maps to a grey: faint at low values, solid black at 100,
    -- so the reader can make the grid a light guide or as dark as drawn ink
    local lvl = strengthToLevel(self.grid_strength)
    local col = Blitbuffer.ColorRGB32(lvl, lvl, lvl, 0xFF)
    -- clip window in area-local coords (whole area when no clip is given)
    local bx0 = clip and math.max(0, math.floor(clip.x0)) or 0
    local by0 = clip and math.max(0, math.floor(clip.y0)) or 0
    local bx1 = clip and math.min(aw, math.ceil(clip.x1)) or aw
    local by1 = clip and math.min(ah, math.ceil(clip.y1)) or ah
    if bx1 <= bx0 or by1 <= by0 then return end
    local function ax(cx) return (cx - v.pan_x) * v.zoom end
    local function ay(cy) return (cy - v.pan_y) * v.zoom end
    -- paint a rect given in area coords, clipped to the clip window then offset
    local function rect(px, py, w, h, c)
        local x0 = math.max(px, bx0); local y0 = math.max(py, by0)
        local x1 = math.min(px + w, bx1); local y1 = math.min(py + h, by1)
        if x1 > x0 and y1 > y0 then bb:paintRect(ox + x0, oy + y0, x1 - x0, y1 - y0, c) end
    end
    -- canvas-coord span that maps into the clip window, so uniform grids iterate
    -- only the lines that can land inside it instead of the whole page every frame
    local cxA = math.max(0, bx0 / v.zoom + v.pan_x)
    local cxB = math.min(v.canvas_w, bx1 / v.zoom + v.pan_x)
    local cyA = math.max(0, by0 / v.zoom + v.pan_y)
    local cyB = math.min(v.canvas_h, by1 / v.zoom + v.pan_y)

    if style == "thirds" then
        -- rule of thirds over the page rectangle
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
        local dcol = col                              -- follow the grid strength
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
    elseif style == "iso" then                      -- isometric: verticals + 30 deg diagonals
        local cx = math.floor(cxA / g) * g
        while cx <= cxB do
            local x = ax(cx)
            if x >= 0 and x < aw then rect(math.floor(x), 0, 1, ah, col) end
            cx = cx + g
        end
        local slope = math.tan(math.rad(30))
        local spacing = g / math.cos(math.rad(30))
        -- two diagonal families, offset so they cover the whole area (each gridLine
        -- rejects itself when its bbox misses the clip window)
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

return InkAwayView
