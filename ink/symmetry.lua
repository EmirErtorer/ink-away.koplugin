--[[
Symmetry mode. When it is on, everything you draw is mirrored live: a vertical
axis mirrors left to right, a horizontal axis mirrors top to bottom, and the
four-way mode does both at once.

The trick that keeps it fast and keeps the screen, the master bitmap and the
export perfectly in step is to mirror at the very last moment: the span writer.
Every stroke, shape, fill and eraser pass already emits horizontal spans through
a `put(x, y, len)` callback. Symmetry just wraps that callback so each span is
also written at its mirrored position (or two, or three, for four-way). Because
it works on the spans and not on the model, it costs only a little arithmetic per
span and it behaves the same for a pen line, a rotated shape, a flood fill or the
eraser, with no special cases anywhere.

A span [x, x+len) reflected about the vertical centre of a width W becomes
[W-len-x, W-x): the pixel p maps to W-1-p, which is an exact, pixel-perfect
mirror. A single-row span at y reflects to row H-1-y. On screen the axis has to
be mapped through the current zoom and pan, so there it can be off by at most one
pixel; that is invisible and self-corrects the moment the stroke is committed and
the view is repainted from the exact master.

The mode a stroke was drawn with is stored on its op, so replaying the ops (for
the master, for undo, and for the export) reproduces every mirror without the
current setting mattering.
]]

local Symmetry = {}

-- Does this mode mirror across the vertical axis (left<->right)?
local function mirrorsX(mode) return mode == "vert" or mode == "quad" end
-- Does this mode mirror across the horizontal axis (top<->bottom)?
local function mirrorsY(mode) return mode == "horiz" or mode == "quad" end

Symmetry.mirrorsX = mirrorsX
Symmetry.mirrorsY = mirrorsY

-- Exact pixel reflectors for canvas / export space (width W, height H).
function Symmetry.canvasRefs(W, H)
    return function(x, len) return W - len - x end,
           function(y) return H - 1 - y end
end

-- Reflectors for the on-screen area buffer, where the canvas centre lines are
-- mapped through the current zoom and pan. Good to within a pixel, which the
-- final repaint from the master then makes exact.
function Symmetry.areaRefs(view)
    local kx = (view.canvas_w - 2 * view.pan_x) * view.zoom
    local ky = (view.canvas_h - 2 * view.pan_y) * view.zoom
    return function(x, len) return kx - x - len end,
           function(y) return ky - y end
end

-- Wrap a span writer so it also emits the mirrored spans for `mode`. `refx(x,len)`
-- gives the reflected start of a span across the vertical axis; `refy(y)` gives
-- the reflected row across the horizontal axis. The mirrored spans go to `mirror`
-- when given, else to `put`. Returns `put` unchanged when the mode is off, so
-- there is no cost at all when symmetry is not in use.
function Symmetry.wrap(put, mode, refx, refy, mirror)
    if not mode or mode == "off" then return put end
    mirror = mirror or put
    local mx, my = mirrorsX(mode), mirrorsY(mode)
    if mx and my then
        return function(x, y, len)
            put(x, y, len)
            mirror(refx(x, len), y, len)
            mirror(x, refy(y), len)
            mirror(refx(x, len), refy(y), len)
        end
    elseif mx then
        return function(x, y, len)
            put(x, y, len)
            mirror(refx(x, len), y, len)
        end
    else
        return function(x, y, len)
            put(x, y, len)
            mirror(x, refy(y), len)
        end
    end
end

local function setRect(out, n, x0, y0, x1, y1)
    local r = out[n]
    if not r then r = {}; out[n] = r end
    r.x0, r.y0, r.x1, r.y1 = x0, y0, x1, y1
end

-- The rect r ({x0, y0, x1, y1}) and its mirror images under `mode`, reflected
-- across x = kx / 2 and y = ky / 2 (kx, ky are the canvas size on the canvas).
-- The rects are written into `out` (reused when given, so a per-point caller
-- allocates nothing); returns out and the count.
function Symmetry.mirrorRects(r, mode, kx, ky, out)
    out = out or {}
    local x0, y0, x1, y1 = r.x0, r.y0, r.x1, r.y1
    setRect(out, 1, x0, y0, x1, y1)
    local n = 1
    local mx, my = mirrorsX(mode), mirrorsY(mode)
    if mx then n = n + 1; setRect(out, n, kx - x1, y0, kx - x0, y1) end
    if my then n = n + 1; setRect(out, n, x0, ky - y1, x1, ky - y0) end
    if mx and my then n = n + 1; setRect(out, n, kx - x1, ky - y1, kx - x0, ky - y0) end
    return out, n
end

return Symmetry
