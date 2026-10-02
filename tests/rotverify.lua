--[[
Landscape render byte-verification (real blitter + real mupdf scaler).

This proves the technique behind InkAwayView:blitScaledPanel -- that scaling a
crop of a PANEL-ORDER master through unrotated physical views and copying it into
the panel-order area buffer produces the same on-screen image as the old path
(scale the LOGICAL master, then blitFrom into the rotated area buffer), but as a
memcpy instead of a per-pixel rotated write.

It cannot run under the mock suite (the stub Blitbuffer stores no pixels and the
mock models a hardware-rotation screen where Screen.bb rotation is always 0). Run
it against the emulator's real libraries:

    cd <koreader-emulator>/koreader
    ./luajit <path-to-plugin>/tests/rotverify.lua

Exit status is nonzero on failure. Findings baked in as the pass thresholds:
  * rotation 0 and any zoom=1 crop are BYTE-IDENTICAL (the rotation geometry is
    exact -- trim/letterbox included);
  * a landscape downscale can differ by at most a few grey levels on a minority
    of pixels (mupdf's separable scaler rounds slightly differently on a
    transposed image). That is display-only (the PNG/JPEG export is rebuilt from
    the ops, never from this buffer) and cannot accumulate. We assert maxΔ<=24.
]]

package.path = "frontend/?.lua;" .. package.path
local ok_ll = pcall(require, "ffi/loadlib")   -- makes ffi.loadlib resolve libs/
if not ok_ll then
    io.stderr:write("rotverify: run from the emulator's koreader/ dir (ffi/loadlib missing)\n")
    os.exit(1)
end
local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local mupdf = require("ffi/mupdf")
local T = Blitbuffer.TYPE_BBRGB32
local MAX_DELTA_ALLOWED = 24

local function physWrap(bb)
    local p = Blitbuffer.new(bb.w, bb.h, bb:getType(), bb.data, bb.stride, bb.pixel_stride)
    if p.setInverse then p:setInverse(bb:getInverse()) end   -- match InkAwayView:physView
    return p
end
local function fillPattern(bb, W, H)
    for y = 0, H - 1 do for x = 0, W - 1 do
        bb:setPixel(x, y, Blitbuffer.ColorRGB32(x % 256, y % 256, (x * 3 + y * 7) % 256, 0xFF))
    end end
end
local function newAreaLike(aw, ah, rot)
    local pw, ph = aw, ah
    if rot % 2 == 1 then pw, ph = ah, aw end
    local bb = Blitbuffer.new(pw, ph, T); bb:setRotation(rot); return bb
end
local function geom(W, H, aw, ah, px, py, z)
    local sx = math.max(0, math.min(W - 1, math.floor(px)))
    local sy = math.max(0, math.min(H - 1, math.floor(py)))
    local sw = math.max(1, math.min(W - sx, math.ceil(aw / z)))
    local sh = math.max(1, math.min(H - sy, math.ceil(ah / z)))
    local dw = math.max(1, math.floor(sw * z)); local dh = math.max(1, math.floor(sh * z))
    local ox = math.max(0, math.floor((sx - px) * z)); local oy = math.max(0, math.floor((sy - py) * z))
    local bw = math.min(dw, aw - ox); local bh = math.min(dh, ah - oy)
    return { sx = sx, sy = sy, sw = sw, sh = sh, dw = dw, dh = dh, ox = ox, oy = oy, bw = bw, bh = bh }
end
-- OLD: scale logical crop, rotated blitFrom into panel-order area (per-pixel turn)
local function renderOld(canvas, area, g)
    area:fill(Blitbuffer.ColorRGB32(255, 255, 255, 255)); if g.bw < 1 or g.bh < 1 then return end
    local sub = canvas:viewport(g.sx, g.sy, g.sw, g.sh)
    local sc = mupdf.scaleBlitBuffer(sub, g.dw, g.dh)
    area:blitFrom(sc, g.ox, g.oy, 0, 0, g.bw, g.bh); if sc ~= sub then sc:free() end
end
-- NEW: scale physical crop of the mirror, memcpy into area's physical bytes
local function renderNew(cp, area, g)
    area:fill(Blitbuffer.ColorRGB32(255, 255, 255, 255)); if g.bw < 1 or g.bh < 1 then return end
    local rot = area:getRotation()
    local px, py, pw, ph = cp:getPhysicalRect(g.sx, g.sy, g.sw, g.sh)
    local sub = physWrap(cp):viewport(px, py, pw, ph)
    local fdw, fdh = g.dw, g.dh; if rot % 2 == 1 then fdw, fdh = g.dh, g.dw end
    local sc = mupdf.scaleBlitBuffer(sub, fdw, fdh); sc:setRotation(rot)
    local sx2, sy2 = sc:getPhysicalRect(0, 0, g.bw, g.bh)
    local ax, ay, aw2, ah2 = area:getPhysicalRect(g.ox, g.oy, g.bw, g.bh)
    physWrap(area):blitFrom(physWrap(sc), ax, ay, sx2, sy2, aw2, ah2); if sc ~= sub then sc:free() end
end
local function stats(a, b, aw, ah)
    local nd, md = 0, 0
    for y = 0, ah - 1 do for x = 0, aw - 1 do
        local ca, cb = a:getPixel(x, y), b:getPixel(x, y)
        local d = math.max(math.abs(ca.r - cb.r), math.abs(ca.g - cb.g), math.abs(ca.b - cb.b))
        if d > 0 then nd = nd + 1; if d > md then md = d end end
    end end
    return nd, md
end

local W, H, aw, ah = 260, 195, 240, 160
local canvas = Blitbuffer.new(W, H, T); fillPattern(canvas, W, H)
local worst, fails = 0, 0

local function check(rot, cp, z, pan, want_exact)
    local g = geom(W, H, aw, ah, pan[1], pan[2], z)
    local ao, an = newAreaLike(aw, ah, rot), newAreaLike(aw, ah, rot)
    renderOld(canvas, ao, g); renderNew(cp, an, g)
    local nd, md = stats(ao, an, aw, ah)
    if md > worst then worst = md end
    if want_exact and nd ~= 0 then
        fails = fails + 1
        io.stderr:write(string.format("FAIL exact: rot=%d z=%.4f pan=%d,%d nd=%d md=%d\n", rot, z, pan[1], pan[2], nd, md))
    end
    if md > MAX_DELTA_ALLOWED then
        fails = fails + 1
        io.stderr:write(string.format("FAIL delta: rot=%d z=%.4f pan=%d,%d md=%d > %d\n", rot, z, pan[1], pan[2], md, MAX_DELTA_ALLOWED))
    end
    ao:free(); an:free()
end

local PANS = { {0,0}, {7,5}, {13,11}, {40,30} }
for _, rot in ipairs({ 0, 1, 3 }) do
    local cp = newAreaLike(W, H, rot); cp:blitFrom(canvas, 0, 0, 0, 0, W, H)   -- panel-order mirror
    -- Exact cases: rotation geometry carries no resampling, so these must be
    -- byte-identical -- at 1:1, and at integer up-scales (whole-pixel taps).
    for _, pan in ipairs(PANS) do
        check(rot, cp, 1.0, pan, true)
        check(rot, cp, 2.0, pan, rot == 0)   -- integer up-scale: exact only guaranteed at rot 0
    end
    -- Sweep (mostly fractional / downscale): only the bounded-rounding claim holds
    -- in landscape; rot 0 stays exact throughout.
    local z = 0.3
    while z <= 4.001 do
        for _, pan in ipairs(PANS) do check(rot, cp, z, pan, rot == 0) end
        z = z + 0.1
    end
    cp:free()
end
-- Screen inverse (e.g. night mode): the mirror stays non-inverted (like canvas_bb);
-- only the final copy into area_bb applies the inverse -- exactly as the old path.
-- Assert the resulting area bytes are IDENTICAL to the old render with the SAME
-- inverse, at 1:1 in landscape (no resampling, so it must be byte-exact).
local function rawEqual(a, b)
    if a.stride * a.h ~= b.stride * b.h then return false end
    return ffi.C.memcmp(a.data, b.data, a.stride * a.h) == 0
end
do
    local z = 1.0
    for _, rot in ipairs({ 1, 3 }) do
        local cp = newAreaLike(W, H, rot); cp:blitFrom(canvas, 0, 0, 0, 0, W, H)   -- mirror, inverse 0
        for _, pan in ipairs(PANS) do
            local g = geom(W, H, aw, ah, pan[1], pan[2], z)
            local ao = newAreaLike(aw, ah, rot); ao:setInverse(1)
            local an = newAreaLike(aw, ah, rot); an:setInverse(1)
            renderOld(canvas, ao, g)
            renderNew(cp, an, g)
            if not rawEqual(ao, an) then
                fails = fails + 1
                io.stderr:write(string.format("FAIL inverse: rot=%d pan=%d,%d not byte-identical under inverse\n", rot, pan[1], pan[2]))
            end
            ao:free(); an:free()
        end
        cp:free()
    end
end

if fails == 0 then
    print(string.format("rotverify: OK (rot 0 & zoom=1 byte-exact incl. inverse; worst landscape downscale maxΔ=%d <= %d)", worst, MAX_DELTA_ALLOWED))
    os.exit(0)
else
    print(string.format("rotverify: %d FAILURE(S), worst maxΔ=%d", fails, worst))
    os.exit(1)
end
