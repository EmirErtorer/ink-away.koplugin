-- See-through pens (ink/wash.lua): a stroke never darkens itself, a second
-- stroke over it does, the highlighter keeps black black, and the export's
-- blend follows the C blitter's integer formula.
--   luajit tests/wash.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local ffi = require("ffi")
local Wash = require("ink/wash")
local Export = require("ink/export")
local Canvas = require("ink/canvas")
local Raster = require("ink/raster")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function at(m, x, y) return m.buf[(y - m.oy) * m.w + (x - m.ox)] end

-- ---- DIV_255 is the C blitter's rounding --------------------------------------
do
    local bad = 0
    for v = 0, 255 * 255 do
        local c = math.floor((math.floor((v + 128) / 256) + v + 128) / 256)
        if Wash.div255(v) ~= c then bad = bad + 1 end
    end
    ok(bad == 0, "div255: matches ((v+128)>>8 + v+128)>>8 everywhere")
    ok(Wash.div255(255 * 255) == 255 and Wash.div255(0) == 0, "div255: ends")
end

-- ---- a stroke over itself keeps its strength; the mask is its own -------------
for _i, style in ipairs({ "highlighter", "felttip", "wash" }) do
    local st = Raster.STYLES[style]
    local op = { kind = "ink", style = style, width = 20, alpha = 120, seed = 5,
                 pts = { 20, 50, 180, 50, 20, 52, 180, 48 } }        -- back and forth twice
    local m = Wash.buildMask(op, st, 400, 200)
    local once = { kind = "ink", style = style, width = 20, alpha = 120, seed = 5, pts = { 20, 50, 180, 50 } }
    local m1 = Wash.buildMask(once, st, 400, 200)
    local maxv, max1 = 0, 0
    for i = 0, m.w * m.h - 1 do if m.buf[i] > maxv then maxv = m.buf[i] end end
    for i = 0, m1.w * m1.h - 1 do if m1.buf[i] > max1 then max1 = m1.buf[i] end end
    ok(maxv == max1, style .. ": going over the stroke again never raises its strength")
    local want = (st.blend == "multiply") and 255 or 120
    ok(maxv <= want and maxv > 0, style .. ": strength is the opacity (" .. maxv .. ")")
end

-- ---- watercolour: soft edge, wet rim, smooth along the stroke --------------------
do
    local st = Raster.STYLES.wash
    local op = { kind = "ink", style = "wash", width = 60, alpha = 200, seed = 1, pts = { 100, 100, 300, 100 } }
    local m = Wash.buildMask(op, st, 400, 200)
    local centre, edge = at(m, 200, 100), at(m, 200, 128)
    ok(centre > 0 and edge < centre, "wash: fades toward the edge (" .. centre .. " / " .. edge .. ")")
    local vals = {}
    for x = 150, 250 do vals[at(m, x, 100)] = true end
    local n = 0
    for _k in pairs(vals) do n = n + 1 end
    ok(n == 1, "wash: smooth along the stroke, no grain (" .. n .. " values)")
end

-- ---- symmetry: the mask gets every copy ---------------------------------------
do
    local st = Raster.STYLES.felttip
    local op = { kind = "ink", style = "felttip", width = 10, alpha = 255, pts = { 20, 20, 60, 20 }, sym = "quad" }
    local m = Wash.buildMask(op, st, 200, 100)
    ok(m.w == 200 and m.h == 100, "sym: the mask spans the page")
    ok(at(m, 40, 20) > 0 and at(m, 159, 20) > 0 and at(m, 40, 79) > 0 and at(m, 159, 79) > 0,
        "sym: all four copies are stamped")
end

-- ---- export blends: over, multiply, and the transparent PNG -------------------
do
    local c = Canvas.new(120, 40)
    -- black ink, then a yellow highlighter across it and across white paper
    c.ops = {
        { kind = "ink", style = "solid", width = 6, alpha = 255, pts = { 60, 0, 60, 40 } },
        { kind = "ink", style = "highlighter", width = 16, alpha = 255, color = { 255, 235, 59 }, pts = { 10, 20, 110, 20 } },
    }
    local rgb, _n, ow = Export.buildRGB(c)
    local function px(buf, bpp, x, y) local o = (y * ow + x) * bpp; return buf[o], buf[o + 1], buf[o + 2], buf[o + 3] end
    local r, g, b = px(rgb, 3, 60, 20)
    ok(r == 0 and g == 0 and b == 0, "multiply: black ink stays black under the highlighter")
    r, g, b = px(rgb, 3, 20, 20)
    ok(r == 255 and g == 235 and b == 59, "multiply: white paper takes the tint")
    r, g, b = px(rgb, 3, 20, 2)
    ok(r == 255 and g == 255 and b == 255, "multiply: nothing outside the stroke")
    -- in a transparent PNG the tint is the colour at its opacity: over white it
    -- gives the same tint
    c.ops[2].alpha = 128
    local tr, tg, tb = Wash.tint(c.ops[2])
    local rgba = Export.buildRGBA(c)
    local pr, pg, pb, pa = px(rgba, 4, 20, 20)
    local function over(cv) return 255 - Wash.div255((255 - cv) * pa) end
    ok(math.abs(over(pr) - tr) <= 1 and math.abs(over(pg) - tg) <= 1 and math.abs(over(pb) - tb) <= 1,
        "PNG: the highlighter over white matches the screen's tint")
    -- over: a marker at 50% twice is darker than once
    local c2 = Canvas.new(120, 40)
    c2.ops = {
        { kind = "ink", style = "felttip", width = 10, alpha = 128, color = { 0, 0, 255 }, pts = { 10, 10, 110, 10 } },
        { kind = "ink", style = "felttip", width = 10, alpha = 128, color = { 0, 0, 255 }, pts = { 60, 0, 60, 40 } },
    }
    local rgb2 = Export.buildRGB(c2)
    local r1 = px(rgb2, 3, 30, 10)
    local r2 = px(rgb2, 3, 60, 10)
    ok(r1 == Wash.div255(255 * 127), "over: once is the C blend of white and blue")
    ok(r2 < r1, "over: where two strokes cross it is darker")
end

print(("wash: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
