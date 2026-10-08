-- What each pen costs, on KOReader's real blitter (headless): a live pen sample
-- (the handler and the paint that follows), committing a stroke, building a
-- page of 150 strokes of that pen again, and exporting that page. One screen
-- config per process; prints the median and 90th percentile in microseconds.
--   cd <emulator>/koreader && ./luajit pens.lua <plugin_dir> <mock_dir> <cfg> <out> <WxH>
--   cfg: grey:<rot> | colour:<rot>
local REPO, MOCK, CFG, OUT, SIZE = arg[1], arg[2], arg[3], arg[4], arg[5] or "1072x1448"
local HERE = debug.getinfo(1, "S").source:sub(2):match("^(.*)/") or "."
local H = dofile(HERE .. "/harness.lua")(REPO, MOCK, CFG, SIZE)
local BB, now_us = H.BB, H.now_us
local Screen, UIManager = H.Screen, H.UIManager
local colour, rot, SW, SH = H.colour, H.rot, H.SW, H.SH

local samples, order = {}, {}
local function rec(metric, v)
    local t = samples[metric]
    if not t then t = {}; samples[metric] = t; order[#order + 1] = metric end
    t[#t + 1] = v
end
local function timeit(metric, fn)
    local t = now_us(); local r = fn(); rec(metric, now_us() - t); return r
end

Screen.bb = BB.new(SW, SH, colour and BB.TYPE_BBRGB32 or BB.TYPE_BB8)
Screen.bb:setRotation(rot)
UIManager.reset()
math.randomseed(7)

local View = dofile(REPO .. "/ink/view.lua")
local Export = require("ink/export")
local view = View:new{}
UIManager:show(view)
local clock = 0
view.nowMs = function() return clock end
local function paint() view:paintTo(Screen.bb, 0, 0) end
paint()
UIManager.fireScheduled()
local v = view.view
local function P(x, y) return { pos = { x = math.floor(x), y = math.floor(y) } } end
local Geom = require("ink/geom")
local function scr(cx, cy) return Geom.toScreen(v, cx, cy) end

-- The pens, with the width and opacity each is used at.
local PENS = {
    { "fineliner",   "solid",       6,  255 },
    { "pencil",      "pencil",      8,  255 },
    { "acrylic",     "acrylic",     14, 255 },
    { "ballpoint",   "ballpoint",   6,  255 },
    { "fountain",    "fountain",    12, 255 },
    { "calligraphy", "calligraphy", 22, 255 },
    { "highlighter", "highlighter", 36, 255 },
    { "marker",      "felttip",     22, 150 },
    { "watercolor",  "wash",        60, 160 },
    { "smudge",      "smudge",      40, 255 },
}
local REPEAT = tonumber(os.getenv("PEN_REPEAT") or "5")
local W, Hh = v.canvas_w, v.canvas_h

local function wave(x0, y0, x1, n, amp, phase)
    local t = {}
    for i = 0, n do
        local u = i / n
        t[#t + 1] = x0 + (x1 - x0) * u
        t[#t + 1] = y0 + math.sin(u * math.pi * 3 + (phase or 0)) * amp
    end
    return t
end

-- a page of plain handwriting-like ink, for the smudge to work on
local function inkPage()
    local ops = {}
    for k = 1, 150 do
        local row, col = math.floor((k - 1) / 5), (k - 1) % 5
        local x0 = 40 + col * (W - 80) / 5
        local y0 = 60 + row * (Hh - 120) / 30
        ops[#ops + 1] = { kind = "ink", style = "solid", width = 4, alpha = 255,
            pts = wave(x0, y0, x0 + (W - 80) / 5 - 12, 24, 8, k), color = { (k * 37) % 200, 60, (k * 91) % 220 } }
    end
    return ops
end

-- a page of 150 strokes of one pen
local function penPage(style, width, alpha)
    local ops = (style == "smudge") and inkPage() or {}
    for k = 1, 150 do
        local row, col = math.floor((k - 1) / 5), (k - 1) % 5
        local x0 = 40 + col * (W - 80) / 5
        local y0 = 60 + row * (Hh - 120) / 30
        local pts = wave(x0, y0, x0 + (W - 80) / 5 - 12, 24, 8, k)
        local pr = {}
        for i = 1, #pts / 2 do pr[i] = 80 + (i * 23 + k) % 175 end
        if style == "smudge" then
            ops[#ops + 1] = { kind = "smudge", width = width, alpha = alpha, pts = pts }
        else
            ops[#ops + 1] = { kind = "ink", style = style, width = width, alpha = alpha, seed = k,
                color = { 40, 90, 200 }, pts = pts, pr = (style ~= "solid" and style ~= "acrylic" and
                    style ~= "highlighter" and style ~= "felttip") and pr or nil }
        end
    end
    return ops
end

for _r = 1, REPEAT do
    for _i, pen in ipairs(PENS) do
        local name, style, width, alpha = pen[1], pen[2], pen[3], pen[4]
        -- live: a 120-sample stroke over a page with some ink on it
        view.canvas:setOps(style == "smudge" and inkPage() or {})
        view:composeCanvas(); view:renderView(); paint()
        view:setTool("pen")
        view.pen_style, view.pen_width, view.pen_alpha, view.pen_color = style, width, alpha, { 40, 90, 200 }
        local y = Hh * 0.4
        local sx, sy = scr(W * 0.1, y)
        view:onIaTouch(nil, P(sx, sy))
        for i = 1, 120 do
            clock = clock + 8
            local cx = W * 0.1 + i * (W * 0.75 / 120)
            local cy = y + math.sin(i / 8) * 80
            local px, py = scr(cx, cy)
            timeit(name .. ".sample", function()
                view:onIaPan(nil, P(px, py))
                paint()
            end)
        end
        local ex, ey = scr(W * 0.85, y)
        timeit(name .. ".commit", function()
            view:onIaPanRelease(nil, P(ex, ey))
            view:flushPending()
            paint()
        end)
        UIManager.fireScheduled()
        -- a page of this pen: built again, and exported
        view.canvas:setOps(penPage(style, width, alpha))
        timeit(name .. ".page", function() view:composeCanvas() end)
        timeit(name .. ".page_again", function() view:composeCanvas() end)   -- e.g. after an undo
        timeit(name .. ".export", function() return Export.buildRGB(view.canvas) end)
        collectgarbage()
    end
end

local f = io.open(OUT, "w")
for _, m in ipairs(order) do
    local t = samples[m]
    table.sort(t)
    local med = t[math.ceil(#t / 2)]
    local p90 = t[math.max(1, math.ceil(#t * 0.9))]
    f:write(string.format("%-24s n=%-5d median %10.1f  p90 %10.1f\n", m, #t, med, p90))
end
f:close()
