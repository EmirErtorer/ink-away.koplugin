--[[
The drawing model: an ordered list of stroke operations over a fixed W x H
canvas. This list is the one source of truth. The view on screen and the saved
image are both produced by replaying these ops in order.

An op is:
    { kind = "ink" | "erase", width = <canvas px>, alpha = 0..255,
      color = { r, g, b } or nil (black), style = "solid"|"pencil"|"charcoal"|"marker",
      seed = <int for grain>, pts = { x1,y1, x2,y2, ... } }

Points are in canvas coordinates, so a stroke keeps the same thickness and
position in the exported W x H image whatever zoom it was drawn at.

Erase is just another op that clears pixels along its path (to transparent in
the export, to the background on screen).

Undo/redo keep a history of the ops list. Snapshots are shallow (arrays of op
references), which is cheap because appends and deletes never change an existing
op. The one case that would -- editing a placed shape's colour/size/angle -- goes
through cloneOp + replaceOp instead, so older snapshots keep the original.

Plain Lua, nothing from KOReader, so the headless tests drive it directly.
]]

local Geom = require("ink/geom")

local Canvas = {}
Canvas.__index = Canvas

-- Simplification tuning (canvas pixels).
local MIN_SPACING = 1.5   -- drop points closer than this while drawing
local RDP_TOL = 0.75      -- max deviation when collapsing a finished stroke
local HISTORY_MAX = 8     -- undo/redo depth (kept small: each entry pins a full
                          -- ops snapshot, and deep history is the main avoidable
                          -- memory a long session accumulates)

function Canvas.new(w, h)
    return setmetatable({
        w = w,
        h = h,
        ops = {},          -- committed strokes
        live = nil,        -- stroke currently being drawn
        undo_stack = {},   -- past ops-list snapshots (shallow)
        redo_stack = {},
    }, Canvas)
end

-- A shallow snapshot of the current ops list (op tables are shared by reference;
-- only the array of pointers is copied). table.move is the C-level array copy.
local function snapshot(self)
    return table.move(self.ops, 1, #self.ops, 1, {})
end

-- History entries are one of:
--   { snap = <ops array> }  -- restore this whole list; used for edits that change
--                              existing ops (colour/size/move/delete/z-order/clear/load).
--   { add = true }          -- the last op was appended; to undo, drop the last op.
-- Appending one op is by far the most common action while drawing, so it uses the
-- cheap `add` entry: a committed stroke costs O(1) history instead of copying the
-- whole ops list. Copying the list every stroke is what made a long drawing throw
-- off garbage proportional to its size and slow down as it filled up.
local function pushEntry(self, entry)
    local u = self.undo_stack
    u[#u + 1] = entry
    if #u > HISTORY_MAX then table.remove(u, 1) end
    self.redo_stack = {}
end

-- Snapshot checkpoint: call BEFORE an edit that changes existing ops in place.
function Canvas:pushHistory()
    pushEntry(self, { snap = snapshot(self) })
end

-- O(1) checkpoint for appending one op to the end of the list. Undo just drops
-- whatever is last, so it does not matter that the op is recorded by position.
function Canvas:recordAppend()
    pushEntry(self, { add = true })
end

function Canvas:canUndo() return #self.undo_stack > 0 end
function Canvas:canRedo() return #self.redo_stack > 0 end

-- A copy of an op safe to edit without touching older snapshots.
function Canvas:cloneOp(op)
    local c = {}
    for k, v in pairs(op) do c[k] = v end
    if op.pts then
        local p = {}; for i = 1, #op.pts do p[i] = op.pts[i] end; c.pts = p
    end
    if op.color then c.color = { op.color[1], op.color[2], op.color[3] } end
    if op.fill_color then c.fill_color = { op.fill_color[1], op.fill_color[2], op.fill_color[3] } end
    if op.runs then
        local r = {}; for i = 1, #op.runs do r[i] = op.runs[i] end; c.runs = r
    end
    return c
end

function Canvas:replaceOp(idx, op) self.ops[idx] = op end
function Canvas:removeOp(idx) return table.remove(self.ops, idx) end

function Canvas:isEmpty()
    return #self.ops == 0 and not self.live
end

function Canvas:opCount()
    return #self.ops
end

-- Begin a new stroke. `kind` is "ink" or "erase"; `alpha` (0-255) is the ink
-- opacity (ignored for erase, which always clears fully); `color` is an optional
-- {r,g,b} table (defaults to black). Opacity defaults to opaque.
function Canvas:startStroke(kind, width, alpha, color, style, seed)
    self.live = { kind = kind, width = width, alpha = alpha or 255, color = color,
                  style = style, seed = seed, pts = {} }
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
    self:recordAppend()
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
    self:recordAppend()
    return op
end

-- Commit a flood fill as one op. `runs` is a flat { x,y,len, ... } run list.
function Canvas:addFillOp(runs, color, alpha)
    local op = { kind = "fill", runs = runs, color = color, alpha = alpha or 255 }
    self.ops[#self.ops + 1] = op
    self:recordAppend()
    return op
end

-- Undo/redo step through the history entries. An `add` entry is reversed by
-- dropping (undo) or re-appending (redo) the single op; a `snap` entry swaps the
-- whole ops list. Returns true if it moved.
function Canvas:undo()
    local entry = table.remove(self.undo_stack)
    if not entry then return false end
    if entry.snap ~= nil then
        self.redo_stack[#self.redo_stack + 1] = { snap = snapshot(self) }
        self.ops = entry.snap
    else   -- an appended op: drop the last one, remember it so redo can re-add it
        local op = table.remove(self.ops)
        self.redo_stack[#self.redo_stack + 1] = { readd = op }
    end
    self.live = nil
    return true
end

function Canvas:redo()
    local entry = table.remove(self.redo_stack)
    if not entry then return false end
    if entry.snap ~= nil then
        self.undo_stack[#self.undo_stack + 1] = { snap = snapshot(self) }
        self.ops = entry.snap
    else   -- re-append the op an undo removed
        self.ops[#self.ops + 1] = entry.readd
        self.undo_stack[#self.undo_stack + 1] = { add = true }
    end
    self.live = nil
    return true
end

function Canvas:clear()
    self:pushHistory()
    self.ops = {}
    self.live = nil
end

-- Replace all ops (used when loading a project). Clears history.
function Canvas:setOps(ops)
    self.ops = ops or {}
    self.live = nil
    self.undo_stack = {}
    self.redo_stack = {}
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
