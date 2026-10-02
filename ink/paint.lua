--[[
Blitbuffer painting helpers shared by the screen code: the UI greys, colour
conversion, and span writers that paint, or restore a background, along runs.
]]

local Blitbuffer = require("ffi/blitbuffer")
local Raster = require("ink/raster")
local Template = require("ink/template")

local WHITE = Blitbuffer.COLOR_WHITE

local Paint = {}

-- Flagship UI greys (e-ink grayscale): a soft selection pill and a hairline.
-- These are plain greys, so they are Color8: KOReader draws a rounded corner in C
-- only for a Color8, and walks it pixel by pixel in Lua for an RGB32 colour (about
-- 20x slower on grey screens and 200x on colour ones -- the bulk of a menu's paint).
local HAIRLINE  = Blitbuffer.Color8(0xCC)
local TILE_BG   = Blitbuffer.Color8(0xE6)   -- shape-menu tile fill
local CARET_BG  = Blitbuffer.Color8(0xB0)   -- line-tile corner caret chip
local TRACK_BG  = Blitbuffer.Color8(0xCF)   -- slider and switch track
local KNOB_EDGE = Blitbuffer.Color8(0x99)   -- slider and switch knob rim

-- Map a grid/ruling strength (1..100) to a grey level: faint at low values,
-- solid black at 100, so a guide can be a whisper or as dark as drawn ink.
local function strengthToLevel(s)
    local lvl = math.floor(255 - (s or 45) / 100 * 255 + 0.5)
    if lvl < 0 then lvl = 0 elseif lvl > 255 then lvl = 255 end
    return lvl
end

-- A grey that, over the white canvas, looks like black ink at the given alpha,
-- so the display matches the exported PNG and JPEG. alpha 255 is black, 0 white.
-- On-screen colour for ink of rgb {r,g,b} drawn at opacity `alpha`, composited
-- over the white canvas so the display matches the exported image. rgb defaults
-- to black. On a grey e-ink panel the blitter turns the result into the right
-- shade; on a colour screen it shows in colour.
local function displayColor(rgb, alpha)
    local a = alpha or 255
    local r = rgb and rgb[1] or 0
    local g = rgb and rgb[2] or 0
    local b = rgb and rgb[3] or 0
    local function over(c) return math.floor(255 - a * (255 - c) / 255 + 0.5) end
    return Blitbuffer.ColorRGB32(over(r), over(g), over(b), 0xFF)
end

-- A swatch/tile fill for an {r,g,b}. A grey becomes a Color8 so KOReader draws its
-- rounded corners in C (an RGB32 colour takes a per-pixel Lua path); a real colour
-- has to stay RGB32 to keep its hue.
local function uiFill(rgb)
    local r, g, b = rgb[1], rgb[2], rgb[3]
    if r == g and g == b then return Blitbuffer.Color8(r) end
    return Blitbuffer.ColorRGB32(r, g, b, 0xFF)
end

-- Is this a real colour (not black/white/grey)?
local function isChromatic(color)
    if not (color and color.getColorRGB32) then return false end
    local c = color:getColorRGB32()
    return (c.r ~= c.g) or (c.g ~= c.b)
end

-- Fill a rectangle with `color`, keeping it a colour on a colour buffer.
-- KOReader's paintRect flattens any fill colour to grey (it takes getColor8()
-- first), even into an RGB32 buffer; paintRectRGB32 is its C colour fill. Older
-- builds without it fall back to setPixel, which keeps the colour too.
local function fillRect(bb, x, y, w, h, color, chromatic)
    if not chromatic then
        bb:paintRect(x, y, w, h, color)
    elseif bb.paintRectRGB32 then
        bb:paintRectRGB32(x, y, w, h, color)
    else
        for j = y, y + h - 1 do
            for i = x, x + w - 1 do bb:setPixel(i, j, color) end
        end
    end
end

-- A span writer that paints horizontal runs into `bb`, clipped to w x h, and
-- (optionally) grows `acc` to cover everything it touched. Shared by the 1:1
-- master bitmap and the on-screen buffer so both are stamped the same way.
-- Black and grey ink use paintRect; a picked colour uses the C colour fill (it
-- used to be a per-pixel loop, which made coloured pens slower the wider they got).
local function spanWriter(bb, w, h, color, acc)
    local chromatic = isChromatic(color)
    return function(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        fillRect(bb, x, y, len, 1, color, chromatic)
        if acc then
            if x < acc.x0 then acc.x0 = x end
            if x + len > acc.x1 then acc.x1 = x + len end
            if y < acc.y0 then acc.y0 = y end
            if y + 1 > acc.y1 then acc.y1 = y + 1 end
        end
    end
end

-- A span writer that restores the background image over the run (instead of
-- painting a colour). Used by the eraser when it should reveal the background
-- rather than clear to white. Optionally grows `acc` like spanWriter.
local function bgSpanWriter(bb, bg, w, h, acc)
    return function(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        bb:blitFrom(bg, x, y, x, y, len, 1)
        if acc then
            if x < acc.x0 then acc.x0 = x end
            if x + len > acc.x1 then acc.x1 = x + len end
            if y < acc.y0 then acc.y0 = y end
            if y + 1 > acc.y1 then acc.y1 = y + 1 end
        end
    end
end

-- A rectangle outline `t` pixels thick (1 by default), inside x, y, w, h.
local function outline(bb, x, y, w, h, color, t)
    t = t or 1
    bb:paintRect(x, y, w, t, color)
    bb:paintRect(x, y + h - t, w, t, color)
    bb:paintRect(x, y, t, h, color)
    bb:paintRect(x + w - t, y, t, h, color)
end

-- Draw a sample stroke of brush style `st` across bb: one sine wave of `n`
-- segments with amplitude `amp` (a fraction of the height), inset `pad`, radius
-- `r`, in `ink`. The pen menu's brush tiles and the brush maker show these.
local function brushSample(bb, st, ink, pad, r, amp, n)
    local w, h = bb:getWidth(), bb:getHeight()
    local function put(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len > 0 then bb:paintRect(x, y, len, 1, ink) end
    end
    local pts = {}
    for i = 0, n do
        local u = i / n
        pts[#pts + 1] = pad + u * (w - pad * 2)
        pts[#pts + 1] = h / 2 + math.sin(u * math.pi * 2) * (h * amp)
    end
    if st.solid then Raster.path(pts, r, put) else Raster.pathTex(pts, r, put, st, 12345) end
end

-- Paint a notebook page's paper into `dst`: the background picture / PDF page if
-- there is one (else the paper colour), then the ruling on top.
local function paintPaper(dst, W, H, tmpl, bg)
    if bg then
        dst:blitFrom(bg, 0, 0, 0, 0, W, H)
    else
        local paper = tmpl and tmpl.paper
        local col = paper and Blitbuffer.ColorRGB32(paper[1], paper[2], paper[3], 0xFF) or WHITE
        fillRect(dst, 0, 0, W, H, col, isChromatic(col))
    end
    if tmpl and tmpl.style and tmpl.style ~= "blank" then
        local lvl = strengthToLevel(tmpl.strength)
        local put = spanWriter(dst, W, H, Blitbuffer.ColorRGB32(lvl, lvl, lvl, 0xFF), nil)
        Template.render(tmpl.style, W, H, tmpl.size or 40, put)
    end
end

Paint.HAIRLINE = HAIRLINE
Paint.TILE_BG = TILE_BG
Paint.CARET_BG = CARET_BG
Paint.TRACK_BG = TRACK_BG
Paint.KNOB_EDGE = KNOB_EDGE
Paint.strengthToLevel = strengthToLevel
Paint.displayColor = displayColor
Paint.uiFill = uiFill
Paint.isChromatic = isChromatic
Paint.fillRect = fillRect
Paint.outline = outline
Paint.brushSample = brushSample
Paint.spanWriter = spanWriter
Paint.bgSpanWriter = bgSpanWriter
Paint.paintPaper = paintPaper

return Paint
