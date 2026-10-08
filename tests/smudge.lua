-- The smudge (ink/smudge.lua): it moves ink and only ink. Paper and ruling are
-- never picked up, ink is dragged along the stroke, colours mix, and the
-- symmetry copies smudge too.
--   luajit tests/smudge.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local Canvas = require("ink/canvas")
local Export = require("ink/export")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local function render(ops, w, h, template, rgba)
    local c = Canvas.new(w, h)
    c.ops = ops
    if rgba then
        local buf, _n, ow = Export.buildRGBA(c)
        return function(x, y) local o = (y * ow + x) * 4; return buf[o], buf[o + 1], buf[o + 2], buf[o + 3] end
    end
    local buf, _n, ow = Export.buildRGB(c, nil, template)
    return function(x, y) local o = (y * ow + x) * 3; return buf[o], buf[o + 1], buf[o + 2] end
end
local function lum(r, g, b) return (r + g + b) / 3 end

-- ---- a smudge over bare paper and ruling changes nothing ---------------------
do
    local tmpl = { style = "lines", size = 20, gray = 150 }
    local plain = render({}, 200, 120, tmpl)
    local sm = render({ { kind = "smudge", width = 24, alpha = 255, pts = { 20, 40, 60, 41, 100, 40, 180, 42 } } },
        200, 120, tmpl)
    local same = true
    for y = 0, 119 do for x = 0, 199 do
        local a1, a2, a3 = plain(x, y)
        local b1, b2, b3 = sm(x, y)
        if a1 ~= b1 or a2 ~= b2 or a3 ~= b3 then same = false end
    end end
    ok(same, "paper: a smudge over ruling alone moves nothing")
end

-- ---- ink is dragged along the stroke -------------------------------------------
do
    local ink = { kind = "ink", style = "solid", width = 10, alpha = 255, pts = { 60, 20, 60, 100 } }
    local before = render({ ink }, 200, 120)
    local after = render({ ink, { kind = "smudge", width = 30, alpha = 255,
        pts = { 50, 60, 60, 60, 70, 60, 80, 60, 90, 60, 100, 60, 110, 60 } } }, 200, 120)
    ok(lum(before(80, 60)) == 255, "drag: right of the stroke is white before")
    ok(lum(after(80, 60)) < 220, "drag: ink is pulled to the right (" .. lum(after(80, 60)) .. ")")
    ok(lum(after(60, 60)) > lum(before(60, 60)), "drag: and the stroke thins where it was dragged from")
    ok(lum(after(40, 60)) == 255, "drag: nothing moves behind the brush's start")
    ok(lum(after(60, 20)) == lum(before(60, 20)), "drag: the stroke outside the brush is untouched")
end

-- ---- colours mix as paint does ------------------------------------------------
do
    local function mixAt(c1, c2)
        local a = { kind = "ink", style = "solid", width = 30, alpha = 255, color = c1, pts = { 40, 10, 40, 110 } }
        local b = { kind = "ink", style = "solid", width = 30, alpha = 255, color = c2, pts = { 75, 10, 75, 110 } }
        local px = render({ a, b, { kind = "smudge", width = 30, alpha = 255,
            pts = { 30, 60, 40, 60, 50, 60, 60, 60, 70, 60, 80, 60 } } }, 200, 120)
        return px(72, 60)
    end
    local r, g, b = mixAt({ 220, 30, 40 }, { 30, 80, 220 })
    ok(r > g and b > g, ("mix: red pushed into blue turns purple (%d, %d, %d)"):format(r, g, b))
    r, g, b = mixAt({ 245, 200, 30 }, { 30, 80, 220 })
    ok(g > r and g > b, ("mix: yellow pushed into blue turns green, not grey (%d, %d, %d)"):format(r, g, b))
    local Smudge = require("ink/smudge")
    local exact = true
    for c = 0, 255 do if Smudge.fromAbsorbance(Smudge.absorbance(c)) ~= c then exact = false end end
    ok(exact, "mix: every value survives the trip to absorbance and back")
end

-- ---- symmetry and the kept points ------------------------------------------------
do
    local ink = { kind = "ink", style = "solid", width = 8, alpha = 255, pts = { 40, 10, 40, 50 }, sym = "vert" }
    local px = render({ ink, { kind = "smudge", width = 20, alpha = 255, sym = "vert",
        pts = { 32, 30, 40, 30, 48, 30, 56, 30, 64, 30 } } }, 200, 60)
    ok(lum(px(55, 30)) < 240 and lum(px(199 - 55, 30)) < 240, "sym: both copies are smudged")
    local c = Canvas.new(200, 100)
    c:startStroke("smudge", 20, 255, nil, "smudge", 1)
    for i = 0, 30 do c:addPoint(10 + i, 50 + (i % 2) * 0.3) end
    local op = c:finishStroke()
    ok(op.kind == "smudge" and #op.pts == 62, "canvas: a smudge keeps every point as drawn")
end

-- ---- a transparent PNG: smudged ink fades onto transparency ---------------------
do
    local ink = { kind = "ink", style = "solid", width = 10, alpha = 255, pts = { 60, 20, 60, 100 } }
    local px = render({ ink, { kind = "smudge", width = 30, alpha = 255,
        pts = { 50, 60, 60, 60, 70, 60, 80, 60, 90, 60 } } }, 200, 120, nil, true)
    local _r, _g, _b, a = px(78, 60)
    local _r2, _g2, _b2, a0 = px(20, 60)
    ok(a > 0 and a < 255, "png: dragged ink is partly transparent (" .. a .. ")")
    ok(a0 == 0, "png: untouched paper stays transparent")
end

print(("smudge: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
