-- Optional document surfaces supplied by viewers. No viewer/plugin identities
-- belong here: see docs/Plugin-integration.md for the versioned contract.
local Canvas = require("ink/canvas")
local Transform = require("ink/transform")

local Surface = {}

-- An affine part of a surface also describes how widths and non-path objects
-- turn. Path mapping can additionally cross discontinuities in a document view.
local function mapped(op, surface, page, to_page)
    local c = Canvas.cloneOp(nil, op)
    local x0, y0 = Canvas.opBox(op)
    if not x0 then return nil end
    local x, y, scale, angle
    if to_page then
        local p, px, py, zoom, rotation = surface:toPage(x0, y0)
        if not p then return nil end
        page, x, y, scale, angle = p, px, py, 1 / zoom, -(rotation or 0)
    else
        x, y, scale, angle = surface:toScreen(page, x0, y0)
        if not x then return nil end
    end
    Transform.scale(c, x0, y0, scale)
    Transform.rotate(c, x0, y0, angle or 0)
    Canvas.translateOp(c, x - x0, y - y0)
    if surface.mapPath then
        if op.kind == "ink" then
            c.pts = surface:mapPath(op.pts, to_page, page)
        elseif op.kind == "shape" and surface.isAffine and not surface:isAffine() then
            -- A primitive crossing a discontinuity is a polygon in the other
            -- coordinate system. Keep it in the existing shape format; no new
            -- persistent op types or viewer-specific metadata are needed.
            local outline = require("ink/shapes").outlines(op)[1]
            if outline then
                c.pts = surface:mapPath(outline, to_page, page)
                c.shape, c.angle = "poly", nil
                c.closed = op.shape ~= "line" and op.shape ~= "curve"
                    and (op.shape ~= "poly" or op.closed) or false
            end
        end
    end
    return c, page
end

function Surface.doc(surface)
    local doc = { kind = "paging" }
    function doc:toPage(x, y) return surface:toPage(x, y) end
    function doc:toScreen(page, x, y) return surface:toScreen(page, x, y) end
    function doc:anchorOp(op)
        local c, page = mapped(op, surface, nil, true)
        if not c then return nil end
        local x, y = Canvas.opBox(c)
        return { op = require("ink/reader/place").moved(c, -x, -y), a = { page = page, x = x, y = y } }
    end
    function doc:placeOp(item)
        local op = require("ink/reader/place").moved(item.op, item.a.x, item.a.y)
        return mapped(op, surface, item.a.page, false)
    end
    return doc
end

return Surface
