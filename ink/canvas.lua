--[[
The drawing model: an ordered list of stroke operations over a fixed W x H
canvas. This list is the one source of truth. The view on screen and the saved
image are both produced by replaying these ops in order.

An op is:
    { kind = "ink" | "erase", width = <canvas px>, alpha = 0..255,
      color = { r, g, b } or nil (black), pts = { x1,y1, x2,y2, ... } }

Points are in canvas coordinates, so a stroke keeps the same thickness and
position in the exported W x H image whatever zoom it was drawn at.

Erase is just another op. When the list is replayed it clears pixels along its
path, to transparent in the export and to the background on screen. Because the
replay is ordered, undo is nothing more than dropping the last op and redrawing
the region it touched, and ink that an erase had removed comes back on its own.
No pixel snapshots are ever kept.

Plain Lua, nothing from KOReader, so the headless tests drive it directly.
]]

local Geom = require("ink/geom")

local Canvas = {}
Canvas.__index = Canvas

-- Simplification tuning (canvas pixels).
local MIN_SPACING = 1.5   -- drop points closer than this while drawing
local RDP_TOL = 0.75      -- max deviation when collapsing a finished stroke

function Canvas.new(w, h)
    return setmetatable({
        w = w,
        h = h,
        ops = {},        -- committed strokes
        live = nil,      -- stroke currently being drawn
    }, Canvas)
end

function Canvas:isEmpty()
    return #self.ops == 0 and not self.live
end

function Canvas:opCount()
    return #self.ops
end

-- Begin a new stroke. `kind` is "ink" or "erase"; `alpha` (0-255) is the ink
-- opacity (ignored for erase, which always clears fully); `color` is an optional
-- {r,g,b} table (defaults to black). Opacity defaults to opaque.
function Canvas:startStroke(kind, width, alpha, color)
    self.live = { kind = kind, width = width, alpha = alpha or 255, color = color, pts = {} }
end

-- Add a raw point, in canvas coordinates, to the live stroke. Repeated points are
-- dropped so a stationary finger does not bloat the point list.
function Canvas:addPoint(cx, cy)
    local live = self.live
    if not live then return end
    local pts = live.pts
    local n = #pts
    if n >= 2 and pts[n - 1] == cx and pts[n] == cy then return end
    pts[n + 1] = cx
    pts[n + 2] = cy
end

-- Finish the live stroke, simplify it, and commit it. Returns the committed op
-- (or nil if the stroke had no points).
function Canvas:finishStroke()
    local live = self.live
    self.live = nil
    if not live or #live.pts == 0 then return nil end
    local pts = Geom.dropClose(live.pts, MIN_SPACING)
    pts = Geom.rdp(pts, RDP_TOL)
    live.pts = pts
    self.ops[#self.ops + 1] = live
    return live
end

function Canvas:cancelStroke()
    self.live = nil
end

-- Commit a shape as one op (shapes are placed whole, not point by point).
-- `pts` is { x0,y0, x1,y1 [, cx,cy] } in canvas coordinates. Returns the op.
function Canvas:addShape(shape, fill, pts, width, alpha, color)
    local op = {
        kind = "shape", shape = shape, fill = fill and true or false,
        width = width, alpha = alpha or 255, color = color, pts = pts,
    }
    self.ops[#self.ops + 1] = op
    return op
end

-- Commit a flood fill as one op. `runs` is a flat { x,y,len, ... } run list.
function Canvas:addFillOp(runs, color, alpha)
    local op = { kind = "fill", runs = runs, color = color, alpha = alpha or 255 }
    self.ops[#self.ops + 1] = op
    return op
end

-- Remove and return the most recent committed op, or nil if there is none.
function Canvas:undo()
    local n = #self.ops
    if n == 0 then return nil end
    local op = self.ops[n]
    self.ops[n] = nil
    return op
end

function Canvas:clear()
    self.ops = {}
    self.live = nil
end

-- Bounding rect {x,y,w,h} of an op in canvas coordinates, padded by half its width (plus
-- a pixel of safety) so the whole stamped disc is covered. nil for empty ops.
function Canvas:opRect(op, extra)
    local x0, y0, x1, y1 = Geom.bounds(op.pts)
    if not x0 then return nil end
    local pad = op.width / 2 + 1 + (extra or 0)
    return {
        x = x0 - pad,
        y = y0 - pad,
        w = (x1 - x0) + 2 * pad,
        h = (y1 - y0) + 2 * pad,
    }
end

return Canvas
