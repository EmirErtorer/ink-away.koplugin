--[[
Drawing a see-through pen live (Highlighter, Marker, Watercolor; see
ink/wash.lua). Blending each new piece of the stroke onto the page would darken
it wherever the stroke overlaps itself, so a wash stroke keeps:
  * a mask of the whole stroke so far, the larger value winning, and
  * a copy of the page as it was under the stroke, taken tile by tile the first
    time the stroke reaches a tile.
Each new point stamps its segment into the mask, puts back the page under that
segment's box from the copy, and blends the mask over the box again. At the lift
the stroke is drawn again from the saved op (see finalizeStroke), so the screen
always matches thumbnails and exports.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Raster = require("ink/raster")
local Symmetry = require("ink/symmetry")
local Wash = require("ink/wash")

local InkAwayView = {}

local TILE = 64

-- Start a wash stroke for style `st`; the pen's colour, opacity and width are
-- those of the live op.
function InkAwayView:washBegin(st)
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    if not self.canvas_bb then return end
    local m = self._wash_live_mask
    if not (m and m.w == W and m.h == H) then
        m = Wash.newMask(W, H, 0, 0)
        self._wash_live_mask = m
    end
    local under = self._wash_under
    if not (under and under:getWidth() == W and under:getHeight() == H
            and under:getType() == self.canvas_bb:getType()) then
        if under then under:free() end
        under = Blitbuffer.new(W, H, self.canvas_bb:getType())
        self._wash_under = under
    end
    local live = self.canvas.live
    self._wl = {
        st = st, mask = m, under = under, tiles = {},
        op = live,                  -- colour, opacity, width, seed and symmetry
        box = { x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge },
    }
end

-- Copy the tiles of the page under canvas rect r into the "under" copy, the
-- first time the stroke reaches each.
local function ensureUnder(wl, src, r)
    local tiles, under = wl.tiles, wl.under
    local W, H = src:getWidth(), src:getHeight()
    for ty = math.floor(r.y0 / TILE), math.floor((r.y1 - 1) / TILE) do
        for tx = math.floor(r.x0 / TILE), math.floor((r.x1 - 1) / TILE) do
            local k = ty * 100000 + tx
            if not tiles[k] then
                tiles[k] = true
                local x, y = tx * TILE, ty * TILE
                under:blitFrom(src, x, y, x, y, math.min(TILE, W - x), math.min(TILE, H - y))
            end
        end
    end
end

-- One point of a wash stroke, at canvas (cx, cy) with pressure p.
function InkAwayView:washPoint(cx, cy, fresh, p)
    local wl = self._wl
    if not (wl and self.canvas_bb) then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    local op, st = wl.op, wl.st
    local r = (op.width or 1) / 2
    local seg, pr
    if self.last_cx and not fresh then
        seg = { self.last_cx, self.last_cy, cx, cy }
        pr = p and { self._live_p or p, p } or nil
    else
        seg = { cx, cy }
        pr = p and { p } or nil
    end
    self.last_cx, self.last_cy = cx, cy
    self._live_p = p
    if self._live_dither then return self:washDotPoint(wl, seg, r) end
    Wash.stamp(wl.mask, st, seg, pr, r, Wash.strength(op, st), op.sym, W, H)
    -- the segment's box, and its mirror images
    local pad = math.ceil(r) + 2
    local x0, y0 = math.min(seg[1], seg[#seg - 1]) - pad, math.min(seg[2], seg[#seg]) - pad
    local x1, y1 = math.max(seg[1], seg[#seg - 1]) + pad, math.max(seg[2], seg[#seg]) + pad
    local base = { x0 = math.max(0, math.floor(x0)), y0 = math.max(0, math.floor(y0)),
                   x1 = math.min(W, math.ceil(x1)), y1 = math.min(H, math.ceil(y1)) }
    if base.x1 <= base.x0 or base.y1 <= base.y0 then return end
    local rects, nr = Symmetry.mirrorRects(base, op.sym, W, H)
    local cacc = self._lw_cacc
    for i = 1, nr do
        local rr = rects[i]
        rr.x0, rr.y0 = math.max(0, rr.x0), math.max(0, rr.y0)
        rr.x1, rr.y1 = math.min(W, rr.x1), math.min(H, rr.y1)
        if rr.x1 > rr.x0 and rr.y1 > rr.y0 then
            ensureUnder(wl, self.canvas_bb, rr)
            local w, h = rr.x1 - rr.x0, rr.y1 - rr.y0
            self.canvas_bb:blitFrom(wl.under, rr.x0, rr.y0, rr.x0, rr.y0, w, h)
            Wash.blendBB(self.canvas_bb, wl.mask, op, st, rr.x0, rr.y0, rr.x1, rr.y1)
            self:markCanvasDirty(rr.x0, rr.y0, rr.x1, rr.y1)
            local b = wl.box
            b.x0, b.y0 = math.min(b.x0, rr.x0), math.min(b.y0, rr.y0)
            b.x1, b.y1 = math.max(b.x1, rr.x1), math.max(b.y1, rr.y1)
            if cacc then
                cacc.x0, cacc.y0 = math.min(cacc.x0, rr.x0), math.min(cacc.y0, rr.y0)
                cacc.x1, cacc.y1 = math.max(cacc.x1, rr.x1), math.max(cacc.y1, rr.y1)
            end
            -- show it: the screen's rect from the master
            local ax0, ay0 = self:toAreaLocal(rr.x0, rr.y0)
            local ax1, ay1 = self:toAreaLocal(rr.x1, rr.y1)
            local ar = { x0 = math.min(ax0, ax1) - 1, y0 = math.min(ay0, ay1) - 1,
                         x1 = math.max(ax0, ax1) + 1, y1 = math.max(ay0, ay1) + 1 }
            self:renderViewRect(ar.x0, ar.y0, ar.x1, ar.y1)
            self._stroke_rect = self._stroke_rect and {
                x0 = math.min(self._stroke_rect.x0, ar.x0), y0 = math.min(self._stroke_rect.y0, ar.y0),
                x1 = math.max(self._stroke_rect.x1, ar.x1), y1 = math.max(self._stroke_rect.y1, ar.y1) } or ar
            self:liveDirty(self._live_mode or "ui", ar, 1)
        end
    end
end

------------------------------------------------------------------------------
-- Dots: a see-through pen on grey e-ink, live
--
-- Greys need the slow grey waveform, which on a Kindle takes a few hundred ms
-- for each refresh and, as each piece of a wide stroke overlaps the last, makes
-- the stroke seem to flow in behind the pen. So there the stroke is shown as
-- it is drawn with black dots (an ordered dither, as dark as the pen) in the
-- fast black-and-white waveform, the true blend going into the master as
-- always; once the pen rests the stroke is drawn from the master and one grey
-- refresh settles it (see finalizeStroke and queueReconcile). Only dots are
-- added, so text under a highlighter stays readable.
------------------------------------------------------------------------------

-- 4 x 4 ordered dither thresholds, over 2 x 2 px cells.
local BAYER = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 }

-- Draw dots live? A see-through pen, on grey e-ink, without symmetry (its
-- mirror copies are drawn the slow way).
function InkAwayView:ditherLive()
    return not self:colourPanel() and not self:instantColour()
        and (self.symmetry == nil or self.symmetry == "off")
end

-- How much of the paper the dots cover, from how dark the pen leaves white
-- paper (at least a sparse pattern, so the lightest highlighter still shows).
function InkAwayView:washDotLevel(op, st)
    if not op then return 0.5 end
    local r, g, b
    if st.blend == "multiply" then
        r, g, b = Wash.tint(op)                 -- white under a highlighter
    else
        local c = op.color or { 0, 0, 0 }
        local k = Wash.strength(op, st) / 255   -- the pen over white at full strength
        r, g, b = 255 - (255 - c[1]) * k, 255 - (255 - c[2]) * k, 255 - (255 - c[3]) * k
    end
    local d = 1 - (0.299 * r + 0.587 * g + 0.114 * b) / 255
    return math.max(0.19, math.min(0.81, d))
end

-- The cells of a 4-cell period black on each row phase, at dot level `d`.
local function dotCells(d)
    local rows = {}
    for ry = 0, 3 do
        local on = {}
        for rx = 0, 3 do
            if BAYER[ry * 4 + rx + 1] + 0.5 < d * 16 then on[#on + 1] = rx end
        end
        rows[ry] = on
    end
    return rows
end

-- One point of a stroke drawn as dots: only the dots go on the screen; the
-- master is drawn from the saved stroke at the lift (see finalizeStroke), so the
-- blend each point would make there is never seen and not made. The boxes the
-- lift redraws and refreshes still grow.
function InkAwayView:washDotPoint(wl, seg, r)
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    local pad = math.ceil(r) + 2
    local x0 = math.max(0, math.floor(math.min(seg[1], seg[#seg - 1]) - pad))
    local y0 = math.max(0, math.floor(math.min(seg[2], seg[#seg]) - pad))
    local x1 = math.min(W, math.ceil(math.max(seg[1], seg[#seg - 1]) + pad))
    local y1 = math.min(H, math.ceil(math.max(seg[2], seg[#seg]) + pad))
    if x1 <= x0 or y1 <= y0 then return end
    local b = wl.box
    b.x0, b.y0, b.x1, b.y1 = math.min(b.x0, x0), math.min(b.y0, y0), math.max(b.x1, x1), math.max(b.y1, y1)
    local cacc = self._lw_cacc
    if cacc then
        cacc.x0, cacc.y0 = math.min(cacc.x0, x0), math.min(cacc.y0, y0)
        cacc.x1, cacc.y1 = math.max(cacc.x1, x1), math.max(cacc.y1, y1)
    end
    local ax0, ay0 = self:toAreaLocal(x0, y0)
    local ax1, ay1 = self:toAreaLocal(x1, y1)
    local ar = { x0 = math.min(ax0, ax1) - 1, y0 = math.min(ay0, ay1) - 1,
                 x1 = math.max(ax0, ax1) + 1, y1 = math.max(ay0, ay1) + 1 }
    local sr = self._stroke_rect
    self._stroke_rect = sr and { x0 = math.min(sr.x0, ar.x0), y0 = math.min(sr.y0, ar.y0),
        x1 = math.max(sr.x1, ar.x1), y1 = math.max(sr.y1, ar.y1) } or ar
    self:washDots(seg, r)
    self:liveDirty("fast", ar, 1)
end

-- Dot the segment `seg` (canvas coords, radius r) into the screen copy.
function InkAwayView:washDots(seg, r)
    local bb = self.area_bb
    if not bb then return end
    local cells = self._dot_cells
    if not cells or self._dot_cells_level ~= self._dots_level then
        cells = dotCells(self._dots_level or 0.5)
        self._dot_cells, self._dot_cells_level = cells, self._dots_level
    end
    local v = self.view
    local zoom = v.zoom or 1
    local a = self._dot_seg or { 0, 0, 0, 0 }
    self._dot_seg = a
    local n = #seg
    a[1], a[2] = self:toAreaLocal(seg[1], seg[2])
    if n >= 4 then a[3], a[4] = self:toAreaLocal(seg[3], seg[4]) else a[3], a[4] = nil, nil end
    local aw, ah = v.area_w, v.area_h
    local BLACK = Blitbuffer.COLOR_BLACK
    Raster.path(a, r * zoom, function(x, y, len)
        if y < 0 or y >= ah then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > aw then len = aw - x end
        if len <= 0 then return end
        local on = cells[math.floor(y / 2) % 4]
        if #on == 0 then return end
        local c0 = math.floor(x / 2)
        local base = c0 - c0 % 4
        local last = math.floor((x + len - 1) / 2)
        for cb = base, last, 4 do
            for k = 1, #on do
                local cx = cb + on[k]
                if cx >= c0 and cx <= last then
                    local px = cx * 2
                    local w = math.min(2, x + len - px)
                    if px < x then w = w - (x - px); px = x end
                    if w > 0 then bb:paintRect(px, y, w, 1, BLACK) end
                end
            end
        end
    end)
end

-- End (or drop) the wash stroke: clear what the mask holds, forget the tiles.
function InkAwayView:washEnd()
    local wl = self._wl
    self._wl = nil
    if not wl then return end
    local b = wl.box
    if b.x1 > b.x0 then Wash.clearMask(wl.mask, b.x0, b.y0, b.x1, b.y1) end
end

-- Let go of the wash buffers (closing, or memory pressure).
function InkAwayView:washFree()
    self._wl = nil
    self._wash_live_mask = nil
    if self._wash_under then self._wash_under:free(); self._wash_under = nil end
    Wash.clearCache()
end

-- Is the pen being set up a see-through one? Its style, or nil.
function InkAwayView:washStyle(style)
    local st = style and Raster.STYLES[style]
    return st and st.engine == "wash" and st or nil
end

return InkAwayView
