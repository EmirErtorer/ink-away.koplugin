-- The optimised rasterizer (merged spans, cached disc rows, textured runs) must
-- cover exactly the pixels the plain disc-stamping reference does, for solid and
-- every textured style, at any radius. Run from the plugin root:
--   luajit tests/raster_identity.lua
package.path = "./?.lua;" .. package.path
local Ref = dofile("tests/ref/raster_reference.lua")
local Raster = require("ink/raster")
local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end
local function render(fn)
    local px, n = {}, 0
    fn(function(x, y, len)
        for i = x, x + len - 1 do local k = y * 100000 + i; if not px[k] then px[k] = true; n = n + 1 end end
    end)
    return px, n
end
local function same(a, na, b, nb)
    if na ~= nb then return false end
    for k in pairs(a) do if not b[k] then return false end end
    return true
end
math.randomseed(4242)
local radii = { 0.2, 0.5, 0.7, 1, 1.5, 2.5, 3.3, 5, 7.5, 7.51, 12.25, 20, 40 }
local styles = {}
for name, st in pairs(Ref.STYLES) do if not st.solid then styles[#styles + 1] = name end end
table.sort(styles)
local solid_bad, tex_bad, n = 0, 0, 0
for trial = 1, 600 do
    local r = radii[(trial % #radii) + 1] * ((trial % 7 == 0) and (0.37 + math.random() * 3) or 1)
    local pts, x, y = {}, math.random() * 800 - 50, math.random() * 800 - 50
    for _ = 1, 1 + math.random(0, 6) do
        pts[#pts + 1] = x; pts[#pts + 1] = y
        local step = (trial % 5 == 0) and math.random() * 1.5 or math.random() * 50
        local a = math.random() * 2 * math.pi
        x, y = x + math.cos(a) * step, y + math.sin(a) * step
    end
    n = n + 1
    local a, na = render(function(put) Ref.path(pts, r, put) end)
    local b, nb = render(function(put) Raster.path(pts, r, put) end)
    if not same(a, na, b, nb) then solid_bad = solid_bad + 1 end
    local name = styles[(trial % #styles) + 1]
    local c, nc = render(function(put) Ref.pathTex(pts, r, put, Ref.STYLES[name], trial) end)
    local d, nd = render(function(put) Raster.pathTex(pts, r, put, Raster.STYLES[name], trial) end)
    if not same(c, nc, d, nd) then tex_bad = tex_bad + 1 end
end
ok(solid_bad == 0, ("solid strokes match the reference pixel for pixel (%d of %d differ)"):format(solid_bad, n))
ok(tex_bad == 0, ("textured strokes match the reference pixel for pixel (%d of %d differ)"):format(tex_bad, n))
print(("raster identity: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
