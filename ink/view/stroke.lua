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

local PREVIEW_INK = Blitbuffer.COLOR_BLACK   -- live preview of non-black ink on colour panels

-- After a lift, wait this long before committing the stroke; a touch that lands
-- nearby in the meantime continues it. Panels often drop and reacquire a finger
-- mid-line, and this keeps one lift as one stroke and one undo step, with no gap.
local COALESCE_SEC = 0.15

local GC_HEAL_KB = 48 * 1024        -- ~48 MB: far above any legitimate drawing
local GC_HEAL_EVERY = 96            -- check at most once per this many commits

local InkAwayView = {}

------------------------------------------------------------------------------
-- Drawing a stroke
------------------------------------------------------------------------------

-- Current live ink colour and width, from the active tool.
function InkAwayView:liveColor()
    if self.tool == "erase" then return WHITE end
    return displayColor(self.pen_color, self.pen_alpha)
end
function InkAwayView:liveWidth()
    return (self.tool == "erase") and self.eraser_width or self.pen_width
end

-- Build the stroke's writers once, in beginStroke. Colour, width, brush and
-- symmetry are fixed for the whole stroke, so the per-point path (stampLive)
-- allocates almost nothing; building them per point made fast symmetric drawing
-- stutter under garbage collection.
function InkAwayView:setupLiveWriters()
    local color = self:liveColor()
    local style = (self.tool ~= "erase") and self.pen_style or nil
    local st = style and Raster.STYLES[style]
    local textured = st and not st.solid
    local seed = self.live_seed or 0
    self._lw_stroke = function(seg, r, put)
        if textured then Raster.pathTex(seg, r, put, st, seed) else Raster.path(seg, r, put) end
    end
    -- the buffers these writers target, so stampLive can rebuild them if a relayout
    -- reallocated one mid-stroke (rather than draw into a freed buffer)
    self._lw_area_bb, self._lw_canvas_bb = self.area_bb, self.canvas_bb
    self._lw_acc = self._lw_acc or { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
    -- canvas bbox of everything the stroke writes into the master, so the mirror
    -- (see display.lua) is resynced over just that rect when it ends
    self._lw_cacc = self._lw_cacc or { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    -- reused segment tables (master and screen); Raster reads them synchronously
    self._lw_seg_c = self._lw_seg_c or { 0, 0, 0, 0 }
    self._lw_seg_a = self._lw_seg_a or { 0, 0, 0, 0 }
    local sym = self.symmetry
    -- On a colour panel live ink uses the fast black-and-white waveform (the
    -- grey-capable one blocks on each sample there), which cannot show colour, grey
    -- or a light tint. So the screen copy is drawn black while the master keeps the
    -- real colour; the true pixels come back on lift and settle in one refresh.
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
    -- On-screen writer: the base image grows _lw_acc, the mirror images go through
    -- a writer that does not, so the refresh stays a few small rects.
    local aput = spanWriter(self.area_bb, v.area_w, v.area_h, area_color, self._lw_acc)
    if sym and sym ~= "off" then
        local arefx, arefy = Symmetry.areaRefs(v)
        aput = Symmetry.wrap(aput, sym, arefx, arefy,
            spanWriter(self.area_bb, v.area_w, v.area_h, area_color, nil))
    end
    self._lw_aput = aput
end

-- The eraser over something to reveal (a background, images, notebook paper):
-- restore those pixels along the path in the master, then re-render the touched
-- rects on screen, so ink goes and the picture underneath shows through.
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
    -- sync the mirror over the restored region before renderViewRect reads it
    self:markCanvasDirtyAcc(cacc)
    self.last_cx, self.last_cy = cx, cy
    local zr = r * self.view.zoom + 2
    local ax0, ay0 = self:toAreaLocal(px or cx, py or cy)
    local ax1, ay1 = self:toAreaLocal(cx, cy)
    local acc = {
        x0 = math.min(ax0, ax1) - zr, y0 = math.min(ay0, ay1) - zr,
        x1 = math.max(ax0, ax1) + zr, y1 = math.max(ay0, ay1) + zr,
    }
    self._stroke_rect = InkGeom.growRect(self._stroke_rect, acc.x0, acc.y0, acc.x1, acc.y1)
    -- re-render only the touched rects (base and mirrors) from the master
    local rects, nr = self:symAreaRects(acc)
    for i = 1, nr do
        local rr = rects[i]
        self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1)
        self:liveDirty(self._live_mode or "fast", rr, 1)
    end
end

-- Stamp the live segment ending at canvas point (cx, cy) into the master (1:1,
-- so a later re-render is right) and into the on-screen buffer at the current
-- zoom (so drawing is immediate), refreshing only what changed. `fresh` starts a
-- new segment with no line back.
function InkAwayView:stampLive(cx, cy, fresh)
    if self.tool == "erase" then
        -- a soft erase reveals the page; in a notebook even a hard erase reveals the
        -- bare paper, so the ruling can never be rubbed out
        local reveal
        if self.erase_bg then reveal = self.notebook and self:barePaperBB() or nil
        else reveal = self:eraseRevealBB() end
        if reveal then return self:stampEraseRestore(cx, cy, fresh, reveal) end
    end
    -- rebuild the writers if they are missing or a buffer was reallocated
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

    -- on screen, at the current zoom; acc tracks the base image only (see
    -- setupLiveWriters) and is reset for each point
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
        -- grow the whole stroke's base rect for the refresh at the end
        self._stroke_rect = InkGeom.growRect(self._stroke_rect, acc.x0, acc.y0, acc.x1, acc.y1)
        local rects, nr = self:symAreaRects(acc)
        for i = 1, nr do
            self:liveDirty(self._live_mode or "fast", rects[i], 1)
        end
    end
end

-- Add a screen point to the live stroke (kept in canvas coords) and draw it.
-- The stabilizer pulls the point towards the previous one, turning wobble into a
-- clean line; strength 0 draws the raw point.
function InkAwayView:addScreenPoint(sx, sy, fresh)
    if self._wipe then return self:wipeTo(sx, sy) end   -- the whole-stroke eraser
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
    if self.tool == "erase" and self.erase_whole then return self:wipeBegin(sx, sy) end
    local is_erase = self.tool == "erase"
    self.live_seed = math.random(1, 1000000)
    local style = nil
    if not is_erase then style = self.pen_style end
    -- The live refresh waveform, chosen once per stroke. The fast (A2/DU) waveform
    -- is black and white only: it shows solid opaque black ink at once but cannot
    -- render grey, colour or partial opacity, which would only appear at the lift.
    if is_erase then
        -- fast can only show white, so it suits erasing to a blank page; over a
        -- notebook ruling or a picture the erased path needs the grey-capable "ui"
        local reveal = self.erase_bg and (self.notebook and self:barePaperBB()) or self:eraseRevealBB()
        self._live_mode = reveal and "ui" or "fast"
    else
        -- on a colour panel every pen draws with "fast" (a black preview, see
        -- setupLiveWriters) because the grey-capable waveform blocks each refresh
        self._live_mode = (self:pureBlackPen() or self:colourPanel()) and "fast" or "ui"
    end
    -- a new stroke pushes back the pending colour settle (see queueReconcile)
    if self._reconcile then UIManager:unschedule(self._reconcile_cb) end
    self.canvas:startStroke(is_erase and "erase" or "ink",
        self:liveWidth(), self.pen_alpha, self.pen_color, style, self.live_seed)
    if self.symmetry ~= "off" and self.canvas.live then self.canvas.live.sym = self.symmetry end
    -- a "hard" erase also removes pictures; the soft default leaves them
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
    -- Shape assist may swap this stroke for a clean shape on lift. Snapshot the
    -- master now so that swap restores just the stroke's footprint instead of
    -- replaying every op (see beautifyRecompose); only when assist could run.
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
    self:setupLiveWriters()
    self:addScreenPoint(sx, sy, true)
end

-- A lift: hold the stroke open for COALESCE_SEC in case the panel dropped the
-- contact and it comes back nearby.
function InkAwayView:scheduleFinalize(sx, sy)
    self.pending_lift = { x = sx, y = sy }
    UIManager:unschedule(self._finalize)
    UIManager:scheduleIn(COALESCE_SEC, self._finalize)
end

------------------------------------------------------------------------------
-- Committing a stroke
------------------------------------------------------------------------------

-- Shape assist: replace the just-committed ink op `committed` with a clean shape
-- recognised from its raw path, in place. Returns true if it did. It reuses the
-- history entry finishStroke pushed, so the swap is part of the same undo step.
function InkAwayView:beautifyStroke(raw, committed)
    -- the minimum size is ~20 screen px at any zoom
    local zoom = (self.view and self.view.zoom) or 1
    local min_size = Screen:scaleBySize(20) / (zoom > 0 and zoom or 1)
    local pts, shape = Recognize.detect(raw, { min_size = min_size })
    if not pts then return false end
    if shape then
        -- A line, rectangle, ellipse or triangle becomes a real shape op, so it gets
        -- the same edit menu as a shape drawn with the tool. It keeps the pen's
        -- width, colour, opacity and symmetry.
        committed.kind = "shape"
        committed.shape = shape.shape
        committed.pts = shape.pts
        committed.closed = shape.closed
        committed.fill = false
        committed.angle = 0
        committed.style, committed.seed = nil, nil   -- ink-only fields; a shape ignores them
    else
        -- any other straightened path (an L, a polygon) stays ink with the same
        -- brush; only its points change
        committed.pts = pts
    end
    self:markDirty()
    if not self:beautifyRecompose(raw, committed) then
        self:composeCanvas()
    end
    self:redraw()
    return true
end

-- Update the master after shape assist swapped a stroke, without replaying every
-- op: restore the raw stroke's footprint (and its mirrors) from the snapshot
-- beginStroke took, then stamp the clean op on top. Pixel-identical to
-- composeCanvas at the cost of the stroke's area. Returns false when the
-- snapshot cannot be used, and the caller recomposes instead.
function InkAwayView:beautifyRecompose(raw, committed)
    if not (self._pre_stroke_valid and self._pre_stroke_bb and self.canvas_bb) then
        return false
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._pre_stroke_bb:getWidth() ~= W or self._pre_stroke_bb:getHeight() ~= H then
        return false
    end
    -- footprint (canvas px) of the raw ink and the clean op together
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
    -- under symmetry the raw ink was mirrored too, so restore every mirror
    local rects, nr = Symmetry.mirrorRects(base, committed.sym, W, H)
    for i = 1, nr do
        local r = rects[i]
        local w, h = r.x1 - r.x0, r.y1 - r.y0
        if w > 0 and h > 0 then
            self.canvas_bb:blitFrom(self._pre_stroke_bb, r.x0, r.y0, r.x0, r.y0, w, h)
            self:markCanvasDirty(r.x0, r.y0, r.x1, r.y1)
        end
    end
    self:stampOpIntoCanvas(committed)   -- the clean op (all mirrors) on top
    self._pre_stroke_valid = false      -- the snapshot is used up
    return true
end

-- Commit the live stroke as one op. Called by the coalesce timer, or straight
-- away by flushPending before anything that needs the ops up to date.
function InkAwayView:finalizeStroke()
    if not self.capturing then return end
    UIManager:unschedule(self._finalize)
    self.pending_lift = nil
    self.capturing = false
    if self._wipe then return self:wipeEnd() end
    -- the live stroke wrote canvas_bb directly; resync the mirror over it
    self:markCanvasDirtyAcc(self._lw_cacc)
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    local was_erase = self.tool == "erase"
    -- keep the raw points before finishStroke simplifies them: shape assist
    -- recognises from the full path
    local raw
    if self.shape_assist and self.tool == "pen" and self.canvas.live then
        local lp = self.canvas.live.pts
        raw = {}
        for i = 1, #lp do raw[i] = lp[i] end
    end
    local committed = self.canvas:finishStroke()
    -- An erase records whether text was protected when it was made, so changing
    -- the setting later never erases or restores text retroactively.
    if committed and committed.kind == "erase" then
        committed.spare_text = self.text_erase_protect or nil
    end
    if raw and committed and committed.kind == "ink" and self:beautifyStroke(raw, committed) then
        self._stroke_rect = nil
        self:afterCommit()
        return
    end
    self:markDirty()
    local sr = self._stroke_rect
    if self:colourPanel() then
        -- show the last samples now, put the real colours back where the black
        -- preview was, and let one refresh settle them once the pen rests
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
    elseif was_erase then
        -- Taking ink back to white with the fast waveform leaves a faint grey
        -- ghost, which one cleaning refresh over the erased rects removes. A pen
        -- stroke needs nothing more: its live refreshes already showed it as it is
        -- ("fast" for solid black, which that waveform shows exactly, "ui" for any
        -- other ink), and refreshing it again only redrew the page under it.
        local mode = self:cleanMode()
        if sr then
            local rects, nr = self:symAreaRects(sr)
            for i = 1, nr do
                self:dirtyAreaRect(mode, rects[i], 2)
            end
        else
            UIManager:setDirty(self, mode, self:areaScreenRect())
        end
    end
    self._stroke_rect = nil
    self:afterCommit()
end

-- Called once per committed drawing action. With ghosting clean-up on, every
-- `ghost_clean` actions get one full-screen refresh to clear what the fast
-- refreshes left behind.
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

-- A safety net: if the Lua heap ever grows large over a long session, collect
-- between strokes, where the pause goes unnoticed. Normal drawing allocates
-- almost nothing per stroke, so this should never fire.
function InkAwayView:healMemory()
    self._commits_since_gc = (self._commits_since_gc or 0) + 1
    if self._commits_since_gc < GC_HEAL_EVERY then return end
    self._commits_since_gc = 0
    if collectgarbage("count") > GC_HEAL_KB then collectgarbage("collect") end
end

-- Give the previous drawing's or notebook's memory back after starting a new one
-- (not on a page turn): drop the stroke snapshot and collect now.
function InkAwayView:resetTransientMemory()
    if self._pre_stroke_bb then self._pre_stroke_bb:free(); self._pre_stroke_bb = nil end
    self._pre_stroke_valid = false
    self._commits_since_gc = 0
    collectgarbage("collect")
end

-- Commit the stroke now if one is open or pending. Safe to call any time.
function InkAwayView:flushPending()
    if self.capturing then self:finalizeStroke() end
end

return InkAwayView
