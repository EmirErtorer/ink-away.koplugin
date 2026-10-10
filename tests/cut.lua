-- The eraser that cuts strokes (ink/cut.lua), used over a book: the parts of a
-- stroke outside the eraser become strokes of their own; shapes are cut along
-- their outline; text and pictures go whole when asked.
--   luajit tests/cut.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Cut = require("ink/cut")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function bounds(op)
    local x0, x1 = math.huge, -math.huge
    for i = 1, #op.pts, 2 do x0 = math.min(x0, op.pts[i]); x1 = math.max(x1, op.pts[i]) end
    return x0, x1
end

-- ---- a line crossed in the middle becomes two -----------------------------------
do
    local line = { kind = "ink", style = "ballpoint", width = 6, alpha = 255, color = { 0, 0, 0 },
                   pts = { 100, 100, 300, 100 }, pr = { 100, 200 } }
    local out, changed = Cut.ops({ line }, { 200, 60, 200, 140 }, 10)
    ok(changed and #out == 2, "line: cut in two (" .. #out .. ")")
    local _a, a1 = bounds(out[1])
    local b0 = bounds(out[2])
    ok(a1 <= 200 - 13 + 1 and b0 >= 200 + 13 - 1, ("line: nothing left under the eraser (%.1f .. %.1f)"):format(a1, b0))
    ok(out[1].style == "ballpoint" and out[1].pr and #out[1].pr * 2 == #out[1].pts, "line: each piece keeps its pen and pressures")
    ok(out[1].pr[1] == 100 and out[2].pr[#out[2].pr] == 200, "line: the ends keep their pressures")
    ok(out[1] ~= line and line.pts[3] == 300, "line: the original is left as it was")
end

-- ---- untouched and wholly erased --------------------------------------------------
do
    local line = { kind = "ink", width = 4, alpha = 255, pts = { 100, 100, 200, 100 } }
    local out, changed = Cut.ops({ line }, { 100, 300, 200, 300 }, 10)
    ok(not changed and out[1] == line, "far: an eraser elsewhere leaves the stroke itself")
    out = Cut.ops({ line }, { 90, 100, 210, 100 }, 10)
    ok(#out == 0, "over: an eraser along the whole stroke takes it away")
    local dot = { kind = "ink", width = 4, alpha = 255, pts = { 150, 150 } }
    ok(#Cut.ops({ dot }, { 150, 150 }, 5) == 0, "dot: rubbed out")
end

-- ---- shapes -------------------------------------------------------------------------
do
    local rect = { kind = "shape", shape = "rect", width = 4, alpha = 255, color = { 200, 0, 0 },
                   pts = { 100, 100, 300, 200 } }
    local out, changed = Cut.ops({ rect }, { 200, 80, 200, 120 }, 8)   -- across its top edge
    ok(changed and #out >= 1, "rect: cut")
    local all_ink = true
    for _, o in ipairs(out) do all_ink = all_ink and o.kind == "ink" and o.color[1] == 200 end
    ok(all_ink, "rect: its outline left as strokes of its colour")
    local filled = { kind = "shape", shape = "ellipse", width = 4, alpha = 255, fill = true, pts = { 100, 100, 200, 200 } }
    ok(#Cut.ops({ filled }, { 150, 150 }, 8) == 0, "filled: touched, it goes whole")
end

-- ---- text and pictures --------------------------------------------------------------
do
    local text = { kind = "text", x = 100, y = 100, w = 120, h = 40, text = "hello", size = 20 }
    local pic = { kind = "image", x = 300, y = 300, w = 80, h = 80, path = "/x.png" }
    local out = Cut.ops({ text, pic }, { 150, 120, 340, 340 }, 6, { text = false, pictures = false })
    ok(#out == 2, "kept: protected text and pictures stay")
    out = Cut.ops({ text, pic }, { 150, 120, 340, 340 }, 6, { text = true, pictures = true })
    ok(#out == 0, "gone: unprotected text and pictures go whole")
    -- a long straight eraser passing over a picture between its two points
    out = Cut.ops({ pic }, { 250, 340, 450, 340 }, 6, { pictures = true })
    ok(#out == 0, "gone: an eraser crossing a picture between its points reaches it")
end

-- ---- a fill loses the pixels under the eraser, exactly ------------------------------
do
    -- a 40 x 20 block of fill, rows 0..19, columns 10..49
    local runs = {}
    for y = 0, 19 do runs[#runs + 1] = 10; runs[#runs + 1] = y; runs[#runs + 1] = 40 end
    local fill = { kind = "fill", runs = runs, color = { 200, 0, 0 }, alpha = 255, layer = 3 }
    local epts, er = { 30, -10, 30, 30 }, 5   -- a vertical eraser down the middle
    local out, changed = Cut.ops({ fill }, epts, er)
    ok(changed and #out == 1 and out[1].kind == "fill" and out[1].layer == 3, "fill: cut, one op, same layer")
    -- every pixel of the block: kept exactly when its centre is outside the eraser
    local kept = {}
    local r = out[1].runs
    for i = 1, #r - 2, 3 do
        for x = r[i], r[i] + r[i + 2] - 1 do kept[r[i + 1] * 1000 + x] = true end
    end
    local right = true
    for y = 0, 19 do
        for x = 10, 49 do
            local under = math.abs(x + 0.5 - 30) <= er   -- the path covers rows -10..30
            if (kept[y * 1000 + x] or false) == under then right = false end
        end
    end
    ok(right, "fill: exactly the pixels under the eraser go")
    ok(#fill.runs == 60, "fill: the original is left as it was")
    -- missed, and rubbed out whole
    ok(not select(2, Cut.ops({ fill }, { 200, 200, 210, 210 }, 5)), "fill: an eraser elsewhere changes nothing")
    local small = { kind = "fill", runs = { 30, 5, 4 }, color = { 0, 0, 0 } }
    local gone = Cut.ops({ small }, { 32, 0, 32, 10 }, 6)
    ok(#gone == 0, "fill: rubbed out whole, it goes")
end

-- ---- only some ops (a layered drawing's active layer) ---------------------------------
do
    local a = { kind = "ink", width = 4, alpha = 255, pts = { 0, 50, 100, 50 } }
    local b = { kind = "ink", width = 4, alpha = 255, pts = { 0, 50, 100, 50 }, layer = 2 }
    local out = Cut.ops({ a, b }, { 50, 0, 50, 100 }, 6, { only = function(op) return op.layer == 2 end })
    ok(#out == 3 and out[1] == a and out[2].layer == 2 and out[3].layer == 2, "only the active layer is cut")
    local box = { kind = "shape", shape = "rect", pts = { 0, 0, 100, 100 }, width = 4, alpha = 255, layer = 2 }
    local pieces = Cut.ops({ box }, { 50, -10, 50, 10 }, 6)
    local same = #pieces > 0
    for _, p in ipairs(pieces) do same = same and p.layer == 2 end
    ok(same, "a cut shape's pieces stay on its layer")
end

print(("cut: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
