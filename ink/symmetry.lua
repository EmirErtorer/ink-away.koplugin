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
-- the reflected row across the horizontal axis. Returns `put` unchanged when the
-- mode is off, so there is no cost at all when symmetry is not in use.
function Symmetry.wrap(put, mode, refx, refy)
    if not mode or mode == "off" then return put end
    local mx, my = mirrorsX(mode), mirrorsY(mode)
    if mx and my then
        return function(x, y, len)
            put(x, y, len)
            put(refx(x, len), y, len)
            put(x, refy(y), len)
            put(refx(x, len), refy(y), len)
        end
    elseif mx then
        return function(x, y, len)
            put(x, y, len)
            put(refx(x, len), y, len)
        end
    else
        return function(x, y, len)
            put(x, y, len)
            put(x, refy(y), len)
        end
    end
end

return Symmetry
