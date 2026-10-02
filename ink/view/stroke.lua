--[[
Freehand pen and eraser strokes, from touch-down to commit: live stamping into the
master and the on-screen buffer, rejoining a dropped contact, and shape assist.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local UIManager = require("ui/uimanager")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")
local Raster = require("ink/raster")
local Recognize = require("ink/recognize")
local Symmetry = require("ink/symmetry")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local displayColor = Paint.displayColor
local spanWriter = Paint.spanWriter
local bgSpanWriter = Paint.bgSpanWriter

local InkAwayView = {}

local PREVIEW_INK = Blitbuffer.COLOR_BLACK   -- live preview of non-black ink on colour panels

-- When the finger lifts, wait this long before committing the stroke. If a
-- fresh touch lands nearby within the window, treat it as the SAME stroke.
-- Touch panels on these readers often drop and reacquire a finger in the middle
-- of a line, and this is what keeps one lift as one undo step, keeps exported
-- strokes whole, and fills the gap a dropped contact would otherwise leave.
local COALESCE_SEC = 0.15

------------------------------------------------------------------------------
-- Drawing gesture handlers
------------------------------------------------------------------------------

-- Current live ink colour and width, from the active tool.
function InkAwayView:liveColor()
    if self.tool == "erase" then return WHITE end
    return displayColor(self.pen_color, self.pen_alpha)
end
function InkAwayView:liveWidth()
    return (self.tool == "erase") and self.eraser_width or self.pen_width
end

-- Build the reusable per-stroke drawing writers ONCE (called from beginStroke) so
-- the per-point path (stampLive) allocates almost nothing. Colour, width, brush
-- style and symmetry are fixed for the whole stroke, so the span writers, the
-- symmetry-combining wrapper and the raster dispatcher never need rebuilding per
-- point -- rebuilding them ~18x/point under quad symmetry was the GC thrash that
-- made fast drawing with symmetry stutter (and never fully recover).
function InkAwayView:setupLiveWriters()
    local color = self:liveColor()
    local style = (self.tool ~= "erase") and self.pen_style or nil
    local st = style and Raster.STYLES[style]
    local textured = st and not st.solid
    local seed = self.live_seed or 0
    self._lw_stroke = function(seg, r, put)
        if textured then Raster.pathTex(seg, r, put, st, seed) else Raster.path(seg, r, put) end
    end
    -- remember which buffers these writers target, so stampLive can rebuild them if
    -- a relayout/rotation reallocated a buffer mid-interaction (else the writers
    -- would poke a freed buffer)
    self._lw_area_bb, self._lw_canvas_bb = self.area_bb, self.canvas_bb
    self._lw_acc = self._lw_acc or { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
    -- canvas-space bbox of everything this stroke writes into the master, so the
    -- panel-order mirror can be resynced over just that rect when the stroke ends
    self._lw_cacc = self._lw_cacc or { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    -- reused 4-slot segment tables (master + on-screen), so a continuing stroke
    -- allocates no per-point segment garbage; Raster.path reads them synchronously
    self._lw_seg_c = self._lw_seg_c or { 0, 0, 0, 0 }
    self._lw_seg_a = self._lw_seg_a or { 0, 0, 0, 0 }
    local sym = self.symmetry
    -- On a colour panel the live ink is shown with the fast black/white waveform
    -- (the grey/colour one blocks on every sample there), which cannot show colour,
    -- grey or a light tint: those would vanish or look wrong while drawing. So the
    -- on-screen copy is drawn in black and the master keeps the real colour; the
    -- true pixels are put back on lift and settle in one refresh (queueReconcile).
    local area_color = color
    self._live_preview = false
    if self:colourPanel() and self.tool ~= "erase" and self._live_mode == "fast"
            and not self:pureBlackPen() then
        area_color, self._live_preview = PREVIEW_INK, true
    end
    -- master (1:1) writer
    local v = self.view
    local cput = spanWriter(self.canvas_bb, v.canvas_w, v.canvas_h, color, self._lw_cacc)
    if sym and sym ~= "off" then
        local crefx, crefy = Symmetry.canvasRefs(v.canvas_w, v.canvas_h)
        cput = Symmetry.wrap(cput, sym, crefx, crefy)
    end
    self._lw_cput = cput
    -- on-screen writer, accumulating the base bbox into the reused acc table; the
    -- mirror images are painted through a writer that does NOT grow acc, so the
    -- refresh stays a few small rects (one per image) rather than one giant box.
    local baseput = spanWriter(self.area_bb, v.area_w, v.area_h, area_color, self._lw_acc)
    local aput = baseput
    if sym and sym ~= "off" then
        local arefx, arefy = Symmetry.areaRefs(v)
        local mirror = spanWriter(self.area_bb, v.area_w, v.area_h, area_color, nil)
        local mx, my = Symmetry.mirrorsX(sym), Symmetry.mirrorsY(sym)
        aput = function(x, y, len)
            baseput(x, y, len)
            if mx then mirror(arefx(x, len), y, len) end
            if my then mirror(x, arefy(y), len) end
            if mx and my then mirror(arefx(x, len), arefy(y), len) end
        end
    end
    self._lw_aput = aput
end

-- Stamp the live segment ending at canvas point (cx,cy) into BOTH buffers: the
-- 1:1 master (so a later zoom/pan re-render is correct) and the on-screen buffer
-- at the current zoom (so drawing feels immediate). Only the on-screen dirty
-- rectangle is refreshed. `fresh` starts a new segment with no line back.
-- The eraser, when set to leave the background, restores the background image
-- along its path in the master and re-renders the affected area, so erasing
-- takes away your ink but the picture underneath shows through (matching what a
-- background-keeping export produces).
function InkAwayView:stampEraseRestore(cx, cy, fresh, reveal)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local r = self.eraser_width / 2
    local px, py = self.last_cx, self.last_cy
    local cacc = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    local put = bgSpanWriter(self.canvas_bb, reveal or self:eraseRevealBB(), W, H, cacc)
    if self.symmetry ~= "off" then
        local rx, ry = Symmetry.canvasRefs(W, H)
        put = Symmetry.wrap(put, self.symmetry, rx, ry)
    end
    if px and not fresh then
        Raster.path({ px, py, cx, cy }, r, put)
    else
        Raster.path({ cx, cy }, r, put)
    end
    -- mirror the just-restored region before renderViewRect (below) reads the mirror
    self:markCanvasDirtyAcc(cacc)
    self.last_cx, self.last_cy = cx, cy
    local zr = r * self.view.zoom + 2
    local ax0, ay0 = self:toAreaLocal(px or cx, py or cy)
    local ax1, ay1 = self:toAreaLocal(cx, cy)
    local acc = {
        x0 = math.min(ax0, ax1) - zr, y0 = math.min(ay0, ay1) - zr,
        x1 = math.max(ax0, ax1) + zr, y1 = math.max(ay0, ay1) + zr,
    }
    local sr = self._stroke_rect
    if not sr then
        self._stroke_rect = { x0 = acc.x0, y0 = acc.y0, x1 = acc.x1, y1 = acc.y1 }
    else
        if acc.x0 < sr.x0 then sr.x0 = acc.x0 end
        if acc.y0 < sr.y0 then sr.y0 = acc.y0 end
        if acc.x1 > sr.x1 then sr.x1 = acc.x1 end
        if acc.y1 > sr.y1 then sr.y1 = acc.y1 end
    end
    -- Re-render only the touched region (base + each mirror) from the restored
    -- master, instead of a full-screen crop-scale on every point.
    local rects, nr = self:symAreaRects(acc)
    for i = 1, nr do
        local rr = rects[i]
        self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1)
        self:liveDirty(self._live_mode or "fast", rr, 1)
    end
end

function InkAwayView:stampLive(cx, cy, fresh)
    if self.tool == "erase" then
        -- soft erase reveals the page; in a notebook even a hard erase reveals the
        -- bare paper, so the ruling can never be rubbed out
        local reveal
        if self.erase_bg then reveal = self.notebook and self:barePaperBB() or nil
        else reveal = self:eraseRevealBB() end
        if reveal then return self:stampEraseRestore(cx, cy, fresh, reveal) end
    end
    -- writers were built once in beginStroke (setupLiveWriters); rebuild them if
    -- missing or if a buffer was reallocated since (relayout/rotation), so we never
    -- draw into a freed buffer.
    if not self._lw_stroke or self._lw_area_bb ~= self.area_bb
            or self._lw_canvas_bb ~= self.canvas_bb then
        self:setupLiveWriters()
    end
    local width = self:liveWidth()
    local strokeFn = self._lw_stroke

    -- master, at 1:1
    if self.canvas_bb then
        if self.last_cx and not fresh then
            local seg = self._lw_seg_c
            seg[1], seg[2], seg[3], seg[4] = self.last_cx, self.last_cy, cx, cy
            strokeFn(seg, width / 2, self._lw_cput)
        else
            strokeFn({ cx, cy }, width / 2, self._lw_cput)
        end
        self.last_cx, self.last_cy = cx, cy
    end

    -- on screen, at the current zoom. The reused `acc` table tracks only the base
    -- image (reset each point); the mirror images paint through a writer that does
    -- NOT grow acc, so the refresh stays a few small rects (one per image).
    local ax, ay = self:toAreaLocal(cx, cy)
    local acc = self._lw_acc
    acc.x0, acc.y0, acc.x1, acc.y1 = math.huge, math.huge, -math.huge, -math.huge
    if self.last_ax and not fresh then
        local seg = self._lw_seg_a
        seg[1], seg[2], seg[3], seg[4] = self.last_ax, self.last_ay, ax, ay
        strokeFn(seg, (width * self.view.zoom) / 2, self._lw_aput)
    else
        strokeFn({ ax, ay }, (width * self.view.zoom) / 2, self._lw_aput)
    end
    self.last_ax, self.last_ay = ax, ay
    if acc.x1 >= acc.x0 then
        -- grow the whole-stroke (base) bbox for a tidy refresh at the end
        local sr = self._stroke_rect
        if not sr then
            self._stroke_rect = { x0 = acc.x0, y0 = acc.y0, x1 = acc.x1, y1 = acc.y1 }
        else
            if acc.x0 < sr.x0 then sr.x0 = acc.x0 end
            if acc.y0 < sr.y0 then sr.y0 = acc.y0 end
            if acc.x1 > sr.x1 then sr.x1 = acc.x1 end
            if acc.y1 > sr.y1 then sr.y1 = acc.y1 end
        end
        local rects, nr = self:symAreaRects(acc)
        for i = 1, nr do
            self:liveDirty(self._live_mode or "fast", rects[i], 1)
        end
    end
end

-- Add a screen point to the live stroke (kept in canvas coords) and draw it.
-- The stabilizer smooths the finger's path toward a trailing point, so wobble
-- becomes a clean line; strength 0 draws the raw point.
function InkAwayView:addScreenPoint(sx, sy, fresh)
    local cx, cy = self:toCanvasClamped(sx, sy)
    if fresh then
        self.sm_x, self.sm_y = cx, cy
    else
        local a = InkGeom.stabilizerAlpha(self.stabilizer)
        self.sm_x, self.sm_y = InkGeom.ema(self.sm_x, self.sm_y, cx, cy, a)
        cx, cy = self.sm_x, self.sm_y
    end
    self.canvas:addPoint(cx, cy)
    self:stampLive(cx, cy, fresh)
end

-- Is the pen solid, fully opaque, pure black (what the fast waveform shows as is)?
function InkAwayView:pureBlackPen()
    local style = self.pen_style
    local solid = (style == nil) or (Raster.STYLES[style] and Raster.STYLES[style].solid)
    local c = self.pen_color
    return (self.pen_alpha or 255) >= 255 and solid and (c == nil
        or (c[1] == 0 and c[2] == 0 and c[3] == 0)) and true or false
end

function InkAwayView:beginStroke(sx, sy)
    local is_erase = self.tool == "erase"
    self.live_seed = math.random(1, 1000000)
    local style = nil
    if not is_erase then style = self.pen_style end
    -- Live-refresh waveform, chosen once for the whole stroke. The "fast" (A2/DU)
    -- waveform is 1-bit black/white: it shows opaque BLACK solid ink instantly, but
    -- it physically cannot render grey/colour/low-opacity ink, so such a stroke
    -- looks wrong (or invisible) mid-draw and only snaps in on the "ui" settle at
    -- lift -- which is exactly why grey/white pens felt slow. Use "fast" only for a
    -- solid, fully-opaque, pure-black pen; everything else draws under grey-capable
    -- "ui" so it appears in the right shade as you draw.
    if is_erase then
        -- "fast" (A2/DU) is 1-bit black/white, so it can only show white. That is
        -- fine when the eraser reveals plain white (a blank drawing page), but in a
        -- notebook it reveals the grey ruling, and over a background image it reveals
        -- that picture -- neither of which A2 can render, so the erased path flashes
        -- to white and (on colour panels especially) does not settle back to the
        -- revealed shade. Use the grey-capable "ui" waveform whenever the reveal is
        -- non-white; keep the snappy "fast" erase only for the blank-white case.
        local reveal = self.erase_bg and (self.notebook and self:barePaperBB()) or self:eraseRevealBB()
        self._live_mode = reveal and "ui" or "fast"
    else
        -- On a colour panel every pen draws live with "fast" (a black preview for
        -- anything that is not pure black, see setupLiveWriters): the grey/colour
        -- waveform there blocks on each refresh.
        self._live_mode = (self:pureBlackPen() or self:colourPanel()) and "fast" or "ui"
    end
    -- a new stroke pushes back the pending colour settle (see queueReconcile)
    if self._reconcile then UIManager:unschedule(self._reconcile_cb) end
    self.canvas:startStroke(is_erase and "erase" or "ink",
        self:liveWidth(), self.pen_alpha, self.pen_color, style, self.live_seed)
    if self.symmetry ~= "off" and self.canvas.live then self.canvas.live.sym = self.symmetry end
    -- a "hard" erase also removes the background; the soft default leaves it
    if is_erase and self.erase_bg and self.canvas.live then self.canvas.live.ebg = true end
    self.capturing = true
    self.pending_lift = nil
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    self._stroke_rect = nil
    if self._lw_cacc then
        self._lw_cacc.x0, self._lw_cacc.y0 = math.huge, math.huge
        self._lw_cacc.x1, self._lw_cacc.y1 = -math.huge, -math.huge
    end
    -- Shape assist may rewrite this stroke into a clean shape on lift, which means
    -- rebuilding the master. Snapshot the pre-stroke master now so beautify can
    -- restore just the stroke's footprint instead of replaying every op (which got
    -- progressively slower as a drawing filled up). Only when it might actually
    -- run: a pen stroke with shape assist on.
    self._pre_stroke_valid = false
    if self.shape_assist and not is_erase and self.canvas_bb then
        local W, H = self.view.canvas_w, self.view.canvas_h
        if self._pre_stroke_bb and (self._pre_stroke_bb:getWidth() ~= W
                or self._pre_stroke_bb:getHeight() ~= H) then
            self._pre_stroke_bb:free(); self._pre_stroke_bb = nil
        end
        if not self._pre_stroke_bb then
            self._pre_stroke_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
        end
        self._pre_stroke_bb:blitFrom(self.canvas_bb, 0, 0, 0, 0, W, H)
        self._pre_stroke_valid = true
    end
    self:setupLiveWriters()        -- build the reusable per-stroke writers once
    self:addScreenPoint(sx, sy, true)
end

-- Provisional lift: hold the stroke open briefly (COALESCE_SEC) in case the
-- panel dropped the contact and it is about to come back nearby.
function InkAwayView:scheduleFinalize(sx, sy)
    self.pending_lift = { x = sx, y = sy }
    UIManager:unschedule(self._finalize)
    UIManager:scheduleIn(COALESCE_SEC, self._finalize)
end

-- Commit the live stroke as one op. Called by the coalesce timer, or eagerly
-- via flushPending() before any action that must see a consistent model.
-- Shape assist: try to replace a just-committed freehand ink op with a clean
-- shape recognised from its raw path `raw`. `committed` is the ink op (already
-- at the end of the ops list). Returns true if it swapped one in. The swap
-- reuses the single history entry finishStroke pushed, so it is one undo step,
-- and the master is recomposed so the freehand ink is replaced by the shape.
function InkAwayView:beautifyStroke(raw, committed)
    -- Threshold in canvas px, scaled by zoom so "~20 screen px of travel" is the
    -- floor whether zoomed in or out (canvas px shrink as you zoom in).
    local zoom = (self.view and self.view.zoom) or 1
    local min_size = Screen:scaleBySize(20) / (zoom > 0 and zoom or 1)
    local pts, shape = Recognize.detect(raw, { min_size = min_size })
    if not pts then return false end
    if shape then
        -- The stroke reads as a toolbar primitive (line / rectangle / ellipse /
        -- triangle): turn the ink op INTO a real shape op, in place, so tapping or
        -- holding it later brings up the very same edit menu as a shape drawn from
        -- the toolbar. It keeps the pen's width, colour, opacity and symmetry.
        -- Still one op, so it remains a single undo step.
        committed.kind = "shape"
        committed.shape = shape.shape
        committed.pts = shape.pts
        committed.closed = shape.closed
        committed.fill = false
        committed.angle = 0
        committed.style, committed.seed = nil, nil   -- ink-only fields; a shape ignores them
    else
        -- A straightened but non-primitive path (an L bend, a general polygon):
        -- keep the SAME ink op and only swap its points, so the clean path is drawn
        -- with the very brush the user was using.
        committed.pts = pts
    end
    self.dirty = true
    -- Rebuild the master WITHOUT replaying every op when we can (see below); only
    -- fall back to a full composeCanvas when the snapshot is unusable.
    if not self:beautifyRecompose(raw, committed) then
        self:composeCanvas()
    end
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

-- Rebuild the master after shape assist swapped a stroke, without a whole-canvas
-- replay. beginStroke snapshotted the pre-stroke master; restore just the raw
-- stroke's footprint (and each symmetry mirror of it) from that snapshot to wipe
-- the old wobbly ink, then stamp the clean op back on top. The result is pixel
-- identical to composeCanvas but costs O(stroke area) instead of O(number of
-- ops), which is what made a filling-up drawing get slower per stroke. Returns
-- false (caller runs the full composeCanvas) when the snapshot cannot be used.
function InkAwayView:beautifyRecompose(raw, committed)
    if not (self._pre_stroke_valid and self._pre_stroke_bb and self.canvas_bb) then
        return false
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._pre_stroke_bb:getWidth() ~= W or self._pre_stroke_bb:getHeight() ~= H then
        return false
    end
    -- footprint (canvas px) of the OLD raw ink and the NEW clean op together
    local hw = (committed.width or self.pen_width or 1) / 2 + 2
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local function grow(pts)
        if not pts then return end
        for i = 1, #pts - 1, 2 do
            local px, py = pts[i], pts[i + 1]
            if px < x0 then x0 = px end
            if px > x1 then x1 = px end
            if py < y0 then y0 = py end
            if py > y1 then y1 = py end
        end
    end
    grow(raw)
    grow(committed.pts)
    if x1 < x0 or y1 < y0 then return false end
    local base = {
        x0 = math.max(0, math.floor(x0 - hw)),
        y0 = math.max(0, math.floor(y0 - hw)),
        x1 = math.min(W, math.ceil(x1 + hw)),
        y1 = math.min(H, math.ceil(y1 + hw)),
    }
    -- the raw ink was mirrored into the master under symmetry, so restore every
    -- mirror of the footprint too (exact pixel reflection in canvas space)
    local rects = { base }
    local sym = committed.sym
    if sym and sym ~= "off" then
        local mx, my = Symmetry.mirrorsX(sym), Symmetry.mirrorsY(sym)
        local function flipX(r) return { x0 = W - r.x1, y0 = r.y0, x1 = W - r.x0, y1 = r.y1 } end
        local function flipY(r) return { x0 = r.x0, y0 = H - r.y1, x1 = r.x1, y1 = H - r.y0 } end
        if mx then rects[#rects + 1] = flipX(base) end
        if my then rects[#rects + 1] = flipY(base) end
        if mx and my then rects[#rects + 1] = flipY(flipX(base)) end
    end
    for _, r in ipairs(rects) do
        local w, h = r.x1 - r.x0, r.y1 - r.y0
        if w > 0 and h > 0 then
            self.canvas_bb:blitFrom(self._pre_stroke_bb, r.x0, r.y0, r.x0, r.y0, w, h)
            self:markCanvasDirty(r.x0, r.y0, r.x1, r.y1)   -- resync mirror over the restored footprint
        end
    end
    self:stampOpIntoCanvas(committed)   -- draw the clean op (all mirrors) back on top
    self._pre_stroke_valid = false      -- snapshot consumed; a stale reuse would be wrong
    return true
end

function InkAwayView:finalizeStroke()
    if not self.capturing then return end
    UIManager:unschedule(self._finalize)
    self.pending_lift = nil
    self.capturing = false
    -- the live stroke wrote canvas_bb directly; resync the mirror over its footprint
    self:markCanvasDirtyAcc(self._lw_cacc)
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    local was_erase = self.tool == "erase"
    -- Grab the raw points before finishStroke simplifies them, so shape assist
    -- recognises the shape from the full path rather than an RDP skeleton.
    local raw
    if self.shape_assist and self.tool == "pen" and self.canvas.live then
        local lp = self.canvas.live.pts
        raw = {}
        for i = 1, #lp do raw[i] = lp[i] end
    end
    local committed = self.canvas:finishStroke()
    -- Record whether text was protected when THIS stroke was made, so later
    -- toggling the setting never retroactively erases (or un-erases) text that a
    -- past stroke passed over. Compose then honours each erase op's own flag.
    if committed and committed.kind == "erase" then
        committed.spare_text = self.text_erase_protect or nil
    end
    -- Shape assist: if the finished pen stroke reads as a clean shape, swap it in.
    if raw and committed and committed.kind == "ink" and self:beautifyStroke(raw, committed) then
        self._stroke_rect = nil
        self:afterCommit()
        return
    end
    self.dirty = true
    local sr = self._stroke_rect
    if self:colourPanel() then
        -- Show the last samples now, put the real colours back where a black
        -- preview was drawn, and let one grey/colour refresh settle the stroke once
        -- the pen rests -- no blocking refresh (or flash) on every lift.
        self:liveFlush()
        if sr then
            local rects, nr = self:symAreaRects(sr)
            for i = 1, nr do
                local rr = rects[i]
                if self._live_preview then self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1) end
                self:queueReconcile(rr, 2)
            end
        else
            local v = self.view
            if self._live_preview then self:renderView() end
            self:queueReconcile({ x0 = 0, y0 = 0, x1 = v.area_w, y1 = v.area_h }, 0)
        end
        self._live_preview = false
        self._stroke_rect = nil
        if self.hwr_enabled and self.tool == "pen" and committed and committed.kind == "ink" then
            self:hwrCapture(committed)
        end
        self:afterCommit()
        return
    end
    -- Settle the fast-refresh ghosting over just the stroke's area. Erasing dark
    -- or textured ink leaves grey ghosts, so an erase gets a flashing refresh
    -- (which fully repaints black/white) to clear them.
    local mode = was_erase and "flashui" or "ui"
    if sr then
        -- refresh the base rect and each mirror rect separately, so an erase
        -- under symmetry flashes a few small areas rather than the whole screen
        local rects, nr = self:symAreaRects(sr)
        for i = 1, nr do
            self:dirtyAreaRect(mode, rects[i], 2)
        end
    else
        UIManager:setDirty(self, mode, self:areaScreenRect())
    end
    self._stroke_rect = nil
    -- Handwriting to text: buffer the pen stroke and (re)arm the pause timer.
    if self.hwr_enabled and self.tool == "pen" and committed and committed.kind == "ink" then
        self:hwrCapture(committed)
    end
    self:afterCommit()
end

-- Called once per committed drawing action. When ghosting cleanup is on, count
-- the actions and, at the threshold, force one full-screen refresh to clear the
-- ghosting that fast refreshes leave behind, then reset the count and carry on.
function InkAwayView:afterCommit()
    self:healMemory()
    local n = self.ghost_clean or 0
    if n <= 0 then return end
    self._strokes_since_full = (self._strokes_since_full or 0) + 1
    if self._strokes_since_full >= n then
        self._strokes_since_full = 0
        UIManager:setDirty(self, "full")
    end
end

-- Safety net against a runaway heap. Called at idle moments (a stroke just
-- committed): if the Lua heap has grown large over a very long session, reclaim
-- garbage right here so drawing can never degrade into GC thrashing. This is a
-- backstop, not the fix -- the per-stroke allocation is already flat (see the
-- delta-history + pooled-hot-path work); this only ever fires if something starts
-- leaking again. Gated on size so a normal session pays nothing, and it runs
-- between strokes (never mid-stroke), so the one-off collect is invisible.
local GC_HEAL_KB = 48 * 1024        -- ~48 MB: far above any legitimate drawing
local GC_HEAL_EVERY = 96            -- check at most once per this many commits
function InkAwayView:healMemory()
    self._commits_since_gc = (self._commits_since_gc or 0) + 1
    if self._commits_since_gc < GC_HEAL_EVERY then return end
    self._commits_since_gc = 0
    if collectgarbage("count") > GC_HEAL_KB then collectgarbage("collect") end
end

-- Hand the previous drawing's / notebook's memory back when switching to a fresh
-- one: drop the per-stroke snapshot buffer and collect now, so the new context
-- starts light without needing to close Ink Away or restart KOReader. Call after
-- the new canvas/notebook is loaded (a New action, not a page turn).
function InkAwayView:resetTransientMemory()
    if self._pre_stroke_bb then self._pre_stroke_bb:free(); self._pre_stroke_bb = nil end
    self._pre_stroke_valid = false
    self._commits_since_gc = 0
    collectgarbage("collect")
end

-- Commit immediately if a stroke is open (or pending). Safe to call any time.
function InkAwayView:flushPending()
    if self.capturing then self:finalizeStroke() end
end

return InkAwayView
