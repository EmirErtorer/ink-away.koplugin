--[[
InkAwayView, the fullscreen finger drawing canvas.

The layout is a thin toolbar across the top with the drawing area filling the
rest. The drawing area shows the fixed W x H canvas at the current zoom and pan.
The exported image is always the full W x H, whatever is on screen.

How it draws: the committed strokes are the source of truth. To show them, they
are replayed in screen space into one reused Blitbuffer the size of the area
(`area_bb`). paintTo just copies that buffer onto the screen, so a refresh is
cheap. A new stroke segment is stamped straight into `area_bb` and only its
small changed rectangle is refreshed. The big RGBA export buffer, which is the
full canvas size, is built only when you save and is never kept around.
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

-- Grey shades, the primary choice on e-ink. Ordered dark to light.
local SHADES = {
    { name = _("Black"),      rgb = { 0x00, 0x00, 0x00 } },
    { name = _("Dark grey"),  rgb = { 0x44, 0x44, 0x44 } },
    { name = _("Grey"),       rgb = { 0x88, 0x88, 0x88 } },
    { name = _("Light grey"), rgb = { 0xBB, 0xBB, 0xBB } },
    { name = _("White"),      rgb = { 0xFF, 0xFF, 0xFF } },
}

-- Colours, offered only on colour screens (colour e-ink, Android, desktop).
local COLORS = {
    { name = _("Red"),    rgb = { 0xD0, 0x00, 0x00 } },
    { name = _("Orange"), rgb = { 0xE0, 0x70, 0x00 } },
    { name = _("Yellow"), rgb = { 0xE8, 0xC0, 0x00 } },
    { name = _("Green"),  rgb = { 0x00, 0x90, 0x00 } },
    { name = _("Blue"),   rgb = { 0x00, 0x50, 0xD0 } },
    { name = _("Purple"), rgb = { 0x80, 0x00, 0xB0 } },
}

local Canvas = require("ink/canvas")
local InkGeom = require("ink/geom")
local Raster = require("ink/raster")
local Shapes = require("ink/shapes")
local Fill = require("ink/fill")
local Export = require("ink/export")
local Project = require("ink/project")
local Symmetry = require("ink/symmetry")
local Brushes = require("ink/brushes")
local Notebook = require("ink/notebook")
local Template = require("ink/template")
local Text = require("ink/text")
local Recognize = require("ink/recognize")
local Stylus = require("ink/stylus")
-- ui/font and ui/rendertext are required lazily (only when a text box is used)
-- so the pure-Lua headless tests can still load this module.

-- PDF paper colours (shown in the exported PDF; grey e-ink can't show the tint).
local PAPERS = {
    white = { 255, 255, 255 },
    sand  = { 240, 230, 200 },   -- warm "sandpaper" / legal-pad
}

local Screen = Device.screen

-- Remembered across saves within a KOReader session (module scope).
local last_save_dir = nil

-- Worked out once: are a BBRGB32 buffer's bytes laid out R,G,B,A (so they can be
-- copied straight into an RGBA export buffer) or B,G,R,A (so R and B must swap)?
local rgb32_is_rgba = nil
local function rgb32IsRGBA()
    if rgb32_is_rgba ~= nil then return rgb32_is_rgba end
    rgb32_is_rgba = true
    pcall(function()
        local probe = Blitbuffer.new(1, 1, Blitbuffer.TYPE_BBRGB32)
        probe:setPixel(0, 0, Blitbuffer.ColorRGB32(10, 20, 30, 40))
        local p = ffi.cast("uint8_t*", probe.data)
        rgb32_is_rgba = (p[0] == 10 and p[1] == 20 and p[2] == 30)
        probe:free()
    end)
    return rgb32_is_rgba
end

local WHITE = Blitbuffer.COLOR_WHITE
local FRAME = Blitbuffer.COLOR_GRAY   -- colour of the frame around the page
-- Flagship UI greys (e-ink grayscale): a soft selection pill and a hairline.
local PILL_GREY = Blitbuffer.ColorRGB32(0xD6, 0xD6, 0xD6, 0xFF)
local HAIRLINE  = Blitbuffer.ColorRGB32(0xCC, 0xCC, 0xCC, 0xFF)
local TILE_BG   = Blitbuffer.ColorRGB32(0xE6, 0xE6, 0xE6, 0xFF)   -- shape-menu tile fill
local CARET_BG  = Blitbuffer.ColorRGB32(0xB0, 0xB0, 0xB0, 0xFF)   -- line-tile corner caret chip
-- Sheet widgets are defined further down but used by menu functions above them;
-- forward-declare so those closures capture the right upvalues.
local IconMenu, ToggleRow, SliderRow, TRACK_OFF, KNOB_EDGE
-- The floating zoom control. E-ink cannot reliably alpha-blend a rounded fill
-- (it paints opaque), so instead of a see-through charcoal box we use a light,
-- airy pill with a soft border and dark glyphs: it reads as a whisper-quiet
-- floating control rather than a heavy solid button, and its auto-hide (melting
-- away as the pen draws near) is what actually keeps the canvas reachable.
local FAB_FILL   = Blitbuffer.ColorRGB32(0xF0, 0xF0, 0xF0, 0xFF)
local FAB_BORDER = Blitbuffer.ColorRGB32(0xB4, 0xB4, 0xB4, 0xFF)
local FAB_GLYPH  = Blitbuffer.ColorRGB32(0x33, 0x34, 0x36, 0xFF)

-- Map a grid/ruling strength (1..100) to a grey level: faint at low values,
-- solid black at 100, so a guide can be a whisper or as dark as drawn ink.
local function strengthToLevel(s)
    local lvl = math.floor(255 - (s or 45) / 100 * 255 + 0.5)
    if lvl < 0 then lvl = 0 elseif lvl > 255 then lvl = 255 end
    return lvl
end

-- Convert a canvas-sized BBRGB32 into a packed RGBA FFI buffer (r,g,b,a), one
-- memcpy per row. Panels that store B,G,R,A get R/B swapped back. Returns buf or nil.
local function bbToRGBA(bb, W, H)
    if not bb then return nil end
    local buf = ffi.new("uint8_t[?]", W * H * 4)
    local ok = pcall(function()
        local src = ffi.cast("uint8_t*", bb.data)
        local stride = bb.stride or (W * 4)
        for y = 0, H - 1 do ffi.copy(buf + y * W * 4, src + y * stride, W * 4) end
    end)
    if not ok then return nil end
    if not rgb32IsRGBA() then
        for i = 0, W * H - 1 do local o = i * 4; buf[o], buf[o + 2] = buf[o + 2], buf[o] end
    end
    return buf
end

-- Even-odd ray cast: is point (px,py) inside the polygon `poly` (flat x,y list)?
local function pointInPoly(px, py, poly)
    local n = #poly / 2
    if n < 3 then return false end
    local inside = false
    local j = n
    for i = 1, n do
        local xi, yi = poly[i * 2 - 1], poly[i * 2]
        local xj, yj = poly[j * 2 - 1], poly[j * 2]
        if ((yi > py) ~= (yj > py))
           and (px < (xj - xi) * (py - yi) / (yj - yi) + xi) then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Average point of an op's geometry (canvas coords), or nil if it has none.
local function opCentroid(op)
    local sx, sy, n = 0, 0, 0
    if op.pts then
        for i = 1, #op.pts, 2 do sx = sx + op.pts[i]; sy = sy + op.pts[i + 1]; n = n + 1 end
    elseif op.runs then
        for i = 1, #op.runs, 3 do sx = sx + op.runs[i]; sy = sy + op.runs[i + 1]; n = n + 1 end
    end
    if n == 0 then return nil end
    return sx / n, sy / n
end

-- Is an op picked by a lasso polygon (canvas coords)? An op counts as selected
-- when most of it sits inside the loop (a fraction of its points, sampled and
-- capped so a dense ink stroke stays cheap), OR when its centre is inside (so a
-- big shape looped around its middle still selects). The point-fraction test is
-- what makes ink as easy to grab as a shape: a stroke's average point is often
-- outside a loop that clearly encircles the stroke, but its points are not.
local function opInPoly(op, poly)
    local inside, total = 0, 0
    local function sample(x, y)
        total = total + 1
        if pointInPoly(x, y, poly) then inside = inside + 1 end
    end
    if op.pts then
        local pairs_n = #op.pts / 2
        local step = math.max(1, math.floor(pairs_n / 48))   -- <= ~48 samples
        for p = 0, pairs_n - 1, step do
            local i = p * 2 + 1
            sample(op.pts[i], op.pts[i + 1])
        end
    elseif op.runs then
        local triples = #op.runs / 3
        local step = math.max(1, math.floor(triples / 48))
        for t = 0, triples - 1, step do
            local i = t * 3 + 1
            sample(op.runs[i], op.runs[i + 1])
        end
    end
    if total == 0 then return false end
    if inside / total >= 0.3 then return true end             -- a good chunk is inside
    local cx, cy = opCentroid(op)
    if cx and pointInPoly(cx, cy, poly) then return true end   -- centre of mass is inside
    -- bounding-box centre is inside (stable for long strokes)
    local x0, y0, x1, y1
    local function ext(x, y)
        if not x0 or x < x0 then x0 = x end
        if not y0 or y < y0 then y0 = y end
        if not x1 or x > x1 then x1 = x end
        if not y1 or y > y1 then y1 = y end
    end
    if op.pts then for i = 1, #op.pts, 2 do ext(op.pts[i], op.pts[i + 1]) end
    elseif op.runs then for i = 1, #op.runs, 3 do ext(op.runs[i], op.runs[i + 1]) end end
    if x0 then return pointInPoly((x0 + x1) / 2, (y0 + y1) / 2, poly) end
    return false
end

-- Accumulate an op's bounds into x0,y0,x1,y1 (canvas coords). Returns updated four.
local function accumBounds(op, x0, y0, x1, y1)
    local function acc(x, y)
        if not x0 or x < x0 then x0 = x end
        if not y0 or y < y0 then y0 = y end
        if not x1 or x > x1 then x1 = x end
        if not y1 or y > y1 then y1 = y end
    end
    if op.pts then for i = 1, #op.pts, 2 do acc(op.pts[i], op.pts[i + 1]) end end
    if op.runs then for i = 1, #op.runs, 3 do acc(op.runs[i], op.runs[i + 1]); acc(op.runs[i] + op.runs[i + 2], op.runs[i + 1]) end end
    return x0, y0, x1, y1
end

-- Shift every coordinate of an op by (dx,dy) canvas pixels, in place.
local function translateOp(op, dx, dy)
    if op.pts then for i = 1, #op.pts, 2 do op.pts[i] = op.pts[i] + dx; op.pts[i + 1] = op.pts[i + 1] + dy end end
    if op.runs then for i = 1, #op.runs, 3 do op.runs[i] = op.runs[i] + dx; op.runs[i + 1] = op.runs[i + 1] + dy end end
end

-- Fit a source BlitBuffer inside a W x H page keeping its aspect, centre it on a
-- white RGB32 page, and free the source. Returns the new page BlitBuffer.
local function fitIntoCanvasBB(img, W, H)
    local iw, ih = img:getWidth(), img:getHeight()
    local scale = math.min(W / iw, H / ih)
    local dw = math.max(1, math.floor(iw * scale + 0.5))
    local dh = math.max(1, math.floor(ih * scale + 0.5))
    local fitted = img
    if dw ~= iw or dh ~= ih then fitted = RenderImage:scaleBlitBuffer(img, dw, dh, false) end
    local bg = Blitbuffer.new(W, H, Blitbuffer.TYPE_BBRGB32)
    bg:fill(WHITE)
    bg:blitFrom(fitted, math.floor((W - dw) / 2), math.floor((H - dh) / 2), 0, 0, dw, dh)
    if fitted ~= img and fitted.free then fitted:free() end
    if img.free then img:free() end
    return bg
end

-- When the finger lifts, wait this long before committing the stroke. If a
-- fresh touch lands nearby within the window, treat it as the SAME stroke.
-- Touch panels on these readers often drop and reacquire a finger in the middle
-- of a line, and this is what keeps one lift as one undo step, keeps exported
-- strokes whole, and fills the gap a dropped contact would otherwise leave.
local COALESCE_SEC = 0.15
-- After the pen lifts, keep ignoring finger touches this long: a resting palm
-- usually lifts a fraction of a second after the pen, so this stops it landing a
-- stray mark or tap in the gap.
local PEN_LIFT_DEBOUNCE = 0.35
local ZOOM_RATIO = 1.5    -- one zoom press multiplies by this, for even steps
local ZOOM_MAX = 8.0

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

-- A span writer that paints horizontal runs into `bb`, clipped to w x h, and
-- (optionally) grows `acc` to cover everything it touched. Shared by the 1:1
-- master bitmap and the on-screen buffer so both are stamped the same way.
--
-- KOReader's paintRect flattens any fill colour to grey (it takes getColor8()
-- first), even into an RGB32 buffer, so a coloured pen would show grey on a
-- colour screen. For a chromatic colour we therefore fill pixel by pixel with
-- setPixel, which keeps the colour. This only happens when a colour was actually
-- picked (colour screens only); black and grey ink keep the fast paintRect path.
local function spanWriter(bb, w, h, color, acc)
    local chromatic = false
    if color and color.getColorRGB32 then
        local c = color:getColorRGB32()
        chromatic = (c.r ~= c.g) or (c.g ~= c.b)
    end
    return function(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len <= 0 then return end
        if chromatic then
            for i = 0, len - 1 do bb:setPixel(x + i, y, color) end
        else
            bb:paintRect(x, y, len, 1, color)
        end
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

local InkAwayView = InputContainer:extend{
    name = "inkaway_view",
    covers_fullscreen = true,
    -- The canvas is modal: swallow any gesture a toolbar button did not take
    -- (pinch, double tap, multiswipe, and so on) so the view under it stays put.
    stop_events_propagation = true,
}

------------------------------------------------------------------------------
-- Small geometry helpers
------------------------------------------------------------------------------

function InkAwayView:inArea(x, y)
    local v = self.view
    return x >= v.area_x and x < v.area_x + v.area_w
       and y >= v.area_y and y < v.area_y + v.area_h
end

-- screen -> canvas, clamped to the canvas bounds
function InkAwayView:toCanvasClamped(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    if cx < 0 then cx = 0 elseif cx > self.view.canvas_w then cx = self.view.canvas_w end
    if cy < 0 then cy = 0 elseif cy > self.view.canvas_h then cy = self.view.canvas_h end
    return cx, cy
end

-- canvas to area coordinates (origin at the area's top left corner, i.e. area_bb)
function InkAwayView:toAreaLocal(cx, cy)
    local v = self.view
    return (cx - v.pan_x) * v.zoom, (cy - v.pan_y) * v.zoom
end

-- Snap a screen point to the grid (in canvas space) when grid snapping is on.
function InkAwayView:snapScreen(sx, sy)
    if not self.snap_grid then return sx, sy end
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    cx, cy = InkGeom.snapToGrid(cx, cy, self.grid_size)
    return InkGeom.toScreen(self.view, cx, cy)
end

------------------------------------------------------------------------------
-- Preferences (kept in KOReader's global settings so they persist)
------------------------------------------------------------------------------

function InkAwayView:getSetting(key, default)
    local G = rawget(_G, "G_reader_settings")
    if G and G.readSetting then
        local v = G:readSetting(key)
        if v ~= nil then return v end
    end
    return default
end

function InkAwayView:setSetting(key, value)
    local G = rawget(_G, "G_reader_settings")
    if G and G.saveSetting then G:saveSetting(key, value) end
end

-- Whether to offer the colour picker: yes on a real colour screen. Setting the
-- INKAWAY_FORCE_MONO environment variable forces it off, which is handy in the
-- desktop emulator (which always reports a colour screen) for previewing how the
-- plugin looks on a plain grey e-ink device.
function InkAwayView:colorScreen()
    -- A testing override honoured only in the desktop emulator (which always
    -- reports a colour screen), so the grey UI can be previewed there. Real
    -- hardware never reads the environment variable.
    if Device.isEmulator and Device:isEmulator() and os.getenv("INKAWAY_FORCE_MONO") then
        return false
    end
    return (Device.hasColorScreen and Device:hasColorScreen()) and true or false
end

------------------------------------------------------------------------------
-- Orientation (portrait / landscape)
--
-- KOReader rotates the whole screen: a rotation mode is 0 (upright portrait),
-- 1 (clockwise landscape), 2 (upside-down portrait) or 3 (counter-clockwise
-- landscape) -- the odd modes are the two landscapes. Ink Away can run either
-- way up. It remembers the reader's own rotation when it opens and puts it back
-- on close, and it remembers the orientation you last drew in so a fresh launch
-- comes up the same way. Opening while the device is already held in landscape
-- works too, since the very first launch simply adopts whatever the screen is.
--
-- The canvas is created at the screen size, so a landscape session gets a wide
-- canvas and its PNG/JPEG/PDF export comes out landscape with no extra work. A
-- drawing already on screen keeps its size and is just shown rotated (you pan to
-- reach it); only a still-blank page is reshaped to the new orientation.
------------------------------------------------------------------------------

local function modeIsLandscape(mode) return mode ~= nil and (mode % 2 == 1) end

-- Is screen rotation available at all (it is on real devices and the emulator;
-- guard so the headless tests, which stub Screen, never call a missing method).
function InkAwayView:orientationSupported()
    return (Screen.setRotationMode and Screen.getRotationMode) and true or false
end

function InkAwayView:currentRotation()
    return (Screen.getRotationMode and Screen:getRotationMode()) or 0
end

-- The "portrait" / "landscape" class of a rotation mode (the current one if none
-- is given).
function InkAwayView:orientationClass(mode)
    if mode == nil then mode = self:currentRotation() end
    return modeIsLandscape(mode) and "landscape" or "portrait"
end

-- Which rotation mode to use for a requested orientation. Prefer the reader's own
-- rotation when it already matches the class (so we keep the exact way up the
-- device is held), else a sensible default: upright for portrait, and
-- counter-clockwise for landscape (so the device's bottom bezel ends up on the
-- right, matching how most readers turn a device for landscape).
function InkAwayView:rotationForClass(class)
    local orig = self.orig_rotation
    if class == "landscape" then
        if modeIsLandscape(orig) then return orig end
        return Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE or 3
    else
        if orig ~= nil and not modeIsLandscape(orig) then return orig end
        return Screen.DEVICE_ROTATED_UPRIGHT or 0
    end
end

-- Apply the orientation Ink Away should open in, called once at init BEFORE the
-- canvas and buffers are sized. Uses the remembered choice if there is one, else
-- adopts (and remembers) however the device is currently held.
function InkAwayView:applyStartupOrientation()
    if not self:orientationSupported() then
        self.orientation = self:orientationClass()
        return
    end
    local pref = self:getSetting("inkaway_orientation", nil)
    if pref ~= "portrait" and pref ~= "landscape" then
        self.orientation = self:orientationClass()
        self:setSetting("inkaway_orientation", self.orientation)
        return
    end
    self.orientation = pref
    local target = self:rotationForClass(pref)
    if target ~= self:currentRotation() then
        pcall(function() Screen:setRotationMode(target) end)
    end
end

-- Switch orientation from the Settings sheet. Rotates the screen, remembers the
-- choice, then re-lays-out (and reshapes a blank page to the new orientation).
function InkAwayView:setOrientation(class)
    if not self:orientationSupported() then return end
    if self:orientationClass() == class then return end   -- already that way up
    pcall(function() Screen:setRotationMode(self:rotationForClass(class)) end)
    self.orientation = class
    self:setSetting("inkaway_orientation", class)
    self:handleScreenResize()
    -- a full refresh both draws the new orientation and clears the panel, which is
    -- exactly when a full refresh earns its cost
    UIManager:setDirty(self, "full")
end

-- If nothing has been drawn yet, reshape the blank page to match the screen's
-- current size, so a fresh drawing or notebook fills the whole screen in the new
-- orientation. A page with work on it is left at its own size (shown rotated).
-- Returns true if it reshaped. Recomposes the master buffer so the caller's
-- renderView shows the reshaped (blank) page.
function InkAwayView:reshapeIfEmpty()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local v = self.view
    if not v then return false end
    if v.canvas_w == W and v.canvas_h == H then return false end   -- already that shape
    local empty
    if self.notebook then
        -- a PDF-backed notebook is tied to its source pages: never reshape it
        if self.notebook.template and self.notebook.template.pdf_path then return false end
        empty = true
        for _, pg in ipairs(self.notebook.pages) do
            if pg.ops and #pg.ops > 0 then empty = false; break end
        end
    else
        empty = self.canvas:isEmpty() and not self.bg_bb
    end
    if not empty then return false end
    v.canvas_w, v.canvas_h = W, H
    self.canvas.w, self.canvas.h = W, H
    if self.notebook then self.notebook.w, self.notebook.h = W, H end
    if self.canvas_bb then self.canvas_bb:free() end
    self.canvas_bb = Blitbuffer.new(W, H, Screen.bb:getType())
    self:composeCanvas()   -- fill the fresh master (paper/ruling for a notebook)
    return true
end

-- Re-lay-out after the screen size changed -- from our own orientation toggle, or
-- the device being physically turned (onSetDimensions). Reshape a blank page to
-- the new orientation first, then rebuild the toolbar/area and refit the view.
function InkAwayView:handleScreenResize()
    self:reshapeIfEmpty()
    self:relayout()
    self.orientation = self:orientationClass()
end

------------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------------

function InkAwayView:init()
    -- Remember the reader's own rotation (restored on close) and apply the
    -- orientation Ink Away should open in, BEFORE the canvas and buffers below are
    -- sized to the screen -- so a landscape session gets a wide canvas from the
    -- start and its export comes out landscape automatically.
    self.orig_rotation = self:currentRotation()
    self:applyStartupOrientation()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
    self.dimen = GeomUI:new{ x = 0, y = 0, w = W, h = H }
    self.closing = false
    self.tool = "pen"          -- "pen" | "erase" | "pan" | "shape"
    self.capturing = false     -- a pen/erase stroke is in progress
    self.pending_lift = nil    -- {x,y}: finger lifted, stroke not yet committed
    self.pan_last = nil        -- last point of a pan drag in progress (screen)

    -- Shapes: the chosen shape and whether it is filled; drag/preview state.
    self.shape = "rect"        -- "line"|"curve"|"rect"|"ellipse"|"triangle"
    self.shape_fill = false
    self.shape_drag = nil      -- {x0,y0,x1,y1} in screen coords, while stretching
    self.curve_stage = nil     -- nil | "bend" (second phase of the curve tool)
    self.shape_preview = nil   -- op (screen coords) drawn on top in paintTo
    self._preview_rect = nil   -- last previewed screen rect, for tidy refreshes
    self.selected = nil        -- {op, idx}: shape picked by a long press
    self.rotating = nil        -- rotation-in-progress state

    -- Pen: width in canvas pixels (constant thickness in the export regardless
    -- of zoom) and opacity 0-255. The eraser is a good deal fatter.
    self.pen_width = 15               -- canvas px; a comfortable default
    self.pen_alpha = 255
    self.pen_color = { 0x00, 0x00, 0x00 }   -- {r,g,b}; black to start
    self.fill_color = { 0x88, 0x88, 0x88 }  -- paint bucket has its own colour...
    self.fill_alpha = 255                   -- ...and opacity, set from its menu
    self.eraser_width = 40            -- canvas px; adjustable, like the pen
    -- How close a fresh touch must land (screen px) to count as the same stroke.
    self.bridge_dist = math.max(24, math.floor(W / 22))

    -- Preferences and drawing aids, loaded from saved settings.
    -- Register any brushes the reader has made so their strokes resolve.
    Brushes.loadAll(function(k) return self:getSetting(k) end)
    self.pen_style   = self:getSetting("inkaway_pen_style", "solid")
    if not Raster.STYLES[self.pen_style] then self.pen_style = "solid" end
    self.stabilizer  = self:getSetting("inkaway_stabilizer", 40)       -- 0..100
    self.grid_on     = self:getSetting("inkaway_grid", false)
    self.grid_style  = self:getSetting("inkaway_grid_style", "square")  -- square|dots|lines|iso|thirds
    self.grid_size   = self:getSetting("inkaway_grid_size", math.max(24, math.floor(W / 16)))
    self.grid_strength = self:getSetting("inkaway_grid_strength", 45)   -- 1..100, 100 = ink black
    -- Notebook ruling: remembered across notebooks so a new one starts like the last.
    self.nb_style    = self:getSetting("inkaway_nb_style", "lines")
    self.nb_size     = self:getSetting("inkaway_nb_size", nil)          -- nil = fall back to grid_size
    self.nb_strength = self:getSetting("inkaway_nb_strength", nil)      -- nil = fall back to grid_strength
    self.snap_grid   = self:getSetting("inkaway_snap_grid", false)
    self.snap_angle  = self:getSetting("inkaway_snap_angle", false)
    -- Shape assist (beautify): a finished pen stroke that clearly reads as a
    -- line/rectangle/ellipse/triangle (or an L, for x/y axes) is replaced with a
    -- clean shape. Unrecognised strokes are left exactly as drawn.
    self.shape_assist = self:getSetting("inkaway_shape_assist", false)
    -- Handwriting to text (beta): when on, printed pen strokes are recognised on a
    -- pause and replaced with a text box using the current text settings. Offline
    -- and best-effort (see ink/hwr.lua). Off by default; a no-op unless enabled.
    self.hwr_enabled = self:getSetting("inkaway_hwr", false) and true or false
    -- Palm rejection: on a device with a pen, take the pen over (draw from its raw
    -- events) and ignore finger touches while the pen is down, so a resting palm
    -- never marks the page. Defaults ON on pen devices (Kindle Scribe, reMarkable)
    -- and OFF on finger-only readers (Paperwhite) and Kobo (which KOReader gives no
    -- reliable "has a pen" flag for, so it opts in via the toggle). It is a no-op
    -- until a real pen is present regardless. The one hard part is that KOReader
    -- routes a resting palm to us wearing the stylus eraser's tool number
    -- (MT_TOOL_PALM == TOOL_TYPE_ERASER == 2); we tell a real pen from a promoted
    -- palm by slot with Stylus.classify (see onStylusSlot / ink/stylus.lua).
    self.palm_reject = self:getSetting("inkaway_palm_reject", self:deviceHasStylus()) and true or false
    self._pen_state  = Stylus.new()
    self._pen_owner  = nil        -- slot number currently drawing the pen stroke
    self._palm_slots = {}         -- slot number -> tracking id, for palms we swallow
    self._palm_count = 0
    self._reject_finger = false   -- true while a pen/palm is down (plus a short debounce)
    -- After a debounce with no pen/palm activity, re-enable fingers and forget any
    -- palm we never saw lift (a palm whose tool reverts to finger stops arriving at
    -- the stylus callback, so the count is refreshed by activity, not trusted long).
    self._pen_clear  = function()
        self._reject_finger = false
        self._palm_slots = {}
        self._palm_count = 0
    end
    self.symmetry    = self:getSetting("inkaway_symmetry", "off")      -- off|vert|horiz|quad
    self.ghost_clean = self:getSetting("inkaway_ghost", 0)             -- 0 = off, else stroke count
    self.erase_bg    = self:getSetting("inkaway_erase_bg", false)      -- eraser also removes the background?
    self._strokes_since_full = 0
    self.autosave    = self:getSetting("inkaway_autosave", "exit")     -- off|exit|periodic
    self.dirty = false
    self._autosave_tick = function() self:autosaveTick() end

    -- Arrows on line/curve shapes.
    self.shape_arrow = nil                                             -- nil|"end"|"both"
    self.arrow_head  = self:getSetting("inkaway_arrow_head", math.max(16, math.floor(W / 32)))

    -- Text notes: default font (nil = the reader's content font) and size.
    local tf = self:getSetting("inkaway_text_font", "")
    self.text_font = (tf ~= "" ) and tf or nil
    self.text_size = self:getSetting("inkaway_text_size", nil)
    -- Snap each typed line onto the notebook ruling (only affects ruled pages).
    self.text_grid_snap = self:getSetting("inkaway_text_grid_snap", false) and true or false
    -- Whether the eraser is allowed to rub out typed text. Off by default: text is
    -- drawn on top of the ink and the eraser leaves it untouched.
    self.text_erase_protect = self:getSetting("inkaway_text_erase_protect", true) and true or false
    -- Per-box edit history kept alive after a text box is committed, keyed by the
    -- op itself (weak, so it is dropped when the op is gone). It lets Undo peel a
    -- committed text box back word by word instead of deleting the whole block.
    self._text_hist = setmetatable({}, { __mode = "k" })

    -- Optional background image (a picture your drawing sits on top of).
    self.bg_bb, self.bg_rgba, self.bg_path = nil, nil, nil
    self.export_bg = true          -- include the background in a save, by default
    self.save_area = nil           -- nil = whole page, or a crop rect in canvas px
    self.selecting_crop = false    -- dragging out an export area

    -- Default folders: koreader/ink away/{drawings,projects,notebooks}, created once.
    self.default_dir = self:ensureDefaultDir()

    -- Notebook mode: nil = a single canvas (the classic mode); a Notebook table
    -- when the reader is working through pages. nb_bar_h reserves room for the
    -- bottom page-nav strip, and is 0 in canvas mode so nothing else changes.
    self.notebook = nil
    self.nb_bar_h = 0

    -- The canvas has a fixed size: the current screen dimensions.
    self.canvas = Canvas.new(W, H)

    -- Bound once so it can be scheduled and unscheduled by identity.
    self._finalize = function() self:finalizeStroke() end
    -- Coalesced refresh while dragging a lasso selection: many pan events collapse
    -- into at most one small refresh per interval, so the e-ink panel is never
    -- flooded (which on device froze it mid-refresh).
    self._sel_refresh_tick = function() self:selRefreshNow() end
    -- Bring the floating controls back once drawing near them has stopped.
    self._show_zoom_fab = function()
        if self._zoom_hidden then
            self._zoom_hidden = false
            self:refreshFabRegion(self:fabRect("zoom"))
        end
    end
    self._show_bar_toggle = function()
        if self._bar_toggle_hidden then
            self._bar_toggle_hidden = false
            self:refreshFabRegion(self:fabRect("bar"))
        end
    end
    self._show_nbbar_toggle = function()
        if self._nbbar_toggle_hidden then
            self._nbbar_toggle_hidden = false
            self:refreshFabRegion(self:fabRect("nbbar"))
        end
    end
    -- Let the exporter render text ops (it has no fonts of its own).
    Export.text_raster = function(op) return self:exportTextRaster(op) end
    -- ...and placed images (it has no image decoder either).
    Export.image_raster = function(op) return self:exportImageRaster(op) end

    self:buildToolbar()
    local th = self.toolbar:getSize().h
    self.view = {
        area_x = 0, area_y = th, area_w = W, area_h = H - th - self.nb_bar_h,
        canvas_w = W, canvas_h = H,
        zoom = 1, pan_x = 0, pan_y = 0,
    }
    self.zoom_min = InkGeom.fitZoom(self.view)
    -- Start filling the full width of the drawing area (no side letterbox), so the
    -- whole screen is paintable. The page is as wide as the screen, so this is 1:1;
    -- any part taller than the visible area is reachable by panning or by hiding the
    -- toolbar. zoom_min (fit-to-page) stays the lower bound for pinch-zooming out.
    self.view.zoom = math.max(self.zoom_min, self.view.area_w / self.view.canvas_w)
    InkGeom.clampPan(self.view)

    -- self[1] lets gesture events propagate to the toolbar buttons; the actual
    -- painting is done by our own paintTo.
    self[1] = self.toolbar

    if Device:isTouchDevice() then
        local full = self.dimen
        -- Ranged across the whole screen so we always get the lift even if the finger
        -- strays; the handlers gate on the area rect and the active tool.
        self.ges_events = {
            IaTouch      = { GestureRange:new{ ges = "touch",        range = full } },
            IaPan        = { GestureRange:new{ ges = "pan",          range = full } },
            IaHoldPan    = { GestureRange:new{ ges = "hold_pan",     range = full } },
            IaPanRelease = { GestureRange:new{ ges = "pan_release",  range = full } },
            IaHoldRel    = { GestureRange:new{ ges = "hold_release", range = full } },
            IaSwipe      = { GestureRange:new{ ges = "swipe",        range = full } },
            IaTap        = { GestureRange:new{ ges = "tap",          range = full } },
            IaHold       = { GestureRange:new{ ges = "hold",         range = full } },
            IaTwoPan     = { GestureRange:new{ ges = "two_finger_pan", range = full } },
            IaTwoPanRel  = { GestureRange:new{ ges = "two_finger_pan_release", range = full } },
            IaPinch      = { GestureRange:new{ ges = "pinch",  range = full } },
            IaSpread     = { GestureRange:new{ ges = "spread", range = full } },
        }
    end
    if Device:hasKeys() then
        self.key_events = { IaClose = { { Device.input.group.Back } } }
    end

    -- Two buffers, both reused for the whole session:
    --  * canvas_bb is the drawing at 1:1 (the full canvas size). Strokes are
    --    stamped here once, at their real size, independent of zoom.
    --  * area_bb is what actually shows on screen. Zoom and pan just scale a
    --    crop of canvas_bb into it (a fast mupdf blit), so their cost depends
    --    only on the screen size, never on how much has been drawn or how far
    --    it is zoomed in.
    local bbtype = Screen.bb:getType()
    self.canvas_bb = Blitbuffer.new(self.view.canvas_w, self.view.canvas_h, bbtype)
    self.area_bb = Blitbuffer.new(self.view.area_w, self.view.area_h, bbtype)

    self:restoreSession()   -- reopen the last drawing if one was kept
    self:composeCanvas()
    self:renderView()
    self:scheduleAutosave()
    self:applyPalmReject()   -- hook the pen if palm rejection is on and supported
    -- Dev hook (emulator only): force an orientation at launch so the landscape
    -- layout can be screenshotted without driving the settings menu. No-op on device.
    local autoorient = os.getenv("INKAWAY_AUTOORIENT")
    if autoorient == "landscape" or autoorient == "portrait" then
        UIManager:scheduleIn(0.4, function() self:setOrientation(autoorient) end)
    end
    -- Dev hook (emulator only): auto-open a named options sheet so UI work can be
    -- screenshotted without driving the mouse. No-op on device.
    local autosheet = os.getenv("INKAWAY_AUTOSHEET")
    if autosheet then
        UIManager:scheduleIn(0.7, function()
            if autosheet == "pen" then self:openPenSettings()
            elseif autosheet == "eraser" then self:openEraserSettings()
            elseif autosheet == "text" then self:openTextSettings()
            elseif autosheet == "settings" then self:openSettings()
            elseif autosheet == "save" then self:onSave()
            elseif autosheet == "brush" then self:openBrushMaker()
            elseif autosheet == "shape" then self:openShapePicker()
            elseif autosheet == "shapeline" then self:openShapePicker(); self:openShapeLineMenu()
            elseif autosheet == "fill" then self:openFillColor()
            elseif autosheet == "notebook" then self:startNotebook({ style = "lines", size = self.grid_size or 40, strength = self.grid_strength or 45 })
            end
        end)
    end
    -- Dev hook (emulator only): dump the framebuffer to a PNG a moment after the
    -- sheet opens, so UI iteration needs no OS-level screen capture. No-op on device.
    local autoshot = os.getenv("INKAWAY_AUTOSHOT")
    if autoshot then
        UIManager:scheduleIn(1.7, function() pcall(function() Screen:shot(autoshot) end) end)
    end
end

------------------------------------------------------------------------------
-- Projects and autosave
------------------------------------------------------------------------------

-- Path of the kept "last session" file.
function InkAwayView:sessionPath()
    local ok, DataStorage = pcall(require, "datastorage")
    local dir = (ok and DataStorage and DataStorage:getSettingsDir()) or "/tmp"
    return dir .. "/inkaway_session." .. Project.EXT
end

-- Load ops from a project into the canvas, if they fit this screen. Returns ok.
function InkAwayView:loadProjectData(data)
    if not data or not data.ops then return false end
    self.canvas:setOps(data.ops)
    self.selected, self.rotating = nil, nil
    self.active_image, self._img_drag = nil, nil
    self:freeImageCache()
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self.dirty = false
    return true
end

function InkAwayView:restoreSession()
    if self.autosave == "off" then return end
    local data = Project.load(self:sessionPath())
    if not data then return end
    if Project.isNotebook(data) then
        self:openNotebookData(data)      -- comes back as a notebook, not a flat canvas
    else
        self:loadProjectData(data)
    end
end

function InkAwayView:saveSession()
    if self.notebook then
        self:nbSyncOut()
        Project.saveNotebook(self.notebook, self:sessionPath())
        return
    end
    if self.canvas:isEmpty() then return end
    Project.save(self.canvas, self:sessionPath())
end

function InkAwayView:scheduleAutosave()
    UIManager:unschedule(self._autosave_tick)
    if self.autosave == "periodic" then
        UIManager:scheduleIn(180, self._autosave_tick)   -- every 3 minutes
    end
end

function InkAwayView:autosaveTick()
    if self.closing then return end
    if self.dirty then self:saveSession(); self.dirty = false end
    self:scheduleAutosave()
end

function InkAwayView:free()
    if self.area_bb then self.area_bb:free(); self.area_bb = nil end
    if self.canvas_bb then self.canvas_bb:free(); self.canvas_bb = nil end
    if self.bg_bb then self.bg_bb:free(); self.bg_bb = nil end
    if self._paper_bb then self._paper_bb:free(); self._paper_bb = nil end
    if self._reveal_text_bb then self._reveal_text_bb:free(); self._reveal_text_bb = nil end
    if self._reveal_pic_bb then self._reveal_pic_bb:free(); self._reveal_pic_bb = nil end
    if self._pre_stroke_bb then self._pre_stroke_bb:free(); self._pre_stroke_bb = nil end
    self._pre_stroke_valid = false
    if self._nav_img then
        for _, ic in pairs(self._nav_img) do if ic then pcall(function() ic:free() end) end end
        self._nav_img = nil
    end
    self:freeImageCache()
    self.bg_rgba = nil
end

function InkAwayView:onShow()
    UIManager:setDirty(self, "full")
    return true
end

-- Screen size changed, from a rotation or a window resize. The canvas keeps the
-- pixel size it had when it opened, since the export size is fixed at that
-- point, so all we do here is rebuild the toolbar and viewport and refit the page.
function InkAwayView:relayout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.screen_w, self.screen_h = W, H
    self.dimen.w, self.dimen.h = W, H     -- mutate in place; GestureRanges hold it
    self:buildToolbar()
    self[1] = self.toolbar
    if self.notebook then self.nb_bar_h = self:nbBarHeight() end
    local th = self.toolbar:getSize().h
    local v = self.view
    v.area_x, v.area_y, v.area_w, v.area_h = 0, th, W, H - th - self.nb_bar_h
    self.zoom_min = InkGeom.fitZoom(v)
    v.zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, v.zoom))
    InkGeom.clampPan(v)
    -- the canvas keeps its size; only the on-screen buffer follows the screen
    if self.area_bb then self.area_bb:free() end
    self.area_bb = Blitbuffer.new(v.area_w, v.area_h, Screen.bb:getType())
    self:renderView()
end

function InkAwayView:onSetDimensions()
    self:handleScreenResize()
    UIManager:setDirty(self, "full")
end

function InkAwayView:onCloseWidget()
    self.closing = true
    if self._stylus_cb then
        pcall(function() Device.input:unregisterStylusCallback() end)
        self._stylus_cb = nil
    end
    UIManager:unschedule(self._pen_clear)
    UIManager:unschedule(self._finalize)
    UIManager:unschedule(self._autosave_tick)
    if self._sel_refresh_tick then UIManager:unschedule(self._sel_refresh_tick) end
    if self._show_zoom_fab then UIManager:unschedule(self._show_zoom_fab) end
    if self._show_bar_toggle then UIManager:unschedule(self._show_bar_toggle) end
    if self._show_nbbar_toggle then UIManager:unschedule(self._show_nbbar_toggle) end
    self:hwrCancel()   -- drop any pending handwriting recognition timer
    if self.editing_text then self:finishTextEdit(true) end   -- bake an open text box
    if self.active_image then self:finishImageEdit() end       -- bake a selected image
    self.selected, self.shape_move = nil, nil
    self:setSelectionActive(false)
    self:hideTextKeyboard()
    Export.text_raster = nil   -- drop the closure over this view
    Export.image_raster = nil
    if self.autosave ~= "off" then self:saveSession() end
    self:freeThumbs()   -- release any decoded online-image thumbnails
    -- Close any of our popups so nothing is left shown or referenced.
    for _, key in ipairs({ "_pen_dialog", "_shape_dialog", "_shape_line_dialog", "_fill_dialog", "_eraser_dialog", "_chooser_dialog", "_bg_dialog", "_goto_dialog", "_shape_menu", "_image_menu", "_img_src_dialog", "_image_browser_dialog", "_img_search_dialog", "_settings_dialog", "_page_dialog", "_save_dialog", "_text_fmt", "_text_settings" }) do
        if self[key] then UIManager:close(self[key]); self[key] = nil end
    end
    -- Release the large buffers and drop references so the GC can reclaim them.
    self:closeNotebookPDF()
    self:free()
    self.selected, self.rotating, self.shape_preview = nil, nil, nil
    if self.canvas then
        self.canvas.ops, self.canvas.undo_stack, self.canvas.redo_stack = {}, {}, {}
    end
    -- Reclaim our large buffers and ops now, so the next session starts clean
    -- rather than inheriting the heap pressure (which shows up as slowdown).
    collectgarbage("collect")
    -- Remember the orientation we were drawing in (so the next launch opens the
    -- same way up), then put the device back the way it was before Ink Away opened.
    -- The full refresh below leaves the panel clean and, where landscape uses
    -- software rotation, the reader back on its native fast path.
    if self:orientationSupported() then
        self:setSetting("inkaway_orientation", self:orientationClass())
        if self.orig_rotation ~= nil and self:currentRotation() ~= self.orig_rotation then
            pcall(function() Screen:setRotationMode(self.orig_rotation) end)
        end
    end
    -- Leave the screen clean underneath.
    UIManager:setDirty(nil, "full")
end

function InkAwayView:onIaClose()
    self:promptExit()
    return true
end

------------------------------------------------------------------------------
-- Toolbar
------------------------------------------------------------------------------

function InkAwayView:buildToolbar()
    local specs = {
        -- First tap selects the tool (so you can draw/type right away with the
        -- current settings); tapping it again, while already active, opens its
        -- options. The options use KOReader's standard ButtonDialog, which renders
        -- and takes taps identically on every device.
        { id = "pen",   label = _("Pen"),   tool = true, cb = function()
            if self.tool == "pen" then self:openPenSettings() else self:setTool("pen") end
        end },
        { id = "erase", label = _("Erase"), tool = true, cb = function()
            if self.tool == "erase" then self:openEraserSettings() else self:setTool("erase") end
        end },
        { id = "shape", label = _("Shapes"), tool = true, cb = function()
            if self.tool == "shape" then self:openShapePicker() else self:setTool("shape") end
        end },
        { id = "text",  label = _("Text"),  tool = true, cb = function()
            -- tapping Text while a box is open finishes it (and closes the keyboard);
            -- once the tool is active, a second tap opens the font & size options
            if self.editing_text then self:finishTextEdit(true)
            elseif self.tool == "text" then self:openTextSettings()
            else self:setTool("text") end
        end },
        -- quick access to placing an image, instead of digging into Settings
        { id = "image", label = _("Image"), cb = function() self:chooseImage() end },
        { id = "pan",   label = _("Pan"),   tool = true, cb = function() self:setTool("pan") end },
        { id = "undo",  label = _("Undo"),  cb = function() self:undo() end },
        { id = "redo",  label = _("Redo"),  cb = function() self:redo() end },
        { id = "menu",  label = "\u{2699}", cb = function() self:openSettings() end },   -- gear
        { id = "save",  label = _("Save"),  cb = function() self:onSave() end },
        { id = "exit",  label = _("Exit"),  cb = function() self:promptExit() end },
    }
    -- each tool id maps to an SVG in ink/icons (erase uses "eraser")
    local ICON = { pen = "pen", erase = "eraser", shape = "shape", text = "text",
        image = "image", pan = "pan",
        undo = "undo", redo = "redo", menu = "menu", save = "save", exit = "exit" }
    self:ensureUserIcons()   -- so the Buttons can render the icons by name
    local n = #specs
    local btn_w = math.floor(Screen:getWidth() / n)
    -- a compact bar: the icons carry the meaning, so the buttons are short. This is
    -- the active pill's height; the toolbar is taller by twice the button margin,
    -- so the pill floats clear of the top/bottom edges.
    local bar_h = math.max(Screen:scaleBySize(32), math.min(Screen:scaleBySize(46), math.floor(btn_w * 0.66)))
    self._btn_w, self._bar_h = btn_w, bar_h   -- for the active-tool pill in paintTo
    -- centre of the last (Exit) button, so the collapse chevron lines up under it
    self._last_btn_center = math.floor(btn_w * (n - 1) + (Screen:getWidth() - btn_w * (n - 1)) / 2)
    -- The icon sits centred in a fixed-height cell (height = bar_h below), so every
    -- tool's icon shares the same height and baseline and the active black pill is
    -- identical for all of them. Keep the icon well inside the cell so the pill has
    -- clear breathing room and never reaches the toolbar edges.
    local isz = math.max(20, math.floor(bar_h * 0.66))
    self._icon_sz = isz   -- the notebook bottom bar matches this exactly, for one consistent style
    self.tool_buttons = {}
    self._toolbar_icons = {}
    local row = {}
    for i, s in ipairs(specs) do
        local w = (i == n) and (Screen:getWidth() - btn_w * (n - 1)) or btn_w
        -- The icon belongs to the Button (via KOReader's user-icon dir), so the
        -- Button paints and repaints it itself -- including its tap feedback, which
        -- for an icon (text-less) Button just inverts and restores the region. That
        -- is why the icon no longer vanishes on press (an overdrawn overlay would).
        -- Guard every tool action: if a callback ever errors, catch it so the
        -- Button's tap feedback still un-inverts (no dead black button) and the
        -- reader sees what went wrong instead of a menu that silently won't open.
        local raw_cb = s.cb
        local guarded_cb = function()
            local ok, err = xpcall(raw_cb, debug.traceback)
            if not ok then
                logger.warn("Ink Away toolbar '" .. s.id .. "' failed: " .. tostring(err))
                UIManager:show(InfoMessage:new{
                    text = _("Something went wrong opening that tool. Please report this.") ..
                        "\n\n" .. tostring(err):match("[^\n]*") })
            end
        end
        local b = Button:new{
            icon = "inkaway." .. ICON[s.id],
            icon_width = isz,
            icon_height = isz,
            callback = guarded_cb,
            width = w,
            height = bar_h,
            -- Borderless icons on a clean bar: no per-button boxes. The active tool
            -- is shown by a filled rounded pill = that button's own grey background
            -- (set in updateToolbarActive), inset by the margin so it reads as a
            -- pill rather than a full-cell block.
            bordersize = 0,
            radius = 0,
            background = nil,
            margin = Screen:scaleBySize(4),
            padding = 0,
            show_parent = self,
        }
        -- Point the icon at the plugin's own SVG by absolute path, bypassing
        -- IconWidget's name lookup. That lookup builds its search-directory list
        -- and a name->path cache once, when the iconwidget module is first loaded
        -- during KOReader startup, and it only searches the user-icon dir when
        -- that dir already existed at that moment. On a first run our
        -- ensureUserIcons() creates that dir only later (when the canvas opens),
        -- so "inkaway.<id>" resolves to the not-found triangle for the rest of the
        -- session -- which is exactly why some users saw triangles until they
        -- restarted (or reinstalled). A file-based IconWidget takes the file
        -- directly and always renders, on every device and on the very first run.
        local icon_path = self:pluginDir() .. "ink/icons/" .. ICON[s.id] .. ".svg"
        local ok_icon, file_icon = pcall(function()
            return IconWidget:new{ file = icon_path, width = isz, height = isz }
        end)
        if ok_icon and file_icon and b.label_container then
            b.label_widget = file_icon
            b.label_container[1] = file_icon
        end
        -- Make the button transparent: KOReader defaults a border-less button to a
        -- white fill, which would cover the active pill we paint behind it. With no
        -- fill, the white bar shows through and the active pill (drawn in paintTo)
        -- reads correctly under the icon.
        if b.frame then b.frame.background = nil end
        if s.tool then self.tool_buttons[s.id] = { button = b } end
        self._toolbar_icons[i] = { button = b, id = s.id, tool = s.tool == true }
        row[i] = b
    end
    self.toolbar = FrameContainer:new{
        background = nil,   -- transparent bar; the screen's white shows through
        bordersize = 0,
        padding = 0,
        margin = 0,
        HorizontalGroup:new(row),
    }
    -- the real bar height includes each button's margin, so the hairline and the
    -- drawing area sit at the true bottom edge (not one margin too high)
    self._bar_h = self.toolbar:getSize().h
    self:updateToolbarActive()   -- give the current tool its pill
end

-- Mark the active tool: remember its button index (so paintTo can draw an inset
-- black pill behind it) and invert its icon to white. Inverting works because the
-- icon renders on an opaque white ground, so invert flips it to white-on-black,
-- merging seamlessly into the black pill. Inactive tools stay transparent (their
-- icon reads black on the white bar).
function InkAwayView:updateToolbarActive()
    if not self._toolbar_icons then return end
    local active = (self.tool == "fill") and "shape" or self.tool
    self._active_btn_idx = nil
    for i, e in ipairs(self._toolbar_icons) do
        if e.tool and e.button then
            local on = (e.id == active)
            if on then self._active_btn_idx = i end
            if e.button.label_widget then e.button.label_widget.invert = on end
        end
    end
end

-- Paint the active tool's pill: a black rounded rect inset within its cell so it
-- floats clear of every toolbar edge. Called from paintTo BEFORE the (transparent)
-- toolbar paints, so the icon lands on top and its invert reads white-on-black.
function InkAwayView:drawActiveToolPill(bb, ox, oy)
    if self._toolbar_hidden or not self._active_btn_idx or not self._btn_w or not self._bar_h then return end
    local m = Screen:scaleBySize(7)
    local cx = ox + self._btn_w * (self._active_btn_idx - 1)
    bb:paintRoundedRect(cx + m, oy + m, self._btn_w - 2 * m, self._bar_h - 2 * m,
        Blitbuffer.COLOR_BLACK, Screen:scaleBySize(9))
end

-- The active tool is shown by a short underline drawn in paintTo, so a tool
-- change only needs the toolbar area repainted.
function InkAwayView:refreshToolLabels()
    self:updateToolbarActive()   -- move the pill to the current tool
    UIManager:setDirty(self, "ui", self.toolbar and self.toolbar.dimen or nil)
end

-- Absolute path to the plugin's own directory (this file lives in ink/).
function InkAwayView:pluginDir()
    if self._plugin_dir then return self._plugin_dir end
    local src = debug.getinfo(1, "S").source
    self._plugin_dir = (src:match("^@(.*/)ink/[^/]*$")) or "./"
    return self._plugin_dir
end

-- Copy the plugin's tool icons into KOReader's user-icon dir (once, refreshed
-- when the plugin ships newer ones), so a toolbar Button can render them by the
-- name "inkaway.<id>" -- IconWidget searches that dir first. Owning the icon in
-- the Button (rather than overdrawing it) is what keeps it from vanishing on tap.
function InkAwayView:ensureUserIcons()
    -- Sync once per session: the plugin's files never change while it runs, so the
    -- mtime-compare (46 stat calls) is pure latency on every later toolbar/menu open.
    if self._icons_synced then return true end
    local ok = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local dst_dir = DataStorage:getDataDir() .. "/icons"
        if lfs.attributes(dst_dir, "mode") ~= "directory" then lfs.mkdir(dst_dir) end
        local src_dir = self:pluginDir() .. "ink/icons/"
        for _, name in ipairs({ "pen", "eraser", "shape", "text", "image", "pan",
                                "undo", "redo", "menu", "save", "exit",
                                "sh_line", "sh_rect", "sh_ellipse", "sh_triangle",
                                "sh_curve", "sh_arrow", "sh_darrow", "sh_carrow", "sh_cdarrow",
                                "bucket", "lasso", "caret" }) do
            local src = src_dir .. name .. ".svg"
            local dst = dst_dir .. "/inkaway." .. name .. ".svg"
            local sa, da = lfs.attributes(src), lfs.attributes(dst)
            if sa and (not da or (sa.modification or 0) > (da.modification or 0)) then
                local fin = io.open(src, "rb")
                if fin then
                    local data = fin:read("*a"); fin:close()
                    local fout = io.open(dst, "wb")
                    if fout then fout:write(data); fout:close() end
                end
            end
        end
    end)
    if ok then self._icons_synced = true end
    return ok
end

-- A hairline under the toolbar, painted on top after the icons, separating the
-- bar from the canvas.
function InkAwayView:drawToolbarIcons(bb)
    if not self._bar_h then return end
    local y = (self.dimen and self.dimen.y or 0) + self._bar_h - 1
    bb:paintRect(0, y, self.screen_w, 1, HAIRLINE)
end

function InkAwayView:setTool(tool)
    if self.tool == tool then return end
    self:flushPending()        -- commit any stroke still in progress first
    self:flushShape()          -- and place any finished-but-pending shape/curve
    if self._hwr_ops then      -- recognise any pending handwriting before leaving the pen
        if self._hwr_cb then UIManager:unschedule(self._hwr_cb) end
        self:hwrRecognizePending()
    end
    if self.editing_text then self:finishTextEdit(true) end   -- bake any open text box
    if self.active_image then self:finishImageEdit() end       -- settle a selected image
    if self.selected then self:deselectShape() end             -- drop a picked shape
    if self.selection or self.lassoing then self:clearSelection() end
    self.pan_last = nil
    self.tool = tool
    self:refreshToolLabels()
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
end

-- Is the pen currently set to this rgb?
local function sameColor(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end

-- One row of colour swatches. Each is a coloured button; the selected one gets
-- a thick border so it reads on any shade (a checkmark would vanish on a dark
-- swatch). `current` is the rgb to mark; `onpick(rgb)` is called on a tap.
function InkAwayView:swatchRowFor(entries, current, onpick)
    local sw = math.floor(math.min(self.screen_w, self.screen_h) * 0.9 / 6)
    local row = {}
    for _, e in ipairs(entries) do
        local selected = sameColor(current, e.rgb)
        row[#row + 1] = {
            text = "",
            background = Blitbuffer.ColorRGB32(e.rgb[1], e.rgb[2], e.rgb[3], 0xFF),
            width = sw,
            bordersize = selected and Size.border.thick or Size.border.default,
            radius = 0,
            callback = function() onpick(e.rgb) end,
        }
    end
    return row
end

-- The reader's saved custom colours (a list of {r,g,b}), persisted so they last.
function InkAwayView:getCustomColors()
    local list = self:getSetting("inkaway_custom_colors")
    return type(list) == "table" and list or {}
end

function InkAwayView:addCustomColor(rgb)
    local list = self:getCustomColors()
    for _, c in ipairs(list) do
        if c[1] == rgb[1] and c[2] == rgb[2] and c[3] == rgb[3] then return end  -- already saved
    end
    list[#list + 1] = { rgb[1], rgb[2], rgb[3] }
    while #list > 18 do table.remove(list, 1) end   -- 3 rows of 6, oldest drops out
    self:setSetting("inkaway_custom_colors", list)
end

function InkAwayView:removeCustomColor(rgb)
    local list = self:getCustomColors()
    for i, c in ipairs(list) do
        if c[1] == rgb[1] and c[2] == rgb[2] and c[3] == rgb[3] then table.remove(list, i); break end
    end
    self:setSetting("inkaway_custom_colors", list)
end

-- Open the colour wheel to pick (and optionally save) an exact colour.
function InkAwayView:openColorPicker(target)
    local ok, ColorPicker = pcall(require, "ink/colorpicker")
    if not ok then return end
    local isFill = target == "fill"
    local function apply(rgb)
        if isFill then self.fill_color = { rgb[1], rgb[2], rgb[3] }
        else self.pen_color = { rgb[1], rgb[2], rgb[3] } end
    end
    local function reopen()
        if isFill then self:openFillSettings() else self:openPenSettings() end
    end
    UIManager:show(ColorPicker:new{
        color = isFill and self.fill_color or self.pen_color,
        on_pick = function(rgb) apply(rgb); reopen() end,
        on_save = function(rgb) apply(rgb); self:addCustomColor(rgb); reopen() end,
    })
end

-- Pen settings sheet (same rounded-sheet style as the Shapes menu): size and
-- opacity sliders, brush-style wave tiles with a create (+) tile, colour swatch
-- rows, and the stroke aids. Rebuilt and reshown whenever something changes.
local PEN_CUSTOM_CAP = 12   -- how many made brushes a reader may keep
function InkAwayView:openPenSettings()
    if self._pen_dialog then self._pen_dialog:rebuild(); return end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Font = require("ui/font")
    self:ensureUserIcons()

    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local tileW = math.floor((target - 3 * gap) / 4)
    local content_w = 4 * tileW + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local pxfmt = function(v) return v .. _(" px") end
    local function closeSelf() if self._pen_dialog then UIManager:close(self._pen_dialog); self._pen_dialog = nil end end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end

        add(self:sheetTitle(_("Pen"), content_w, _("Done"), closeSelf))
        add(vspan(12))
        add(SliderRow:new{ label = _("Size"), value = self.pen_width, min = 1, max = 60,
            width = content_w, parent = menu, format = pxfmt,
            on_set = function(v) self.pen_width = math.max(1, v) end })
        add(vspan(10))
        add(SliderRow:new{ label = _("Opacity"), value = math.floor(self.pen_alpha / 255 * 100 + 0.5),
            width = content_w, parent = menu,
            on_set = function(v) self.pen_alpha = math.max(1, math.floor(v / 100 * 255 + 0.5)) end })
        add(vspan(12))

        -- brush styles: wave tiles (four per row, wrapping), then a create (+) tile
        local styleMenu = Brushes.menu(function(k) return self:getSetting(k) end)
        local ncustom = 0
        for _, s in ipairs(styleMenu) do if s.custom then ncustom = ncustom + 1 end end
        local per = 4
        local swtile = math.floor((content_w - (per - 1) * gap) / per)
        local wave_h = Screen:scaleBySize(46)
        local tiles = {}
        for _, s in ipairs(styleMenu) do
            local sel = (self.pen_style == s.key)
            tiles[#tiles + 1] = self:brushWaveTile(s.key, swtile, wave_h, sel, function()
                self.pen_style = s.key; self:setSetting("inkaway_pen_style", s.key); self:openPenSettings()
            end, s.custom and function() self:confirmDeleteBrush(s.key, s.label) end or nil)
        end
        if ncustom < PEN_CUSTOM_CAP then
            tiles[#tiles + 1] = Button:new{ text = "+", text_font_size = 26, text_font_bold = true,
                width = swtile, height = wave_h, bordersize = 0, radius = Screen:scaleBySize(12),
                background = TILE_BG, margin = 0, padding = 0, show_parent = self,
                callback = function() closeSelf(); self:openBrushMaker() end }
        end
        for i = 1, #tiles, per do
            local row = HorizontalGroup:new{ align = "center" }
            for j = i, math.min(i + per - 1, #tiles) do
                if j > i then table.insert(row, HorizontalSpan:new{ width = gap }) end
                table.insert(row, tiles[j])
            end
            add(row)
            if i + per <= #tiles then add(vspan(gap)) end
        end
        add(vspan(12))

        -- The stroke aids (toggles + stabilizer) are the fixed tail of the sheet and
        -- must never be pushed off-screen by the colour rows, so build them first,
        -- measure them, and cap how many custom-colour rows we render to whatever
        -- vertical space is left (see the colour section below).
        local TextBoxWidget = require("ui/widget/textboxwidget")
        local HINT = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF)
        local function toggle(label, on, cb)
            return ToggleRow:new{ label = label, is_on = on, compact = true, parent = menu, callback = cb }
        end
        local tail = VerticalGroup:new{ align = "left" }
        local assistRow = HorizontalGroup:new{ align = "center",
            toggle(_("Shape assist"), self.shape_assist, function(on)
                self.shape_assist = on; self:setSetting("inkaway_shape_assist", on)
                -- release the pre-stroke snapshot when assist is off; it is only
                -- ever used by beautify, and re-created on the next stroke if needed
                if not on and self._pre_stroke_bb then
                    self._pre_stroke_bb:free(); self._pre_stroke_bb = nil
                    self._pre_stroke_valid = false
                end end),
        }
        do
            local pr = toggle(_("Palm rejection"), self.palm_reject, function(on)
                self.palm_reject = on; self:setSetting("inkaway_palm_reject", on); self:applyPalmReject()
                if on and not self:penCapable() then
                    UIManager:show(InfoMessage:new{ text = _(
                        "Palm rejection needs KOReader 2026.07 or newer (that release added the pen input support). Please update KOReader and it will start working. On a reader without a pen it does nothing.") })
                end
            end)
            local a1w = assistRow[1].width
            local slack = math.max(Screen:scaleBySize(16), content_w - a1w - pr.width)
            table.insert(assistRow, HorizontalSpan:new{ width = slack })
            table.insert(assistRow, pr)
        end
        table.insert(tail, assistRow)
        table.insert(tail, vspan(12))
        table.insert(tail, SliderRow:new{ label = _("Stabilizer"), value = self.stabilizer, min = 0, max = 100,
            width = content_w, parent = menu, format = function(v) return tostring(v) end,
            on_set = function(v) self.stabilizer = v; self:setSetting("inkaway_stabilizer", v) end })
        table.insert(tail, vspan(4))
        table.insert(tail, TextBoxWidget:new{
            text = _("Smooths shaky lines. Higher values steady the stroke but trail your finger slightly."),
            face = Font:getFace("cfont", 13), fgcolor = HINT, width = content_w })
        -- Handwriting to text (beta) is hidden from the pen menu for now, while the
        -- feature is still being worked on. All of its code is left in place (the
        -- hwr_enabled setting, hwrCapture/hwrRecognizePending, ink/hwr.lua, and the
        -- finalizeStroke hook); flip this guard back to `true` to show the toggle
        -- again. hwr_enabled defaults off, so with the toggle hidden it stays dormant.
        if false then
            table.insert(tail, vspan(10))
            table.insert(tail, ToggleRow:new{ label = _("Handwriting to text (beta)"), is_on = self.hwr_enabled,
                width = content_w, parent = menu, callback = function(on)
                    self.hwr_enabled = on; self:setSetting("inkaway_hwr", on)
                    if not on then self:hwrCancel() end
                end })
            table.insert(tail, vspan(4))
            table.insert(tail, TextBoxWidget:new{
                text = _("Print letters with the pen, then pause -- they turn into text in your current text style. Offline; clear, separated capitals and digits work best."),
                face = Font:getFace("cfont", 13), fgcolor = HINT, width = content_w })
        end

        -- colour swatches: shades, then (colour screens) colours + saved customs,
        -- and always the RGB picker as a "+" tile. Rows are centred so a short row
        -- (the 5 shades) stays symmetrical instead of hugging the left.
        local CenterContainer = require("ui/widget/container/centercontainer")
        local BLACK = Blitbuffer.COLOR_BLACK
        -- Swatches fill the width (six per row), so grey and colour tiles are all the
        -- same size with no empty margins. Their height is capped on big high-DPI
        -- colour screens so two colour rows don't overflow the sheet (they become
        -- wide rounded tiles rather than large squares).
        local sw = math.floor((content_w - 5 * gap) / 6)
        local swh = math.min(sw, Screen:scaleBySize(58))
        local function swatch(rgb, custom)
            return self:swatchTile(rgb, sameColor(self.pen_color, rgb), sw,
                function() self.pen_color = { rgb[1], rgb[2], rgb[3] }; self:openPenSettings() end,
                custom and function() self:removeCustomColor(rgb); self:openPenSettings() end or nil, swh)
        end
        local function pickerTile()
            local inner = sw - Screen:scaleBySize(8)
            local inner_h = swh - Screen:scaleBySize(8)
            local b = Button:new{ text = "+", text_font_size = 24, text_font_bold = true,
                width = inner, height = inner_h, background = TILE_BG,
                radius = Screen:scaleBySize(11), bordersize = 0, margin = 0, padding = 0,
                show_parent = self, callback = function() closeSelf(); self:openColorPicker() end }
            return FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = BLACK,
                radius = Screen:scaleBySize(14), padding = Screen:scaleBySize(3), margin = 0, b }
        end
        local function centeredRow(list)
            local hg = HorizontalGroup:new{ align = "center" }
            for i, t in ipairs(list) do
                if i > 1 then table.insert(hg, HorizontalSpan:new{ width = gap }) end
                table.insert(hg, t)
            end
            return CenterContainer:new{ dimen = GeomUI:new{ w = content_w, h = hg:getSize().h }, hg }
        end

        -- Build the colour rows as measurable widgets so we can cap custom rows by
        -- their real rendered height (estimates were off by a row on high-DPI
        -- colour screens), keeping the toggles + stabilizer always on screen.
        local rowWidgets = {}
        local shadeTiles = {}
        for _, e in ipairs(SHADES) do shadeTiles[#shadeTiles + 1] = swatch(e.rgb) end
        rowWidgets[#rowWidgets + 1] = centeredRow(shadeTiles)
        if self:colorScreen() then
            -- Colours row: five preset colours plus the "+" RGB picker, so with no
            -- saved customs the colour section is one clean row of six.
            local colorTiles = {}
            for i = 1, 5 do colorTiles[#colorTiles + 1] = swatch(COLORS[i].rgb) end
            colorTiles[#colorTiles + 1] = pickerTile()
            rowWidgets[#rowWidgets + 1] = centeredRow(colorTiles)

            -- Saved custom colours go on additional rows below, but only as many as
            -- fit: measure everything and cap by the real remaining height.
            local head_h = content:getSize().h   -- head = title..brushes
            content._size = nil                  -- invalidate (VerticalGroup caches offsets)
            local fixed_h = head_h + tail:getSize().h + Screen:scaleBySize(16)
            for _, w in ipairs(rowWidgets) do fixed_h = fixed_h + w:getSize().h + gap end
            local per_row = rowWidgets[1]:getSize().h + gap
            local budget = Screen:getHeight() - self:sheetTopY() - Screen:scaleBySize(4)
                - Screen:scaleBySize(8) - 2 * Screen:scaleBySize(18) - 2 * Size.border.window
            local ncustrows = math.max(0, math.floor((budget - fixed_h) / per_row))
            local customs = self:getCustomColors()
            local shown = math.min(#customs, ncustrows * 6)
            for i = 1, shown, 6 do
                local chunk = {}
                for j = i, math.min(i + 5, shown) do chunk[#chunk + 1] = swatch(customs[j], true) end
                rowWidgets[#rowWidgets + 1] = centeredRow(chunk)
            end
        end
        for i, w in ipairs(rowWidgets) do
            if i > 1 then add(vspan(gap)) end
            add(w)
        end
        add(vspan(16))
        for _, w in ipairs(tail) do add(w) end

        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end

    self._pen_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._pen_dialog = nil end }
    UIManager:show(self._pen_dialog)
end

-- Open the brush maker. A saved brush is registered, made the current pen, and
-- appears in the pen menu from then on (it is kept in KOReader's settings, so it
-- survives restarts and plugin updates).
function InkAwayView:openBrushMaker()
    local ok, BrushMaker = pcall(require, "ink/brushmaker")
    if not ok then return end
    local maker = BrushMaker:new{
        params = Brushes.defaults(),
        on_save = function(name, params)
            local key = Brushes.save(
                function(k) return self:getSetting(k) end,
                function(k, val) self:setSetting(k, val) end,
                name, params)
            self.pen_style = key
            self:setSetting("inkaway_pen_style", key)
            self:openPenSettings()
        end,
    }
    UIManager:show(maker)
end

function InkAwayView:confirmDeleteBrush(key, label)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = string.format(_("Delete the brush \"%s\"?"), label),
        ok_text = _("Delete"),
        ok_callback = function()
            local name = key:gsub("^user:", "")
            Brushes.remove(function(k) return self:getSetting(k) end,
                           function(k, v) self:setSetting(k, v) end, name)
            if self.pen_style == key then
                self.pen_style = "solid"
                self:setSetting("inkaway_pen_style", "solid")
            end
            self:openPenSettings()
        end,
    })
end

-- Eraser menu: size, and whether the eraser also removes the background image.
-- Eraser sheet (shapes-menu style): a size slider and an "erase pictures" toggle.
function InkAwayView:openEraserSettings()
    if self._eraser_dialog then self._eraser_dialog:rebuild(); return end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    self:ensureUserIcons()
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._eraser_dialog then UIManager:close(self._eraser_dialog); self._eraser_dialog = nil end
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        table.insert(content, self:sheetTitle(_("Eraser"), content_w, _("Done"), closeSelf))
        table.insert(content, vspan(16))
        table.insert(content, SliderRow:new{ label = _("Size"), value = self.eraser_width, min = 4, max = 120,
            width = content_w, parent = menu, format = function(v) return v .. _(" px") end,
            on_set = function(v) self.eraser_width = math.max(1, v) end })
        table.insert(content, vspan(14))
        table.insert(content, ToggleRow:new{ label = _("Erase pictures"), is_on = self.erase_bg,
            width = content_w, parent = menu,
            callback = function(on) self.erase_bg = on; self:setSetting("inkaway_erase_bg", on) end })
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._eraser_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._eraser_dialog = nil end }
    UIManager:show(self._eraser_dialog)
end

-- Arrowhead size, in canvas pixels (used by the arrow shapes).
function InkAwayView:openArrowSize()
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = _("Arrowhead size"),
        info_text = _("How big the arrowheads are, in canvas pixels."),
        value = self.arrow_head, value_min = 6, value_max = 120, value_step = 2, value_hold_step = 10,
        unit = _("px"),
        callback = function(spin)
            self.arrow_head = math.max(4, math.floor(spin.value))
            self:setSetting("inkaway_arrow_head", self.arrow_head)
            self:openShapeLineMenu()
        end,
    })
end

-- Shape chooser. Each entry shows the actual shape glyph next to its name; the
-- current one gets a checkmark. Shapes are drawn with the pen's size, opacity
-- and colour.
-- A lightweight modal composed of stock KOReader widgets, mirroring ButtonDialog's
-- machinery (CenterContainer > MovableContainer > FrameContainer) so it opens
-- reliably on device. `build(menu)` returns the FrameContainer (built with a
-- reference to the menu, so child CheckButtons can use it as their repaint
-- parent). A tap outside the panel, or Back, closes it.
--
-- The critical detail: UIManager:show(widget) with no refreshtype only marks the
-- widget dirty -- it paints into the buffer but schedules NO e-ink refresh, so
-- nothing reaches the panel and the menu looks like it "never opened". onShow must
-- schedule the refresh itself (as every stock modal does), with the region read
-- from a closure so movable.dimen is available (it is nil until first paintTo).
-- NOTE: deliberately NOT covers_fullscreen. The canvas below must keep painting
-- under the sheet (as ButtonDialog does): the sheet is smaller than the screen
-- and the child submenu is smaller than the parent, so covering the screen would
-- make _repaint skip the canvas and leave stale sheet pixels around a closing or
-- reopening smaller sheet (visible as ghost panels until you draw or refresh).
IconMenu = InputContainer:extend{
    modal = true,              -- stay on top; don't let un-consumed gestures fall
                               -- through and draw on the canvas underneath
    build = nil,               -- function(menu) -> FrameContainer
    on_close = nil,
    top_y = nil,               -- if set, pin the sheet's top here (below the toolbar)
                               -- instead of centring it vertically
    bottom_y = nil,            -- if set, pin the sheet's BOTTOM here (e.g. touching
                               -- the notebook bottom bar); takes precedence over top_y
}
function IconMenu:init()
    local MovableContainer = require("ui/widget/container/movablecontainer")
    if self.build then self.frame = self:build() end
    if Device:isTouchDevice() then
        self.ges_events = { TapClose = { GestureRange:new{ ges = "tap",
            range = GeomUI:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } } }
    end
    if Device:hasKeys() then
        self.key_events = { CloseMenu = { { Device.input.group.Back } } }
    end
    -- MovableContainer gives the content a reliable .dimen (set at paint time),
    -- and swallows drag gestures that start on the frame. We position it ourselves
    -- in paintTo (see below), so it is the sole child.
    self.movable = MovableContainer:new{ self.frame }
    self[1] = self.movable
end
-- The sheet opens OVER the drawing canvas, which holds dark ink and grid lines.
-- It MUST be shown with a flashing refresh ("flashui"): only a flash fully clears
-- the region to the opaque white sheet. A non-flashing "ui" morphs the dark pixels
-- in (a slow fade), and a 1-bit "fast"/A2 refresh does not clear at all, so the
-- grid and ink ghost straight through the sheet (it looks translucent) and every
-- later refresh has to fight that ghost. The flash is a deliberate, one-time cost
-- for a crisp, opaque sheet -- do not "optimise" it to fast/ui.
function IconMenu:onShow()
    UIManager:setDirty(self, function() return "flashui", self.movable.dimen end)
end
-- On close, UIManager repaints the uncovered canvas underneath, so a plain "ui"
-- brings it back with no black blink. (A "flashui" here would be a black flash
-- where the menu had been.) Free the content subtree (some sheets build
-- blitbuffers, e.g. brush previews).
function IconMenu:onCloseWidget()
    local region = self.movable and self.movable.dimen
    UIManager:setDirty(nil, function() return "ui", region end)
    if self.movable and self.movable.free then self.movable:free() end
end
-- Rebuild the sheet's contents in place (used when a control inside it changes
-- state, e.g. picking a brush or colour), instead of closing and reopening the
-- whole dialog. When the sheet keeps its footprint -- the common case, a
-- selection highlight moving -- refresh only that region with a non-flashing "ui"
-- (the sheet is already an opaque white rectangle on screen, so there is nothing
-- dark to clear): the same partial, no-flash update the sliders and toggles do.
-- Only when the footprint changes (a row added/removed) fall back to repainting
-- the exposed canvas and flashing the union.
function IconMenu:rebuild()
    if not (self.movable and self.build) then return end
    local old = self.movable.dimen and self.movable.dimen:copy()
    if self.movable.free then self.movable:free() end
    local MovableContainer = require("ui/widget/container/movablecontainer")
    self.frame = self:build()
    self.movable = MovableContainer:new{ self.frame }
    self[1] = self.movable
    UIManager:widgetRepaint(self, 0, 0)      -- paint the new contents; sets movable.dimen
    local new = self.movable.dimen
    if old and new and old.x == new.x and old.y == new.y
            and old.w == new.w and old.h == new.h then
        -- mark THIS menu dirty (not nil): if the same tap also repaints the view
        -- underneath (e.g. a shape pick refreshes the toolbar pill), the menu must
        -- be repainted on top of it, or the canvas would clobber the sheet.
        UIManager:setDirty(self, function() return "ui", new end)
    else
        local region = (old and new) and old:combine(new) or new
        UIManager:setDirty("all", function() return "flashui", region end)
    end
end
-- Paint the sheet horizontally centred and, when top_y is set, pinned just below
-- the toolbar (so tapping a toolbar tool drops its options right under the hand),
-- clamped to stay on screen. MovableContainer sets its own .dimen from where we
-- paint it, which we adopt for hit-testing and refresh regions.
function IconMenu:paintTo(bb, x, y)
    local sz = self.movable:getSize()
    local pad = Screen:scaleBySize(4)
    local px = math.floor((Screen:getWidth() - sz.w) / 2)
    local py
    if self.bottom_y then
        -- pin the sheet's BOTTOM here (e.g. touching the notebook bottom bar's top)
        py = math.max(pad, math.min(self.bottom_y - sz.h, Screen:getHeight() - sz.h - pad))
    elseif self.top_y then
        py = math.max(pad, math.min(self.top_y, Screen:getHeight() - sz.h - pad))
    else
        py = math.floor((Screen:getHeight() - sz.h) / 2)
    end
    self.movable:paintTo(bb, px, py)
    self.dimen = self.movable.dimen
end
function IconMenu:onTapClose(_, ges)
    if ges and ges.pos and self.movable.dimen
            and ges.pos:notIntersectWith(self.movable.dimen) then
        self:onCloseMenu()
    end
    return true
end
function IconMenu:onCloseMenu()
    UIManager:close(self)
    if self.on_close then self.on_close() end
    return true
end

-- A classic sliding on/off toggle row: a label on the left and a pill switch on
-- the right (grey track + white knob at left when off; black track + knob at
-- right when on). The whole row is one tap target and flips in place; `parent`
-- is the shown widget used as the repaint target.
ToggleRow = InputContainer:extend{
    label = "", is_on = false, width = nil, callback = nil, parent = nil,
}
TRACK_OFF = Blitbuffer.ColorRGB32(0xCF, 0xCF, 0xCF, 0xFF)
KNOB_EDGE = Blitbuffer.ColorRGB32(0x99, 0x99, 0x99, 0xFF)
function ToggleRow:init()
    self.sw_h = Screen:scaleBySize(30)
    self.sw_w = Screen:scaleBySize(54)
    self:_build()
    if Device:isTouchDevice() then
        self.ges_events = { Tap = { GestureRange:new{ ges = "tap",
            range = function() return self.dimen end } } }
    end
end
function ToggleRow:_switch()
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local w, h = self.sw_w, self.sw_h
    local track = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0,
        radius = math.floor(h / 2), background = self.is_on and Blitbuffer.COLOR_BLACK or TRACK_OFF,
        WidgetContainer:new{ dimen = GeomUI:new{ w = w, h = h } } }
    local knob = h - Screen:scaleBySize(6)
    local inset = Screen:scaleBySize(3)
    local knobFrame = FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = KNOB_EDGE,
        padding = 0, margin = 0, radius = math.floor(knob / 2), background = Blitbuffer.COLOR_WHITE,
        WidgetContainer:new{ dimen = GeomUI:new{ w = knob - Screen:scaleBySize(2), h = knob - Screen:scaleBySize(2) } } }
    knobFrame.overlap_offset = { self.is_on and (w - knob - inset) or inset, math.floor((h - knob) / 2) }
    local OverlapGroup = require("ui/widget/overlapgroup")
    return OverlapGroup:new{ dimen = { w = w, h = h }, allow_mirroring = false, track, knobFrame }
end
function ToggleRow:_build()
    local TextWidget = require("ui/widget/textwidget")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Font = require("ui/font")
    local label = TextWidget:new{ text = self.label, face = Font:getFace("cfont", 18) }
    local sw = self:_switch()
    local span
    if self.compact then
        -- toggle sits just after the label; the row is only as wide as its content
        span = Screen:scaleBySize(12)
        self.width = label:getSize().w + span + self.sw_w
    else
        span = math.max(Screen:scaleBySize(8), self.width - label:getSize().w - self.sw_w)
    end
    self[1] = HorizontalGroup:new{ align = "center",
        label, HorizontalSpan:new{ width = span }, sw }
    local sz = self[1]:getSize()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.width, h = sz.h }
end
function ToggleRow:onTap()
    self.is_on = not self.is_on
    self:_build()
    if self.callback then self.callback(self.is_on) end
    UIManager:setDirty(self.parent or self, "ui", self.dimen)
    return true
end
function ToggleRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

-- A horizontal slider row (0..100): a label on the left, a draggable track in
-- the middle, and the value on the right. Tap or drag the track to set it; the
-- value flips in place. `parent` is the shown widget used as the repaint target.
SliderRow = InputContainer:extend{
    label = "", value = 0, width = nil, on_set = nil, parent = nil,
    min = 0, max = 100, step = 1, format = nil,   -- format(v) -> value text (default "N%")
}
function SliderRow:_fmt(v) return self.format and self.format(v) or string.format("%d%%", v) end
function SliderRow:init()
    self.knob = Screen:scaleBySize(26)
    self.track_h = Screen:scaleBySize(8)
    self:_build()
    if Device:isTouchDevice() then
        local range = function() return self.dimen end
        self.ges_events = {
            SlTap = { GestureRange:new{ ges = "tap", range = range } },
            SlPan = { GestureRange:new{ ges = "pan", range = range } },
            SlPanRelease = { GestureRange:new{ ges = "pan_release", range = range } },
            SlHold = { GestureRange:new{ ges = "hold", range = range } },
            SlHoldPan = { GestureRange:new{ ges = "hold_pan", range = range } },
        }
    end
end
function SliderRow:_build()
    local FrameContainer = require("ui/widget/container/framecontainer")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(14)
    local labelw = TextWidget:new{ text = self.label, face = Font:getFace("cfont", 18) }
    local valw = TextWidget:new{ text = self:_fmt(self.value),
        face = Font:getFace("cfont", 16), bold = true }
    -- reserve a fixed width for the value (measured at the max) so the track
    -- doesn't jump as digits change
    local wmax = TextWidget:new{ text = self:_fmt(self.max), face = Font:getFace("cfont", 16), bold = true }
    local val_w = math.max(wmax:getSize().w, Screen:scaleBySize(40)); wmax:free()
    local track_w = self.width - labelw:getSize().w - val_w - 2 * gap
    self._track_w = track_w
    self._track_dx = labelw:getSize().w + gap
    local frac = math.max(0, math.min(1, (self.value - self.min) / (self.max - self.min)))
    local th, kn = self.track_h, self.knob
    local ty = math.floor((kn - th) / 2)
    local fillW = math.max(th, math.floor(track_w * frac))
    local track = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, radius = math.floor(th / 2),
        background = TRACK_OFF, WidgetContainer:new{ dimen = GeomUI:new{ w = track_w, h = th } } }
    track.overlap_offset = { 0, ty }
    local fill = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, radius = math.floor(th / 2),
        background = Blitbuffer.COLOR_BLACK, WidgetContainer:new{ dimen = GeomUI:new{ w = fillW, h = th } } }
    fill.overlap_offset = { 0, ty }
    local knob = FrameContainer:new{ bordersize = Screen:scaleBySize(1), color = KNOB_EDGE,
        padding = 0, margin = 0, radius = math.floor(kn / 2), background = Blitbuffer.COLOR_WHITE,
        WidgetContainer:new{ dimen = GeomUI:new{ w = kn - Screen:scaleBySize(2), h = kn - Screen:scaleBySize(2) } } }
    local knobX = math.max(0, math.min(track_w - kn, math.floor(track_w * frac) - math.floor(kn / 2)))
    knob.overlap_offset = { knobX, 0 }
    local trackGroup = OverlapGroup:new{ dimen = { w = track_w, h = kn }, allow_mirroring = false,
        track, fill, knob }
    self[1] = HorizontalGroup:new{ align = "center",
        labelw, HorizontalSpan:new{ width = gap }, trackGroup, HorizontalSpan:new{ width = gap }, valw }
    -- references so _apply can update the moving parts in place, without rebuilding
    -- the whole row (and re-measuring text) on every drag tick
    self._fill_wc, self._knob, self._valw = fill[1], knob, valw
    local sz = self[1]:getSize()
    self.dimen = GeomUI:new{ x = 0, y = 0, w = self.width, h = sz.h }
end
-- Update only the fill width, knob position and value text for the current value,
-- in place -- no widget/text-shaping churn per drag tick.
function SliderRow:_apply()
    local track_w, th, kn = self._track_w, self.track_h, self.knob
    local frac = math.max(0, math.min(1, (self.value - self.min) / (self.max - self.min)))
    if self._fill_wc then self._fill_wc.dimen.w = math.max(th, math.floor(track_w * frac)) end
    if self._knob then
        self._knob.overlap_offset[1] =
            math.max(0, math.min(track_w - kn, math.floor(track_w * frac) - math.floor(kn / 2)))
    end
    if self._valw then self._valw:setText(self:_fmt(self.value)) end
end
function SliderRow:_setFromX(x, mode)
    if not (self.dimen and self._track_w and self._track_w > 0) then return end
    local rel = x - (self.dimen.x + self._track_dx)
    local frac = math.max(0, math.min(1, rel / self._track_w))
    local v = self.min + frac * (self.max - self.min)
    v = self.min + math.floor((v - self.min) / self.step + 0.5) * self.step
    v = math.max(self.min, math.min(self.max, v))
    if v ~= self.value then
        self.value = v
        self:_apply()   -- update the moving parts in place; no rebuild, dimen unchanged
        if self.on_set then self.on_set(v) end
        -- Refresh only the track-to-value band, not the whole row, and use the fast
        -- (A2, monochrome) waveform WHILE dragging so the black fill, white knob and
        -- value follow the finger crisply; settle to grey-capable "ui" on release so
        -- the light-grey track renders correctly (A2 can't show its grey). This is
        -- what stops a slider drag from flashing a screen-wide GC16 strip per tick.
        -- self.parent (the sheet) is still the repaint target so the menu stays on
        -- top of any canvas the on_set refreshed underneath (e.g. a grid preview).
        local band = GeomUI:new{ x = self.dimen.x + self._track_dx, y = self.dimen.y,
            w = self.width - self._track_dx, h = self.dimen.h }
        UIManager:setDirty(self.parent or self, mode or "ui", band)
    end
end
function SliderRow:onSlTap(_, ges) self:_setFromX(ges.pos.x, "ui"); return true end
function SliderRow:onSlPan(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlHold(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlHoldPan(_, ges) self:_setFromX(ges.pos.x, "fast"); return true end
function SliderRow:onSlPanRelease(_, ges) if ges and ges.pos then self:_setFromX(ges.pos.x, "ui")
    else UIManager:setDirty(self.parent or self, "ui", self.dimen) end; return true end
function SliderRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    InputContainer.paintTo(self, bb, x, y)
end

-- Where a tool sheet's top should sit: just under the toolbar, so its options
-- open right where the hand tapped (falls back to a small margin if unknown).
function InkAwayView:sheetTopY()
    return (self._bar_h or 0) + Screen:scaleBySize(6)
end

-- Shared tile helpers, used by both the Shapes menu and its line/arrow/curve
-- child menu so they look identical.
function InkAwayView:iconPath(name)
    return self:pluginDir() .. "ink/icons/" .. name .. ".svg"
end
-- Transparent icon (tile colour shows through) when unselected; white-flattened +
-- whole-rect inverted when selected so black strokes read white on the black tile.
function InkAwayView:tileIcon(name, size, sel)
    local ok, w = pcall(function()
        if sel then
            return IconWidget:new{ file = self:iconPath(name), width = size, height = size,
                alpha = false, invert = true }
        end
        return IconWidget:new{ file = self:iconPath(name), width = size, height = size, alpha = true }
    end)
    return ok and w or nil
end
-- A rounded tile button. Uses Button's native icon path (so `text` stays nil and
-- the tap-highlight takes the safe invert branch, not the text one which would
-- index a fgcolor our icon widget lacks), then swaps in a transparent icon,
-- optionally above a label and a small grey hint sublabel. `hold_cb` wires a
-- long-press action.
function InkAwayView:makeTile(name, w, h, size, sel, cb, label, sublabel, hold_cb)
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Font = require("ui/font")
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    local b = Button:new{ icon = "inkaway." .. name, icon_width = size, icon_height = size,
        width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(16), background = sel and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    local iw = self:tileIcon(name, size, sel)
    if iw and b.label_container then
        if label then
            local tw = TextWidget:new{ text = label, face = Font:getFace("cfont", 15),
                bold = true, fgcolor = sel and WHITE or BLACK }
            local vg = VerticalGroup:new{ align = "center", iw,
                VerticalSpan:new{ width = Screen:scaleBySize(6) }, tw }
            if sublabel then
                local hint = TextWidget:new{ text = sublabel, face = Font:getFace("cfont", 11),
                    fgcolor = sel and Blitbuffer.ColorRGB32(0xC8, 0xC8, 0xC8, 0xFF)
                                   or Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF) }
                table.insert(vg, VerticalSpan:new{ width = Screen:scaleBySize(3) })
                table.insert(vg, hint)
            end
            b.label_widget = vg; b.label_container[1] = vg
        else
            b.label_widget = iw; b.label_container[1] = iw
        end
    end
    return b
end

-- Title row shared by every tool sheet: the sheet title on the left and a filled
-- black pill (Done / Back) on the right, spanning content_w.
function InkAwayView:sheetTitle(title, content_w, pill_label, pill_cb)
    local TextWidget = require("ui/widget/textwidget")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local Font = require("ui/font")
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    local titleW = TextWidget:new{ text = title, face = Font:getFace("cfont", 22), bold = true }
    local pill = Button:new{ text = "", width = Screen:scaleBySize(84), height = Screen:scaleBySize(34),
        bordersize = 0, radius = Screen:scaleBySize(11), background = BLACK, margin = 0, padding = 0,
        callback = pill_cb, show_parent = self }
    local ptw = TextWidget:new{ text = pill_label or _("Done"), face = Font:getFace("cfont", 15),
        bold = true, fgcolor = WHITE }
    if pill.label_container then pill.label_widget = ptw; pill.label_container[1] = ptw end
    local g = content_w - titleW:getSize().w - pill:getSize().w
    return HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), g) }, pill }
end

-- A full/any-width rounded action button (grey by default, black when `dark`).
function InkAwayView:actionButton(label, w, cb, dark)
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    local b = Button:new{ text = "", width = w, height = Screen:scaleBySize(48), bordersize = 0,
        radius = Screen:scaleBySize(14), background = dark and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, show_parent = self }
    local tw = TextWidget:new{ text = label, face = Font:getFace("cfont", 17), bold = true,
        fgcolor = dark and WHITE or BLACK }
    if b.label_container then b.label_widget = tw; b.label_container[1] = tw end
    return b
end

-- A colour swatch tile: a colour-filled rounded square with a thin black border
-- (thicker when selected, so white/light swatches stay visible). Optional
-- hold_cb for deleting a saved custom colour.
function InkAwayView:swatchTile(rgb, selected, w, cb, hold_cb, h)
    local BLACK = Blitbuffer.COLOR_BLACK
    local inner = w - Screen:scaleBySize(8)
    local inner_h = (h or w) - Screen:scaleBySize(8)
    local btn = Button:new{ text = "", width = inner, height = inner_h,
        background = Blitbuffer.ColorRGB32(rgb[1], rgb[2], rgb[3], 0xFF),
        radius = Screen:scaleBySize(11), bordersize = 0, margin = 0, padding = 0,
        callback = cb, hold_callback = hold_cb, show_parent = self }
    return FrameContainer:new{
        bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
        color = BLACK, radius = Screen:scaleBySize(14),
        padding = selected and Screen:scaleBySize(1) or Screen:scaleBySize(3),
        margin = 0, btn }
end

-- A brush-style tile: a small rounded rectangle showing a sample wave rendered
-- through the same rasterizer the pen uses, so it previews how the brush looks.
function InkAwayView:brushWaveTile(key, w, h, sel, cb, hold_cb)
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local BLACK = Blitbuffer.COLOR_BLACK
    local b = Button:new{ text = "", width = w, height = h, bordersize = 0,
        radius = Screen:scaleBySize(12), background = sel and BLACK or TILE_BG,
        margin = 0, padding = 0, callback = cb, hold_callback = hold_cb, show_parent = self }
    -- render the sample wave into a bb sized to the inner tile
    local iw = w - Screen:scaleBySize(16)
    local ih = h - Screen:scaleBySize(16)
    local ok, wave = pcall(function() return self:renderBrushWave(key, iw, ih, sel) end)
    if ok and wave and b.label_container then
        local ImageWidget = require("ui/widget/imagewidget")
        -- `fgcolor` is unused by ImageWidget, but Button's tap-highlight inverts
        -- `label_widget.fgcolor` whenever `text` is set (ours is ""), so it must be
        -- a real colour or the highlight crashes indexing a nil field.
        local img = ImageWidget:new{ image = wave, width = iw, height = ih,
            fgcolor = Blitbuffer.COLOR_BLACK }
        b.label_widget = img; b.label_container[1] = img
    end
    return b
end

-- Render a sample stroke for brush `key` into a fresh blitbuffer (caller frees via
-- the ImageWidget). White wave on a dark tile when selected, black on grey else.
function InkAwayView:renderBrushWave(key, w, h, sel)
    local st = Raster.STYLES[key] or Raster.STYLES.solid
    local bg = sel and Blitbuffer.COLOR_BLACK or TILE_BG
    local ink = sel and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    local bb = Blitbuffer.new(w, h, Screen.bb:getType())
    bb:paintRect(0, 0, w, h, bg)
    local pad = Screen:scaleBySize(6)
    local function put(x, y, len)
        if y < 0 or y >= h then return end
        if x < 0 then len = len + x; x = 0 end
        if x + len > w then len = w - x end
        if len > 0 then bb:paintRect(x, y, len, 1, ink) end
    end
    local pts, n = {}, 36
    for i = 0, n do
        local u = i / n
        pts[#pts + 1] = pad + u * (w - pad * 2)
        pts[#pts + 1] = h / 2 + math.sin(u * math.pi * 2) * (h * 0.26)
    end
    local r = math.max(3, Screen:scaleBySize(5))
    if st.solid then Raster.path(pts, r, put) else Raster.pathTex(pts, r, put, st, 12345) end
    return bb
end

-- The Shapes menu: big rounded-square icon tiles (the Line tile carries a small
-- caret in its bottom-right corner that opens the line/arrow/curve submenu; the
-- rest of the tile selects a plain line), the paint-bucket and lasso tools as
-- smaller secondary tiles, and Fill / snap options as sliding toggles that flip
-- in place. Icons are rendered with true transparency (alpha = true) so the tile
-- colour shows through; the selected tile inverts a white-flattened icon so black
-- strokes read as white on the black tile.
function InkAwayView:openShapePicker()
    self:flushShape()
    if self._shape_dialog then self._shape_dialog:rebuild(); return end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local Font = require("ui/font")
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    self:ensureUserIcons()

    -- Four square tiles fill the row with equal gaps; derive the exact content
    -- width from the tile size so everything lines up flush to the panel padding.
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local tileW = math.floor((target - 3 * gap) / 4)
    local content_w = 4 * tileW + 3 * gap
    local halfW = math.floor((content_w - gap) / 2)
    local isz = math.floor(tileW * 0.60)   -- big icon inside the tile

    -- The Line tile: a full-size select button (picks a plain line) with a small
    -- caret button pinned to the bottom-right that opens the variants submenu.
    local function lineTile(sel)
        local select_btn = self:makeTile("sh_line", tileW, tileW, isz, sel, function()
            self:flushShape(); self.shape, self.shape_arrow = "line", nil
            self:refreshToolLabels(); self:openShapePicker()
        end)
        local caretW = Screen:scaleBySize(30)
        local inset = Screen:scaleBySize(5)
        local caretIsz = caretW - Screen:scaleBySize(8)
        local caret_btn = Button:new{ icon = "inkaway.caret", icon_width = caretIsz, icon_height = caretIsz,
            width = caretW, height = caretW,
            bordersize = 0, radius = Screen:scaleBySize(8), background = CARET_BG,
            margin = 0, padding = 0, show_parent = self,
            callback = function() self:openShapeLineMenu() end,
            overlap_offset = { tileW - caretW - inset, tileW - caretW - inset } }
        local cw = self:tileIcon("caret", caretIsz, false)
        if cw and caret_btn.label_container then
            caret_btn.label_widget = cw; caret_btn.label_container[1] = cw
        end
        -- Caret is child[1] so the default first->last dispatch checks its small
        -- corner range first; any tap outside it falls through to the big select
        -- button (child[2]). paintTo is reversed so the select button draws
        -- underneath and the caret stays visible on top.
        local og = OverlapGroup:new{ dimen = { w = tileW, h = tileW },
            allow_mirroring = false, caret_btn, select_btn }
        function og:paintTo(bb, x, y)
            for i = #self, 1, -1 do
                local w = self[i]
                if w.overlap_offset then
                    w:paintTo(bb, x + w.overlap_offset[1], y + w.overlap_offset[2])
                else
                    w:paintTo(bb, x, y)
                end
            end
        end
        return og
    end

    local function shapeTile(name, shape)
        return self:makeTile(name, tileW, tileW, isz, self.shape == shape, function()
            self:flushShape(); self.shape, self.shape_arrow = shape, nil
            self:refreshToolLabels(); self:openShapePicker()
        end)
    end

    -- title row: "Shapes" on the left, a black Done pill on the right
    local titleW = TextWidget:new{ text = _("Shapes"), face = Font:getFace("cfont", 22), bold = true }
    local done = Button:new{ text = "", width = Screen:scaleBySize(84), height = Screen:scaleBySize(34),
        bordersize = 0, radius = Screen:scaleBySize(11), background = BLACK, margin = 0, padding = 0,
        callback = function() UIManager:close(self._shape_dialog); self._shape_dialog = nil end, show_parent = self }
    do
        local dtw = TextWidget:new{ text = _("Done"), face = Font:getFace("cfont", 15), bold = true, fgcolor = WHITE }
        if done.label_container then done.label_widget = dtw; done.label_container[1] = dtw end
    end
    local title_gap = content_w - titleW:getSize().w - done:getSize().w
    local titleRow = HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), title_gap) }, done }

    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

    -- The whole panel is built inside the menu's build callback so the toggle
    -- rows can use the (about-to-be-shown) menu as their repaint parent.
    local build = function(menu)
        -- The shape and tool tiles show the current selection, so they must be
        -- rebuilt here (inside the rebuild callback), not once above -- otherwise
        -- picking a shape would not move the highlight until the sheet reopened.
        local lineSel = (self.shape == "line" or self.shape == "curve")
        local shapeRow = HorizontalGroup:new{ align = "center",
            lineTile(lineSel), HorizontalSpan:new{ width = gap },
            shapeTile("sh_rect", "rect"), HorizontalSpan:new{ width = gap },
            shapeTile("sh_ellipse", "ellipse"), HorizontalSpan:new{ width = gap },
            shapeTile("sh_triangle", "triangle"),
        }
        -- tools row: paint bucket + lasso, smaller/secondary tiles with a label
        local toolH = Screen:scaleBySize(96)
        local toolIsz = Screen:scaleBySize(36)
        local toolRow = HorizontalGroup:new{ align = "center",
            self:makeTile("bucket", halfW, toolH, toolIsz, self.tool == "fill", function()
                self:flushShape(); self.tool = "fill"; self:refreshToolLabels()
                UIManager:close(self._shape_dialog); self._shape_dialog = nil
            end, _("Paint bucket"), _("hold to pick colour"), function() self:openFillColor() end),
            HorizontalSpan:new{ width = gap },
            self:makeTile("lasso", halfW, toolH, toolIsz, self.tool == "lasso", function()
                self:flushPending(); self:flushShape()
                if self.selection or self.lassoing then self:clearSelection() end
                self.tool = "lasso"; self:refreshToolLabels()
                UIManager:close(self._shape_dialog); self._shape_dialog = nil
                self:composeCanvas(); self:renderView(); self:refresh("all", "full")
            end, _("Lasso select")),
        }
        -- three compact toggles (switch right after its label) spread across one row
        local function toggle(label, on, cb)
            return ToggleRow:new{ label = label, is_on = on, compact = true, parent = menu, callback = cb }
        end
        local fillRow = toggle(_("Fill"), self.shape_fill, function(on)
            self.shape_fill = on end)
        local gridRow = toggle(_("Snap to grid"), self.snap_grid, function(on)
            self.snap_grid = on; self:setSetting("inkaway_snap_grid", on) end)
        local snap45Row = toggle(_("Snap to 45\u{00B0}"), self.snap_angle, function(on)
            self.snap_angle = on; self:setSetting("inkaway_snap_angle", on) end)
        local totalW = fillRow.width + gridRow.width + snap45Row.width
        local slack = math.max(Screen:scaleBySize(16), math.floor((content_w - totalW) / 2))
        local togglesRow = HorizontalGroup:new{ align = "center",
            fillRow, HorizontalSpan:new{ width = slack },
            gridRow, HorizontalSpan:new{ width = slack },
            snap45Row }
        local content = VerticalGroup:new{ align = "left",
            titleRow, vspan(16),
            shapeRow, vspan(16),
            togglesRow, vspan(16),
            toolRow,
        }
        return FrameContainer:new{
            background = WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18),
            content,
        }
    end

    self._shape_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._shape_dialog = nil end }
    UIManager:show(self._shape_dialog)
end

-- The line/arrow/curve variants, opened from the Line tile. Kept as a compact
-- ButtonDialog (glyph + label), with the arrowhead size for the arrow variants.
-- The line/arrow/curve variants, in the SAME rounded-tile style as the parent
-- Shapes menu but with smaller tiles (it is a child menu): two rows of three
-- (straight family / curved family), plus an arrowhead-size row and a Back pill.
function InkAwayView:openShapeLineMenu()
    -- (no rebuild-in-place: every button here closes this sheet and navigates
    -- away, so it is always opened fresh)
    if self._shape_dialog then UIManager:close(self._shape_dialog); self._shape_dialog = nil end
    if self._shape_line_dialog then UIManager:close(self._shape_line_dialog); self._shape_line_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    self:ensureUserIcons()

    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local parentTileW = math.floor((target - 3 * gap) / 4)
    local tileW = math.floor(parentTileW * 0.78)   -- smaller than the parent's tiles
    local isz = math.floor(tileW * 0.60)
    local content_w = 3 * tileW + 2 * gap

    local function isSel(shape, arrow)
        return self.shape == shape and (self.shape_arrow or false) == (arrow or false)
    end
    local function pick(shape, arrow)
        return function()
            self:flushShape(); self.shape, self.shape_arrow = shape, arrow
            self:refreshToolLabels()
            if self._shape_line_dialog then UIManager:close(self._shape_line_dialog); self._shape_line_dialog = nil end
            self:openShapePicker()
        end
    end
    local function tile(name, shape, arrow)
        return self:makeTile(name, tileW, tileW, isz, isSel(shape, arrow), pick(shape, arrow))
    end

    local row1 = HorizontalGroup:new{ align = "center",
        tile("sh_line", "line", nil), HorizontalSpan:new{ width = gap },
        tile("sh_arrow", "line", "end"), HorizontalSpan:new{ width = gap },
        tile("sh_darrow", "line", "both") }
    local row2 = HorizontalGroup:new{ align = "center",
        tile("sh_curve", "curve", nil), HorizontalSpan:new{ width = gap },
        tile("sh_carrow", "curve", "end"), HorizontalSpan:new{ width = gap },
        tile("sh_cdarrow", "curve", "both") }

    -- title row: label on the left, a black Back pill on the right
    local titleW = TextWidget:new{ text = _("Line / arrow / curve"), face = Font:getFace("cfont", 20), bold = true }
    local back = Button:new{ text = "", width = Screen:scaleBySize(84), height = Screen:scaleBySize(34),
        bordersize = 0, radius = Screen:scaleBySize(11), background = BLACK, margin = 0, padding = 0,
        callback = function()
            if self._shape_line_dialog then UIManager:close(self._shape_line_dialog); self._shape_line_dialog = nil end
            self:openShapePicker()
        end, show_parent = self }
    do
        local btw = TextWidget:new{ text = _("Back"), face = Font:getFace("cfont", 15), bold = true, fgcolor = WHITE }
        if back.label_container then back.label_widget = btw; back.label_container[1] = btw end
    end
    local title_gap = content_w - titleW:getSize().w - back:getSize().w
    local titleRow = HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), title_gap) }, back }

    -- arrowhead size: a full-width rounded grey text button (text buttons are safe)
    local ahRow = Button:new{ text = string.format(_("Arrowhead size: %d px"), self.arrow_head),
        width = content_w, height = Screen:scaleBySize(48), bordersize = 0,
        radius = Screen:scaleBySize(14), background = TILE_BG, margin = 0, padding = 0,
        text_font_size = 17, show_parent = self,
        callback = function()
            if self._shape_line_dialog then UIManager:close(self._shape_line_dialog); self._shape_line_dialog = nil end
            self:openArrowSize()
        end }

    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local build = function()
        local content = VerticalGroup:new{ align = "left",
            titleRow, vspan(16),
            row1, vspan(gap),
            row2, vspan(16),
            ahRow,
        }
        return FrameContainer:new{ background = WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._shape_line_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._shape_line_dialog = nil end }
    UIManager:show(self._shape_line_dialog)
end

-- The paint-bucket colour picker (opened by holding the Paint bucket tile), in
-- the same rounded-sheet style as the Shapes menu: rows of colour swatch tiles
-- (grey shades, plus chromatic colours on a colour screen) and an opacity row.
function InkAwayView:openFillColor()
    if self._fill_dialog then self._fill_dialog:rebuild(); return end
    if self._shape_dialog then UIManager:close(self._shape_dialog); self._shape_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local WHITE, BLACK = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
    self:ensureUserIcons()

    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local sw = math.floor((target - 5 * gap) / 6)   -- 6 swatches per row (colours)
    local content_w = 6 * sw + 5 * gap

    -- one colour swatch: a colour-filled rounded tile; the current colour gets a
    -- black ring (via a wrapping FrameContainer), others a hairline.
    local function swatch(e)
        local selected = sameColor(self.fill_color, e.rgb)
        local inner = sw - Screen:scaleBySize(8)
        local btn = Button:new{ text = "", width = inner, height = inner,
            background = Blitbuffer.ColorRGB32(e.rgb[1], e.rgb[2], e.rgb[3], 0xFF),
            radius = Screen:scaleBySize(12), bordersize = 0, margin = 0, padding = 0,
            show_parent = self,
            callback = function() self.fill_color = { e.rgb[1], e.rgb[2], e.rgb[3] }; self:openFillColor() end }
        return FrameContainer:new{
            bordersize = selected and Screen:scaleBySize(3) or Screen:scaleBySize(1),
            color = selected and BLACK or HAIRLINE,
            radius = Screen:scaleBySize(15),
            padding = selected and Screen:scaleBySize(1) or Screen:scaleBySize(3),
            margin = 0, btn }
    end
    local function swatchRow(entries)
        local row = HorizontalGroup:new{ align = "center" }
        for i, e in ipairs(entries) do
            if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
            table.insert(row, swatch(e))
        end
        return row
    end

    -- title + Done
    local titleW = TextWidget:new{ text = _("Fill colour"), face = Font:getFace("cfont", 22), bold = true }
    local done = Button:new{ text = "", width = Screen:scaleBySize(84), height = Screen:scaleBySize(34),
        bordersize = 0, radius = Screen:scaleBySize(11), background = BLACK, margin = 0, padding = 0,
        callback = function() if self._fill_dialog then UIManager:close(self._fill_dialog); self._fill_dialog = nil end end,
        show_parent = self }
    do
        local dtw = TextWidget:new{ text = _("Done"), face = Font:getFace("cfont", 15), bold = true, fgcolor = WHITE }
        if done.label_container then done.label_widget = dtw; done.label_container[1] = dtw end
    end
    local title_gap = content_w - titleW:getSize().w - done:getSize().w
    local titleRow = HorizontalGroup:new{ align = "center",
        titleW, HorizontalSpan:new{ width = math.max(Screen:scaleBySize(8), title_gap) }, done }

    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    -- opacity: a 0..100 slider built inside build() so it can use the shown menu
    -- as its repaint parent for the in-place value change.
    local build = function(menu)
        local pct = math.floor(self.fill_alpha / 255 * 100 + 0.5)
        local opacity = SliderRow:new{ label = _("Opacity"), value = pct, width = content_w, parent = menu,
            on_set = function(v) self.fill_alpha = math.floor(v / 100 * 255 + 0.5) end }
        local content = VerticalGroup:new{ align = "center" }
        table.insert(content, titleRow)
        table.insert(content, vspan(16))
        table.insert(content, swatchRow(SHADES))
        if self:colorScreen() then
            table.insert(content, vspan(gap))
            table.insert(content, swatchRow(COLORS))
        end
        table.insert(content, vspan(18))
        table.insert(content, opacity)
        return FrameContainer:new{ background = WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._fill_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._fill_dialog = nil end }
    UIManager:show(self._fill_dialog)
end


------------------------------------------------------------------------------
-- Zoom  (consistent multiplicative steps between fit and ZOOM_MAX)
------------------------------------------------------------------------------

function InkAwayView:setZoom(new_zoom, anchor_sx, anchor_sy)
    local v = self.view
    new_zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, new_zoom))
    if math.abs(new_zoom - v.zoom) < 1e-6 then return false end
    -- keep the canvas point under (anchor_sx, anchor_sy) fixed; default to the
    -- centre of the drawing area
    anchor_sx = anchor_sx or (v.area_x + v.area_w / 2)
    anchor_sy = anchor_sy or (v.area_y + v.area_h / 2)
    local acx, acy = InkGeom.toCanvas(v, anchor_sx, anchor_sy)
    v.zoom = new_zoom
    v.pan_x = acx - (anchor_sx - v.area_x) / v.zoom
    v.pan_y = acy - (anchor_sy - v.area_y) / v.zoom
    InkGeom.clampPan(v)
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

function InkAwayView:zoomStep(dir)
    self:flushPending()
    local factor = (dir > 0) and ZOOM_RATIO or (1 / ZOOM_RATIO)
    self:setZoom(self.view.zoom * factor)
end

-- Pinch (dir<0, fingers together -> zoom out) and spread (dir>0, fingers apart
-- -> zoom in) zoom the CANVAS, anchored at the gesture's midpoint, by an amount
-- proportional to how far the fingers moved. On e-ink a single anchored jump per
-- gesture (rather than a live continuous zoom) is what avoids ghosting.
function InkAwayView:pinchZoom(ges, dir)
    self:flushPending()
    self:cancelShape()
    local v = self.view
    local dist = (ges and ges.distance) or 0
    local ref = math.min(self.screen_w, self.screen_h) * 0.6
    local factor = 1 + math.min(dist, ref) / ref            -- up to ~2x per gesture
    local nz = (dir > 0) and (v.zoom * factor) or (v.zoom / factor)
    local pos = ges and ges.pos
    self:setZoom(nz, pos and pos.x, pos and pos.y)
end

function InkAwayView:onIaPinch(_, ges)
    if self:fingerRejected() then return true end
    self:pinchZoom(ges, -1)
    return true
end

function InkAwayView:onIaSpread(_, ges)
    if self:fingerRejected() then return true end
    self:pinchZoom(ges, 1)
    return true
end

------------------------------------------------------------------------------
-- Floating immersive controls: a zoom pill at the bottom-right, and a toolbar
-- collapse/expand arrow at the top-right. Both zoom/toggle on a tap and melt away
-- while the pen draws near them (reappearing shortly after) so the canvas beneath
-- stays reachable. Their geometry follows the drawing area, so they move when the
-- toolbar hides and the paper grows.
------------------------------------------------------------------------------

-- Screen rect of a named control ("zoom" pill or "bar" toggle), or nil.
function InkAwayView:fabRect(which)
    if not self.view then return nil end
    local v = self.view
    local m = Screen:scaleBySize(16)
    local w = Screen:scaleBySize(46)
    if which == "zoom" then
        local h = Screen:scaleBySize(92)
        return { x = v.area_x + v.area_w - m - w, y = v.area_y + v.area_h - m - h, w = w, h = h }
    elseif which == "nbbar" then -- notebook bottom-bar toggle: a bare chevron at the
        -- bar's top-left, mirroring the toolbar toggle. Anchored to the area bottom
        -- so it stays reachable whether the bar is shown (sits on the bar's top edge)
        -- or collapsed (sits near the screen bottom).
        if not self.notebook then return nil end
        local bw = Screen:scaleBySize(34)
        local bh = Screen:scaleBySize(22)
        local cx = v.area_x + Screen:scaleBySize(24)
        return { x = math.floor(cx - bw / 2), y = v.area_y + v.area_h - bh - Screen:scaleBySize(2),
                 w = bw, h = bh }
    else -- "bar": a small bare chevron centred under the toolbar's Exit button
        local bw = Screen:scaleBySize(34)
        local bh = Screen:scaleBySize(22)
        local cx = self._last_btn_center or (v.area_x + v.area_w - Screen:scaleBySize(24))
        return { x = math.floor(cx - bw / 2), y = v.area_y + Screen:scaleBySize(2), w = bw, h = bh }
    end
end

function InkAwayView:fabHidden(which)
    if which == "zoom" then return self._zoom_hidden
    elseif which == "nbbar" then return self._nbbar_toggle_hidden
    else return self._bar_toggle_hidden end
end

-- Repaint just a control's footprint (plus a margin): hiding reveals the canvas,
-- showing draws the control, both without a full redraw.
function InkAwayView:refreshFabRegion(r)
    if not r then return end
    self._blit_rect = nil   -- a control melted/appeared over the canvas; blit the
                            -- whole area so the region under it is restored, not
                            -- just the live-stroke sub-rect
    local m = Screen:scaleBySize(4)
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = r.x - m, y = r.y - m, w = r.w + 2 * m, h = r.h + 2 * m })
end

-- What a point hits: "zoomin"/"zoomout" (halves of the pill), "bar" (the toggle),
-- or nil. Hidden controls are not hittable, so a draw passes straight through.
function InkAwayView:fabHit(px, py)
    if not self._zoom_hidden then
        local r = self:fabRect("zoom")
        if r and px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h then
            return (py < r.y + r.h / 2) and "zoomin" or "zoomout"
        end
    end
    if not self._bar_toggle_hidden then
        local r = self:fabRect("bar")
        if r and px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h then
            return "bar"
        end
    end
    if self.notebook and not self._nbbar_toggle_hidden then
        local r = self:fabRect("nbbar")
        if r and px >= r.x and px <= r.x + r.w and py >= r.y and py <= r.y + r.h then
            return "nbbar"
        end
    end
    return nil
end

-- Act on a completed tap of a control.
function InkAwayView:fabAction(kind)
    if kind == "zoomin" then self:zoomStep(1)
    elseif kind == "zoomout" then self:zoomStep(-1)
    elseif kind == "bar" then self:setToolbarHidden(not self._toolbar_hidden)
    elseif kind == "nbbar" then self:setNbBarHidden(not self._nb_collapsed) end
end

-- Called from the drawing handlers: if the active point comes near a control,
-- fade it out and keep pushing back its return until drawing there stops.
function InkAwayView:fabProximity(px, py)
    local function near(r) local m = r.w
        return px >= r.x - m and px <= r.x + r.w + m and py >= r.y - m and py <= r.y + r.h + m end
    local rz = self:fabRect("zoom")
    if rz and not self._zoom_hidden and near(rz) then
        self._zoom_hidden = true; self:refreshFabRegion(rz)
    end
    if rz and self._zoom_hidden and near(rz) then
        UIManager:unschedule(self._show_zoom_fab); UIManager:scheduleIn(0.6, self._show_zoom_fab)
    end
    local rb = self:fabRect("bar")
    if rb and not self._bar_toggle_hidden and near(rb) then
        self._bar_toggle_hidden = true; self:refreshFabRegion(rb)
    end
    if rb and self._bar_toggle_hidden and near(rb) then
        UIManager:unschedule(self._show_bar_toggle); UIManager:scheduleIn(0.6, self._show_bar_toggle)
    end
    local rn = self.notebook and self:fabRect("nbbar")
    if rn and not self._nbbar_toggle_hidden and near(rn) then
        self._nbbar_toggle_hidden = true; self:refreshFabRegion(rn)
    end
    if rn and self._nbbar_toggle_hidden and near(rn) then
        UIManager:unschedule(self._show_nbbar_toggle); UIManager:scheduleIn(0.6, self._show_nbbar_toggle)
    end
end

-- A small chevron centred at (cx, cy): up = -1 (collapse), down = 1 (expand).
local function fabChevron(bb, cx, cy, half, dir, tk)
    local function seg(x0, y0, x1, y1)
        local dx, dy = math.abs(x1 - x0), -math.abs(y1 - y0)
        local sx, sy = x0 < x1 and 1 or -1, y0 < y1 and 1 or -1
        local err, hb = dx + dy, math.floor(tk / 2)
        while true do
            bb:paintRect(x0 - hb, y0 - hb, tk, tk, FAB_GLYPH)
            if x0 == x1 and y0 == y1 then break end
            local e2 = 2 * err
            if e2 >= dy then err = err + dy; x0 = x0 + sx end
            if e2 <= dx then err = err + dx; y0 = y0 + sy end
        end
    end
    -- dir -1 = up chevron (^, collapse); dir +1 = down chevron (v, expand)
    local yTip = cy + dir * math.floor(half * 0.6)
    local yEnd = cy - dir * math.floor(half * 0.6)
    seg(cx - half, yEnd, cx, yTip)
    seg(cx, yTip, cx + half, yEnd)
end

-- Paint the floating controls onto the screen buffer (called last in paintTo so
-- they float on top). A light, airy pill so it never reads as a solid box.
function InkAwayView:drawFabs(bb, ox, oy)
    if self.selecting_crop then return end
    local S1 = math.max(1, Screen:scaleBySize(1))
    -- zoom pill (+ over -)
    if not self._zoom_hidden then
        local r = self:fabRect("zoom")
        if r then
            local x, y, w, h = ox + r.x, oy + r.y, r.w, r.h
            local rad = math.floor(w / 2)
            bb:paintRoundedRect(x, y, w, h, FAB_FILL, rad)
            bb:paintBorder(x, y, w, h, S1, FAB_BORDER, rad)
            local midy = y + math.floor(h / 2)
            bb:paintRect(x + Screen:scaleBySize(10), midy, w - 2 * Screen:scaleBySize(10), S1, FAB_BORDER)
            local gw = math.floor(w * 0.34)
            local gt = math.max(2, Screen:scaleBySize(2))
            local cx = x + math.floor(w / 2)
            local cyTop, cyBot = y + math.floor(h / 4), y + math.floor(3 * h / 4)
            bb:paintRect(cx - math.floor(gw / 2), cyTop - math.floor(gt / 2), gw, gt, FAB_GLYPH)
            bb:paintRect(cx - math.floor(gt / 2), cyTop - math.floor(gw / 2), gt, gw, FAB_GLYPH)
            bb:paintRect(cx - math.floor(gw / 2), cyBot - math.floor(gt / 2), gw, gt, FAB_GLYPH)
        end
    end
    -- toolbar toggle: a bare chevron (no pill) -- up to collapse, down to expand
    if not self._bar_toggle_hidden then
        local r = self:fabRect("bar")
        if r then
            local x, y, w, h = ox + r.x, oy + r.y, r.w, r.h
            local dir = self._toolbar_hidden and 1 or -1   -- down = expand, up = collapse
            fabChevron(bb, x + math.floor(w / 2), y + math.floor(h / 2),
                math.floor(w * 0.28), dir, math.max(2, Screen:scaleBySize(2)))
        end
    end
    -- notebook bottom-bar toggle: the same bare chevron at the bar's top-left. Bar
    -- shown -> down (collapse it away); collapsed -> up (bring it back).
    if self.notebook and not self._nbbar_toggle_hidden then
        local r = self:fabRect("nbbar")
        if r then
            local x, y, w, h = ox + r.x, oy + r.y, r.w, r.h
            local dir = self._nb_collapsed and -1 or 1     -- up = expand, down = collapse
            fabChevron(bb, x + math.floor(w / 2), y + math.floor(h / 2),
                math.floor(w * 0.28), dir, math.max(2, Screen:scaleBySize(2)))
        end
    end
end

-- Hide or show the top toolbar, growing the paper to fill the freed space. The
-- drawing-area buffer is reallocated and the view re-fitted, exactly as on a
-- screen-rotation relayout.
function InkAwayView:setToolbarHidden(hidden)
    if (self._toolbar_hidden or false) == hidden then return end
    self:flushPending()
    self._toolbar_hidden = hidden
    local v = self.view
    local th = self.toolbar:getSize().h
    v.area_y = hidden and 0 or th
    v.area_h = (hidden and self.screen_h or (self.screen_h - th)) - self.nb_bar_h
    -- when hidden, the toolbar buttons must not swallow taps in the freed strip
    -- (plain if/else: `hidden and nil or self.toolbar` would never yield nil)
    if hidden then self[1] = nil else self[1] = self.toolbar end
    self.zoom_min = InkGeom.fitZoom(v)
    v.zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, v.zoom))
    InkGeom.clampPan(v)
    if self.area_bb then self.area_bb:free() end
    self.area_bb = Blitbuffer.new(v.area_w, v.area_h, Screen.bb:getType())
    self:renderView()
    self:refresh(self, "full")
end

-- Hide or show the notebook bottom bar, growing the paper to fill the freed space
-- (mirrors setToolbarHidden). Honours a hidden toolbar too, so the two can be
-- collapsed independently.
function InkAwayView:setNbBarHidden(hidden)
    if not self.notebook then return end
    if (self._nb_collapsed or false) == hidden then return end
    self:flushPending()
    self._nb_collapsed = hidden
    self.nb_bar_h = self:nbBarHeight()      -- 0 when collapsed (see nbBarHeight)
    local v = self.view
    local th = self._toolbar_hidden and 0 or self.toolbar:getSize().h
    v.area_y = th
    v.area_h = self.screen_h - th - self.nb_bar_h
    self.zoom_min = InkGeom.fitZoom(v)
    v.zoom = math.max(self.zoom_min, math.min(ZOOM_MAX, v.zoom))
    InkGeom.clampPan(v)
    if self.area_bb then self.area_bb:free() end
    self.area_bb = Blitbuffer.new(v.area_w, v.area_h, Screen.bb:getType())
    self:renderView()
    self:refresh(self, "full")
end

------------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------------

-- The drawing area as a screen rect. A fresh Geom every call, because setDirty
-- keeps the region by reference rather than copying it.
function InkAwayView:areaScreenRect()
    local v = self.view
    return GeomUI:new{ x = v.area_x, y = v.area_y, w = v.area_w, h = v.area_h }
end

-- True only on a colour (Kaleido) panel. Cached once: on grey e-ink a full-screen
-- flash is cheap, but on a colour panel it costs ~1-2s of colour waveform whether
-- or not any pixel changed, so colour needs a lighter refresh policy.
function InkAwayView:colourPanel()
    if self._is_colour == nil then self._is_colour = self:colorScreen() end
    return self._is_colour
end

-- Colour-aware refresh. On grey e-ink this is a byte-for-byte pass-through to
-- UIManager:setDirty (zero Kindle change). On a colour panel it turns an AVOIDABLE
-- full-screen flash ("full") into a non-flashing partial update ("ui"), which
-- covers the same region without the ~1-2s colour flash. Other modes are passed
-- through unchanged. Use this for repaints that only need the pixels updated (tool
-- switches, bar toggles, page turns, text-box commit); keep a literal
-- setDirty(..., "full", ...) for the deliberate flashes that must clear ghosting
-- (open/close, rotation, the periodic de-ghost, and big page-wide content swaps).
function InkAwayView:refresh(target, mode, region)
    if self:colourPanel() and mode == "full" then mode = "ui" end
    UIManager:setDirty(target, mode, region)
end

-- Given a changed rectangle of the base (un-mirrored) stroke in area-local
-- coordinates, return that rectangle plus one for each mirror image the current
-- symmetry produces. This keeps refreshes to a few small rectangles instead of
-- one huge box spanning the drawn side and all its mirrors (which would make
-- every stroke a near full-screen refresh, the symmetry slowdown).
-- Returns a REUSED pool of rects and a count (base rect + one per mirror). The
-- pool and the arithmetic (no per-call closures) keep this allocation-free, since
-- it runs once per drawn point under symmetry. Callers must read each rect within
-- the loop before the next call -- which they do, consuming it immediately.
function InkAwayView:symAreaRects(acc)
    local p = self._sar_pool
    if not p then p = { {}, {}, {}, {} }; self._sar_pool = p end
    local b = p[1]
    b.x0, b.y0, b.x1, b.y1 = acc.x0, acc.y0, acc.x1, acc.y1
    local sym = self.symmetry
    if not sym or sym == "off" then return p, 1 end
    local v = self.view
    local kx = (v.canvas_w - 2 * v.pan_x) * v.zoom
    local ky = (v.canvas_h - 2 * v.pan_y) * v.zoom
    local mx, my = Symmetry.mirrorsX(sym), Symmetry.mirrorsY(sym)
    local n = 1
    if mx then
        n = n + 1; local r = p[n]
        r.x0, r.y0, r.x1, r.y1 = kx - b.x1, b.y0, kx - b.x0, b.y1
    end
    if my then
        n = n + 1; local r = p[n]
        r.x0, r.y0, r.x1, r.y1 = b.x0, ky - b.y1, b.x1, ky - b.y0
    end
    if mx and my then
        n = n + 1; local r = p[n]
        r.x0, r.y0, r.x1, r.y1 = kx - b.x1, ky - b.y1, kx - b.x0, ky - b.y0
    end
    return p, n
end

-- Refresh one area-local rectangle (clipped to the drawing area) at `mode`.
function InkAwayView:dirtyAreaRect(mode, r, pad)
    pad = pad or 0
    local v = self.view
    local x0 = math.max(0, math.floor(r.x0) - pad)
    local y0 = math.max(0, math.floor(r.y0) - pad)
    local x1 = math.min(v.area_w, math.ceil(r.x1) + pad)
    local y1 = math.min(v.area_h, math.ceil(r.y1) + pad)
    if x1 <= x0 or y1 <= y0 then return end
    -- While a live stroke is drawing, only these sub-rects of area_bb change, so
    -- accumulate them and let paintTo blit ONLY this region instead of the whole
    -- drawing surface every point (see paintTo). Area-local coords.
    if self.capturing then
        local br = self._blit_rect
        if not br then self._blit_rect = { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
        else
            if x0 < br.x0 then br.x0 = x0 end
            if y0 < br.y0 then br.y0 = y0 end
            if x1 > br.x1 then br.x1 = x1 end
            if y1 > br.y1 then br.y1 = y1 end
        end
    end
    UIManager:setDirty(self, mode, GeomUI:new{
        x = v.area_x + x0, y = v.area_y + y0, w = x1 - x0, h = y1 - y0 })
end

-- The colour a committed op is drawn with on screen (ink shade at its opacity,
-- or the background for an eraser).
function InkAwayView:opColor(op)
    if op.kind == "erase" then return WHITE end
    return displayColor(op.color, op.alpha or 255)
end

------------------------------------------------------------------------------
-- Text notes: font faces and the measuring/rendering context handed to the
-- text engine. Kept here (not in ink/text.lua) so the engine stays pure Lua and
-- testable; only this side touches KOReader fonts.
------------------------------------------------------------------------------

function InkAwayView:textFontName()
    return self.text_font or "cfont"
end

-- Friendly display name for the current note font.
function InkAwayView:textFontDisplay()
    if not self.text_font then return _("Default") end
    return (self.text_font:gsub(".*/", ""):gsub("%.%w+$", ""))
end

-- Text settings submenu: font family and default size.
-- Text sheet (shapes-menu style): font chooser, a font-size slider, and the
-- snap / eraser-protect toggles.
function InkAwayView:openTextSettings()
    if self._text_settings then UIManager:close(self._text_settings); self._text_settings = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    self:ensureUserIcons()
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local size = self.text_size or math.max(16, math.floor(self.view.canvas_w / 32))
    local closeSelf = function()
        if self._text_settings then UIManager:close(self._text_settings); self._text_settings = nil end
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Text"), content_w, _("Done"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Font: ") .. self:textFontDisplay(), content_w,
            function() closeSelf(); self:openTextFont() end))
        add(vspan(12))
        add(SliderRow:new{ label = _("Font size"), value = size, min = 10, max = 96,
            width = content_w, parent = menu, format = function(v) return v .. _(" px") end,
            on_set = function(v) self.text_size = v; self:setSetting("inkaway_text_size", v) end })
        add(vspan(14))
        add(ToggleRow:new{ label = _("Snap lines to ruling"), is_on = self.text_grid_snap,
            width = content_w, parent = menu,
            callback = function(on)
                self.text_grid_snap = on; self:setSetting("inkaway_text_grid_snap", on)
                if self.editing_text then
                    self.editing_text.grid_snap = on
                    if on then self:snapTextBoxToGrid(self.editing_text) end
                    self:invalidateLayout(); self:refreshTextBox("flashui")
                end
            end })
        add(vspan(10))
        add(ToggleRow:new{ label = _("Protect text from eraser"), is_on = self.text_erase_protect,
            width = content_w, parent = menu,
            callback = function(on)
                self.text_erase_protect = on; self:setSetting("inkaway_text_erase_protect", on)
            end })
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._text_settings = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._text_settings = nil end }
    UIManager:show(self._text_settings)
end

-- Apply a font change: rebuild the face cache, update the box being edited (or
-- recompose so committed boxes on the default font pick it up), and persist.
function InkAwayView:afterFontChange()
    self._face_cache = nil
    self:invalidateLayout()
    self:setSetting("inkaway_text_font", self.text_font or "")
    if self.editing_text then
        self.editing_text.font = self.text_font
        self:refreshTextBox("flashui")
    else
        self:composeCanvas(); self:renderView(); self:refresh(self, "full")
    end
end

-- A Menu that renders each row's label in that row's own font, so the font
-- chooser is a live preview instead of one uniform typeface. The standalone Menu
-- widget uses a single face for every item, so we replace its item rows with
-- borderless left-aligned Buttons whose face is the font itself (Button passes
-- text_font_face straight to Font:getFace, which accepts a font file path).
function InkAwayView:fontMenuClass()
    if InkAwayView._FontMenu then return InkAwayView._FontMenu end
    local Menu = require("ui/widget/menu")
    local Button = require("ui/widget/button")
    local UIManager_ = require("ui/uimanager")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local FontMenu = Menu:extend{}
    -- The base Menu paints its popup at the top-left: InputContainer:paintTo
    -- overwrites self.dimen.x/y with the paint origin (0,0), so setting them in
    -- init alone is discarded. Instead we paint at a centred offset inside
    -- `center_rect` (the drawing area, so the popup clears the toolbar and the
    -- page-nav strip). Painting there sets self.dimen to match, so the refresh
    -- region and the button hit-boxes both follow.
    function FontMenu:init()
        Menu.init(self)
        local cr = self.center_rect
            or { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
        self._ox = cr.x + math.floor((cr.w - self.dimen.w) / 2)
        self._oy = cr.y + math.floor((cr.h - self.dimen.h) / 2)
        self.dimen.x, self.dimen.y = self._ox, self._oy
    end
    function FontMenu:paintTo(bb, x, y)
        InputContainer.paintTo(self, bb, x + (self._ox or 0), y + (self._oy or 0))
    end
    function FontMenu:updateItems(select_number, no_recalculate_dimen)
        self.layout = {}
        self.item_group:clear()
        self.page_info:resetLayout()
        self.return_button:resetLayout()
        self.content_group:resetLayout()
        self:_recalculateDimen(no_recalculate_dimen)
        local idx0 = (self.page - 1) * self.perpage
        for i = 1, self.perpage do
            local item = self.item_table[idx0 + i]
            if not item then break end
            local btn = Button:new{
                text = item.text,
                text_font_face = item.preview_font or "smallinfofont",
                text_font_size = self.font_size,
                text_font_bold = false,
                align = "left",
                width = self.inner_dimen.w,
                max_width = self.inner_dimen.w,
                height = self.item_dimen.h,   -- fixed row height so a page never
                                              -- overflows onto the page buttons
                bordersize = 0,
                margin = 0,
                radius = 0,
                padding_v = 0,
                padding_h = Screen:scaleBySize(16),   -- a little breathing room at the left
                callback = item.callback,
                show_parent = self.show_parent,
            }
            table.insert(self.item_group, btn)
            table.insert(self.layout, { btn })
        end
        self:updatePageInfo(select_number)
        if self.mergeTitleBarIntoLayout then self:mergeTitleBarIntoLayout() end
        UIManager_:setDirty(self.show_parent, function()
            return "ui", self.dimen
        end)
    end
    InkAwayView._FontMenu = FontMenu
    return FontMenu
end

-- Scrollable chooser over the device's installed fonts, each shown in its own font.
function InkAwayView:openTextFont()
    local FontList = require("fontlist")
    local items = {
        { text = (self.text_font == nil and "\u{2713} " or "") .. _("Default (content font)"),
          preview_font = "cfont",
          callback = function() self.text_font = nil; self:afterFontChange() end },
    }
    for _, path in ipairs(FontList:getFontList()) do
        local name = (path:gsub(".*/", ""):gsub("%.%w+$", ""))
        items[#items + 1] = { text = (self.text_font == path and "\u{2713} " or "") .. name,
            preview_font = path,
            callback = function() self.text_font = path; self:afterFontChange() end }
    end
    -- Fit the popup inside the drawing area with a comfortable margin on all four
    -- sides, so it clears the toolbar and the page-nav strip and never gets clipped.
    local v = self.view
    local m = Screen:scaleBySize(28)
    local area = { x = v.area_x, y = v.area_y, w = v.area_w, h = v.area_h }
    local FontMenu = self:fontMenuClass()
    local menu
    menu = FontMenu:new{
        title = _("Note font"),
        item_table = items,
        is_popout = true,
        width = math.max(200, area.w - 2 * m),
        height = math.max(200, area.h - 2 * m),
        center_rect = area,
        close_callback = function() UIManager:close(menu) end,
    }
    UIManager:show(menu)
end

-- Toggle grid-line snapping for new boxes (and the one being edited). It only has
-- a visible effect on a ruled notebook page.
function InkAwayView:toggleTextGridSnap()
    self.text_grid_snap = not self.text_grid_snap
    self:setSetting("inkaway_text_grid_snap", self.text_grid_snap)
    if self.editing_text then
        self.editing_text.grid_snap = self.text_grid_snap
        if self.text_grid_snap then self:snapTextBoxToGrid(self.editing_text) end
        self:invalidateLayout()
        self:refreshTextBox("flashui")
    else
        self:openTextSettings()   -- reopen so the checkmark reflects the change
    end
end

-- Toggle whether the eraser may rub out typed text. Recompose so the change is
-- visible immediately on committed boxes.
function InkAwayView:toggleTextEraseProtect()
    self.text_erase_protect = not self.text_erase_protect
    self:setSetting("inkaway_text_erase_protect", self.text_erase_protect)
    self:composeCanvas(); self:renderView(); UIManager:setDirty(self, "ui")
    if not self.editing_text then self:openTextSettings() end   -- reopen to show the tick
end

-- Snap a text box's top edge onto the notebook ruling so its lines line up with
-- the printed lines (a no-op off a ruled page).
-- The ruling step (canvas px) that grid-snapped text lines up with, or nil when
-- there is nothing to snap to. A notebook uses its printed ruling; a plain
-- drawing uses the on-screen grid, but only the styles that have horizontal rows
-- (square, ruled lines, dots) -- isometric and rule-of-thirds have no rows.
function InkAwayView:textRulingStep()
    if self.notebook then
        local t = self.notebook.template
        if t and t.style and t.style ~= "blank" then return t.size or 40 end
        return nil
    end
    if self.grid_on and self.grid_size and self.grid_size > 0 then
        local s = self.grid_style or "square"
        if s == "square" or s == "lines" or s == "dots" then return self.grid_size end
    end
    return nil
end

function InkAwayView:snapTextBoxToGrid(op)
    local step = self:textRulingStep()
    if op and step and step > 0 then op.y = math.floor(op.y / step + 0.5) * step end
end

-- The font size (canvas px) to use for grid-snapped text, so one line fills one
-- ruling row and the tall letters reach up toward the line above. We aim the
-- font's ascent at ~0.90 of the ruling step, measuring the face's own ascent
-- ratio (it varies a lot between fonts) so the fill is consistent whatever font
-- and however fine the ruling.
function InkAwayView:gridBaseSize(name, rawStep)
    local probe = 100
    local face = self:faceAt(name, probe)
    local ratio = 1.0
    if face and face.ftsize then
        local _, asc = face.ftsize:getHeightAndAscender()
        if asc and asc > 0 then ratio = asc / probe end
    end
    return math.max(6, math.floor(0.90 * rawStep / ratio + 0.5))
end

-- A cached font face at a REAL pixel size. Font:getFace applies Screen DPI
-- scaling (Screen:scaleBySize) to the size it is given, so we divide by that
-- factor first to land on the actual pixel size we asked for (otherwise text is
-- ~2-3x too big on a high-dpi e-ink panel).
function InkAwayView:faceAt(name, px)
    local Font = require("ui/font")
    px = math.max(6, math.floor(px + 0.5))
    if not self._dpi_factor then
        local s = Screen.scaleBySize and (Screen:scaleBySize(1000) / 1000)
        self._dpi_factor = (s and s > 0) and s or 1
    end
    self._face_cache = self._face_cache or {}
    local key = name .. "@" .. px
    local f = self._face_cache[key]
    if not f then
        f = Font:getFace(name, math.max(6, math.floor(px / self._dpi_factor + 0.5)))
        self._face_cache[key] = f
    end
    return f
end

-- Where a digit's INK actually sits inside a TextWidget's box. A text box has empty
-- ascent/descent, so centring the box makes a run of digits look high against an
-- icon; centring the measured ink instead lines them up. Renders the digits to a
-- scratch buffer once per icon size and scans for the first/last inked row, caching
-- {mid, h} (ink centre offset from the box top, and ink height) so the notebook
-- bottom-bar counter can both centre and size itself to the icon glyphs on any font
-- or device. Falls back to box metrics if the scan is unavailable (e.g. in tests).
function InkAwayView:digitInkMetric(face, isz, box_h)
    if self._digit_ink and self._digit_ink.key == isz then return self._digit_ink end
    local res
    pcall(function()
        local TextWidget = require("ui/widget/textwidget")
        local probe = TextWidget:new{ text = "0123456789", face = face,
            fgcolor = Blitbuffer.COLOR_BLACK }
        local pw, ph = probe:getSize().w, probe:getSize().h
        if not (pw and ph and pw > 0 and ph > 0) then probe:free(); return end
        local sb = Blitbuffer.new(pw, ph, Blitbuffer.TYPE_BB8)
        sb:fill(Blitbuffer.COLOR_WHITE)
        probe:paintTo(sb, 0, 0); probe:free()
        local top, bot
        for row = 0, ph - 1 do
            local inked = false
            for col = 0, pw - 1 do
                local c = sb:getPixel(col, row)
                local v = (c and c.getColor8 and c:getColor8().a) or 255
                if v < 128 then inked = true; break end
            end
            if inked then top = top or row; bot = row end
        end
        sb:free()
        if top and bot then res = { key = isz, mid = (top + bot + 1) / 2, h = (bot - top + 1) } end
    end)
    res = res or { key = isz, mid = box_h / 2, h = math.floor(isz * 0.66) }
    self._digit_ink = res
    return res
end

-- The context the text engine uses to measure and render one op. `scale` is 1
-- for the 1:1 master bitmap and the view zoom for the crisp editing overlay.
function InkAwayView:textCtx(op, scale)
    local RenderText = require("ui/rendertext")
    scale = scale or 1
    local name = op.font or self:textFontName()
    -- Grid-line snap: when the box asks for it and the page (notebook ruling or
    -- the drawing-mode grid) has rows, the ruling step drives both the line
    -- snapping AND the font size, so one line fills one row and text never skips a
    -- line however fine the ruling is set.
    local rawStep = op.grid_snap and self:textRulingStep() or nil
    local gridStep = rawStep and rawStep * scale or nil
    local base = rawStep and self:gridBaseSize(name, rawStep) or (op.size or 32)
    local function pxOf(style) return base * ((style and style.sz) or 1) * scale end
    local function faceOf(style) return self:faceAt(name, pxOf(style)) end
    local meta = {}
    local function metaOf(style)
        local px = math.max(6, math.floor(pxOf(style) + 0.5))
        local m = meta[px]
        if not m then
            local face = self:faceAt(name, px)
            local h, asc = face.ftsize:getHeightAndAscender()
            m = { lh = math.max(math.floor(h + 0.5), math.floor(px * 1.3 + 0.5)),
                  asc = math.floor(asc + 0.5) }
            meta[px] = m
        end
        return m
    end
    return {
        gridStep = gridStep,
        measure = function(text, style)
            if not text or text == "" then return 0 end
            return RenderText:sizeUtf8Text(0, nil, faceOf(style), text, true,
                (style and style.b) or false).x
        end,
        lineHeight = function(style) return metaOf(style).lh end,
        ascent = function(style) return metaOf(style).asc end,
        bulletLabel = function(para, pi)
            if para.bullet == "number" then
                local n = 1
                for k = pi - 1, 1, -1 do
                    if op.paras[k].bullet == "number" then n = n + 1 else break end
                end
                return n .. ".  "
            end
            return "\u{2022}  "
        end,
        face = faceOf,
        bold = function(style) return (style and style.b) or false end,
    }
end

-- Lay out a text op and, if its height is automatic, grow the box to fit.
function InkAwayView:layoutText(op, scale)
    local ctx = self:textCtx(op, scale or 1)
    local lay = Text.layout(op, ctx)
    return lay, ctx
end

-- Render a text op into a canvas-space bitmap at its own position.
function InkAwayView:stampTextInto(dst, op)
    local lay, ctx = self:layoutText(op, 1)
    if op.auto_h then op.h = lay.height end
    Text.render(op, lay, dst, op.x, op.y, ctx, { color = Blitbuffer.COLOR_BLACK })
end

-- Rasterise a text op to an 8-bit level buffer (255 = untouched white, lower =
-- ink / highlight shades) at 1:1, for the exporter to composite into PNG / JPEG
-- / PDF. Returns (uint8 buffer, w, h).
function InkAwayView:exportTextRaster(op)
    local ffi = require("ffi")
    local lay, ctx = self:layoutText(op, 1)
    local w = math.max(1, math.floor(op.w + 0.5))
    local h = math.max(1, math.floor((op.auto_h and lay.height or op.h) + 0.5))
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(Blitbuffer.COLOR_WHITE)
    Text.render(op, lay, bb, 0, 0, ctx, { color = Blitbuffer.COLOR_BLACK })
    local out = ffi.new("uint8_t[?]", w * h)
    local data = ffi.cast("uint8_t*", bb.data)
    local stride = bb.stride or w
    for py = 0, h - 1 do
        local srow, drow = py * stride, py * w
        for px = 0, w - 1 do out[drow + px] = data[srow + px] end
    end
    bb:free()
    return out, w, h
end

-- Compose a page into `dst` (a canvas-sized bitmap): white paper, optional
-- background picture, notebook ruling, then the ink ops. Shared by the live
-- master bitmap and by the page-overview thumbnails, so a thumbnail always
-- matches exactly what the page looks like.
-- `reveal_resolved` = the caller already ran the reveal-buffer detection (via
-- buildRevealPic/buildRevealText) and the reveal_pic/reveal_text it passed are
-- authoritative (nil means "not needed"). composeCanvas sets it so composeInto
-- skips two redundant full-ops scans; the thumbnail path leaves it off so
-- composeInto detects and builds its own reveal buffers.
function InkAwayView:composeInto(dst, ops, bg_bb, template, reveal_text, reveal_pic, reveal_resolved)
    local W, H = self.view.canvas_w, self.view.canvas_h
    dst:paintRect(0, 0, W, H, WHITE)
    if bg_bb then dst:blitFrom(bg_bb, 0, 0, 0, 0, W, H) end
    if template and template.style and template.style ~= "blank" then
        local lvl = strengthToLevel(template.strength)
        local put = spanWriter(dst, W, H, Blitbuffer.ColorRGB32(lvl, lvl, lvl, 0xFF), nil)
        Template.render(template.style, W, H, template.size or 40, put)
    end
    -- reveal_pic = the plain page with placed images stamped on it, so a soft erase
    -- keeps the images (like it keeps the background). Built here from these ops
    -- when the caller did not pass one (e.g. page thumbnails), so it is always
    -- correct for whatever is being composed. dst currently holds the plain base.
    local owns_rp = false
    if not reveal_resolved and not reveal_pic then
        local has_img, has_soft = false, false
        for _, op in ipairs(ops) do
            if not op.hidden then
                if op.kind == "image" then has_img = true
                elseif op.kind == "erase" and not op.ebg then has_soft = true end
            end
        end
        if has_img and has_soft then
            reveal_pic = Blitbuffer.new(W, H, dst:getType())
            reveal_pic:blitFrom(dst, 0, 0, 0, 0, W, H)
            for _, op in ipairs(ops) do
                if not op.hidden and op.kind == "image" then self:blitImageInto(reveal_pic, op) end
            end
            owns_rp = true
        end
    end
    -- A text-protecting erase op (op.spare_text) reveals a copy of the page that
    -- INCLUDES the text (built once here if the caller didn't pass it), so it rubs
    -- out ink but leaves text; a normal erase reveals the plain page and removes
    -- both. Whether an erase spares text is baked into the op at draw time, so the
    -- setting is never retroactive. dst currently holds the plain base (paper /
    -- background / ruling), so a copy of it now is exactly the plain reveal.
    local owns_rt = false
    if not reveal_resolved and not reveal_text then
        local has_text, has_spare = false, false
        for _, op in ipairs(ops) do
            if not op.hidden then
                if op.kind == "text" then has_text = true
                elseif op.kind == "erase" and op.spare_text then has_spare = true end
            end
        end
        if has_text and has_spare then
            reveal_text = Blitbuffer.new(W, H, dst:getType())
            reveal_text:blitFrom(reveal_pic or dst, 0, 0, 0, 0, W, H)   -- keep images under it too
            for _, op in ipairs(ops) do
                if not op.hidden and op.kind == "text" then self:stampTextInto(reveal_text, op) end
            end
            owns_rt = true
        end
    end
    local refx, refy = Symmetry.canvasRefs(W, H)
    -- Only skip the selected image from the master while it is actively being
    -- dragged or rotated (then it is drawn live as the overlay). A merely selected,
    -- still image stays in the master so it renders through the exact same path as
    -- everything else -- no sub-pixel jump when it is picked or dropped.
    local dragging = (self._img_drag and self._img_drag.began) or self.image_rotating
    local skip = dragging and self.active_image and self.active_image.op or nil
    for _, op in ipairs(ops) do
        if not op.hidden and op ~= skip then   -- a shape being rotated is a preview
            if op.kind == "text" then
                self:stampTextInto(dst, op)   -- glyphs, drawn straight into dst (z-order)
            elseif op.kind == "image" then
                self:blitImageInto(dst, op)   -- placed picture, alpha-blended (z-order)
            else
                local put, fill_put
                if op.kind == "erase" and op.spare_text and reveal_text then
                    put = bgSpanWriter(dst, reveal_text, W, H, nil)  -- reveal page + text (+ images)
                elseif op.kind == "erase" and not op.ebg and (reveal_pic or bg_bb) then
                    put = bgSpanWriter(dst, reveal_pic or bg_bb, W, H, nil)  -- reveal page (+ images)
                else
                    put = spanWriter(dst, W, H, self:opColor(op), nil)
                end
                if op.kind == "shape" and op.fill_color and not op.fill then
                    fill_put = Symmetry.wrap(
                        spanWriter(dst, W, H, displayColor(op.fill_color, op.fill_alpha or 255), nil),
                        op.sym, refx, refy)
                end
                Export.paintGeom(op, Symmetry.wrap(put, op.sym, refx, refy), fill_put)
            end
        end
    end
    if owns_rt then reveal_text:free() end
    if owns_rp then reveal_pic:free() end
end

-- The buffer the eraser reveals under the ink: in a notebook that is the paper
-- (colour + ruling + any PDF page), so erasing takes away ink but leaves the
-- ruling -- just like the drawing-mode grid, which the eraser also can't touch.
-- In plain drawing mode it is the optional background image (or nil = white).
function InkAwayView:eraseRevealBB()
    -- while protection is on, a live erase stroke spares text, so it reveals the
    -- page-with-text buffer; otherwise it reveals the plain page
    if self.text_erase_protect and self._reveal_text_bb then return self._reveal_text_bb end
    if self._reveal_pic_bb then return self._reveal_pic_bb end   -- keep placed images under a soft erase
    if self.notebook then return self._paper_bb end
    return self.bg_bb
end

-- Keep `_reveal_text_bb` (the plain page with the committed text stamped on top)
-- for the eraser to reveal when it must spare text -- for the live stroke and for
-- protecting erase ops. Built only when some erase spares text (or protection is
-- on, so the next stroke will) and text exists; freed otherwise.
function InkAwayView:buildRevealText(base_bb)
    if not self.canvas_bb then return end
    local has_text, has_spare = false, false
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden then
            if op.kind == "text" then has_text = true
            elseif op.kind == "erase" and op.spare_text then has_spare = true end
        end
    end
    if not (has_text and (self.text_erase_protect or has_spare)) then
        if self._reveal_text_bb then self._reveal_text_bb:free(); self._reveal_text_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._reveal_text_bb and (self._reveal_text_bb:getWidth() ~= W or self._reveal_text_bb:getHeight() ~= H) then
        self._reveal_text_bb:free(); self._reveal_text_bb = nil
    end
    if not self._reveal_text_bb then
        self._reveal_text_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    local rt = self._reveal_text_bb
    if base_bb then rt:blitFrom(base_bb, 0, 0, 0, 0, W, H) else rt:paintRect(0, 0, W, H, WHITE) end
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden and op.kind == "text" then self:stampTextInto(rt, op) end
    end
end

-- Keep `_reveal_pic_bb` = the plain page (background / paper) with the placed
-- images stamped on it, so a soft eraser (the "Erase pictures" toggle off) rubs
-- out ink but reveals the images beneath instead of whitening them. Built only
-- when an image exists; freed otherwise.
function InkAwayView:buildRevealPic(base_bb)
    if not self.canvas_bb then return end
    local has_img = false
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden and op.kind == "image" then has_img = true; break end
    end
    if not has_img then
        if self._reveal_pic_bb then self._reveal_pic_bb:free(); self._reveal_pic_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._reveal_pic_bb and (self._reveal_pic_bb:getWidth() ~= W or self._reveal_pic_bb:getHeight() ~= H) then
        self._reveal_pic_bb:free(); self._reveal_pic_bb = nil
    end
    if not self._reveal_pic_bb then
        self._reveal_pic_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    local rp = self._reveal_pic_bb
    if base_bb then rp:blitFrom(base_bb, 0, 0, 0, 0, W, H) else rp:paintRect(0, 0, W, H, WHITE) end
    for _, op in ipairs(self.canvas.ops) do
        if not op.hidden and op.kind == "image" then self:blitImageInto(rp, op) end
    end
end

-- Build (once per compose) the notebook paper: paper colour or PDF page, then the
-- ruling on top. Kept as its own buffer so the eraser can restore it.
function InkAwayView:buildNotebookPaper()
    if not (self.notebook and self.canvas_bb) then
        if self._paper_bb then self._paper_bb:free(); self._paper_bb = nil end
        return
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._paper_bb and (self._paper_bb:getWidth() ~= W or self._paper_bb:getHeight() ~= H) then
        self._paper_bb:free(); self._paper_bb = nil
    end
    if not self._paper_bb then
        self._paper_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
    end
    local pb, tmpl = self._paper_bb, self.notebook.template
    if self.bg_bb then
        pb:blitFrom(self.bg_bb, 0, 0, 0, 0, W, H)
    else
        local col = WHITE
        local paper = tmpl and tmpl.paper
        if paper then col = Blitbuffer.ColorRGB32(paper[1], paper[2], paper[3], 0xFF) end
        pb:paintRect(0, 0, W, H, col)
    end
    if tmpl and tmpl.style and tmpl.style ~= "blank" then
        local lvl = strengthToLevel(tmpl.strength)
        local put = spanWriter(pb, W, H, Blitbuffer.ColorRGB32(lvl, lvl, lvl, 0xFF), nil)
        Template.render(tmpl.style, W, H, tmpl.size or 40, put)
    end
end

-- Rebuild the 1:1 master bitmap from the committed ops. Cost is proportional to
-- the ink drawn, not the zoom, and it only runs on open, undo, clear, or resize.
function InkAwayView:composeCanvas()
    if not self.canvas_bb then return end
    if self.notebook then
        -- paper (with ruling) is the base AND the erase-reveal source, so ruling
        -- lives under the ink and the eraser restores it instead of whitening it
        self:buildNotebookPaper()
        self:buildRevealPic(self._paper_bb)
        self:buildRevealText(self._reveal_pic_bb or self._paper_bb)   -- text reveal keeps images too
        self:composeInto(self.canvas_bb, self.canvas.ops, self._paper_bb, nil,
            self._reveal_text_bb, self._reveal_pic_bb, true)   -- reveal buffers already resolved
    else
        self:buildRevealPic(self.bg_bb)
        self:buildRevealText(self._reveal_pic_bb or self.bg_bb)
        self:composeInto(self.canvas_bb, self.canvas.ops, self.bg_bb, nil,
            self._reveal_text_bb, self._reveal_pic_bb, true)   -- reveal buffers already resolved
    end
end

-- Rebuild what is on screen from the master bitmap: take the visible crop of
-- canvas_bb (a zero-copy viewport) and scale it into area_bb with mupdf's fast
-- C scaler. This is the whole reason zoom and pan are cheap: the work is a
-- single scale of one screenful, whatever the zoom or the amount of ink.
function InkAwayView:renderView()
    if not (self.area_bb and self.canvas_bb) then return end
    self._blit_rect = nil   -- the whole area_bb is rebuilt; paintTo must blit it all
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h

    -- visible crop of the canvas, clamped inside it
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local sw = math.max(1, math.min(W - sx, math.ceil(v.area_w / v.zoom)))
    local sh = math.max(1, math.min(H - sy, math.ceil(v.area_h / v.zoom)))

    local dw = math.max(1, math.floor(sw * v.zoom))
    local dh = math.max(1, math.floor(sh * v.zoom))
    -- where that crop lands in the area: a positive margin when the whole page
    -- fits (letterbox), or a sub-pixel nudge when zoomed in, which we clamp to
    -- the area and trim so the blit always stays in bounds
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    local bw = math.min(dw, v.area_w - ox)
    local bh = math.min(dh, v.area_h - oy)
    -- Clear to white only what the blit will NOT cover: the letterbox margin when
    -- the whole page fits, or a trimmed edge. When the blit fills the area (the
    -- common case when zoomed in and panning), skip the full-area clear entirely
    -- -- that saves one screenful memset per pan frame.
    if ox > 0 or oy > 0 or bw < v.area_w or bh < v.area_h then
        self.area_bb:paintRect(0, 0, v.area_w, v.area_h, WHITE)
    end
    if bw < 1 or bh < 1 then return end

    local sub = self.canvas_bb:viewport(sx, sy, sw, sh)     -- shares memory
    local scaled = RenderImage:scaleBlitBuffer(sub, dw, dh, false)
    self.area_bb:blitFrom(scaled, ox, oy, 0, 0, bw, bh)
    if scaled ~= sub and scaled.free then scaled:free() end
    -- The grid is NOT drawn here: it is a paint-time overlay (see drawGrid), so
    -- it never lives in area_bb, the eraser can never rub it out, and it never
    -- reaches the export (which is rebuilt from the ops, not from any buffer).
end

-- Re-render just an area-local sub-rectangle from the master, the same way
-- renderView does for the whole screen but scaling ONLY the touched region. The
-- soft eraser uses this so it can update the screen along its path without a
-- full-screen crop-scale on every point (which made erasing heavy).
function InkAwayView:renderViewRect(cx0, cy0, cx1, cy1)
    if not (self.area_bb and self.canvas_bb) then return end
    local v = self.view
    local W, H = v.canvas_w, v.canvas_h
    cx0 = math.max(0, math.floor(cx0)); cy0 = math.max(0, math.floor(cy0))
    cx1 = math.min(v.area_w, math.ceil(cx1)); cy1 = math.min(v.area_h, math.ceil(cy1))
    if cx1 <= cx0 or cy1 <= cy0 then return end
    -- same visible-crop origin + landing offset as renderView
    local sx = math.max(0, math.min(W - 1, math.floor(v.pan_x)))
    local sy = math.max(0, math.min(H - 1, math.floor(v.pan_y)))
    local ox = math.max(0, math.floor((sx - v.pan_x) * v.zoom))
    local oy = math.max(0, math.floor((sy - v.pan_y) * v.zoom))
    -- map the requested area rect back to canvas source pixels
    local scx0 = math.max(0, math.min(W, sx + math.floor((cx0 - ox) / v.zoom)))
    local scy0 = math.max(0, math.min(H, sy + math.floor((cy0 - oy) / v.zoom)))
    local scx1 = math.max(0, math.min(W, sx + math.ceil((cx1 - ox) / v.zoom)))
    local scy1 = math.max(0, math.min(H, sy + math.ceil((cy1 - oy) / v.zoom)))
    local sw, sh = scx1 - scx0, scy1 - scy0
    if sw < 1 or sh < 1 then return end
    -- destination aligned to the canvas source we grabbed
    local dx = ox + math.floor((scx0 - sx) * v.zoom)
    local dy = oy + math.floor((scy0 - sy) * v.zoom)
    local dw = math.max(1, math.floor(sw * v.zoom))
    local dh = math.max(1, math.floor(sh * v.zoom))
    local bw = math.min(dw, v.area_w - dx)
    local bh = math.min(dh, v.area_h - dy)
    if bw < 1 or bh < 1 then return end
    self.area_bb:paintRect(dx, dy, bw, bh, WHITE)
    local sub = self.canvas_bb:viewport(scx0, scy0, sw, sh)
    local scaled = RenderImage:scaleBlitBuffer(sub, dw, dh, false)
    self.area_bb:blitFrom(scaled, dx, dy, 0, 0, bw, bh)
    if scaled ~= sub and scaled.free then scaled:free() end
end

-- A thin line into `bb` at screen offset (ox,oy), clipped to the drawing area.
function InkAwayView:gridLine(bb, ox, oy, x0, y0, x1, y1, color)
    local aw, ah = self.view.area_w, self.view.area_h
    local dx, dy = x1 - x0, y1 - y0
    local steps = math.max(math.abs(dx), math.abs(dy))
    if steps < 1 then return end
    local ix, iy = dx / steps, dy / steps
    local x, y = x0, y0
    for _ = 0, steps do
        local px, py = math.floor(x + 0.5), math.floor(y + 0.5)
        if px >= 0 and px < aw and py >= 0 and py < ah then bb:paintRect(ox + px, oy + py, 1, 1, color) end
        x = x + ix; y = y + iy
    end
end

-- Draw the current grid style into `bb` at screen offset (ox,oy). Display only:
-- painted onto the screen buffer each frame, never baked into area_bb, so the
-- eraser leaves it alone and it stays out of the saved PNG or JPEG.
function InkAwayView:drawGrid(bb, ox, oy)
    local v = self.view
    local aw, ah = v.area_w, v.area_h
    local g = self.grid_size
    local style = self.grid_style or "square"
    -- strength 1..100 maps to a grey: faint at low values, solid black at 100,
    -- so the reader can make the grid a light guide or as dark as drawn ink
    local lvl = strengthToLevel(self.grid_strength)
    local col = Blitbuffer.ColorRGB32(lvl, lvl, lvl, 0xFF)
    local function ax(cx) return (cx - v.pan_x) * v.zoom end
    local function ay(cy) return (cy - v.pan_y) * v.zoom end
    -- paint a rect given in area coords, clipped to the area and then offset
    local function rect(px, py, w, h, c)
        if px < 0 then w = w + px; px = 0 end
        if py < 0 then h = h + py; py = 0 end
        if px + w > aw then w = aw - px end
        if py + h > ah then h = ah - py end
        if w > 0 and h > 0 then bb:paintRect(ox + px, oy + py, w, h, c) end
    end

    if style == "thirds" then
        -- rule of thirds over the page rectangle
        for i = 1, 2 do
            local x = ax(v.canvas_w * i / 3)
            if x >= 0 and x < aw then rect(math.floor(x), 0, 1, ah, col) end
            local y = ay(v.canvas_h * i / 3)
            if y >= 0 and y < ah then rect(0, math.floor(y), aw, 1, col) end
        end
        return
    end

    if not g or g <= 0 then return end

    if style == "lines" then                       -- ruled horizontal lines
        local cy = 0
        while cy <= v.canvas_h do
            local y = math.floor(ay(cy))
            if y >= 0 and y < ah then rect(0, y, aw, 1, col) end
            cy = cy + g
        end
    elseif style == "dots" then                     -- a dot at each intersection
        local dot = math.max(3, math.floor(Screen:scaleBySize(3)))
        local dcol = col                              -- follow the grid strength
        local cy = 0
        while cy <= v.canvas_h do
            local y = math.floor(ay(cy)) - math.floor(dot / 2)
            if y + dot >= 0 and y < ah then
                local cx = 0
                while cx <= v.canvas_w do
                    local x = math.floor(ax(cx)) - math.floor(dot / 2)
                    if x >= 0 and x + dot <= aw and y >= 0 and y + dot <= ah then
                        rect(x, y, dot, dot, dcol)
                    end
                    cx = cx + g
                end
            end
            cy = cy + g
        end
    elseif style == "iso" then                      -- isometric: verticals + 30 deg diagonals
        local cx = 0
        while cx <= v.canvas_w do
            local x = ax(cx)
            if x >= 0 and x < aw then rect(math.floor(x), 0, 1, ah, col) end
            cx = cx + g
        end
        local slope = math.tan(math.rad(30))
        local spacing = g / math.cos(math.rad(30))
        -- two diagonal families, offset so they cover the whole area
        local start = -math.ceil(ah * slope / spacing) * spacing
        local b = start
        while b <= v.canvas_w * v.zoom + ah do
            self:gridLine(bb, ox, oy, ax(0) + b, 0, ax(0) + b + ah * slope, ah, col)   -- down-right
            self:gridLine(bb, ox, oy, ax(0) + b, ah, ax(0) + b + ah * slope, 0, col)   -- up-right
            b = b + spacing * v.zoom
        end
    else                                            -- "square"
        local cx = 0
        while cx <= v.canvas_w do
            local x = math.floor(ax(cx))
            if x >= 0 and x < aw then rect(x, 0, 1, ah, col) end
            cx = cx + g
        end
        local cy = 0
        while cy <= v.canvas_h do
            local y = math.floor(ay(cy))
            if y >= 0 and y < ah then rect(0, y, aw, 1, col) end
            cy = cy + g
        end
    end
end

------------------------------------------------------------------------------
-- Drawing gesture handlers
------------------------------------------------------------------------------

-- Current live ink colour and width, from the active tool.
function InkAwayView:liveColor()
    if self.tool == "erase" then return WHITE end
    return displayColor(self.pen_color, self.pen_alpha)
end
function InkAwayView:liveWidth()
    return (self.tool == "erase") and self.eraser_width or self.pen_width
end

-- Build the reusable per-stroke drawing writers ONCE (called from beginStroke) so
-- the per-point path (stampLive) allocates almost nothing. Colour, width, brush
-- style and symmetry are fixed for the whole stroke, so the span writers, the
-- symmetry-combining wrapper and the raster dispatcher never need rebuilding per
-- point -- rebuilding them ~18x/point under quad symmetry was the GC thrash that
-- made fast drawing with symmetry stutter (and never fully recover).
function InkAwayView:setupLiveWriters()
    local color = self:liveColor()
    local style = (self.tool ~= "erase") and self.pen_style or nil
    local st = style and Raster.STYLES[style]
    local textured = st and not st.solid
    local seed = self.live_seed or 0
    self._lw_stroke = function(seg, r, put)
        if textured then Raster.pathTex(seg, r, put, st, seed) else Raster.path(seg, r, put) end
    end
    -- remember which buffers these writers target, so stampLive can rebuild them if
    -- a relayout/rotation reallocated a buffer mid-interaction (else the writers
    -- would poke a freed buffer)
    self._lw_area_bb, self._lw_canvas_bb = self.area_bb, self.canvas_bb
    self._lw_acc = self._lw_acc or { x0 = 0, y0 = 0, x1 = 0, y1 = 0 }
    -- reused 4-slot segment tables (master + on-screen), so a continuing stroke
    -- allocates no per-point segment garbage; Raster.path reads them synchronously
    self._lw_seg_c = self._lw_seg_c or { 0, 0, 0, 0 }
    self._lw_seg_a = self._lw_seg_a or { 0, 0, 0, 0 }
    local sym = self.symmetry
    -- master (1:1) writer
    local v = self.view
    local cput = spanWriter(self.canvas_bb, v.canvas_w, v.canvas_h, color, nil)
    if sym and sym ~= "off" then
        local crefx, crefy = Symmetry.canvasRefs(v.canvas_w, v.canvas_h)
        cput = Symmetry.wrap(cput, sym, crefx, crefy)
    end
    self._lw_cput = cput
    -- on-screen writer, accumulating the base bbox into the reused acc table; the
    -- mirror images are painted through a writer that does NOT grow acc, so the
    -- refresh stays a few small rects (one per image) rather than one giant box.
    local baseput = spanWriter(self.area_bb, v.area_w, v.area_h, color, self._lw_acc)
    local aput = baseput
    if sym and sym ~= "off" then
        local arefx, arefy = Symmetry.areaRefs(v)
        local mirror = spanWriter(self.area_bb, v.area_w, v.area_h, color, nil)
        local mx, my = Symmetry.mirrorsX(sym), Symmetry.mirrorsY(sym)
        aput = function(x, y, len)
            baseput(x, y, len)
            if mx then mirror(arefx(x, len), y, len) end
            if my then mirror(x, arefy(y), len) end
            if mx and my then mirror(arefx(x, len), arefy(y), len) end
        end
    end
    self._lw_aput = aput
end

-- Stamp the live segment ending at canvas point (cx,cy) into BOTH buffers: the
-- 1:1 master (so a later zoom/pan re-render is correct) and the on-screen buffer
-- at the current zoom (so drawing feels immediate). Only the on-screen dirty
-- rectangle is refreshed. `fresh` starts a new segment with no line back.
-- The eraser, when set to leave the background, restores the background image
-- along its path in the master and re-renders the affected area, so erasing
-- takes away your ink but the picture underneath shows through (matching what a
-- background-keeping export produces).
function InkAwayView:stampEraseRestore(cx, cy, fresh)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local r = self.eraser_width / 2
    local px, py = self.last_cx, self.last_cy
    local put = bgSpanWriter(self.canvas_bb, self:eraseRevealBB(), W, H, nil)
    if self.symmetry ~= "off" then
        local rx, ry = Symmetry.canvasRefs(W, H)
        put = Symmetry.wrap(put, self.symmetry, rx, ry)
    end
    if px and not fresh then
        Raster.path({ px, py, cx, cy }, r, put)
    else
        Raster.path({ cx, cy }, r, put)
    end
    self.last_cx, self.last_cy = cx, cy
    local zr = r * self.view.zoom + 2
    local ax0, ay0 = self:toAreaLocal(px or cx, py or cy)
    local ax1, ay1 = self:toAreaLocal(cx, cy)
    local acc = {
        x0 = math.min(ax0, ax1) - zr, y0 = math.min(ay0, ay1) - zr,
        x1 = math.max(ax0, ax1) + zr, y1 = math.max(ay0, ay1) + zr,
    }
    local sr = self._stroke_rect
    if not sr then
        self._stroke_rect = { x0 = acc.x0, y0 = acc.y0, x1 = acc.x1, y1 = acc.y1 }
    else
        if acc.x0 < sr.x0 then sr.x0 = acc.x0 end
        if acc.y0 < sr.y0 then sr.y0 = acc.y0 end
        if acc.x1 > sr.x1 then sr.x1 = acc.x1 end
        if acc.y1 > sr.y1 then sr.y1 = acc.y1 end
    end
    -- Re-render only the touched region (base + each mirror) from the restored
    -- master, instead of a full-screen crop-scale on every point.
    local rects, nr = self:symAreaRects(acc)
    for i = 1, nr do
        local rr = rects[i]
        self:renderViewRect(rr.x0, rr.y0, rr.x1, rr.y1)
        self:dirtyAreaRect(self._live_mode or "fast", rr, 1)
    end
end

function InkAwayView:stampLive(cx, cy, fresh)
    if self.tool == "erase" and not self.erase_bg and self:eraseRevealBB() then
        return self:stampEraseRestore(cx, cy, fresh)
    end
    -- writers were built once in beginStroke (setupLiveWriters); rebuild them if
    -- missing or if a buffer was reallocated since (relayout/rotation), so we never
    -- draw into a freed buffer.
    if not self._lw_stroke or self._lw_area_bb ~= self.area_bb
            or self._lw_canvas_bb ~= self.canvas_bb then
        self:setupLiveWriters()
    end
    local width = self:liveWidth()
    local strokeFn = self._lw_stroke

    -- master, at 1:1
    if self.canvas_bb then
        if self.last_cx and not fresh then
            local seg = self._lw_seg_c
            seg[1], seg[2], seg[3], seg[4] = self.last_cx, self.last_cy, cx, cy
            strokeFn(seg, width / 2, self._lw_cput)
        else
            strokeFn({ cx, cy }, width / 2, self._lw_cput)
        end
        self.last_cx, self.last_cy = cx, cy
    end

    -- on screen, at the current zoom. The reused `acc` table tracks only the base
    -- image (reset each point); the mirror images paint through a writer that does
    -- NOT grow acc, so the refresh stays a few small rects (one per image).
    local ax, ay = self:toAreaLocal(cx, cy)
    local acc = self._lw_acc
    acc.x0, acc.y0, acc.x1, acc.y1 = math.huge, math.huge, -math.huge, -math.huge
    if self.last_ax and not fresh then
        local seg = self._lw_seg_a
        seg[1], seg[2], seg[3], seg[4] = self.last_ax, self.last_ay, ax, ay
        strokeFn(seg, (width * self.view.zoom) / 2, self._lw_aput)
    else
        strokeFn({ ax, ay }, (width * self.view.zoom) / 2, self._lw_aput)
    end
    self.last_ax, self.last_ay = ax, ay
    if acc.x1 >= acc.x0 then
        -- grow the whole-stroke (base) bbox for a tidy refresh at the end
        local sr = self._stroke_rect
        if not sr then
            self._stroke_rect = { x0 = acc.x0, y0 = acc.y0, x1 = acc.x1, y1 = acc.y1 }
        else
            if acc.x0 < sr.x0 then sr.x0 = acc.x0 end
            if acc.y0 < sr.y0 then sr.y0 = acc.y0 end
            if acc.x1 > sr.x1 then sr.x1 = acc.x1 end
            if acc.y1 > sr.y1 then sr.y1 = acc.y1 end
        end
        local rects, nr = self:symAreaRects(acc)
        for i = 1, nr do
            self:dirtyAreaRect(self._live_mode or "fast", rects[i], 1)
        end
    end
end

-- Add a screen point to the live stroke (kept in canvas coords) and draw it.
-- The stabilizer smooths the finger's path toward a trailing point, so wobble
-- becomes a clean line; strength 0 draws the raw point.
function InkAwayView:addScreenPoint(sx, sy, fresh)
    local cx, cy = self:toCanvasClamped(sx, sy)
    if fresh then
        self.sm_x, self.sm_y = cx, cy
    else
        local a = InkGeom.stabilizerAlpha(self.stabilizer)
        self.sm_x, self.sm_y = InkGeom.ema(self.sm_x, self.sm_y, cx, cy, a)
        cx, cy = self.sm_x, self.sm_y
    end
    self.canvas:addPoint(cx, cy)
    self:stampLive(cx, cy, fresh)
end

function InkAwayView:beginStroke(sx, sy)
    local is_erase = self.tool == "erase"
    self.live_seed = math.random(1, 1000000)
    local style = nil
    if not is_erase then style = self.pen_style end
    -- Live-refresh waveform, chosen once for the whole stroke. The "fast" (A2/DU)
    -- waveform is 1-bit black/white: it shows opaque BLACK solid ink instantly, but
    -- it physically cannot render grey/colour/low-opacity ink, so such a stroke
    -- looks wrong (or invisible) mid-draw and only snaps in on the "ui" settle at
    -- lift -- which is exactly why grey/white pens felt slow. Use "fast" only for a
    -- solid, fully-opaque, pure-black pen; everything else draws under grey-capable
    -- "ui" so it appears in the right shade as you draw.
    if is_erase then
        -- "fast" (A2/DU) is 1-bit black/white, so it can only show white. That is
        -- fine when the eraser reveals plain white (a blank drawing page), but in a
        -- notebook it reveals the grey ruling, and over a background image it reveals
        -- that picture -- neither of which A2 can render, so the erased path flashes
        -- to white and (on colour panels especially) does not settle back to the
        -- revealed shade. Use the grey-capable "ui" waveform whenever the reveal is
        -- non-white; keep the snappy "fast" erase only for the blank-white case.
        self._live_mode = self:eraseRevealBB() and "ui" or "fast"
    else
        local c = self.pen_color
        local solid = (style == nil) or (Raster.STYLES[style] and Raster.STYLES[style].solid)
        self._live_mode = (self.pen_alpha >= 255 and solid and c
            and c[1] == 0 and c[2] == 0 and c[3] == 0) and "fast" or "ui"
    end
    self.canvas:startStroke(is_erase and "erase" or "ink",
        self:liveWidth(), self.pen_alpha, self.pen_color, style, self.live_seed)
    if self.symmetry ~= "off" and self.canvas.live then self.canvas.live.sym = self.symmetry end
    -- a "hard" erase also removes the background; the soft default leaves it
    if is_erase and self.erase_bg and self.canvas.live then self.canvas.live.ebg = true end
    self.capturing = true
    self.pending_lift = nil
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    self._stroke_rect = nil
    -- Shape assist may rewrite this stroke into a clean shape on lift, which means
    -- rebuilding the master. Snapshot the pre-stroke master now so beautify can
    -- restore just the stroke's footprint instead of replaying every op (which got
    -- progressively slower as a drawing filled up). Only when it might actually
    -- run: a pen stroke with shape assist on.
    self._pre_stroke_valid = false
    if self.shape_assist and not is_erase and self.canvas_bb then
        local W, H = self.view.canvas_w, self.view.canvas_h
        if self._pre_stroke_bb and (self._pre_stroke_bb:getWidth() ~= W
                or self._pre_stroke_bb:getHeight() ~= H) then
            self._pre_stroke_bb:free(); self._pre_stroke_bb = nil
        end
        if not self._pre_stroke_bb then
            self._pre_stroke_bb = Blitbuffer.new(W, H, self.canvas_bb:getType())
        end
        self._pre_stroke_bb:blitFrom(self.canvas_bb, 0, 0, 0, 0, W, H)
        self._pre_stroke_valid = true
    end
    self:setupLiveWriters()        -- build the reusable per-stroke writers once
    self:addScreenPoint(sx, sy, true)
end

-- Provisional lift: hold the stroke open briefly (COALESCE_SEC) in case the
-- panel dropped the contact and it is about to come back nearby.
function InkAwayView:scheduleFinalize(sx, sy)
    self.pending_lift = { x = sx, y = sy }
    UIManager:unschedule(self._finalize)
    UIManager:scheduleIn(COALESCE_SEC, self._finalize)
end

-- Commit the live stroke as one op. Called by the coalesce timer, or eagerly
-- via flushPending() before any action that must see a consistent model.
-- Shape assist: try to replace a just-committed freehand ink op with a clean
-- shape recognised from its raw path `raw`. `committed` is the ink op (already
-- at the end of the ops list). Returns true if it swapped one in. The swap
-- reuses the single history entry finishStroke pushed, so it is one undo step,
-- and the master is recomposed so the freehand ink is replaced by the shape.
function InkAwayView:beautifyStroke(raw, committed)
    -- Threshold in canvas px, scaled by zoom so "~20 screen px of travel" is the
    -- floor whether zoomed in or out (canvas px shrink as you zoom in).
    local zoom = (self.view and self.view.zoom) or 1
    local min_size = Screen:scaleBySize(20) / (zoom > 0 and zoom or 1)
    local pts, shape = Recognize.detect(raw, { min_size = min_size })
    if not pts then return false end
    if shape then
        -- The stroke reads as a toolbar primitive (line / rectangle / ellipse /
        -- triangle): turn the ink op INTO a real shape op, in place, so tapping or
        -- holding it later brings up the very same edit menu as a shape drawn from
        -- the toolbar. It keeps the pen's width, colour, opacity and symmetry.
        -- Still one op, so it remains a single undo step.
        committed.kind = "shape"
        committed.shape = shape.shape
        committed.pts = shape.pts
        committed.closed = shape.closed
        committed.fill = false
        committed.angle = 0
        committed.style, committed.seed = nil, nil   -- ink-only fields; a shape ignores them
    else
        -- A straightened but non-primitive path (an L bend, a general polygon):
        -- keep the SAME ink op and only swap its points, so the clean path is drawn
        -- with the very brush the user was using.
        committed.pts = pts
    end
    self.dirty = true
    -- Rebuild the master WITHOUT replaying every op when we can (see below); only
    -- fall back to a full composeCanvas when the snapshot is unusable.
    if not self:beautifyRecompose(raw, committed) then
        self:composeCanvas()
    end
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

-- Rebuild the master after shape assist swapped a stroke, without a whole-canvas
-- replay. beginStroke snapshotted the pre-stroke master; restore just the raw
-- stroke's footprint (and each symmetry mirror of it) from that snapshot to wipe
-- the old wobbly ink, then stamp the clean op back on top. The result is pixel
-- identical to composeCanvas but costs O(stroke area) instead of O(number of
-- ops), which is what made a filling-up drawing get slower per stroke. Returns
-- false (caller runs the full composeCanvas) when the snapshot cannot be used.
function InkAwayView:beautifyRecompose(raw, committed)
    if not (self._pre_stroke_valid and self._pre_stroke_bb and self.canvas_bb) then
        return false
    end
    local W, H = self.view.canvas_w, self.view.canvas_h
    if self._pre_stroke_bb:getWidth() ~= W or self._pre_stroke_bb:getHeight() ~= H then
        return false
    end
    -- footprint (canvas px) of the OLD raw ink and the NEW clean op together
    local hw = (committed.width or self.pen_width or 1) / 2 + 2
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local function grow(pts)
        if not pts then return end
        for i = 1, #pts - 1, 2 do
            local px, py = pts[i], pts[i + 1]
            if px < x0 then x0 = px end
            if px > x1 then x1 = px end
            if py < y0 then y0 = py end
            if py > y1 then y1 = py end
        end
    end
    grow(raw)
    grow(committed.pts)
    if x1 < x0 or y1 < y0 then return false end
    local base = {
        x0 = math.max(0, math.floor(x0 - hw)),
        y0 = math.max(0, math.floor(y0 - hw)),
        x1 = math.min(W, math.ceil(x1 + hw)),
        y1 = math.min(H, math.ceil(y1 + hw)),
    }
    -- the raw ink was mirrored into the master under symmetry, so restore every
    -- mirror of the footprint too (exact pixel reflection in canvas space)
    local rects = { base }
    local sym = committed.sym
    if sym and sym ~= "off" then
        local mx, my = Symmetry.mirrorsX(sym), Symmetry.mirrorsY(sym)
        local function flipX(r) return { x0 = W - r.x1, y0 = r.y0, x1 = W - r.x0, y1 = r.y1 } end
        local function flipY(r) return { x0 = r.x0, y0 = H - r.y1, x1 = r.x1, y1 = H - r.y0 } end
        if mx then rects[#rects + 1] = flipX(base) end
        if my then rects[#rects + 1] = flipY(base) end
        if mx and my then rects[#rects + 1] = flipY(flipX(base)) end
    end
    for _, r in ipairs(rects) do
        local w, h = r.x1 - r.x0, r.y1 - r.y0
        if w > 0 and h > 0 then
            self.canvas_bb:blitFrom(self._pre_stroke_bb, r.x0, r.y0, r.x0, r.y0, w, h)
        end
    end
    self:stampOpIntoCanvas(committed)   -- draw the clean op (all mirrors) back on top
    self._pre_stroke_valid = false      -- snapshot consumed; a stale reuse would be wrong
    return true
end

function InkAwayView:finalizeStroke()
    if not self.capturing then return end
    UIManager:unschedule(self._finalize)
    self.pending_lift = nil
    self.capturing = false
    self.last_ax, self.last_ay = nil, nil
    self.last_cx, self.last_cy = nil, nil
    local was_erase = self.tool == "erase"
    -- Grab the raw points before finishStroke simplifies them, so shape assist
    -- recognises the shape from the full path rather than an RDP skeleton.
    local raw
    if self.shape_assist and self.tool == "pen" and self.canvas.live then
        local lp = self.canvas.live.pts
        raw = {}
        for i = 1, #lp do raw[i] = lp[i] end
    end
    local committed = self.canvas:finishStroke()
    -- Record whether text was protected when THIS stroke was made, so later
    -- toggling the setting never retroactively erases (or un-erases) text that a
    -- past stroke passed over. Compose then honours each erase op's own flag.
    if committed and committed.kind == "erase" then
        committed.spare_text = self.text_erase_protect or nil
    end
    -- Shape assist: if the finished pen stroke reads as a clean shape, swap it in.
    if raw and committed and committed.kind == "ink" and self:beautifyStroke(raw, committed) then
        self._stroke_rect = nil
        self:afterCommit()
        return
    end
    self.dirty = true
    -- Settle the fast-refresh ghosting over just the stroke's area. Erasing dark
    -- or textured ink leaves grey ghosts, so an erase gets a flashing refresh
    -- (which fully repaints black/white) to clear them.
    local mode = was_erase and "flashui" or "ui"
    local sr = self._stroke_rect
    if sr then
        -- refresh the base rect and each mirror rect separately, so an erase
        -- under symmetry flashes a few small areas rather than the whole screen
        local rects, nr = self:symAreaRects(sr)
        for i = 1, nr do
            self:dirtyAreaRect(mode, rects[i], 2)
        end
    else
        UIManager:setDirty(self, mode, self:areaScreenRect())
    end
    self._stroke_rect = nil
    -- Handwriting to text: buffer the pen stroke and (re)arm the pause timer.
    if self.hwr_enabled and self.tool == "pen" and committed and committed.kind == "ink" then
        self:hwrCapture(committed)
    end
    self:afterCommit()
end

-- Called once per committed drawing action. When ghosting cleanup is on, count
-- the actions and, at the threshold, force one full-screen refresh to clear the
-- ghosting that fast refreshes leave behind, then reset the count and carry on.
function InkAwayView:afterCommit()
    self:healMemory()
    local n = self.ghost_clean or 0
    if n <= 0 then return end
    self._strokes_since_full = (self._strokes_since_full or 0) + 1
    if self._strokes_since_full >= n then
        self._strokes_since_full = 0
        UIManager:setDirty(self, "full")
    end
end

-- Safety net against a runaway heap. Called at idle moments (a stroke just
-- committed): if the Lua heap has grown large over a very long session, reclaim
-- garbage right here so drawing can never degrade into GC thrashing. This is a
-- backstop, not the fix -- the per-stroke allocation is already flat (see the
-- delta-history + pooled-hot-path work); this only ever fires if something starts
-- leaking again. Gated on size so a normal session pays nothing, and it runs
-- between strokes (never mid-stroke), so the one-off collect is invisible.
local GC_HEAL_KB = 48 * 1024        -- ~48 MB: far above any legitimate drawing
local GC_HEAL_EVERY = 96            -- check at most once per this many commits
function InkAwayView:healMemory()
    self._commits_since_gc = (self._commits_since_gc or 0) + 1
    if self._commits_since_gc < GC_HEAL_EVERY then return end
    self._commits_since_gc = 0
    if collectgarbage("count") > GC_HEAL_KB then collectgarbage("collect") end
end

-- Hand the previous drawing's / notebook's memory back when switching to a fresh
-- one: drop the per-stroke snapshot buffer and collect now, so the new context
-- starts light without needing to close Ink Away or restart KOReader. Call after
-- the new canvas/notebook is loaded (a New action, not a page turn).
function InkAwayView:resetTransientMemory()
    if self._pre_stroke_bb then self._pre_stroke_bb:free(); self._pre_stroke_bb = nil end
    self._pre_stroke_valid = false
    self._commits_since_gc = 0
    collectgarbage("collect")
end

-- Commit immediately if a stroke is open (or pending). Safe to call any time.
function InkAwayView:flushPending()
    if self.capturing then self:finalizeStroke() end
end

------------------------------------------------------------------------------
-- Shapes: rubber-band placement (drag to stretch, like a paint program). The
-- committed drawing in canvas_bb is never touched while stretching; the shape
-- is drawn on top in paintTo and only its changed rectangle is refreshed, so it
-- stays snappy. On release the shape is stamped into the master and folded in.
------------------------------------------------------------------------------

-- Screen-coordinate op for the current drag, drawn as the live preview.
local function screenShapeOp(self, shape, fill, x0, y0, x1, y1, cx, cy)
    local arrow, head
    if (shape == "line" or shape == "curve") and self.shape_arrow then
        arrow = self.shape_arrow
        head = self.arrow_head * self.view.zoom
    end
    return {
        kind = "shape", shape = shape, fill = fill, arrow = arrow, head = head,
        width = math.max(1, self.pen_width * self.view.zoom),
        color = self.pen_color, alpha = self.pen_alpha,
        pts = cx and { x0, y0, x1, y1, cx, cy } or { x0, y0, x1, y1 },
    }
end

-- Padded screen rect touched by a preview op.
function InkAwayView:previewRect(op)
    local x0, y0, x1, y1 = Shapes.bounds(op)
    local pad = op.width + 4
    return { x = math.floor(x0 - pad), y = math.floor(y0 - pad),
             x2 = math.ceil(x1 + pad), y2 = math.ceil(y1 + pad) }
end

-- Refresh the union of the previous and current preview rectangles, so the old
-- outline is wiped (from the untouched base) and the new one drawn.
function InkAwayView:refreshPreview()
    local r = self.shape_preview and self:previewRect(self.shape_preview) or nil
    local u = r
    local prev = self._preview_rect
    if prev then
        if u then
            u = { x = math.min(u.x, prev.x), y = math.min(u.y, prev.y),
                  x2 = math.max(u.x2, prev.x2), y2 = math.max(u.y2, prev.y2) }
        else
            u = prev
        end
    end
    self._preview_rect = r
    if not u then return end
    local v = self.view
    local x = math.max(0, u.x)
    local yy = math.max(v.area_y, u.y)
    local x2 = math.min(self.screen_w, u.x2)
    local y2 = math.min(v.area_y + v.area_h, u.y2)
    if x2 > x and y2 > yy then
        UIManager:setDirty(self, "fast", GeomUI:new{ x = x, y = yy, w = x2 - x, h = y2 - yy })
    end
end

function InkAwayView:shapeTouch(pos)
    if self.curve_stage == "bend" then
        self.curve_ctrl = { x = pos.x, y = pos.y }
        self.shape_preview = screenShapeOp(self, "curve", false,
            self.curve_p0.x, self.curve_p0.y, self.curve_p1.x, self.curve_p1.y,
            self.curve_ctrl.x, self.curve_ctrl.y)
        self:refreshPreview()
        return true
    end
    -- If a previous shape never got its release (a dropped lift event), place it
    -- now instead of silently losing it when this new drag begins.
    if self.shape_drag then
        if self.shape == "curve" then self:cancelShape() else self:commitShape() end
    end
    local x0, y0 = self:snapScreen(pos.x, pos.y)
    -- Snapshot the settings this shape is being drawn with, so a deferred commit
    -- (a missed lift, or a tool change) still places the shape it started as.
    self.shape_drag = { x0 = x0, y0 = y0, x1 = x0, y1 = y0,
        shape = self.shape, fill = self.shape_fill, arrow = self.shape_arrow,
        head = self.arrow_head, sym = self.symmetry,
        width = self.pen_width, alpha = self.pen_alpha, color = self.pen_color }
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, x0, y0, x0, y0)
    self:refreshPreview()
    return true
end

function InkAwayView:shapeMove(pos)
    if not pos then return true end
    if self.curve_stage == "bend" then
        local c = self.curve_ctrl
        if c and c.x == pos.x and c.y == pos.y then return true end   -- no change, skip
        self.curve_ctrl = { x = pos.x, y = pos.y }
        self.shape_preview = screenShapeOp(self, "curve", false,
            self.curve_p0.x, self.curve_p0.y, self.curve_p1.x, self.curve_p1.y,
            self.curve_ctrl.x, self.curve_ctrl.y)
        self:refreshPreview()
        return true
    end
    if not self.shape_drag then return false end
    local d = self.shape_drag
    local nx, ny = self:shapeEndPoint(pos)
    if nx == d.x1 and ny == d.y1 then return true end   -- endpoint unchanged, skip the flash
    d.x1, d.y1 = nx, ny
    self.shape_preview = screenShapeOp(self, self.shape, self.shape_fill, d.x0, d.y0, d.x1, d.y1)
    self:refreshPreview()
    return true
end

-- Snap the drag's end point: to the grid (if on), and to 45-degree steps for a
-- line or curve (if angle snapping is on). Rectangles and ellipses are NOT
-- forced square, so you can draw any proportion.
function InkAwayView:shapeEndPoint(pos)
    local d = self.shape_drag
    local x1, y1 = self:snapScreen(pos.x, pos.y)
    if self.snap_angle and (self.shape == "line" or self.shape == "curve") then
        x1, y1 = InkGeom.snapAngle(d.x0, d.y0, x1, y1)
    end
    return x1, y1
end

function InkAwayView:shapeRelease(pos)
    if self.curve_stage == "bend" then
        if pos then self.curve_ctrl = { x = pos.x, y = pos.y } end
        self:commitCurve()
        return true
    end
    if not self.shape_drag then return false end
    if pos then self.shape_drag.x1, self.shape_drag.y1 = self:shapeEndPoint(pos) end
    local d = self.shape_drag
    local dx, dy = d.x1 - d.x0, d.y1 - d.y0
    if dx * dx + dy * dy < 9 then      -- basically a tap: nothing to place
        self:cancelShape()
        return true
    end
    if (d.shape or self.shape) == "curve" then
        -- keep the straight segment on screen and wait for a bend drag; carry
        -- the draw-time settings over to the eventual commit
        self.curve_p0 = { x = d.x0, y = d.y0 }
        self.curve_p1 = { x = d.x1, y = d.y1 }
        self.curve_ctrl = { x = (d.x0 + d.x1) / 2, y = (d.y0 + d.y1) / 2 }
        self.curve_snap = { arrow = d.arrow, head = d.head, sym = d.sym,
            width = d.width, alpha = d.alpha, color = d.color }
        self.curve_stage = "bend"
        self.shape_drag = nil
        return true
    end
    self:commitShape()
    return true
end

-- Stamp a committed op into the 1:1 master.
function InkAwayView:stampOpIntoCanvas(op)
    if not self.canvas_bb then return end
    if op.kind == "text" then self:stampTextInto(self.canvas_bb, op); return end
    local put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
        self:opColor(op), nil)
    local fill_put
    if op.kind == "shape" and op.fill_color and not op.fill then
        fill_put = spanWriter(self.canvas_bb, self.view.canvas_w, self.view.canvas_h,
            displayColor(op.fill_color, op.fill_alpha or 255), nil)
    end
    if op.sym and op.sym ~= "off" then
        local refx, refy = Symmetry.canvasRefs(self.view.canvas_w, self.view.canvas_h)
        put = Symmetry.wrap(put, op.sym, refx, refy)
        if fill_put then fill_put = Symmetry.wrap(fill_put, op.sym, refx, refy) end
    end
    Export.paintGeom(op, put, fill_put)
end

-- Give a freshly placed shape op its symmetry mode and, for a line or curve,
-- any arrowheads, before it is stamped in. `snap` is the settings captured when
-- the shape was started (see shapeTouch); it is used in preference to the live
-- settings so a shape always commits as it was drawn, even if the tool changed
-- between the draw and a deferred commit.
function InkAwayView:decorateShapeOp(op, snap)
    local sym = (snap and snap.sym) or self.symmetry
    if sym ~= "off" then op.sym = sym end
    local arrow = snap and snap.arrow
    if arrow == nil and not snap then arrow = self.shape_arrow end
    if (op.shape == "line" or op.shape == "curve") and arrow then
        op.arrow = arrow
        op.head = (snap and snap.head) or self.arrow_head
    end
end

function InkAwayView:commitShape()
    local d = self.shape_drag
    local c0x, c0y = self:toCanvasClamped(d.x0, d.y0)
    local c1x, c1y = self:toCanvasClamped(d.x1, d.y1)
    -- Use the settings snapshotted when the drag began, not the live ones: a
    -- finished shape whose lift was missed can be committed later, after the
    -- tool or shape type has changed, and it must still commit as what it was.
    local shape = d.shape or self.shape
    local fill = d.fill; if fill == nil then fill = self.shape_fill end
    local op = self.canvas:addShape(shape, fill,
        { c0x, c0y, c1x, c1y }, d.width or self.pen_width,
        d.alpha or self.pen_alpha, d.color or self.pen_color)
    self:decorateShapeOp(op, d)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self.shape_drag = nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:afterCommit()
end

function InkAwayView:commitCurve()
    local c0x, c0y = self:toCanvasClamped(self.curve_p0.x, self.curve_p0.y)
    local c1x, c1y = self:toCanvasClamped(self.curve_p1.x, self.curve_p1.y)
    local ccx, ccy = self:toCanvasClamped(self.curve_ctrl.x, self.curve_ctrl.y)
    local snap = self.curve_snap
    local op = self.canvas:addShape("curve", false,
        { c0x, c0y, c1x, c1y, ccx, ccy }, (snap and snap.width) or self.pen_width,
        (snap and snap.alpha) or self.pen_alpha, (snap and snap.color) or self.pen_color)
    self:decorateShapeOp(op, snap)
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self.curve_stage = nil
    self.curve_snap = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self._preview_rect = nil
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:afterCommit()
end

------------------------------------------------------------------------------
-- Export area selection: drag a rectangle to export just part of the page.
------------------------------------------------------------------------------

function InkAwayView:cropTouch(pos)
    self._crop_screen = { x0 = pos.x, y0 = pos.y, x1 = pos.x, y1 = pos.y }
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

function InkAwayView:cropMove(pos)
    if not (pos and self._crop_screen) then return true end
    local c = self._crop_screen
    local ox0, oy0, ox1, oy1 = c.x0, c.y0, c.x1, c.y1   -- previous box
    c.x1, c.y1 = pos.x, pos.y
    -- refresh only the union of the old and new selection boxes, and use a fast
    -- (non-flashing) refresh so dragging stays smooth instead of queueing full
    -- grayscale updates
    local v = self.view
    local minx = math.max(v.area_x, math.min(ox0, ox1, c.x0, c.x1) - 3)
    local miny = math.max(v.area_y, math.min(oy0, oy1, c.y0, c.y1) - 3)
    local maxx = math.min(v.area_x + v.area_w, math.max(ox0, ox1, c.x0, c.x1) + 3)
    local maxy = math.min(v.area_y + v.area_h, math.max(oy0, oy1, c.y0, c.y1) + 3)
    if maxx > minx and maxy > miny then
        UIManager:setDirty(self, "fast", GeomUI:new{ x = minx, y = miny, w = maxx - minx, h = maxy - miny })
    end
    return true
end

function InkAwayView:cropRelease(pos)
    if pos and self._crop_screen then self._crop_screen.x1, self._crop_screen.y1 = pos.x, pos.y end
    self.selecting_crop = false
    local c = self._crop_screen
    self._crop_screen = nil
    if c then
        local ax0, ay0 = self:toCanvasClamped(c.x0, c.y0)
        local ax1, ay1 = self:toCanvasClamped(c.x1, c.y1)
        local x0, x1 = math.min(ax0, ax1), math.max(ax0, ax1)
        local y0, y1 = math.min(ay0, ay1), math.max(ay0, ay1)
        local w, h = math.floor(x1 - x0), math.floor(y1 - y0)
        self.save_area = (w >= 8 and h >= 8)
            and { x = math.floor(x0), y = math.floor(y0), w = w, h = h } or nil
    end
    self:refresh(self, "full")
    self:onSave()   -- return to the save dialog with the area now chosen
    return true
end

-- Drop any in-progress shape and wipe its preview.
function InkAwayView:cancelShape()
    if not (self.shape_drag or self.curve_stage or self.shape_preview) then return end
    self.shape_drag = nil
    self.curve_stage = nil
    self.curve_snap = nil
    self.curve_p0, self.curve_p1, self.curve_ctrl = nil, nil, nil
    self.shape_preview = nil
    self:refreshPreview()   -- clears the old preview region from the base
end

-- Place a shape that is finished but still pending -- typically because its lift
-- event was missed on the touch panel -- before the tool or shape type changes
-- under it. A curve waiting for its bend is placed straight; a pending drag too
-- small to be a shape is dropped. Call this at every transition (tool switch,
-- opening the shape picker, changing the shape type) so a drawn shape is never
-- left as a stray preview to be dropped, nor re-typed into a different shape.
function InkAwayView:flushShape()
    if self.curve_stage == "bend" then
        self:commitCurve()
    elseif self.shape_drag then
        local d = self.shape_drag
        local dx, dy = d.x1 - d.x0, d.y1 - d.y0
        if dx * dx + dy * dy < 9 then self:cancelShape() else self:commitShape() end
    end
end

------------------------------------------------------------------------------
-- Paint bucket: flood fill an enclosed area on tap.
------------------------------------------------------------------------------

-- The paint bucket's own colour/opacity, so it need not share the pen's.
function InkAwayView:openFillSettings()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function pick(rgb)
        self.fill_color = { rgb[1], rgb[2], rgb[3] }
        UIManager:close(dlg)
        self:openFillSettings()
    end
    local pct = math.floor(self.fill_alpha / 255 * 100 + 0.5)
    local buttons = {}
    buttons[#buttons + 1] = {{
        text = string.format(_("Opacity %d%%"), pct),
        callback = function()
            UIManager:close(dlg)
            local SpinWidget = require("ui/widget/spinwidget")
            UIManager:show(SpinWidget:new{
                title_text = _("Fill opacity"), value = pct,
                value_min = 5, value_max = 100, value_step = 5, unit = "%",
                callback = function(s)
                    self.fill_alpha = math.max(1, math.min(255, math.floor(s.value / 100 * 255 + 0.5)))
                    self:openFillSettings()
                end,
            })
        end,
    }}
    buttons[#buttons + 1] = self:swatchRowFor(SHADES, self.fill_color, pick)
    if self:colorScreen() then
        buttons[#buttons + 1] = self:swatchRowFor(COLORS, self.fill_color, pick)
    end
    buttons[#buttons + 1] = {{ text = _("Done"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = _("Fill colour and opacity"), title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

-- The top-most CLOSED shape whose interior contains a canvas point, or nil.
function InkAwayView:shapeUnderPoint(cx, cy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" and Shapes.contains(op, cx, cy) then
            return { op = op, idx = i }
        end
    end
    return nil
end

function InkAwayView:doFill(pos)
    self:flushPending()
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    -- Tapping inside a shape paints THAT shape's interior: the colour is stored on
    -- the shape itself (under its outline), so it moves, rotates, duplicates and
    -- deletes with the shape instead of being left behind. Copy-on-write, so a
    -- single Undo right after lifts just the fill and restores the empty shape.
    local shp = self:shapeUnderPoint(cx, cy)
    if shp then
        self.canvas:pushHistory()
        local clone = self.canvas:cloneOp(shp.op)
        clone.fill_color = { self.fill_color[1], self.fill_color[2], self.fill_color[3] }
        clone.fill_alpha = self.fill_alpha
        self.canvas:replaceOp(shp.idx, clone)
        self.dirty = true
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
        self:afterCommit()
        return
    end
    local gray = Export.buildGray(self.canvas)
    local runs = Fill.compute(gray, self.view.canvas_w, self.view.canvas_h,
        math.floor(cx), math.floor(cy), 40)
    if not runs or #runs == 0 then return end
    local op = self.canvas:addFillOp(runs, self.fill_color, self.fill_alpha)
    if self.symmetry ~= "off" then op.sym = self.symmetry end
    self:stampOpIntoCanvas(op)
    self.dirty = true
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:afterCommit()
end

------------------------------------------------------------------------------
-- Settings menu (gear): drawing aids, projects, autosave.
------------------------------------------------------------------------------

function InkAwayView:refreshArea()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:setAutosave(mode)
    self.autosave = mode
    self:setSetting("inkaway_autosave", mode)
    self:scheduleAutosave()
end

------------------------------------------------------------------------------
-- Symmetry, ghosting cleanup, and the background image.
------------------------------------------------------------------------------

-- Build a canvas-sized RGBA FFI buffer from the background (a BBRGB32 whose
-- memory is already r,g,b,alpha). One memcpy per row, not a million per-pixel
-- reads, so it is quick even on a Kindle. Alpha is kept, so a transparent PNG
-- stays transparent. Returns the buffer, or nil.
function InkAwayView:buildBgRGBA()
    return bbToRGBA(self.bg_bb, self.view.canvas_w, self.view.canvas_h)
end

-- Place an already-rendered source BlitBuffer as the background: fit it inside
-- the canvas keeping aspect (no stretching), centre it on a canvas-sized RGB32
-- buffer with white margins, and take ownership of `img` (it is freed here).
function InkAwayView:placeBackground(img, path)
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bg = fitIntoCanvasBB(img, W, H)
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb = bg
    self.bg_path = path
    self.export_bg = true
    self.bg_rgba = self:buildBgRGBA()
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

function InkAwayView:loadBackground(path)
    local RenderImage = require("ui/renderimage")
    local ok, img = pcall(function() return RenderImage:renderImageFile(path, false) end)
    if not ok or not img then
        UIManager:show(InfoMessage:new{ text = _("Could not open that image.") })
        return
    end
    self:placeBackground(img, path)
end


function InkAwayView:removeBackground()
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb, self.bg_rgba, self.bg_path = nil, nil, nil
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "full")
end

function InkAwayView:chooseBackground()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(path)
            local lower = path:lower()
            if lower:match("%.png$") or lower:match("%.jpe?g$") then
                self:loadBackground(path)
            else
                UIManager:show(InfoMessage:new{ text = _("Please choose a PNG or JPEG image.") })
            end
        end,
    })
end

function InkAwayView:openBackground()
    if self._bg_dialog then UIManager:close(self._bg_dialog); self._bg_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local HINT = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF)
    local closeSelf = function()
        if self._bg_dialog then UIManager:close(self._bg_dialog); self._bg_dialog = nil end
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        table.insert(content, self:sheetTitle(_("Background image"), content_w, _("Done"), closeSelf))
        table.insert(content, vspan(16))
        table.insert(content, self:actionButton(_("Open image as background"), content_w,
            function() closeSelf(); self:chooseBackground() end))
        if self.bg_bb then
            table.insert(content, vspan(8))
            table.insert(content, self:actionButton(_("Remove background"), content_w,
                function() closeSelf(); self:removeBackground() end, true))
        end
        table.insert(content, vspan(12))
        local hint = self.bg_bb
            and _("At save time you can include the picture or export just your drawing. The grid is always left out.")
            or _("Draw over a photo or screenshot; your drawing sits on top. To draw on a PDF, use \u{201C}Open PDF as notebook\u{201D} instead.")
        table.insert(content, TextBoxWidget:new{ text = hint, width = content_w,
            face = Font:getFace("cfont", 15), fgcolor = HINT })
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._bg_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._bg_dialog = nil end }
    UIManager:show(self._bg_dialog)
end

-- Render one PDF page to a canvas-sized page BlitBuffer, on demand. Mirrors the
-- call KOReader uses for cover thumbnails, so it is as fast as KOReader itself
-- (and the result is cached by KOReader's DocCache). Returns a BlitBuffer or nil.
function InkAwayView:renderPdfPage(doc, pageno, tw, th)
    if not doc then return nil end
    local Document = require("document/document")
    local Geom = require("ui/geometry")
    local W, H = tw or self.view.canvas_w, th or self.view.canvas_h
    local img
    pcall(function()
        local native = Document.getNativePageDimensions(doc, pageno)
        if not (native and native.w and native.h) then return end
        local zoom = math.min(W / native.w, H / native.h)
        -- Always pass an explicit full-page rect. Without it, a page too large to
        -- fit KOReader's tile cache (e.g. an A4 page at fit-zoom) is refused
        -- outright ("no render region ... won't render") and comes back blank; a
        -- rect makes it render that region uncached instead.
        local rect = Geom:new{ x = 0, y = 0,
            w = math.floor(native.w * zoom + 0.5), h = math.floor(native.h * zoom + 0.5) }
        local tile = Document.renderPage(doc, pageno, rect, zoom, 0, 1.0, 1.0, false)
        if tile and tile.bb then img = fitIntoCanvasBB(tile.bb:copy(), W, H) end
    end)
    return img
end

-- Friendly names for the notebook paper (ruling) styles.
local TEMPLATE_LABEL = { lines = _("lined"), grid = _("grid"), dots = _("dotted"),
    margin = _("margin"), cornell = _("Cornell"), blank = _("blank") }

-- A generic "pick one of a list" sub-sheet in the shapes-menu style: a vertical
-- stack of full-width buttons, the current one filled black. `options` is a list
-- of { value, label }; onpick(value) is called after the sheet closes.
function InkAwayView:openChooserSheet(title, options, current, onpick)
    if self._chooser_dialog then UIManager:close(self._chooser_dialog); self._chooser_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._chooser_dialog then UIManager:close(self._chooser_dialog); self._chooser_dialog = nil end
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        table.insert(content, self:sheetTitle(title, content_w, _("Done"), closeSelf))
        table.insert(content, vspan(16))
        for i, o in ipairs(options) do
            if i > 1 then table.insert(content, vspan(8)) end
            table.insert(content, self:actionButton(o[2], content_w,
                function() closeSelf(); onpick(o[1]) end, current == o[1]))
        end
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._chooser_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._chooser_dialog = nil end }
    UIManager:show(self._chooser_dialog)
end

-- The gear menu (shapes-menu style): file/page actions as buttons, the grid or
-- notebook-paper controls as a toggle/chooser and sliders, and symmetry /
-- autosave as segmented rows. Reorganised into clear sections.
function InkAwayView:openSettings()
    if self.active_image then self:finishImageEdit() end   -- settle a selected image first
    -- `_settings_dialog` is normally this settings IconMenu (rebuild in place), but a
    -- few transient ButtonDialogs (Page menu, page overview) reuse the field and have
    -- no rebuild -- drop such a one and open fresh instead of crashing.
    if self._settings_dialog then
        if self._settings_dialog.rebuild then self._settings_dialog:rebuild(); return end
        UIManager:close(self._settings_dialog); self._settings_dialog = nil
    end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    self:ensureUserIcons()
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local halfW = math.floor((content_w - gap) / 2)
    local pxfmt = function(v) return v .. _(" px") end
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._settings_dialog then UIManager:close(self._settings_dialog); self._settings_dialog = nil end
    end
    local function act(label, w, cb, dark)
        return self:actionButton(label, w, function() closeSelf(); cb() end, dark)
    end
    local function header(txt)
        return TextWidget:new{ text = txt, face = Font:getFace("cfont", 15), bold = true,
            fgcolor = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF) }
    end

    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        local function row2(a, b)
            return HorizontalGroup:new{ align = "center", a, HorizontalSpan:new{ width = gap }, b }
        end
        -- a segmented picker: N equal buttons, the current one filled black
        local function seg(options, current, onpick)
            local n = #options
            local w = math.floor((content_w - (n - 1) * gap) / n)
            local row = HorizontalGroup:new{ align = "center" }
            for i, o in ipairs(options) do
                if i > 1 then table.insert(row, HorizontalSpan:new{ width = gap }) end
                -- do NOT close the sheet: these pickers change a setting and stay,
                -- so onpick's openSettings() rebuilds this sheet in place (the moved
                -- highlight refreshes just this region, no full-screen flash)
                table.insert(row, self:actionButton(o[2], w, function() onpick(o[1]) end,
                    current == o[1]))
            end
            return row
        end

        add(self:sheetTitle(_("Settings"), content_w, _("Done"), closeSelf))
        add(vspan(16))

        -- files & pages
        add(row2(act(_("New drawing"), halfW, function() self:newDrawing() end),
                 act(_("New notebook"), halfW, function() self:newNotebook() end)))
        add(vspan(8))
        add(row2(act(_("Open project"), halfW, function() self:openProject() end),
                 act(_("Save project"), halfW, function() self:saveProject() end)))
        add(vspan(8))
        add(act(_("Open PDF as notebook"), content_w, function() self:openPdfAsNotebook() end))
        add(vspan(8))
        add(act(_("Background image"), content_w, function() self:openBackground() end))
        add(vspan(16))

        -- orientation: portrait vs landscape. Switches the whole app (and the shape
        -- of new canvases and notebooks) the chosen way up. Closes the sheet on pick
        -- because the screen size changes; reopen it to see the new highlight.
        if self:orientationSupported() then
            add(header(_("Orientation")))
            add(vspan(6))
            local cur = self:orientationClass()
            add(row2(
                self:actionButton(_("Portrait"), halfW, function()
                    closeSelf(); self:setOrientation("portrait") end, cur == "portrait"),
                self:actionButton(_("Landscape"), halfW, function()
                    closeSelf(); self:setOrientation("landscape") end, cur == "landscape")))
            add(vspan(16))
        end

        -- grid (canvas) or paper (notebook)
        if self.notebook then
            local t = self.notebook.template
            add(act(_("Paper: ") .. (TEMPLATE_LABEL[t.style or "lines"] or t.style), content_w, function()
                self:openChooserSheet(_("Notebook paper"), {
                    { "lines", _("Lined") }, { "grid", _("Grid") }, { "dots", _("Dotted") },
                    { "margin", _("Margin ruled") }, { "cornell", _("Cornell") }, { "blank", _("Blank") } },
                    t.style, function(v)
                        t.style = v; self.nb_style = v; self:setSetting("inkaway_nb_style", v); self.dirty = true
                        self:composeCanvas(); self:renderView(); self:refreshArea(); self:openSettings()
                    end)
            end))
            add(vspan(12))
            add(SliderRow:new{ label = _("Line spacing"), value = t.size or 40, min = 12, max = 200, step = 2,
                width = content_w, parent = menu, format = pxfmt,
                on_set = function(v) t.size = v; self.nb_size = v; self:setSetting("inkaway_nb_size", v)
                    self.dirty = true; self:composeCanvas(); self:renderView(); self:refreshArea() end })
            add(vspan(10))
            add(SliderRow:new{ label = _("Line strength"), value = t.strength or 45, min = 5, max = 100, step = 5,
                width = content_w, parent = menu,
                on_set = function(v) t.strength = v; self.nb_strength = v; self:setSetting("inkaway_nb_strength", v)
                    self.dirty = true; self:composeCanvas(); self:renderView(); self:refreshArea() end })
        else
            add(ToggleRow:new{ label = _("Grid"), is_on = self.grid_on, width = content_w, parent = menu,
                callback = function(on) self.grid_on = on; self:setSetting("inkaway_grid", on)
                    self:renderView(); self:refreshArea() end })
            add(vspan(10))
            add(act(_("Grid style: ") .. self.grid_style, content_w, function()
                self:openChooserSheet(_("Grid style"), {
                    { "square", _("Square grid") }, { "dots", _("Dot grid") }, { "lines", _("Ruled lines") },
                    { "iso", _("Isometric") }, { "thirds", _("Rule of thirds") } }, self.grid_style,
                    function(v) self.grid_style = v; self:setSetting("inkaway_grid_style", v)
                        self.grid_on = true; self:setSetting("inkaway_grid", true)
                        self:renderView(); self:refreshArea(); self:openSettings() end)
            end))
            add(vspan(12))
            add(SliderRow:new{ label = _("Grid size"), value = self.grid_size, min = 8, max = 200, step = 2,
                width = content_w, parent = menu, format = pxfmt,
                on_set = function(v) self.grid_size = v; self:setSetting("inkaway_grid_size", v)
                    self:renderView(); self:refreshArea() end })
            add(vspan(10))
            add(SliderRow:new{ label = _("Grid strength"), value = self.grid_strength, min = 5, max = 100, step = 5,
                width = content_w, parent = menu,
                on_set = function(v) self.grid_strength = v; self:setSetting("inkaway_grid_strength", v)
                    self.grid_on = true; self:setSetting("inkaway_grid", true); self:refreshArea() end })
        end
        add(vspan(16))

        -- symmetry (segmented)
        add(header(_("Symmetry")))
        add(vspan(6))
        add(seg({ { "off", _("Off") }, { "vert", _("Vertical") }, { "horiz", _("Horizontal") }, { "quad", _("Four-way") } },
            self.symmetry, function(v) self.symmetry = v; self:setSetting("inkaway_symmetry", v); self:openSettings() end))
        add(vspan(14))

        -- ghosting cleanup slider (0 = off). 0-50 in 5s: a small range is easier to
        -- pinpoint, and clearing every >50 strokes is effectively never anyway.
        add(SliderRow:new{ label = _("Ghosting"), value = math.min(50, self.ghost_clean or 0), min = 0, max = 50, step = 5,
            width = content_w, parent = menu,
            format = function(v) return v == 0 and _("off") or string.format(_("%d strokes"), v) end,
            on_set = function(v) self.ghost_clean = v; self:setSetting("inkaway_ghost", v)
                self._strokes_since_full = 0 end })
        add(vspan(4))
        do
            local TextBoxWidget = require("ui/widget/textboxwidget")
            add(TextBoxWidget:new{
                text = _("Fast strokes leave faint grey marks. A full refresh clears them after this many strokes."),
                face = Font:getFace("cfont", 13),
                fgcolor = Blitbuffer.ColorRGB32(0x90, 0x90, 0x90, 0xFF), width = content_w })
        end
        add(vspan(14))

        -- autosave (segmented)
        add(header(_("Autosave")))
        add(vspan(6))
        add(seg({ { "off", _("Off") }, { "exit", _("On exit") }, { "periodic", _("Every 3 min") } },
            self.autosave, function(v) self:setAutosave(v); self:openSettings() end))

        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._settings_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._settings_dialog = nil end }
    UIManager:show(self._settings_dialog)
end

------------------------------------------------------------------------------
-- Projects: new / open / save (the editable drawing, not the image export).
------------------------------------------------------------------------------

function InkAwayView:newDrawing()
    local function fresh()
        self:exitNotebook()
        self.canvas:setOps({})
        self.selected, self.rotating = nil, nil
        self.active_image, self._img_drag = nil, nil
        self:freeImageCache()
        self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
        self.dirty = false
        os.remove(self:sessionPath())   -- so reopening does not restore the old drawing
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()     -- reclaim the old drawing's memory now
        UIManager:setDirty(self, "full")
    end
    if self.canvas:isEmpty() and not self.notebook then fresh(); return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Start a new drawing? The current one will be cleared."),
        ok_text = _("New"), ok_callback = fresh,
    })
end

function InkAwayView:openProject()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:projectDir(),
        onConfirm = function(path)
            local data, err = Project.load(path)
            if data and Project.isNotebook(data) then
                self:openNotebookData(data)
            elseif data and self:loadProjectData(data) then
                self:exitNotebook()
                self:composeCanvas(); self:renderView()
                UIManager:setDirty(self, "full")
            else
                UIManager:show(InfoMessage:new{
                    text = _("Could not open that project.\n") .. tostring(err) })
            end
        end,
    })
end

function InkAwayView:saveProject()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true, select_file = false, show_files = true,
        path = self:projectDir(),
        onConfirm = function(dir)
            self:rememberProjectDir(dir)
            local InputDialog = require("ui/widget/inputdialog")
            local name = os.date(self.notebook and "notebook-%Y%m%d-%H%M%S" or "ink-%Y%m%d-%H%M%S")
            local d
            d = InputDialog:new{
                title = _("Project name"),
                input = name,
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(d) end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        local n = d:getInputText()
                        UIManager:close(d)
                        if not n or n == "" then n = name end
                        n = n:gsub("[/\\]", "_")
                        if not n:lower():match("%." .. Project.EXT .. "$") then n = n .. "." .. Project.EXT end
                        local sep = (dir:sub(-1) == "/") and "" or "/"
                        local ok, e
                        if self.notebook then
                            self:nbSyncOut()
                            ok, e = Project.saveNotebook(self.notebook, dir .. sep .. n)
                        else
                            ok, e = Project.save(self.canvas, dir .. sep .. n)
                        end
                        UIManager:show(InfoMessage:new{
                            text = ok and (_("Project saved:\n") .. dir .. sep .. n)
                                        or (_("Could not save project.\n") .. tostring(e)) })
                    end },
                }},
            }
            UIManager:show(d)
            d:onShowKeyboard()
        end,
    })
end

------------------------------------------------------------------------------
-- Editing a placed shape: hold one to pick it, then rotate / recolour / resize
-- / delete it from a small menu anchored beside it.
------------------------------------------------------------------------------

-- Find the top-most shape op under a screen point. Returns {op, idx} or nil.
function InkAwayView:hitTestShape(sx, sy)
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "shape" then
            local tol = (op.width or 6) / 2 + 8 / self.view.zoom
            if Shapes.hit(op, cx, cy, tol) then return { op = op, idx = i } end
        end
    end
    return nil
end

-- A screen-coordinate copy of a shape op (for the rotate preview overlay).
function InkAwayView:screenShapeFromOp(op, angle)
    local v = self.view
    local sp = {}
    for i = 1, #op.pts, 2 do
        local sx, sy = InkGeom.toScreen(v, op.pts[i], op.pts[i + 1])
        sp[#sp + 1] = sx
        sp[#sp + 1] = sy
    end
    return {
        kind = "shape", shape = op.shape, fill = op.fill, angle = angle,
        closed = op.closed,
        width = math.max(1, (op.width or 2) * v.zoom),
        arrow = op.arrow, head = op.head and op.head * v.zoom or nil,
        color = op.color, alpha = op.alpha,
        fill_color = op.fill_color, fill_alpha = op.fill_alpha, pts = sp,
    }
end

-- Deselect the shape: close the menu, stop the canvas grabbing extra gestures,
-- and clear the selection. Called on a tap outside the menu (and by Done).
function InkAwayView:deselectShape()
    if self._shape_menu then
        local m = self._shape_menu; self._shape_menu = nil
        pcall(function() UIManager:close(m) end)
    end
    -- if a drag was somehow cut short, never leave the shape hidden from the master
    if self.selected and self.selected.op and self.selected.op.hidden then
        self.selected.op.hidden = nil
        self.shape_preview = nil; self._preview_rect = nil
        self:composeCanvas(); self:renderView()
    end
    self:setSelectionActive(false)
    self.selected = nil
    self.shape_move = nil
end

function InkAwayView:openShapeMenu(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._shape_menu then UIManager:close(self._shape_menu); self._shape_menu = nil end
    self:setSelectionActive(true)   -- keep the shape draggable while the menu is up
    local op = sel.op
    local dlg
    local function close() if dlg then UIManager:close(dlg) end end
    dlg = ButtonDialog:new{
        shrink_unneeded_width = true,
        tap_close_callback = function() self:deselectShape() end,
        anchor = function()
            local x0, y0, x1, y1 = Shapes.bounds(sel.op)
            local sx0, sy0 = InkGeom.toScreen(self.view, x0, y0)
            local sx1, sy1 = InkGeom.toScreen(self.view, x1, y1)
            return GeomUI:new{ x = math.floor(sx0), y = math.floor(sy0),
                               w = math.ceil(sx1 - sx0), h = math.ceil(sy1 - sy0) }
        end,
        buttons = {
            {
                { text = "\u{27F3} " .. _("Rotate"),  callback = function() close(); self:beginRotate(sel) end },
                { text = "\u{21BB} " .. _("90\u{00B0}"), callback = function() close(); self:rotateShape90(sel) end },
            },
            {
                { text = "\u{2194} " .. _("Flip H"),  callback = function() close(); self:flipShape(sel, "h") end },
                { text = "\u{2195} " .. _("Flip V"),  callback = function() close(); self:flipShape(sel, "v") end },
            },
            {
                { text = "\u{25B2} " .. _("To front"),  callback = function() close(); self:shapeToFront(sel) end },
                { text = "\u{29C9} " .. _("Duplicate"), callback = function() close(); self:duplicateSelected(sel) end },
            },
            {
                { text = "\u{25D1} " .. _("Colour"),  callback = function() close(); self:editSelectedColour(sel) end },
                { text = "\u{25A9} " .. _("Opacity"), callback = function() close(); self:editSelectedOpacity(sel) end },
                { text = "\u{25CF} " .. _("Size"),    callback = function() close(); self:editSelectedSize(sel) end },
            },
            {
                { text = "\u{2715} " .. _("Delete"), callback = function() close(); self:deleteSelected(sel) end },
                { text = _("Done"), callback = function() close(); self:deselectShape() end },
            },
        },
    }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

-- Rotate the selected shape a quarter turn about its centre (a handy preset next
-- to the free-rotate drag). Shapes carry op.angle in radians.
function InkAwayView:rotateShape90(sel)
    self:applyEdit(sel, function(o) o.angle = ((o.angle or 0) + math.pi / 2) end)
    self:openShapeMenu(sel)
end

-- Is a screen point on the given shape op (for picking it up to drag)?
function InkAwayView:pointOnShape(op, sx, sy)
    if not (op and op.kind == "shape") then return false end
    local cx, cy = InkGeom.toCanvas(self.view, sx, sy)
    local tol = (op.width or 6) / 2 + 12 / self.view.zoom
    return Shapes.hit(op, cx, cy, tol)
end

-- Drag a selected shape freely, like an image. The move is copy-on-write (a clone
-- is edited from the first movement) so undo restores the original position.
function InkAwayView:shapeMoveTouch(pos)
    self.shape_move = { sx = pos.x, sy = pos.y, began = false }
    return true
end

function InkAwayView:shapeMovePan(pos)
    local d = self.shape_move
    if not d then return true end
    local sel = self.selected
    if not sel then self.shape_move = nil; return true end
    if not d.began then
        -- First real movement: snapshot for undo, edit a clone, and drop it from the
        -- master ONCE. From here the drag is a cheap screen-space preview (a single
        -- Shapes.render into the changed rect), so recomposing every ops in the
        -- canvas per frame -- the old, frozen path -- never happens.
        self.canvas:pushHistory()
        local clone = self.canvas:cloneOp(sel.op)
        self.canvas:replaceOp(sel.idx, clone)
        sel.op = clone
        clone.hidden = true
        d.began = true
        d.lastx, d.lasty = d.sx, d.sy
        self.dirty = true
        self:composeCanvas(); self:renderView()   -- once: the master, minus the shape
        self._preview_rect = nil
    end
    local v = self.view
    local dx = (pos.x - d.lastx) / v.zoom
    local dy = (pos.y - d.lasty) / v.zoom
    d.lastx, d.lasty = pos.x, pos.y
    translateOp(sel.op, dx, dy)
    self.shape_preview = self:screenShapeFromOp(sel.op, sel.op.angle or 0)
    self:refreshPreview()   -- only the old+new preview rects repaint
    return true
end

function InkAwayView:shapeMoveRelease()
    if self.shape_move then
        local moved = self.shape_move.began
        self.shape_move = nil
        if moved then
            local sel = self.selected
            if sel and sel.op then sel.op.hidden = nil end   -- bake it back into the master
            self.shape_preview = nil
            self._preview_rect = nil
            self:composeCanvas(); self:renderView()
        end
        if self._shape_menu then self:openShapeMenu(self.selected) end   -- re-anchor the menu
        UIManager:setDirty(self, "ui", self:areaScreenRect())
    end
    return true
end

-- Apply an edit to the selected op through copy-on-write, so undo/redo work.
function InkAwayView:applyEdit(sel, mutate)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    mutate(clone)
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    if self.selected then self.selected.op = clone end
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:deleteSelected(sel)
    self.canvas:pushHistory()
    self.canvas:removeOp(sel.idx)
    self.selected = nil
    self.shape_move = nil
    self:setSelectionActive(false)
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self.dirty = true
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Duplicate the selected shape, offset a little, and select the copy.
function InkAwayView:duplicateSelected(sel)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    local d = self.grid_on and self.grid_size or 14
    for i = 1, #clone.pts, 2 do clone.pts[i] = clone.pts[i] + d; clone.pts[i + 1] = clone.pts[i + 1] + d end
    self.canvas.ops[#self.canvas.ops + 1] = clone
    self.selected = { op = clone, idx = #self.canvas.ops }
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openShapeMenu(self.selected)
end

-- Flip the selected shape across the middle of its own bounding box (mirrors the
-- image Flip H / Flip V). Reflecting the defining points and negating the rotation
-- angle mirrors the shape exactly, whatever its rotation.
function InkAwayView:flipShape(sel, axis)
    self:applyEdit(sel, function(o)
        local p = o.pts
        local start = axis == "h" and 1 or 2   -- x's are odd indices, y's even
        local lo, hi = p[start], p[start]
        for i = start, #p, 2 do
            if p[i] < lo then lo = p[i] elseif p[i] > hi then hi = p[i] end
        end
        local s = lo + hi
        for i = start, #p, 2 do p[i] = s - p[i] end
        o.angle = -(o.angle or 0)
    end)
    self:openShapeMenu(sel)
end

-- Move the selected shape to the top of the stack, so later marks no longer cover
-- it (mirrors the image To front). Reordering the array is snapshot-safe.
function InkAwayView:shapeToFront(sel)
    local ops = self.canvas.ops
    if sel.idx >= #ops then self:openShapeMenu(sel); return end
    self.canvas:pushHistory()
    local op = table.remove(ops, sel.idx)
    ops[#ops + 1] = op
    sel.idx = #ops
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openShapeMenu(sel)
end

-- Nudge the selected shape by (dx,dy) canvas px (a grid step, or a few px).
function InkAwayView:nudgeSelected(sel, dirx, diry)
    local step = self.grid_on and self.grid_size or 6
    self:applyEdit(sel, function(o)
        for i = 1, #o.pts, 2 do o.pts[i] = o.pts[i] + dirx * step; o.pts[i + 1] = o.pts[i + 1] + diry * step end
    end)
    self:openShapeMenu(sel)   -- keep the menu up for repeated nudges
end

function InkAwayView:editSelectedColour(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local function pick(rgb)
        self:applyEdit(sel, function(o) o.color = { rgb[1], rgb[2], rgb[3] } end)
        UIManager:close(dlg)
        self:editSelectedColour(sel)   -- reopen to move the selection border
    end
    local buttons = { self:swatchRowFor(SHADES, sel.op.color, pick) }
    if self:colorScreen() then
        buttons[#buttons + 1] = self:swatchRowFor(COLORS, sel.op.color, pick)
    end
    buttons[#buttons + 1] = {{ text = _("Done"), callback = function() UIManager:close(dlg) end }}
    dlg = ButtonDialog:new{ title = _("Shape colour"), title_align = "center", buttons = buttons }
    UIManager:show(dlg)
end

function InkAwayView:editSelectedSize(sel)
    local SpinWidget = require("ui/widget/spinwidget")
    local op = sel.op
    UIManager:show(SpinWidget:new{
        title_text = _("Shape line size"),
        value = op.width, value_min = 1, value_max = 60, value_step = 1, value_hold_step = 6,
        unit = _("px"),
        callback = function(spin)
            self:applyEdit(sel, function(o) o.width = math.max(1, math.floor(spin.value)) end)
        end,
    })
end

function InkAwayView:editSelectedOpacity(sel)
    local SpinWidget = require("ui/widget/spinwidget")
    local op = sel.op
    UIManager:show(SpinWidget:new{
        title_text = _("Shape opacity"),
        value = math.floor((op.alpha or 255) / 255 * 100 + 0.5),
        value_min = 5, value_max = 100, value_step = 5, value_hold_step = 20,
        unit = "%",
        callback = function(spin)
            self:applyEdit(sel, function(o)
                o.alpha = math.max(1, math.min(255, math.floor(spin.value / 100 * 255 + 0.5)))
            end)
        end,
    })
end

-- Rotation: hide the shape from the master, show it as a preview, and let a drag
-- spin it freely about its centre. Cheap per frame (only the preview redraws).
function InkAwayView:beginRotate(sel)
    local op = sel.op
    self:setSelectionActive(false)   -- the menu is gone; rotate routes at the top
    self.shape_move = nil
    op.hidden = true
    self.rotating = { op = op, idx = sel.idx, base = op.angle or 0, cur = op.angle or 0 }
    self:composeCanvas(); self:renderView()
    self.shape_preview = self:screenShapeFromOp(op, op.angle or 0)
    self._preview_rect = nil
    self:refreshPreview()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    UIManager:show(InfoMessage:new{
        text = _("Drag anywhere to rotate the shape; lift to finish."), timeout = 2 })
end

function InkAwayView:rotateCentreScreen(op)
    if op.shape == "poly" then
        local p = op.pts
        local minx, miny, maxx, maxy = p[1], p[2], p[1], p[2]
        for i = 1, #p, 2 do
            if p[i] < minx then minx = p[i] elseif p[i] > maxx then maxx = p[i] end
            if p[i + 1] < miny then miny = p[i + 1] elseif p[i + 1] > maxy then maxy = p[i + 1] end
        end
        return InkGeom.toScreen(self.view, (minx + maxx) / 2, (miny + maxy) / 2)
    end
    local x0, y0, x1, y1 = op.pts[1], op.pts[2], op.pts[3], op.pts[4]
    return InkGeom.toScreen(self.view, (x0 + x1) / 2, (y0 + y1) / 2)
end

function InkAwayView:rotateTouch(pos)
    local r = self.rotating
    local cx, cy = self:rotateCentreScreen(r.op)
    r.cx, r.cy = cx, cy
    r.grab = math.atan2(pos.y - cy, pos.x - cx)
    return true
end

function InkAwayView:rotateMove(pos)
    local r = self.rotating
    if not r.grab then return self:rotateTouch(pos) end
    local a = math.atan2(pos.y - r.cy, pos.x - r.cx)
    r.cur = r.base + (a - r.grab)
    self.shape_preview = self:screenShapeFromOp(r.op, r.cur)
    self:refreshPreview()
    return true
end

function InkAwayView:rotateEnd()
    local r = self.rotating
    if not r then return true end
    r.op.hidden = nil
    self.rotating = nil
    self.shape_preview = nil
    self._preview_rect = nil
    if math.abs((r.cur or r.base) - r.base) > 1e-4 then
        -- commit the new angle through copy-on-write so it can be undone
        self.canvas:pushHistory()
        local clone = self.canvas:cloneOp(r.op)
        clone.angle = r.cur
        self.canvas:replaceOp(r.idx, clone)
        if self.selected then self.selected.op = clone end
        self.dirty = true
    end
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

------------------------------------------------------------------------------
-- Images: place a PNG/JPEG on the page, move/resize it with corner handles, and
-- rotate/flip/reorder it from a hold menu (mirrors the placed-shape menu). An
-- image is an op:
--   { kind="image", x, y, w, h (canvas px), path, natw, nath,
--     angle = 0|90|180|270, flip_h, flip_v }
-- The decoded pixels are cached by path and NEVER serialised, so a project file
-- stores just the path (+ box + orientation) and re-decodes on load. Images
-- compose into the master and export exactly like other ops, so every save
-- includes them. The selected image is skipped from the master by identity (not
-- a stored flag, so undo/redo snapshots stay clean) and drawn as a live overlay,
-- so moving and resizing never recompose the whole page.
------------------------------------------------------------------------------

local IMG_HANDLE = 44   -- touch target for the move / resize handles (screen px)
local IMG_MIN    = 24   -- smallest image side, in canvas px

-- Free every decoded / scaled / oriented / display image buffer and drop the
-- caches. Buffers can be shared (a scaled copy may BE its source when sizes
-- match), so a `seen` set frees each underlying buffer exactly once.
function InkAwayView:freeImageCache()
    local seen = {}
    local function drop(bb)
        if bb and bb.free and not seen[bb] then seen[bb] = true; pcall(function() bb:free() end) end
    end
    if self._img_disp then drop(self._img_disp.bb); self._img_disp = nil end
    if self._img_render then for _, e in pairs(self._img_render) do drop(e.bb) end; self._img_render = nil end
    if self._img_scaled then for _, e in pairs(self._img_scaled) do drop(e.bb) end; self._img_scaled = nil end
    if self._img_bb then for _, bb in pairs(self._img_bb) do drop(bb) end; self._img_bb = nil end
end

-- Free just the one screen-scaled display buffer (rebuilt on the next paint).
function InkAwayView:freeImageDisplay()
    local d = self._img_disp
    if d and d.bb and d.bb.free then pcall(function() d.bb:free() end) end
    self._img_disp = nil
end

-- A short signature of an op's orientation, used as a cache key so a rotate/flip
-- invalidates the oriented and scaled buffers.
local function orientSig(op)
    return ((op.angle or 0) % 360) .. "/" .. (op.flip_h and 1 or 0) .. "/" .. (op.flip_v and 1 or 0)
end

-- Decode (once, cached by path) the source picture for an op as a BBRGB32 that
-- keeps its alpha. The resident copy is capped to the canvas size: an image is
-- never shown or exported larger than the page, so keeping a full-resolution
-- decode (a high-megapixel photo is tens of MB in RGBA) would only waste memory.
-- We downscale once, preserving aspect, and never upscale. Returns the buffer or
-- nil. A `false` entry caches a decode failure so we do not retry every frame.
function InkAwayView:imageSrc(op)
    if not op or not op.path then return nil end
    self._img_bb = self._img_bb or {}
    local c = self._img_bb[op.path]
    if c ~= nil then return c or nil end
    local ok, img = pcall(function() return RenderImage:renderImageFile(op.path, false) end)
    local norm = false
    if ok and img then
        local iw, ih = img:getWidth(), img:getHeight()
        local W, H = self.view.canvas_w, self.view.canvas_h
        local cap = math.min(1, W / iw, H / ih)          -- <=1: only ever shrink
        local sw = math.max(1, math.floor(iw * cap + 0.5))
        local sh = math.max(1, math.floor(ih * cap + 0.5))
        local source = img
        if sw ~= iw or sh ~= ih then
            local sok, s = pcall(function() return RenderImage:scaleBlitBuffer(img, sw, sh, false) end)
            if sok and s then source = s end
        end
        -- Normalise to a BBRGB32 with a transparent ground, so the on-screen
        -- alpha-blit and the raw-bytes export both see a uniform r,g,b,a layout.
        local n = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BBRGB32)
        n:fill(Blitbuffer.ColorRGB32(0, 0, 0, 0))
        pcall(function() n:blitFrom(source, 0, 0, 0, 0, sw, sh) end)
        if source ~= img and source.free then source:free() end
        if img.free then img:free() end
        norm = n
    end
    self._img_bb[op.path] = norm
    return norm or nil
end

-- Build a copy of `src` with the flips and a quarter-turn rotation baked in, by an
-- exact pixel permutation (no interpolation, no gaps). A quarter turn swaps the
-- dimensions. Returns the new buffer, or nil if the pixels could not be read.
-- The axis-aligned bounding box (canvas coords) of an image op at its angle,
-- computed analytically (no buffer): op.w/op.h are the unrotated size, the box
-- grows as it turns. Returns x, y, w, h.
local function imageBBox(op)
    local a = math.rad((op.angle or 0) % 360)
    local c, s = math.abs(math.cos(a)), math.abs(math.sin(a))
    local bw = op.w * c + op.h * s
    local bh = op.w * s + op.h * c
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    return cx - bw / 2, cy - bh / 2, bw, bh
end

-- Build a copy of `src` with the flips and an arbitrary rotation baked in. A
-- quarter turn is an exact pixel permutation (lossless, swaps the dimensions);
-- any other angle is a nearest-neighbour resample into the rotated bounding box
-- (transparent corners). Returns the new buffer, or nil if pixels can't be read.
local function resampleOriented(src, angleDeg, fh, fv)
    local sw, sh = src:getWidth(), src:getHeight()
    local a = angleDeg % 360
    if a == 0 or a == 90 or a == 180 or a == 270 then
        local quarter = (a == 90 or a == 270)
        local dw = quarter and sh or sw
        local dh = quarter and sw or sh
        local dst = Blitbuffer.new(dw, dh, Blitbuffer.TYPE_BBRGB32)
        pcall(function() ffi.fill(dst.data, dst.stride * dst:getHeight(), 0) end)   -- true transparent (colour fill sets alpha opaque)
        local ok = pcall(function()
            for sy = 0, sh - 1 do
                local yy = fv and (sh - 1 - sy) or sy
                for sx = 0, sw - 1 do
                    local xx = fh and (sw - 1 - sx) or sx
                    local dx, dy
                    if a == 90 then dx, dy = sh - 1 - yy, xx
                    elseif a == 180 then dx, dy = sw - 1 - xx, sh - 1 - yy
                    elseif a == 270 then dx, dy = yy, sw - 1 - xx
                    else dx, dy = xx, yy end
                    dst:setPixel(dx, dy, src:getPixel(sx, sy))
                end
            end
        end)
        if not ok then if dst.free then dst:free() end; return nil end
        return dst
    end
    local ar = math.rad(a)
    local cosA, sinA = math.cos(ar), math.sin(ar)
    local bw = math.max(1, math.ceil(math.abs(sw * cosA) + math.abs(sh * sinA)))
    local bh = math.max(1, math.ceil(math.abs(sw * sinA) + math.abs(sh * cosA)))
    local dst = Blitbuffer.new(bw, bh, Blitbuffer.TYPE_BBRGB32)
    pcall(function() ffi.fill(dst.data, dst.stride * dst:getHeight(), 0) end)   -- true transparent (colour fill sets alpha opaque)
    local cxs, cys, cxd, cyd = sw / 2, sh / 2, bw / 2, bh / 2
    local ok = pcall(function()
        for dy = 0, bh - 1 do
            local ry = dy + 0.5 - cyd
            for dx = 0, bw - 1 do
                local rx = dx + 0.5 - cxd
                local ux = rx * cosA + ry * sinA + cxs   -- inverse rotate to source
                local uy = -rx * sinA + ry * cosA + cys
                if fh then ux = sw - ux end
                if fv then uy = sh - uy end
                local sxi = math.floor(ux)
                local syi = math.floor(uy)
                if sxi >= 0 and sxi < sw and syi >= 0 and syi < sh then
                    dst:setPixel(dx, dy, src:getPixel(sxi, syi))
                end
            end
        end
    end)
    if not ok then if dst.free then dst:free() end; return nil end
    return dst
end

-- The picture scaled to the op's on-page size (canvas px), UNROTATED. One copy is
-- kept per path, rebuilt only on a size change, so a resize drag never piles up
-- buffers and a move drag reuses the cached scale.
function InkAwayView:imageScaled(op)
    local src = self:imageSrc(op)
    if not src then return nil end
    local w = math.max(1, math.floor(op.w + 0.5))
    local h = math.max(1, math.floor(op.h + 0.5))
    self._img_scaled = self._img_scaled or {}
    local e = self._img_scaled[op.path]
    if e and e.w == w and e.h == h then return e.bb or nil end
    if e and e.bb and e.bb ~= src and e.bb.free then pcall(function() e.bb:free() end) end
    local scaled
    if w == src:getWidth() and h == src:getHeight() then
        scaled = src
    else
        local ok, s = pcall(function() return RenderImage:scaleBlitBuffer(src, w, h, false) end)
        scaled = (ok and s) or false
    end
    self._img_scaled[op.path] = { w = w, h = h, bb = scaled or false }
    return scaled or nil
end

-- The fully oriented (flipped + rotated) bitmap at on-page size, plus its top-left
-- in CANVAS coords -- which shifts away from op.x/op.y once the picture is rotated,
-- since the bounding box grows. Cached per path; rebuilt only when the size or
-- orientation changes (never per drag frame). With no orientation it returns the
-- plain scaled buffer at op.x/op.y, so the common case allocates nothing extra.
function InkAwayView:imageRendered(op)
    local scaled = self:imageScaled(op)
    if not scaled then return nil end
    local cx, cy = op.x + op.w / 2, op.y + op.h / 2
    if orientSig(op) == "0/0/0" then return scaled, op.x, op.y end
    local sig = orientSig(op)
    local w, h = math.max(1, math.floor(op.w + 0.5)), math.max(1, math.floor(op.h + 0.5))
    self._img_render = self._img_render or {}
    local e = self._img_render[op.path]
    if not (e and e.sig == sig and e.w == w and e.h == h and e.bb) then
        if e and e.bb and e.bb ~= scaled and e.bb.free then pcall(function() e.bb:free() end) end
        local bb = resampleOriented(scaled, (op.angle or 0) % 360, op.flip_h, op.flip_v)
        e = { sig = sig, w = w, h = h, bb = bb or false }
        self._img_render[op.path] = e
    end
    if not e.bb then return nil end
    return e.bb, cx - e.bb:getWidth() / 2, cy - e.bb:getHeight() / 2
end

-- The rendered picture scaled to on-SCREEN size and its screen top-left, for the
-- live overlay, so the selected image is exactly the size and place it will occupy
-- once committed (no jump on Done). Returns bb, sx, sy (area-relative).
function InkAwayView:imageDisplayScaled(op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return nil end
    local v = self.view
    local sx, sy = InkGeom.toScreen(v, ox, oy)
    local dw = math.max(1, math.floor(bb:getWidth() * v.zoom + 0.5))
    local dh = math.max(1, math.floor(bb:getHeight() * v.zoom + 0.5))
    if bb:getWidth() == dw and bb:getHeight() == dh then return bb, sx, sy end
    local sig = orientSig(op) .. ":" .. dw .. "x" .. dh
    local e = self._img_disp
    if e and e.path == op.path and e.sig == sig and e.bb then return e.bb, sx, sy end
    if e and e.bb and e.bb.free then pcall(function() e.bb:free() end) end
    local ok, s = pcall(function() return RenderImage:scaleBlitBuffer(bb, dw, dh, false) end)
    self._img_disp = { path = op.path, sig = sig, bb = (ok and s) or false }
    return (ok and s) or nil, sx, sy
end

-- RGBA byte buffer for export: the oriented picture at on-page size. Returns
-- buf, w, h, ox, oy (canvas top-left). Injected into Export as Export.image_raster.
function InkAwayView:exportImageRaster(op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return nil end
    local w, h = bb:getWidth(), bb:getHeight()
    local buf = bbToRGBA(bb, w, h)
    if not buf then return nil end
    return buf, w, h, ox, oy
end

-- Blit an image op into the canvas-space master `dst`, at its (rotated) top-left,
-- clipped to the canvas.
function InkAwayView:blitImageInto(dst, op)
    local bb, ox, oy = self:imageRendered(op)
    if not bb then return end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local sw, sh = bb:getWidth(), bb:getHeight()
    local dx, dy = math.floor(ox + 0.5), math.floor(oy + 0.5)
    local sx0 = dx < 0 and -dx or 0
    local sy0 = dy < 0 and -dy or 0
    local cx0 = math.max(0, dx)
    local cy0 = math.max(0, dy)
    local cw = math.min(sw - sx0, W - cx0)
    local ch = math.min(sh - sy0, H - cy0)
    if cw > 0 and ch > 0 then
        pcall(function() dst:alphablitFrom(bb, cx0, cy0, sx0, sy0, cw, ch) end)
    end
end

-- The selected image's on-screen rectangle: the (rotated) bounding box, so the
-- frame and handles wrap the whole picture whatever its angle.
function InkAwayView:imageScreenRect()
    local op, v = self.active_image.op, self.view
    local bb, ox, oy = self:imageRendered(op)
    local bw = (bb and bb:getWidth() or op.w) * v.zoom
    local bh = (bb and bb:getHeight() or op.h) * v.zoom
    local sx, sy = InkGeom.toScreen(v, ox or op.x, oy or op.y)
    return { x = sx, y = sy, w = bw, h = bh }
end

-- Which part of the selected image a screen point falls on: a corner ("nw"/"ne"/
-- "sw"/"se") to resize, "move" inside, or "outside".
function InkAwayView:imageZone(sx, sy)
    local r = self:imageScreenRect()
    local function near(hx, hy)
        return sx >= hx - IMG_HANDLE and sx <= hx + IMG_HANDLE
           and sy >= hy - IMG_HANDLE and sy <= hy + IMG_HANDLE
    end
    if near(r.x, r.y) then return "nw" end
    if near(r.x + r.w, r.y) then return "ne" end
    if near(r.x, r.y + r.h) then return "sw" end
    if near(r.x + r.w, r.y + r.h) then return "se" end
    if sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h then return "move" end
    return "outside"
end

-- Refresh the union of two area-relative rects (plus handle margin), clamped to
-- the drawing area, with the given refresh mode.
function InkAwayView:refreshImageUnion(a, b, mode)
    local v = self.view
    local pad = IMG_HANDLE + 4
    local x0 = math.max(v.area_x, math.min(a.x, b.x) - pad)
    local y0 = math.max(v.area_y, math.min(a.y, b.y) - pad)
    local x1 = math.min(v.area_x + v.area_w, math.max(a.x + a.w, b.x + b.w) + pad)
    local y1 = math.min(v.area_y + v.area_h, math.max(a.y + a.h, b.y + b.h) + pad)
    if x1 > x0 and y1 > y0 then
        UIManager:setDirty(self, mode or "fast", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    end
end

-- Pick the image under a canvas point (topmost first). Uses the rotated bounding
-- box so a turned picture is still grabbable over its whole visible area.
function InkAwayView:hitTestImage(sx, sy)
    local cx, cy = self:toCanvasClamped(sx, sy)
    local ops = self.canvas.ops
    for i = #ops, 1, -1 do
        local op = ops[i]
        if op.kind == "image" then
            local bx, by, bw, bh = imageBBox(op)
            if cx >= bx and cx <= bx + bw and cy >= by and cy <= by + bh then
                return { op = op, idx = i }
            end
        end
    end
    return nil
end

-- Keep the canvas receiving gestures while a popup is on top (KOReader only
-- delivers events to a lower widget that is is_always_active), so the picture can
-- be dragged with its menu open. The previous value is restored on close.
function InkAwayView:setSelectionActive(on)
    if on then
        if self._sel_prev_active == nil then self._sel_prev_active = self.is_always_active or false end
        self.is_always_active = true
    elseif self._sel_prev_active ~= nil then
        self.is_always_active = self._sel_prev_active
        self._sel_prev_active = nil
    end
end

-- Select an image. It stays in the ops list and in the master (composeInto only
-- skips it while it is actively dragged), so picking it up changes NO pixels of
-- the drawing -- only a frame and corner handles are drawn over its own rectangle.
-- We therefore refresh just that rectangle, never the whole area: a full-area
-- flashing refresh on every pick was the black flash when moving in pan mode.
-- `fresh` = a just-inserted image that is not in the master yet, so bake it in
-- once (that single insert refresh is expected).
function InkAwayView:selectImage(sel, fresh)
    if self.active_image and self.active_image.op ~= sel.op then self:finishImageEdit() end
    self.active_image = sel
    self._img_drag = nil
    self:freeImageDisplay()
    if fresh then
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
    else
        self:refreshImageUnion(self:imageScreenRect(), self:imageScreenRect(), "ui")
    end
end

-- Finish editing: close the menu, drop the selection, and recompose so the image
-- is baked back into the master at its final spot. Safe to call more than once
-- (e.g. the menu's tap-outside close and a Done both route here).
function InkAwayView:finishImageEdit()
    if not (self.active_image or self.image_rotating or self._image_menu) then return end
    local menu = self._image_menu; self._image_menu = nil
    if menu then pcall(function() UIManager:close(menu) end) end
    self:setSelectionActive(false)
    self.active_image = nil
    self._img_drag = nil
    self.image_rotating = nil
    self:freeImageDisplay()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end
InkAwayView.flushImage = InkAwayView.finishImageEdit

function InkAwayView:deleteActiveImage()
    local sel = self.active_image
    if not sel then return end
    local menu = self._image_menu; self._image_menu = nil
    if menu then pcall(function() UIManager:close(menu) end) end
    self:setSelectionActive(false)
    self.active_image = nil
    self._img_drag = nil
    self.image_rotating = nil
    self:freeImageDisplay()
    self.canvas:pushHistory()
    self.canvas:removeOp(sel.idx)
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Copy-on-write before mutating the selected image, so the pre-drag / pre-edit
-- state stays in the undo snapshot (older snapshots keep the original op). Call
-- once at the start of a change; returns the editable clone.
function InkAwayView:beginImageEdit()
    self.canvas:pushHistory()
    local sel = self.active_image
    local clone = self.canvas:cloneOp(sel.op)
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    self.dirty = true
    return clone
end

-- Apply one discrete edit (rotate / flip / etc.) to the selected image through
-- copy-on-write, then recompose. Undo/redo restore the previous op.
function InkAwayView:applyImageEdit(sel, mutate)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    mutate(clone)
    self.canvas:replaceOp(sel.idx, clone)
    sel.op = clone
    self.dirty = true
    self:freeImageDisplay()   -- size / orientation may have changed
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Rotate a quarter turn clockwise about the image centre. op.w/op.h are the
-- UNROTATED size, so a quarter turn only bumps op.angle; the bounding box (and
-- the frame) follow from the angle.
function InkAwayView:rotateImage90(sel)
    self:applyImageEdit(sel, function(o) o.angle = ((o.angle or 0) + 90) % 360 end)
    self:openImageMenu(sel)   -- keep the menu up for repeated turns
end

function InkAwayView:flipImage(sel, axis)
    self:applyImageEdit(sel, function(o)
        if axis == "h" then o.flip_h = not o.flip_h else o.flip_v = not o.flip_v end
    end)
    self:openImageMenu(sel)
end

-- Move the image to the top of the stack, so later strokes/images no longer cover
-- it. Reordering the array is safe against snapshots (the op itself is untouched).
function InkAwayView:imageToFront(sel)
    local ops = self.canvas.ops
    if sel.idx >= #ops then self:openImageMenu(sel); return end
    self.canvas:pushHistory()
    local op = table.remove(ops, sel.idx)
    ops[#ops + 1] = op
    sel.idx = #ops
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openImageMenu(sel)
end

-- Duplicate the selected image, offset a little, and select the copy (mirrors the
-- shape Duplicate). The pixels are shared by path -- only the box is copied -- so a
-- duplicate costs no extra image memory.
function InkAwayView:duplicateImage(sel)
    self.canvas:pushHistory()
    local clone = self.canvas:cloneOp(sel.op)
    local d = self.grid_on and self.grid_size or 14
    clone.x = clone.x + d; clone.y = clone.y + d
    self.canvas.ops[#self.canvas.ops + 1] = clone
    self.active_image = { op = clone, idx = #self.canvas.ops }
    self._img_drag = nil
    self:freeImageDisplay()
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    self:openImageMenu(self.active_image)
end

-- Free rotation: like the shape rotate, drag anywhere to spin the picture to any
-- angle; a live preview follows the finger, and the angle is committed on lift.
function InkAwayView:beginImageRotate(sel)
    self.image_rotating = { base = sel.op.angle or 0, cur = sel.op.angle or 0 }
    self:composeCanvas(); self:renderView()   -- drop it from the master; preview draws it
    UIManager:show(InfoMessage:new{
        text = _("Drag to rotate the image; lift to finish."), timeout = 2 })
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:imageRotateTouch(pos)
    local op, v = self.active_image.op, self.view
    local cx, cy = InkGeom.toScreen(v, op.x + op.w / 2, op.y + op.h / 2)
    local r = self.image_rotating
    r.cx, r.cy = cx, cy
    r.grab = math.deg(math.atan2(pos.y - cy, pos.x - cx))
    return true
end

function InkAwayView:imageRotateMove(pos)
    local r = self.image_rotating
    if not r.grab then return self:imageRotateTouch(pos) end
    local a = math.deg(math.atan2(pos.y - r.cy, pos.x - r.cx))
    r.cur = r.base + (a - r.grab)
    UIManager:setDirty(self, "fast", self:areaScreenRect())   -- preview redraws
    return true
end

function InkAwayView:imageRotateEnd()
    local r = self.image_rotating
    if not r then return true end
    self.image_rotating = nil
    local sel = self.active_image
    if sel then
        self:applyImageEdit(sel, function(o) o.angle = (r.cur % 360 + 360) % 360 end)
        self:openImageMenu(sel)
    end
    return true
end

-- The hold/tap menu for a placed image, anchored beside it -- same ButtonDialog
-- look as the shape edit menu (free rotate, a 90-degree preset, flips, to front,
-- and the same delete glyph). The image stays draggable underneath (see
-- setSelectionActive); a tap outside the menu deselects and bakes it in.
function InkAwayView:openImageMenu(sel)
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._image_menu then UIManager:close(self._image_menu); self._image_menu = nil end
    self:setSelectionActive(true)
    local dlg
    local function close() if dlg then UIManager:close(dlg) end end
    dlg = ButtonDialog:new{
        shrink_unneeded_width = true,
        tap_close_callback = function() self:finishImageEdit() end,
        anchor = function()
            local r = self:imageScreenRect()
            return GeomUI:new{ x = math.floor(r.x), y = math.floor(r.y),
                               w = math.ceil(r.w), h = math.ceil(r.h) }
        end,
        buttons = {
            {
                { text = "\u{27F3} " .. _("Rotate"),  callback = function() close(); self:beginImageRotate(sel) end },
                { text = "\u{21BB} " .. _("90\u{00B0}"), callback = function() close(); self:rotateImage90(sel) end },
            },
            {
                { text = "\u{2194} " .. _("Flip H"),  callback = function() close(); self:flipImage(sel, "h") end },
                { text = "\u{2195} " .. _("Flip V"),  callback = function() close(); self:flipImage(sel, "v") end },
            },
            {
                { text = "\u{25B2} " .. _("To front"),  callback = function() close(); self:imageToFront(sel) end },
                { text = "\u{29C9} " .. _("Duplicate"), callback = function() close(); self:duplicateImage(sel) end },
            },
            {
                { text = "\u{2715} " .. _("Delete"), callback = function() close(); self:deleteActiveImage() end },
                { text = _("Done"), callback = function() close(); self:finishImageEdit() end },
            },
        },
    }
    self._image_menu = dlg
    UIManager:show(dlg)
end

function InkAwayView:imageTouch(pos)
    local op = self.active_image.op
    local zone = self:imageZone(pos.x, pos.y)
    if zone == "move" then
        self._img_drag = { kind = "move", sx = pos.x, sy = pos.y, x0 = op.x, y0 = op.y }
        return true
    elseif zone ~= "outside" then
        if ((op.angle or 0) % 360) ~= 0 then
            -- rotated: resize by scaling uniformly about the centre
            local cxC, cyC = op.x + op.w / 2, op.y + op.h / 2
            local ccx, ccy = self:toCanvasClamped(pos.x, pos.y)
            local d0 = math.max(1, math.sqrt((ccx - cxC) ^ 2 + (ccy - cyC) ^ 2))
            self._img_drag = { kind = "resize", rotated = true, cxC = cxC, cyC = cyC,
                               d0 = d0, w0 = op.w, h0 = op.h }
        else
            -- upright: keep the OPPOSITE corner fixed, aspect locked
            local ax = (zone == "nw" or zone == "sw") and (op.x + op.w) or op.x
            local ay = (zone == "nw" or zone == "ne") and (op.y + op.h) or op.y
            self._img_drag = { kind = "resize", corner = zone, ax = ax, ay = ay, w0 = op.w, h0 = op.h }
        end
        return true
    else
        -- Touched outside the picture. If the menu is open, leave it: this touch is
        -- almost certainly on a menu button, and the dialog's own tap-outside close
        -- handles a genuine tap away. Only deselect here when no menu is up.
        if not self._image_menu then self:finishImageEdit() end
        return true
    end
end

function InkAwayView:imagePan(pos)
    local d = self._img_drag
    if not d then return true end
    -- Take the undo snapshot on the FIRST real movement (a plain tap that never
    -- moves records no history), then edit a clone from here on. Recompose once so
    -- the master drops the image (now it is the live overlay) for a smooth drag.
    if not d.began then
        self:beginImageEdit(); d.began = true
        self:composeCanvas(); self:renderView()
    end
    local op, v = self.active_image.op, self.view
    local old = self:imageScreenRect()
    if d.kind == "move" then
        op.x = d.x0 + (pos.x - d.sx) / v.zoom
        op.y = d.y0 + (pos.y - d.sy) / v.zoom
    elseif d.kind == "resize" and d.rotated then
        local ccx, ccy = self:toCanvasClamped(pos.x, pos.y)
        local dn = math.sqrt((ccx - d.cxC) ^ 2 + (ccy - d.cyC) ^ 2)
        local scale = math.max(dn / d.d0, IMG_MIN / math.min(d.w0, d.h0))
        op.w, op.h = d.w0 * scale, d.h0 * scale
        op.x, op.y = d.cxC - op.w / 2, d.cyC - op.h / 2
    elseif d.kind == "resize" then
        local cx, cy = self:toCanvasClamped(pos.x, pos.y)
        local wp = math.abs(cx - d.ax)
        local hp = math.abs(cy - d.ay)
        local scale = math.max(wp / d.w0, hp / d.h0, IMG_MIN / d.w0)
        local nw, nh = d.w0 * scale, d.h0 * scale
        op.w, op.h = nw, nh
        op.x = (d.corner == "nw" or d.corner == "sw") and (d.ax - nw) or d.ax
        op.y = (d.corner == "nw" or d.corner == "ne") and (d.ay - nh) or d.ay
    end
    self:refreshImageUnion(old, self:imageScreenRect(), "fast")
    return true
end

function InkAwayView:imageRelease()
    -- keep the image selected so it can be adjusted again; settle the view and,
    -- if a menu is open, re-anchor it to the picture's new spot (like shapes do)
    if self._img_drag then
        local moved = self._img_drag.began
        self._img_drag = nil
        if moved then self:composeCanvas(); self:renderView() end   -- bake it back in
        self:refreshImageUnion(self:imageScreenRect(), self:imageScreenRect(), "ui")
        if moved and self._image_menu then self:openImageMenu(self.active_image) end
    end
    return true
end

-- Draw the selected image as a live overlay (it is skipped from the master while
-- selected), at its true on-screen size, plus its frame and corner handles. While
-- free-rotating, a rotated preview follows the finger instead.
function InkAwayView:paintImageOverlay(bb, x, y)
    local op, v = self.active_image.op, self.view
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    local BLACKC = Blitbuffer.COLOR_BLACK

    if self.image_rotating then
        -- live rotation preview: rotate a screen-scaled copy to the current angle
        local scaled = self:imageScaled(op)
        if scaled then
            local dw = math.max(1, math.floor(op.w * v.zoom + 0.5))
            local dh = math.max(1, math.floor(op.h * v.zoom + 0.5))
            pcall(function()
                local su = RenderImage:scaleBlitBuffer(scaled, dw, dh, false)
                local prev = resampleOriented(su, self.image_rotating.cur, op.flip_h, op.flip_v)
                if su ~= scaled and su.free then su:free() end
                if prev then
                    local ccx, ccy = InkGeom.toScreen(v, op.x + op.w / 2, op.y + op.h / 2)
                    local pw, ph = prev:getWidth(), prev:getHeight()
                    local ox = math.floor(ccx + x - pw / 2)
                    local oy = math.floor(ccy + y - ph / 2)
                    local dx0 = math.max(ox, ax0); local dy0 = math.max(oy, ay0)
                    local dx1 = math.min(ox + pw, ax1); local dy1 = math.min(oy + ph, ay1)
                    if dx1 > dx0 and dy1 > dy0 then
                        bb:alphablitFrom(prev, dx0, dy0, dx0 - ox, dy0 - oy, dx1 - dx0, dy1 - dy0)
                    end
                    if prev.free then prev:free() end
                end
            end)
        end
        return
    end

    local r = self:imageScreenRect()
    local ox, oy = math.floor(r.x + x), math.floor(r.y + y)
    -- The image is only drawn here while it is being dragged (then the master has
    -- dropped it). A still, selected image stays in the master, so we draw only the
    -- frame and handles over it -- picking or dropping never nudges it.
    if self._img_drag and self._img_drag.began then
        local scaled = self:imageDisplayScaled(op)
        if scaled then
            local sw, sh = scaled:getWidth(), scaled:getHeight()
            local dx0 = math.max(ox, ax0); local dy0 = math.max(oy, ay0)
            local dx1 = math.min(ox + sw, ax1); local dy1 = math.min(oy + sh, ay1)
            if dx1 > dx0 and dy1 > dy0 then
                pcall(function() bb:alphablitFrom(scaled, dx0, dy0, dx0 - ox, dy0 - oy, dx1 - dx0, dy1 - dy0) end)
            end
        end
    end
    local fx, fy = math.floor(math.max(ox, ax0)), math.floor(math.max(oy, ay0))
    local fw = math.floor(math.min(ox + r.w, ax1)) - fx
    local fh = math.floor(math.min(oy + r.h, ay1)) - fy
    if fw > 0 and fh > 0 then
        bb:paintRect(fx, fy, fw, 1, BLACKC); bb:paintRect(fx, fy + fh - 1, fw, 1, BLACKC)
        bb:paintRect(fx, fy, 1, fh, BLACKC); bb:paintRect(fx + fw - 1, fy, 1, fh, BLACKC)
    end
    -- corner handles (clamped into the area so they never draw over the toolbar)
    local hs = 12
    local function handle(hx, hy)
        local px = math.max(ax0, math.min(ax1 - hs, math.floor(hx - hs / 2)))
        local py = math.max(ay0, math.min(ay1 - hs, math.floor(hy - hs / 2)))
        bb:paintRect(px, py, hs, hs, BLACKC)
    end
    handle(ox, oy); handle(ox + r.w, oy); handle(ox, oy + r.h); handle(ox + r.w, oy + r.h)
end

-- Insert a new image from a file: fit it to ~60% of the visible area (so its
-- corners show for dragging), centre it in the viewport, and select it. The
-- picture lands in Pan mode with its edit menu already open (see the tail of this
-- function) so it can be moved, resized, duplicated or deleted straight away.
function InkAwayView:insertImage(path)
    local tmp = { kind = "image", path = path, x = 0, y = 0, w = 1, h = 1 }
    local src = self:imageSrc(tmp)
    if not src then
        UIManager:show(InfoMessage:new{ text = _("Could not open that image.") })
        return
    end
    local natw, nath = src:getWidth(), src:getHeight()
    local v = self.view
    local maxw = 0.6 * v.area_w / v.zoom
    local maxh = 0.6 * v.area_h / v.zoom
    local s = math.min(maxw / natw, maxh / nath)
    if s <= 0 then s = 1 end
    local op = { kind = "image", path = path, natw = natw, nath = nath,
                 w = math.max(IMG_MIN, natw * s), h = math.max(IMG_MIN, nath * s) }
    local ccx = v.pan_x + (v.area_w / 2) / v.zoom
    local ccy = v.pan_y + (v.area_h / 2) / v.zoom
    op.x = math.max(0, math.min(v.canvas_w - op.w, ccx - op.w / 2))
    op.y = math.max(0, math.min(v.canvas_h - op.h, ccy - op.h / 2))
    self.canvas:pushHistory()
    self.canvas.ops[#self.canvas.ops + 1] = op
    self.dirty = true
    -- Drop straight into Pan mode with the picture selected and its edit menu open,
    -- exactly as if the reader had tapped it there. Pan mode's move/resize is the
    -- smooth, responsive one, and it isn't obvious you have to switch to it -- so a
    -- freshly added image is immediately ready to move, resize, duplicate or delete.
    self:setTool("pan")
    self:selectImage({ op = op, idx = #self.canvas.ops }, true)   -- fresh: bake it in once
    self:openImageMenu(self.active_image)
end

-- The image tool now asks first: a local file, or browse online. Browsing is
-- entirely optional -- Ink Away never needs a connection -- so the local path is
-- the dark (primary) button and stays exactly as it always was.
function InkAwayView:chooseImage()
    self:flushImage()
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._img_src_dialog then UIManager:close(self._img_src_dialog); self._img_src_dialog = nil end
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Add image"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(self:actionButton(_("Local file"), content_w, function()
            closeSelf(); self:chooseLocalImage() end, true))
        add(vspan(10))
        add(self:actionButton(_("Browse online"), content_w, function()
            closeSelf(); self:browseOnlineImages() end))
        add(vspan(8))
        add(TextBoxWidget:new{ text = _("Browsing needs Wi-Fi. Ink Away itself never requires a connection."),
            face = Font:getFace("cfont", 13), width = content_w,
            fgcolor = Blitbuffer.ColorRGB32(0x80, 0x80, 0x80, 0xFF) })
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._img_src_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._img_src_dialog = nil end }
    UIManager:show(self._img_src_dialog)
end

-- The original local-file picker, unchanged in behaviour.
function InkAwayView:chooseLocalImage()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(path)
            local lower = path:lower()
            if lower:match("%.png$") or lower:match("%.jpe?g$") then
                self:insertImage(path)
            else
                UIManager:show(InfoMessage:new{ text = _("Please choose a PNG or JPEG image.") })
            end
        end,
    })
end

------------------------------------------------------------------------------
-- Handwriting recognition (offline). Templates are built once from the bundled
-- font's glyphs, so coverage follows the font (not just Latin); the pure matcher
-- lives in ink/hwr.lua.
------------------------------------------------------------------------------

-- Sample the OUTLINE of a rendered glyph into a point cloud. The outline (inked
-- pixels bordering blank ones) is a thin curve, so it lies in the same shape space
-- as a thin handwritten stroke -- which discriminates far better than the glyph's
-- solid fill (whose clouds all look alike to the matcher).
function InkAwayView:hwrGlyphCloud(face, charcode)
    local RenderText = require("ui/rendertext")
    local ok, glyph = pcall(function() return RenderText:getGlyph(face, charcode) end)
    if not ok or not glyph or not glyph.bb then return nil end
    local bb = glyph.bb
    local w, h = bb:getWidth(), bb:getHeight()
    if w < 3 or h < 3 then return nil end
    -- scan the glyph into a boolean ink map once
    local map = {}
    for y = 0, h - 1 do
        local row = {}
        for x = 0, w - 1 do
            local okp, v = pcall(function()
                local c = bb:getPixel(x, y)
                if c and c.getColor8 then return c:getColor8().a end
                return 0
            end)
            row[x] = (okp and v and v > 128) and true or false
        end
        map[y] = row
    end
    -- keep inked pixels that touch a blank pixel (or the bitmap edge): the outline
    local pts = {}
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            if map[y][x] then
                local edge = x == 0 or x == w - 1 or y == 0 or y == h - 1
                    or not map[y][x - 1] or not map[y][x + 1]
                    or not map[y - 1][x] or not map[y + 1][x]
                if edge then pts[#pts + 1] = { x = x, y = y } end
            end
        end
    end
    return pts
end

-- Build the recogniser from font glyphs for the given character list. Cached.
function InkAwayView:hwrRecognizer(chars)
    if self._hwr_rec then return self._hwr_rec end
    local Hwr = require("ink/hwr")
    local Font = require("ui/font")
    local rec = Hwr.Recognizer.new()
    local ok = pcall(function()
        local face = Font:getFace("cfont", 48)
        chars = chars or "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        for ch in chars:gmatch(".") do
            local pts = self:hwrGlyphCloud(face, string.byte(ch))
            if pts and #pts >= 8 then rec:add(ch, Hwr.normalizeCloud(pts), true) end
        end
    end)
    if ok and rec:count() > 0 then self._hwr_rec = rec end
    return self._hwr_rec
end

local HWR_PAUSE = 1.1   -- idle seconds after the last pen stroke before recognising

-- Buffer a just-committed pen stroke and (re)start the pause timer. When the pen
-- rests for HWR_PAUSE, hwrRecognizePending fires.
function InkAwayView:hwrCapture(op)
    self._hwr_ops = self._hwr_ops or {}
    self._hwr_ops[#self._hwr_ops + 1] = op
    if not self._hwr_cb then self._hwr_cb = function() self:hwrRecognizePending() end end
    UIManager:unschedule(self._hwr_cb)
    UIManager:scheduleIn(HWR_PAUSE, self._hwr_cb)
end

-- Drop any pending handwriting (timer + buffer). Called when the feature is turned
-- off, the tool changes, or the widget closes.
function InkAwayView:hwrCancel()
    if self._hwr_cb then UIManager:unschedule(self._hwr_cb) end
    self._hwr_ops = nil
end

-- The pause fired: recognise the buffered pen strokes and turn them into text.
function InkAwayView:hwrRecognizePending()
    local buf = self._hwr_ops
    self._hwr_ops = nil
    if not buf or #buf == 0 then return end
    if self.editing_text or self.capturing then return end   -- don't fight an open box / live stroke
    local Hwr = require("ink/hwr")
    local rec = self:hwrRecognizer()
    if not rec then return end
    -- keep only buffered ops that are still on the canvas (not undone / page-changed)
    local present = {}
    for i = 1, #self.canvas.ops do present[self.canvas.ops[i]] = true end
    local strokes, live_ops = {}, {}
    for _, op in ipairs(buf) do
        if present[op] and op.kind == "ink" and op.pts and #op.pts >= 2 then
            local s = {}
            for i = 1, #op.pts, 2 do s[#s + 1] = { x = op.pts[i], y = op.pts[i + 1] } end
            strokes[#strokes + 1] = s
            live_ops[#live_ops + 1] = op
        end
    end
    if #strokes == 0 then return end
    local out = {}
    for _, tk in ipairs(Hwr.segment(strokes)) do
        if tk.kind == "space" then out[#out + 1] = " "
        elseif tk.kind == "newline" then out[#out + 1] = "\n"
        elseif tk.kind == "char" then out[#out + 1] = rec:recognize(tk.strokes) or "" end
    end
    local text = table.concat(out)
    if text:gsub("%s", "") == "" then return end   -- nothing recognised; leave the ink alone
    local minx, miny, maxx, maxy = math.huge, math.huge, -math.huge, -math.huge
    for _, s in ipairs(strokes) do
        for _, p in ipairs(s) do
            if p.x < minx then minx = p.x end
            if p.x > maxx then maxx = p.x end
            if p.y < miny then miny = p.y end
            if p.y > maxy then maxy = p.y end
        end
    end
    self:hwrInsertText(text, live_ops, minx, miny, maxx, maxy)
end

-- Replace the recognised ink with a text box, in one undoable step. Appends to the
-- box the last recognition made when the new writing sits just below/beside it (so
-- writing line after line stays in one box); otherwise starts a fresh box. Uses
-- the current text font/size/grid-snap.
function InkAwayView:hwrInsertText(text, ink_ops, minx, miny, maxx, maxy)
    local Text = require("ink/text")
    self.canvas:pushHistory()
    -- remove the recognised ink ops (highest index first)
    local idxs = {}
    for _, op in ipairs(ink_ops) do
        for i = #self.canvas.ops, 1, -1 do
            if self.canvas.ops[i] == op then idxs[#idxs + 1] = i; break end
        end
    end
    table.sort(idxs, function(a, b) return a > b end)
    for _, i in ipairs(idxs) do table.remove(self.canvas.ops, i) end

    local v = self.view
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    -- reuse the previous handwriting box if it is still around and the new writing
    -- sits within about a line of it (clone it so the history snapshot is untouched)
    local last = self._hwr_last
    local reuse_idx
    if last and last.op and miny >= last.top - size and miny <= last.bottom + 1.6 * size then
        for i = 1, #self.canvas.ops do if self.canvas.ops[i] == last.op then reuse_idx = i; break end end
    end
    if reuse_idx then
        local op = self.canvas.ops[reuse_idx]
        local nop = self.canvas:cloneOp(op)
        nop.paras = Notebook.deepcopy(op.paras)
        local cp = #nop.paras
        local join = (miny > last.bottom + 0.4 * size) and "\n" or " "
        Text.insert(nop, { p = cp, o = Text.paraLen(nop.paras[cp]) }, join .. text, nil)
        self.canvas.ops[reuse_idx] = nop
        self._hwr_last = { op = nop, top = last.top, bottom = math.max(last.bottom, maxy) }
    else
        local margin = math.max(6, math.floor(v.canvas_w * 0.02))
        local x = math.max(margin, math.min(math.floor(minx), v.canvas_w - margin - 10))
        local op = Text.new{ x = x, y = math.floor(miny), w = v.canvas_w - x - margin,
            size = size, font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
        if self.text_grid_snap then self:snapTextBoxToGrid(op) end
        Text.insert(op, { p = 1, o = 0 }, text, nil)
        self.canvas.ops[#self.canvas.ops + 1] = op
        self._hwr_last = { op = op, top = miny, bottom = maxy }
    end
    self.dirty = true
    self:composeCanvas(); self:renderView()
    self:refresh(self, "ui", self:areaScreenRect())
end

------------------------------------------------------------------------------
-- Online image browser: a small e-ink grid over keyless image APIs (Openverse,
-- Wikimedia Commons). Consistent with the tool sheets (rounded IconMenu, black
-- pills, sliding toggles), paged with Prev/Next rather than scrolling, and
-- entirely optional -- see ink/imagesearch.lua for the network/parse pieces.
------------------------------------------------------------------------------

-- A writable folder to keep added online images. Projects reference images by
-- path, so these must persist (unlike the thumbnail cache below). Returns nil if
-- it can't be made (then the caller reports it and does nothing).
function InkAwayView:onlineImagesDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage) then return nil end
    local parent = DataStorage:getDataDir() .. "/ink away"
    local dir = parent .. "/online images"
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lok and lfs then
        if lfs.attributes(parent, "mode") ~= "directory" then pcall(lfs.mkdir, parent) end
        if lfs.attributes(dir, "mode") ~= "directory" then pcall(lfs.mkdir, dir) end
        if lfs.attributes(dir, "mode") == "directory" then return dir end
    end
    return nil
end

-- Free the decoded thumbnail buffers (called on refetch and on close).
function InkAwayView:freeThumbs()
    local st = self._image_browser
    if not st or not st.thumbs then return end
    for i, bb in pairs(st.thumbs) do
        if bb and bb.free then pcall(function() bb:free() end) end
        st.thumbs[i] = nil
    end
end

-- Entry point from the "Browse online" button. runWhenOnline prompts to enable
-- Wi-Fi per the reader's own settings and runs the callback when connected; if
-- they decline or there is no network, nothing happens -- nothing is disrupted.
function InkAwayView:browseOnlineImages()
    local start = function() self:imageBrowserSearchPrompt(true) end
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and NetworkMgr.runWhenOnline then
        NetworkMgr:runWhenOnline(start)
    else
        start()
    end
end

-- Ask for a search term. `is_initial` opens the browser on the first search;
-- otherwise it refines the query in the already-open browser.
function InkAwayView:imageBrowserSearchPrompt(is_initial)
    -- Only ever one search box at a time: a stale one left showing (with its
    -- keyboard) is what made the next one refuse input and what lingered on screen
    -- after closing the browser.
    self:closeImageSearchPrompt()
    local st = self._image_browser
    -- A fresh browse starts empty so a leftover query is never searched by mistake;
    -- refining an already-open browser keeps the current query so it can be tweaked.
    local cur = (not is_initial and st and st.query) or ""
    -- Make sure the on-screen keyboard is available for this search field. On a
    -- device that reports a physical keyboard -- notably the desktop emulator, and
    -- any reader with the on-screen keyboard turned off in settings -- InputDialog
    -- would otherwise suppress its virtual keyboard, leaving no way to type here by
    -- touch. Turning the global flag on only while the dialog is built lets it lay
    -- itself out with the keyboard from the start (one clean paint, no reinit); the
    -- flag is restored immediately after. On a reader with no physical keyboard
    -- nothing was ever suppressed, so this makes no visible difference there.
    local G = rawget(_G, "G_reader_settings")
    local prev_vk = G and G:readSetting("virtual_keyboard_enabled")
    if G then G:saveSetting("virtual_keyboard_enabled", true) end
    local dialog
    dialog = InputDialog:new{
        title = _("Search images"),
        input = cur,
        input_hint = _("e.g. cat, tree, arrow"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() self:closeImageSearchPrompt() end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText() or ""
                    self:closeImageSearchPrompt()
                    q = q:gsub("^%s+", ""):gsub("%s+$", "")
                    if q == "" then return end
                    if is_initial or not self._image_browser then
                        self:openImageBrowser(q)
                    else
                        self._image_browser.query = q
                        self._image_browser.page = 1
                        self:imageBrowserFetch()
                    end
                end,
            },
        }},
    }
    if G then G:saveSetting("virtual_keyboard_enabled", prev_vk) end   -- restore (nil clears it)
    self._img_search_dialog = dialog
    UIManager:show(dialog)
    -- Show the keyboard on the next tick, after the tap that opened this has fully
    -- resolved (doing it inline sometimes lost focus, so the field wouldn't type).
    UIManager:nextTick(function()
        if self._img_search_dialog == dialog and dialog.onShowKeyboard then dialog:onShowKeyboard() end
    end)
end

-- Close the search box and its keyboard if one is open.
function InkAwayView:closeImageSearchPrompt()
    if self._img_search_dialog then
        UIManager:close(self._img_search_dialog)
        self._img_search_dialog = nil
    end
end

function InkAwayView:openImageBrowser(query)
    self:freeThumbs()
    self._image_browser = {
        query = query, page = 1,
        -- Transparent-only is off by default (true PNGs are scarce in both
        -- catalogues, so an on-by-default filter mostly returns nothing); remembered
        -- across sessions once the reader changes it.
        png_only = (self:getSetting("inkaway_img_png_only", false) == true),
        full_res = (self._img_full_res == true),     -- default OFF (scaled to save space)
        -- Which catalogue to search; remembered across sessions. Wikimedia Commons
        -- (faster, most reliable thumbnails) by default, Openverse the alternative --
        -- the reader flips between them with the Source button.
        provider = (self:getSetting("inkaway_img_source", "commons") == "openverse") and "openverse" or "commons",
        results = {}, thumbs = {}, status = _("Searching\u{2026}"), has_next = false,
    }
    if self._image_browser_dialog then
        UIManager:close(self._image_browser_dialog); self._image_browser_dialog = nil
    end
    self._image_browser_dialog = IconMenu:new{
        build = function(menu) return self:imageBrowserBuild(menu) end,
        top_y = self:sheetTopY(),
        -- tap-outside close: tear the whole session down like the Done button does
        on_close = function()
            self:closeImageSearchPrompt(); self:freeThumbs()
            self._image_browser = nil; self._image_browser_dialog = nil
        end,
    }
    UIManager:show(self._image_browser_dialog)
    self:imageBrowserFetch()
end

-- Close the browser completely: the search box, the sheet, its thumbnails, and the
-- session state (so the next "Browse online" starts fresh, not with the old query).
function InkAwayView:onImageBrowserClose()
    self:closeImageSearchPrompt()
    if self._image_browser_dialog then
        UIManager:close(self._image_browser_dialog); self._image_browser_dialog = nil
    end
    self:freeThumbs()
    self._image_browser = nil
    UIManager:setDirty("all", "ui")   -- repaint the whole screen so nothing lingers
end

-- Build the browser sheet: title, a search bar, the source selector, the PNG/full-res toggles, the
-- thumbnail grid, and a Prev/Next footer.
function InkAwayView:imageBrowserBuild(menu)
    local st = self._image_browser or {}
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local Font = require("ui/font")
    local GREY = Blitbuffer.ColorRGB32(0x80, 0x80, 0x80, 0xFF)
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

    -- Build the fixed chrome first and measure it, so the grid can be given exactly
    -- the vertical space that's left. That keeps the whole sheet on screen (with its
    -- Prev/Next footer visible) on every device, from a small Kobo to a Scribe,
    -- instead of a fixed cell size that overflows tall panels.
    local title = self:sheetTitle(_("Browse images"), content_w, _("Done"),
        function() self:onImageBrowserClose() end)
    local q_label = (st.query and st.query ~= "") and st.query or _("Search\u{2026}")
    local search = self:actionButton("\u{1F50D}  " .. q_label, content_w,
        function() self:imageBrowserSearchPrompt(false) end)
    -- Source selector: two keyless catalogues, tap to switch and re-search. Web
    -- engines (DuckDuckGo/Bing/Google) can't be used -- they gate results behind
    -- in-page JavaScript a plain HTTP client can't run -- so this is the way to a
    -- wider selection.
    local SOURCE_LABEL = { openverse = _("Openverse"), commons = _("Wikimedia") }
    local src = self:actionButton(
        _("Source: ") .. (SOURCE_LABEL[st.provider] or _("Openverse")) .. "   \u{21C4}", content_w,
        function()
            st.provider = (st.provider == "commons") and "openverse" or "commons"
            self:setSetting("inkaway_img_source", st.provider)
            st.page = 1
            self:imageBrowserFetch()
        end)
    local tog1 = ToggleRow:new{ label = _("Transparent PNG only"), is_on = st.png_only, width = content_w, parent = menu,
        callback = function(on) st.png_only = on; self:setSetting("inkaway_img_png_only", on); st.page = 1; self:imageBrowserFetch() end }
    local tog2 = ToggleRow:new{ label = _("Full resolution"), is_on = st.full_res, width = content_w, parent = menu,
        callback = function(on) st.full_res = on; self._img_full_res = on end }
    -- A short note on how the two sources differ, so the Source button explains
    -- itself. Grey and small so it reads as a hint under the control, not a button.
    local src_hint = TextBoxWidget:new{
        text = _("Wikimedia is faster. Openverse has a wider variety."),
        face = Font:getFace("cfont", 13), width = content_w, alignment = "center", fgcolor = GREY }
    -- A friendly tip: truly transparent PNGs are scarce in both catalogues, so nudge
    -- the reader toward the eraser's background removal. Framed and accented so it
    -- reads as a helpful aside rather than an error line.
    local ACCENT = Blitbuffer.ColorRGB32(0x2E, 0x2E, 0x2E, 0xFF)
    local tip_pad = Screen:scaleBySize(12)
    local tip_star = TextWidget:new{ text = "\u{2605}", face = Font:getFace("cfont", 20), fgcolor = ACCENT }
    local tip_gap = Screen:scaleBySize(10)
    local tip_text_w = content_w - 2 * (tip_pad + Size.border.default) - tip_star:getSize().w - tip_gap
    local tip_body = VerticalGroup:new{ align = "left",
        TextWidget:new{ text = _("Tip"), face = Font:getFace("cfont", 14), bold = true, fgcolor = ACCENT },
        VerticalSpan:new{ width = Screen:scaleBySize(3) },
        TextBoxWidget:new{
            text = _("Truly transparent pictures are scarce here. Add any image, then switch on Erase pictures in the Eraser settings to wipe its background away."),
            face = Font:getFace("cfont", 13), width = tip_text_w, alignment = "left", fgcolor = GREY },
    }
    local tip = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.default,
        radius = Screen:scaleBySize(14), padding = tip_pad, margin = 0,
        HorizontalGroup:new{ align = "top",
            tip_star, HorizontalSpan:new{ width = tip_gap }, tip_body },
    }
    local btnW = math.floor((content_w - gap) / 2)
    local footer = HorizontalGroup:new{ align = "center",
        self:actionButton("\u{2039} " .. _("Prev"), btnW, function() self:imageBrowserGo(-1) end),
        HorizontalSpan:new{ width = gap },
        self:actionButton(_("Next") .. " \u{203A}", btnW, function() self:imageBrowserGo(1) end) }
    -- A caption under the grid: which catalogue these results came from and the
    -- page number.
    local FRIENDLY = { commons = "Wikimedia Commons", openverse = "Openverse" }
    local caption
    do
        local parts = {}
        if #st.results > 0 and st.provider and FRIENDLY[st.provider] then
            parts[#parts + 1] = _("via ") .. FRIENDLY[st.provider]
        end
        if (st.page and st.page > 1) or st.has_next then
            parts[#parts + 1] = string.format(_("Page %d"), st.page or 1)
        end
        if #parts > 0 then caption = table.concat(parts, "   \u{00B7}   ") end
    end
    local page_w = caption and TextWidget:new{ text = caption,
        face = Font:getFace("cfont", 13), fgcolor = GREY } or nil

    local top_h = title:getSize().h + Screen:scaleBySize(12)
        + search:getSize().h + Screen:scaleBySize(8)
        + src:getSize().h + Screen:scaleBySize(6)
        + src_hint:getSize().h + Screen:scaleBySize(10)
        + tog1:getSize().h + Screen:scaleBySize(8)
        + tog2:getSize().h + Screen:scaleBySize(10)
        + tip:getSize().h + Screen:scaleBySize(12)
    local bottom_h = Screen:scaleBySize(12) + footer:getSize().h
        + (page_w and (Screen:scaleBySize(6) + page_w:getSize().h) or 0)
    local frame_pad = Screen:scaleBySize(18)
    local usable = Screen:getHeight() - self:sheetTopY() - Screen:scaleBySize(10) - 2 * frame_pad
    local grid_avail = math.max(Screen:scaleBySize(80), usable - top_h - bottom_h)

    local content = VerticalGroup:new{ align = "left" }
    local function add(w) content[#content + 1] = w end
    add(title); add(vspan(12))
    add(search); add(vspan(8))
    add(src); add(vspan(6))
    add(src_hint); add(vspan(10))
    add(tog1); add(vspan(8))
    add(tog2); add(vspan(10))
    add(tip); add(vspan(12))

    local cols = 3
    local cell_w = math.floor((content_w - (cols - 1) * gap) / cols)
    local n = #st.results
    if n == 0 then
        local msg = TextBoxWidget:new{ text = st.status or _("Long-press an image to add it."),
            face = Font:getFace("cfont", 15), width = content_w, alignment = "center", fgcolor = GREY }
        add(msg)
        local fill = grid_avail - msg:getSize().h
        if fill > 0 then add(VerticalSpan:new{ width = fill }) end
    else
        local rows = math.ceil(n / cols)
        local cell_h = math.floor((grid_avail - (rows - 1) * gap) / rows)
        cell_h = math.max(Screen:scaleBySize(64), math.min(cell_h, cell_w))
        local i = 1
        while i <= n do
            local row = HorizontalGroup:new{ align = "center" }
            for c = 1, cols do
                if i <= n then
                    row[#row + 1] = self:imageBrowserCell(st, i, cell_w, cell_h, ImageWidget)
                    if c < cols and i < n then row[#row + 1] = HorizontalSpan:new{ width = gap } end
                    i = i + 1
                end
            end
            add(row)
            if i <= n then add(vspan(12)) end
        end
    end

    add(vspan(12))
    add(footer)
    if page_w then add(vspan(6)); add(page_w) end
    return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
        radius = Screen:scaleBySize(28), padding = frame_pad, content }
end

-- One grid cell: a rounded tappable tile holding the thumbnail. A tap and a
-- long-press do the same thing -- ask to add the image -- since a plain tap is
-- what most people try first (paging has its own buttons, so a tap can't page).
function InkAwayView:imageBrowserCell(st, index, cell_w, cell_h, ImageWidget)
    local TILE = TILE_BG
    -- Adding runs behind a guard: if anything goes wrong (a bad result, a network
    -- hiccup) it shows a message instead of letting the error escape and take all
    -- of KOReader down with it.
    local add = function()
        local ok, err = xpcall(function() self:imageBrowserAdd(index) end, debug.traceback)
        if not ok then
            logger.warn("Ink Away: adding an online image failed: " .. tostring(err))
            UIManager:show(InfoMessage:new{
                text = _("Something went wrong adding that image. Please try another."),
                icon = "notice-warning" })
        end
    end
    local b = Button:new{ text = "", width = cell_w, height = cell_h, bordersize = 0,
        radius = Screen:scaleBySize(12), background = TILE, margin = 0, padding = 0,
        callback = add, hold_callback = add, show_parent = self }
    local bb = st.thumbs[index]
    if bb and b.label_container then
        local pad = Screen:scaleBySize(6)
        -- `fgcolor` is unused by ImageWidget, but Button's tap-highlight inverts
        -- `label_widget.fgcolor` whenever `text` is set (ours is ""), so it MUST be a
        -- real colour. Without it a plain tap crashed KOReader indexing a nil field
        -- (a long-press took a different feedback path, which is why only tapping a
        -- result crashed). Same fix as brushWaveTile.
        local img = ImageWidget:new{ image = bb, width = cell_w - 2 * pad, height = cell_h - 2 * pad,
            scale_factor = 0, image_disposable = false, fgcolor = Blitbuffer.COLOR_BLACK }
        b.label_widget = img
        b.label_container[1] = img
    end
    return b
end

function InkAwayView:imageBrowserGo(delta)
    local st = self._image_browser
    if not st then return end
    local np = (st.page or 1) + delta
    if np < 1 then return end
    if delta > 0 and not st.has_next then return end
    st.page = np
    self:imageBrowserFetch()
end

-- Fetch the current page in the main loop under Trapper: the JSON search, then each
-- thumbnail, with a dismissable progress spinner and a cancel check between steps.
-- The network runs here (not a forked subprocess) because LuaSec's SSL can crash a
-- fork on some builds; a small page + short per-request timeouts keep it responsive.
-- Rebuilds the sheet when done.
function InkAwayView:imageBrowserFetch()
    local st = self._image_browser
    if not st then return end
    local ImageSearch = require("ink/imagesearch")
    local Trapper = require("ui/trapper")
    self:freeThumbs()
    st.results, st.thumbs, st.status = {}, {}, _("Searching\u{2026}")
    if self._image_browser_dialog then self._image_browser_dialog:rebuild() end
    local q, opts = st.query, { png_only = st.png_only, page = st.page,
        page_size = ImageSearch.PAGE_SIZE, provider = st.provider }
    Trapper:wrap(function()
        if not Trapper:info(_("Searching images\u{2026}")) then return end
        local page = ImageSearch.searchPage(q, opts)
        if not self._image_browser or self._image_browser ~= st then return end   -- browser closed
        if not (page and page.net_ok) then
            st.status = _("Couldn't reach the image service.\nCheck your Wi-Fi, or try the other source above.")
        elseif #page.results == 0 then
            st.status = _("No images found here.\nTry another search, or the other source above.")
        else
            st.provider = page.provider or st.provider
            st.has_next = page.page_count and (st.page < page.page_count)
                or (#page.results >= ImageSearch.PAGE_SIZE)
            local total = #page.results
            for idx, r in ipairs(page.results) do
                if not Trapper:info(string.format(_("Loading images\u{2026} %d/%d"), idx, total)) then break end
                -- light thumbnail first; fall back to the full image (some providers'
                -- thumbnail proxies fail), with short timeouts so one slow image
                -- can't stall the grid. A browser agent keeps image CDNs from
                -- rejecting the request.
                local iua = { ["User-Agent"] = ImageSearch.BROWSER_UA, ["Accept"] = "image/*,*/*" }
                local bytes = (r.thumb and ImageSearch.httpGet(r.thumb, 6, 12, iua))
                    or (r.full and ImageSearch.httpGet(r.full, 6, 15, iua))
                if not self._image_browser or self._image_browser ~= st then return end
                if type(bytes) == "string" then
                    local bb = ImageSearch.decode(bytes, ImageSearch.THUMB_MAX)
                    if bb then
                        st.results[#st.results + 1] = r
                        st.thumbs[#st.thumbs + 1] = bb
                    end
                end
            end
            st.status = (#st.thumbs == 0) and _("No images found here.\nTry another search, or the other source above.") or nil
        end
        Trapper:reset()
        if self._image_browser and self._image_browser == st and self._image_browser_dialog then
            self._image_browser_dialog:rebuild()
        end
    end)
end

function InkAwayView:imageBrowserAdd(index)
    local st = self._image_browser
    if not st then return end
    local r = st.results[index]
    if not r or not r.full then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Add this image to your drawing?"),
        ok_text = _("Add"),
        ok_callback = function() self:imageBrowserDownloadAndInsert(r) end,
    })
end

-- Download the chosen full image, then place it exactly like a local file. When
-- "full resolution" is off, decode + scale down + re-save as PNG (keeps any
-- transparency and saves space); otherwise keep the original bytes/format.
function InkAwayView:imageBrowserDownloadAndInsert(r)
    local ImageSearch = require("ink/imagesearch")
    local Trapper = require("ui/trapper")
    local full_res = self._image_browser and self._image_browser.full_res
    local dir = self:onlineImagesDir()
    if not dir then
        UIManager:show(InfoMessage:new{ text = _("Couldn't prepare a folder for the image."),
            icon = "notice-warning" })
        return
    end
    self._img_dl_seq = (self._img_dl_seq or 0) + 1
    local base = string.format("online-%d-%d", os.time(), self._img_dl_seq)
    Trapper:wrap(function()
        if not Trapper:info(_("Downloading image\u{2026}")) then return end
        -- main-process download (a browser agent, so image CDNs don't reject us);
        -- kept out of a subprocess for the same LuaSec-in-fork reason as the search
        local bytes = ImageSearch.httpGet(r.full, 10, 30,
            { ["User-Agent"] = ImageSearch.BROWSER_UA, ["Accept"] = "image/*,*/*" })
        Trapper:reset()
        if type(bytes) ~= "string" then
            UIManager:show(InfoMessage:new{ text = _("Couldn't download that image."),
                icon = "notice-warning" })
            return
        end
        local path
        if full_res then
            local ext = (r.mime and r.mime:find("jpeg", 1, true)) and "jpg" or "png"
            path = string.format("%s/%s.%s", dir, base, ext)
            local f = io.open(path, "wb")
            if not f then
                UIManager:show(InfoMessage:new{ text = _("Couldn't save the image."), icon = "notice-warning" })
                return
            end
            f:write(bytes); f:close()
        else
            local bb = ImageSearch.decode(bytes, ImageSearch.FULL_MAX)
            if not bb then
                UIManager:show(InfoMessage:new{ text = _("Couldn't read that image."), icon = "notice-warning" })
                return
            end
            path = string.format("%s/%s.png", dir, base)
            local ok = pcall(function() bb:writePNG(path) end)
            if bb.free then pcall(function() bb:free() end) end
            if not ok then
                UIManager:show(InfoMessage:new{ text = _("Couldn't save the image."), icon = "notice-warning" })
                return
            end
        end
        self:onImageBrowserClose()
        self:insertImage(path)
    end)
end

------------------------------------------------------------------------------
-- Pan, shared by the Pan tool and two finger pan. It works from one step to the
-- next, so it stays reliable even when the panel sends events unevenly.
------------------------------------------------------------------------------

function InkAwayView:panByScreen(dx, dy)
    local v = self.view
    -- content follows the finger: dragging right reveals more of the left
    v.pan_x = v.pan_x - dx / v.zoom
    v.pan_y = v.pan_y - dy / v.zoom
    InkGeom.clampPan(v)
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

------------------------------------------------------------------------------
-- Palm rejection: on a device with a pen, KOReader can hand us the raw stylus
-- stream before it becomes a gesture. We "dominate" (swallow) the pen and drive
-- our own drawing from it, and while the pen is down we ignore finger gestures,
-- so a resting palm never draws. See ink/stylus.lua for the pure pieces.
------------------------------------------------------------------------------

-- Is this build/device able to deliver raw stylus events? (Older KOReader, or a
-- finger-only reader, simply never fire the callback -- so turning the setting on
-- is harmless there, but we only bother registering when the hook exists.)
function InkAwayView:penCapable()
    return Device.input and type(Device.input.registerStylusCallback) == "function"
end

-- Does this device physically have a stylus? Used only to pick the default state
-- of the palm-rejection toggle (which the reader can always override). KOReader
-- flags the Wacom pen devices -- Kindle Scribe, reMarkable -- with wacom_protocol;
-- it exposes no reliable "has a pen" flag for Kobo styluses, so those (and every
-- finger-only reader) default the toggle OFF and turn it on by hand if they draw
-- with a pen. Being wrong here only changes a default, never whether the pen works.
function InkAwayView:deviceHasStylus()
    return Device.input and Device.input.wacom_protocol == true and true or false
end

-- Register or drop the stylus callback to match self.palm_reject. Called at
-- startup and whenever the setting is toggled.
function InkAwayView:applyPalmReject()
    if not self:penCapable() then return end
    if self.palm_reject then
        if not self._stylus_cb then
            self._stylus_cb = function(inp, slot) return self:onStylusSlot(inp, slot) end
            Device.input:registerStylusCallback(self._stylus_cb)
        end
    elseif self._stylus_cb then
        pcall(function() Device.input:unregisterStylusCallback() end)
        self._stylus_cb = nil
        self:resetPenState()
    end
end

-- Drop all in-flight pen/palm state (called when palm rejection is turned off or
-- the widget closes). Restores a tool we swapped for the eraser tip or side button
-- if a stroke was mid-flight, so toggling off during a rear-eraser or side-button
-- stroke can't leave the tool stuck on "erase"/"lasso" or the state machine wedged
-- half-down.
function InkAwayView:resetPenState()
    UIManager:unschedule(self._pen_clear)
    if self._pen_prev_tool then self.tool = self._pen_prev_tool; self._pen_prev_tool = nil end
    self._pen_state = Stylus.new()
    self._pen_started = false
    self._pen_feeding = false
    self._pen_owner = nil
    self._reject_finger = false
    self._palm_slots = {}
    self._palm_count = 0
    self._pen_kin = nil
    self._pen_last_ms = nil
    self._learned_pen_slot = nil
end

-- True while finger input must be ignored. Latched on PHYSICAL presence -- the pen
-- is actually down, or a palm is actually down -- not merely on the debounce timer,
-- so a stray palm frame's short timer can never drop rejection mid-stroke (that was
-- the "lines between palm and pen" leak). The timer (_reject_finger) only adds the
-- brief grace after everything lifts. Pen-fed events set _pen_feeding so they pass
-- through their own handlers.
function InkAwayView:fingerRejected()
    if self._pen_feeding then return false end
    return self._pen_state.down or self._palm_count > 0 or self._reject_finger
end

-- Translate a raw stylus slot position into the same screen coordinates a finger
-- gesture would carry (raw slot pos, then the screen-rotation transform).
function InkAwayView:penScreenXY(slot)
    local S = Screen
    local mode = 0
    if S.getTouchRotation then
        local rot = S:getTouchRotation()
        if rot == S.DEVICE_ROTATED_CLOCKWISE then mode = 1
        elseif rot == S.DEVICE_ROTATED_UPSIDE_DOWN then mode = 2
        elseif rot == S.DEVICE_ROTATED_COUNTER_CLOCKWISE then mode = 3 end
    end
    return Stylus.rotate(slot.x, slot.y, mode, S:getWidth(), S:getHeight())
end

-- The live Input facts Stylus.classify needs to tell a real pen from a promoted
-- palm: the dedicated pen slot, whether this is a Wacom-protocol device, and the
-- barrel-button latches KOReader keeps.
function InkAwayView:stylusFacts(input)
    input = input or Device.input
    return {
        pen_slot          = input and input.pen_slot,
        learned_slot      = self._learned_pen_slot,   -- slot a real TOOL_PEN was seen on
        wacom             = input and input.wacom_protocol == true,
        eraser_latch      = input and input.stylus_eraser_active == true,
        highlighter_latch = input and input.stylus_highlighter_active == true,
    }
end

-- Elapsed milliseconds since the previous stylus frame, from the slot's own
-- timestamp, for the kinematic palm filter. Returns nil when no usable timestamp
-- is present (then the filter does not engage). KOReader's timev has been both a
-- {sec/usec} table and, in newer builds, a plain seconds number, so handle both.
function InkAwayView:penFrameMs(slot)
    local tv = slot.timev
    local ms
    if type(tv) == "number" then
        ms = tv * 1000
    elseif type(tv) == "table" then
        local s = tv.tv_sec or tv.sec
        local u = tv.tv_usec or tv.usec
        if s then ms = s * 1000 + (u or 0) / 1000 end
    end
    if not ms then self._pen_last_ms = nil; return nil end
    local prev = self._pen_last_ms
    self._pen_last_ms = ms
    if not prev then return nil end
    local dt = ms - prev
    if dt < 0 then return nil end
    return dt
end

-- Hold finger rejection open for the lift debounce and (re)start the clear timer.
-- Called on every pen and palm frame so that as long as either is physically
-- present, fingers stay ignored; the timer self-heals when activity truly stops.
function InkAwayView:holdReject()
    self._reject_finger = true
    UIManager:unschedule(self._pen_clear)
    UIManager:scheduleIn(PEN_LIFT_DEBOUNCE, self._pen_clear)
end

-- A palm KOReader promoted to a stylus tool number and routed to us. We never
-- draw from it; we just remember it is down (so a lift can be reasoned about) and
-- keep fingers rejected. A palm whose tool later reverts to an ordinary finger
-- stops arriving here and reappears as a normal gesture -- the held rejection
-- window (refreshed by onIaTouch/onIaPan) covers that until it truly lifts.
function InkAwayView:penPalm(slot)
    local key = slot.slot or 0
    local id = tonumber(slot.id)
    local promoted = false
    if id and id >= 0 then
        local prev = self._palm_slots[key]
        if prev == nil then
            self._palm_count = self._palm_count + 1
            promoted = true              -- a slot that was an ordinary touch is now a palm
        elseif prev ~= id then
            promoted = true              -- a new physical generation on the same slot
        end
        self._palm_slots[key] = id
    elseif id and id < 0 then
        if self._palm_slots[key] then
            self._palm_slots[key] = nil
            self._palm_count = math.max(0, self._palm_count - 1)
        end
    end
    self:holdReject()
    -- A palm is usually promoted MID-CONTACT: the digitizer flags it as a palm only
    -- after it has landed, so it first arrives as an ordinary touch and may already
    -- have opened a stroke (the stray dot/line the tester sees). On the promotion,
    -- retire that contact so no mark is left behind -- unless the pen itself is the
    -- one drawing (a different, trusted slot), whose stroke must never be dropped.
    if promoted and not self._pen_started and not self._pen_owner then
        self:penDropFingerOps()
    end
end

-- The stylus callback (registered on KOReader's Input). Runs before gesture
-- detection; returning true removes the slot from gesture detection so it never
-- also arrives as a finger-style gesture. A slot reaches us because its tool is
-- PEN/ERASER/HIGHLIGHTER or it sits on the pen slot -- but that set includes a
-- resting palm (MT_TOOL_PALM == ERASER == 2), so we classify by slot first and
-- only drive the drawing from a genuinely trusted pen.
function InkAwayView:onStylusSlot(inp, slot)
    if not self.palm_reject or self.closing then return false end
    local input = inp or Device.input
    local facts = self:stylusFacts(input)
    local role = Stylus.classify(slot, facts)
    -- Learn the pen's slot from the first genuine pen-tip frame, so the rear eraser
    -- and a held barrel button (which report the ambiguous ERASER value) are trusted
    -- on that same slot even when the runtime never set Input.pen_slot. The pen slot
    -- is fixed per device, so once learned it stays until palm rejection is reset.
    if role == Stylus.ROLE_PEN and slot.tool == Stylus.TOOL_PEN and slot.slot ~= nil
            and (self._pen_owner == nil or slot.slot == self._pen_owner) then
        self._learned_pen_slot = slot.slot
    end
    -- Single-slot ownership. While one slot is drawing the pen stroke, any OTHER
    -- slot that also classifies as a stylus must NOT co-drive the same stroke --
    -- feeding two slots into one pen state machine is what draws lines between
    -- them. This matters off Wacom (Kobo), where a resting palm promoted to the
    -- eraser/highlighter tool by a held barrel button classifies as a pen too;
    -- here it is demoted back to a palm and discarded. (On Wacom only the single
    -- pen slot is ever ROLE_PEN, so this never triggers there.)
    local sn = slot.slot or 0
    -- The pen's own slot (known from the runtime or learned from a real pen frame)
    -- is always the pen, so it is never demoted -- this also lets a coordinate-late
    -- pen (whose announce frame carried no slot number, defaulting the owner to 0)
    -- keep drawing once its real slotted frames arrive.
    local is_pen_slot = (self._learned_pen_slot ~= nil and sn == self._learned_pen_slot)
                     or (input and input.pen_slot ~= nil and sn == input.pen_slot)
    if role == Stylus.ROLE_PEN and self._pen_owner ~= nil and sn ~= self._pen_owner
            and not is_pen_slot then
        role = Stylus.ROLE_PALM
    end
    if role == Stylus.ROLE_PALM then
        self:penPalm(slot)   -- remember it, keep fingers out; never draw
        return true          -- dominate: keep it out of gesture detection
    elseif role == Stylus.ROLE_TOUCH then
        return false         -- a real finger that only reached us in passing
    end
    -- ROLE_PEN: a trusted stylus. Drive our own touch / pan / release from it.
    -- (Palms are already filtered, so penDown's tool==ERASER test now only ever
    -- sees the pen's genuine rear eraser or a held barrel button.)
    local action = Stylus.step(self._pen_state, slot.id)
    if action == "down" then
        self._pen_owner = sn        -- this slot owns the stroke until it lifts
        self:penDown(slot, facts)
    elseif action == "move" then
        self:penMove(slot)
    elseif action == "up" then
        self:penUp()
        self._pen_owner = nil
    end
    return true   -- swallow the pen; we handle it ourselves
end

-- Feed one synthetic touch/pan/release into our normal handlers, marked so the
-- finger-rejection guard lets it through. This reuses ALL the existing tool
-- routing (pen, eraser, shapes, text, pan, moving images/shapes), so the pen
-- does exactly what a finger would, just without the palm.
function InkAwayView:feedPen(kind, x, y)
    self._pen_feeding = true
    local ges = { pos = { x = x, y = y } }
    if kind == "down" then self:onIaTouch(nil, ges)
    elseif kind == "move" then self:onIaPan(nil, ges)
    elseif kind == "up" then self:onIaPanRelease(nil, ges) end
    self._pen_feeding = false
end

-- Discard anything a palm/finger began in the instant before the pen touched
-- down, so resting your hand first and then writing doesn't leave a stray mark.
function InkAwayView:penDropFingerOps()
    if self.capturing then
        UIManager:unschedule(self._finalize)
        self.pending_lift = nil
        self.capturing = false
        self.canvas:cancelStroke()
        self.last_cx, self.last_cy = nil, nil
        self:composeCanvas(); self:renderView()
        UIManager:setDirty(self, "ui", self:areaScreenRect())
    end
    self:cancelShape()      -- drop a half-drawn shape
    self.pan_last = nil
    self.lassoing, self.lasso_scr, self.sel_press = false, nil, nil
end

function InkAwayView:penDown(slot, facts)
    -- restore a tool we swapped for the eraser tip / side button if the last up was lost
    if self._pen_prev_tool then self.tool = self._pen_prev_tool; self._pen_prev_tool = nil end
    self._reject_finger = true
    self._pen_started = false      -- the stroke opens on the first point with coordinates
    self._pen_kin = {}             -- fresh kinematic-filter state for this stroke
    self._pen_last_ms = nil
    UIManager:unschedule(self._pen_clear)
    self:penDropFingerOps()
    -- What this pen contact does: the rear eraser end erases, the primary side
    -- (barrel) button is a lasso-select modifier, and everything else draws with
    -- the current tool. Swap the tool in just for this stroke and restore it on
    -- lift, so the eraser end and the side button behave like held modifiers. The
    -- lasso selection lives in self.selection independent of the tool, so it
    -- survives the restore and can be moved by re-holding the side button.
    local act = Stylus.penAction(slot, facts)
    if act == Stylus.ACT_SELECT and self.tool ~= "lasso" then
        self._pen_prev_tool = self.tool
        self.tool = "lasso"
    elseif act == Stylus.ACT_ERASE and self.tool ~= "erase" then
        self._pen_prev_tool = self.tool
        self.tool = "erase"
    end
    self:penMove(slot)             -- if this frame already carries coordinates, open here
end

function InkAwayView:penMove(slot)
    if not (slot.x and slot.y) then return end   -- a coordinate-less down/hover frame
    local x, y = self:penScreenXY(slot)
    -- Kinematic palm filter: drop a sample that jumped implausibly far in the elapsed
    -- time (a resting palm's coordinates written into the pen slot), keeping the
    -- stroke open. It seeds itself on the first point and no-ops without a timestamp,
    -- so a normal stroke is never affected. See Stylus.acceptMove.
    if self._pen_kin then
        local dt = self:penFrameMs(slot)
        if not Stylus.acceptMove(self._pen_kin, x, y, dt, self._dpi_factor or 1) then
            return
        end
    end
    self._pen_last_x, self._pen_last_y = x, y
    -- Some pen protocols announce the contact one frame before the first
    -- coordinates, so the stroke is opened by whichever frame first has a point.
    if not self._pen_started then
        self._pen_started = true
        self:feedPen("down", x, y)
    else
        self:feedPen("move", x, y)
    end
end

function InkAwayView:penUp()
    if self._pen_started then
        self:feedPen("up", self._pen_last_x or 0, self._pen_last_y or 0)
        self:flushPending()      -- the pen lift is clean; commit now, no coalesce wait
        self._pen_started = false
    end
    if self._pen_prev_tool then self.tool = self._pen_prev_tool; self._pen_prev_tool = nil end
    -- keep ignoring fingers briefly: a palm often lifts a moment after the pen
    UIManager:unschedule(self._pen_clear)
    UIManager:scheduleIn(PEN_LIFT_DEBOUNCE, self._pen_clear)
end

------------------------------------------------------------------------------
-- Drawing / pan gesture handlers
------------------------------------------------------------------------------

-- Touch down: begin a stroke or a pan, or carry on a stroke that just lifted if
-- the panel dropped the finger and picked it up again.
function InkAwayView:onIaTouch(_, ges)
    -- palm rejection: pen/palm is present. Refresh the window so a palm that
    -- reverted to a finger tool (and so reappears here as a gesture) stays out
    -- until it truly lifts.
    if self:fingerRejected() then self:holdReject(); return true end
    local pos = ges.pos
    if not pos or not self:inArea(pos.x, pos.y) then return false end
    self._peel_op = nil   -- a new interaction ends any committed-text undo peel
    -- floating controls: a tap on one acts; a drag off it (below) draws instead
    local fab = self:fabHit(pos.x, pos.y)
    if fab then self._fab_press = fab; return true end
    if self.selecting_crop then return self:cropTouch(pos) end
    if self.rotating then return self:rotateTouch(pos) end
    if self.image_rotating then return self:imageRotateTouch(pos) end
    if self.active_image then return self:imageTouch(pos) end
    if self.tool == "lasso" then return self:lassoTouch(pos) end
    if self.tool == "text" then return self:textToolTouch(pos) end
    if self.tool == "fill" then self:doFill(pos); return true end
    if self.tool == "shape" then return self:shapeTouch(pos) end
    if self.tool == "pan" then
        -- tap/hold a placed image to select it; the menu opens on the tap/hold
        -- gesture (onIaTap/onIaHold), NOT here -- opening on touch-down lets the
        -- gesture's own completion close the just-shown dialog. The picture is
        -- draggable from this same touch.
        local hit = self:hitTestImage(pos.x, pos.y)
        if hit then self:selectImage(hit); return self:imageTouch(pos) end
        -- a selected shape can be dragged; a fresh touch on a shape selects it
        if self.selected and self:pointOnShape(self.selected.op, pos.x, pos.y) then
            return self:shapeMoveTouch(pos)
        end
        local shp = self:hitTestShape(pos.x, pos.y)
        if shp then self.selected = shp; return self:shapeMoveTouch(pos) end
        self.pan_last = { x = pos.x, y = pos.y }
        return true
    end
    if self.capturing and self.pending_lift then
        -- within the coalesce window: same stroke if the new contact is close
        local dx = pos.x - self.pending_lift.x
        local dy = pos.y - self.pending_lift.y
        if dx * dx + dy * dy <= self.bridge_dist * self.bridge_dist then
            UIManager:unschedule(self._finalize)
            self.pending_lift = nil
            self:addScreenPoint(pos.x, pos.y, false)  -- bridge the gap
            return true
        end
        self:finalizeStroke()   -- genuinely a new stroke elsewhere
    elseif self.capturing then
        self:finalizeStroke()   -- a lift was missed; don't lose the old stroke
    end
    self:beginStroke(pos.x, pos.y)
    return true
end

function InkAwayView:onIaPan(_, ges)
    if self:fingerRejected() then self:holdReject(); return true end
    local pos = ges.pos
    if self._fab_press then           -- a drag off a control is a draw, not a tap
        self._fab_press = nil
        if pos then self:fabProximity(pos.x, pos.y) end
        return true
    end
    if pos then self:fabProximity(pos.x, pos.y) end   -- melt controls if drawing near them
    if self.selecting_crop then return self:cropMove(pos) end
    if self.rotating then return self:rotateMove(pos) end
    if self.image_rotating then return self:imageRotateMove(pos) end
    if self.active_image then return self:imagePan(pos) end
    if self.shape_move then return self:shapeMovePan(pos) end
    if self.tool == "text" then return self:textToolPan(pos) end
    if self.tool == "lasso" then return self:lassoPan(pos) end
    if self.tool == "fill" then return true end   -- fill is a tap, ignore drags
    if self.tool == "shape" then return self:shapeMove(pos) end
    if self.tool == "pan" then
        if self.pan_last then
            self:panByScreen(pos.x - self.pan_last.x, pos.y - self.pan_last.y)
            self.pan_last.x, self.pan_last.y = pos.x, pos.y
            return true
        end
        return false
    end
    if not self.capturing then return false end
    if self.pending_lift then          -- movement resumes the held stroke
        UIManager:unschedule(self._finalize)
        self.pending_lift = nil
    end
    self:addScreenPoint(pos.x, pos.y, false)
    return true
end
InkAwayView.onIaHoldPan = InkAwayView.onIaPan

function InkAwayView:onIaPanRelease(_, ges)
    if self:fingerRejected() then return true end
    if self._fab_press then self._fab_press = nil; return true end
    if self.selecting_crop then return self:cropRelease(ges and ges.pos) end
    if self.rotating then return self:rotateEnd() end
    if self.image_rotating then return self:imageRotateEnd() end
    if self.active_image then return self:imageRelease() end
    if self.shape_move then return self:shapeMoveRelease() end
    if self.tool == "text" then return self:textToolRelease(ges and ges.pos) end
    if self.tool == "lasso" then return self:lassoRelease(ges and ges.pos) end
    if self.tool == "fill" then return true end
    if self.tool == "shape" then return self:shapeRelease(ges and ges.pos) end
    if self.tool == "pan" then
        self.pan_last = nil
        return true
    end
    if not self.capturing then return false end
    if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false) end
    self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                          ges and ges.pos and ges.pos.y or 0)
    return true
end
InkAwayView.onIaHoldRel = InkAwayView.onIaPanRelease

function InkAwayView:onIaSwipe(_, ges)
    if self:fingerRejected() then return true end
    if self._fab_press then self._fab_press = nil; return true end
    if self.selecting_crop then return self:cropRelease(ges and (ges.end_pos or ges.pos)) end
    if self.rotating then return self:rotateEnd() end
    if self.image_rotating then return self:imageRotateEnd() end
    if self.active_image then return self:imageRelease() end
    if self.shape_move then return self:shapeMoveRelease() end
    if self.tool == "lasso" then return self:lassoRelease(ges and (ges.end_pos or ges.pos)) end
    if self.tool == "fill" then return true end
    -- For a shape, only trust the swipe's END position; its start position would
    -- collapse the shape to a dot and cancel it. With no end_pos, keep the last
    -- dragged size (tracked by shapeMove).
    if self.tool == "shape" then return self:shapeRelease(ges and ges.end_pos) end
    if self.tool == "text" then return self:textToolRelease(ges and (ges.end_pos or ges.pos)) end
    if self.tool == "pan" then
        self.pan_last = nil
        return true
    end
    if not self.capturing then return false end
    -- swipe reports the lift point separately as end_pos
    local p = ges and (ges.end_pos or ges.pos)
    if p then self:addScreenPoint(p.x, p.y, false) end
    self:scheduleFinalize(p and p.x or 0, p and p.y or 0)
    return true
end

function InkAwayView:onIaTap(_, ges)
    if self:fingerRejected() then return true end
    -- floating controls: complete a tap begun on one of them
    if self._fab_press then
        local kind = self._fab_press; self._fab_press = nil
        self:fabAction(kind)
        return true
    end
    -- Toolbar taps are consumed by the buttons before this runs.
    -- Page-nav strip taps (notebook mode), below the drawing area.
    local p = ges and ges.pos
    if self.notebook and self.nb_bar_h > 0 and p then
        local function hit(r) return r and p.x >= r.x and p.x <= r.x + r.w and p.y >= r.y and p.y <= r.y + r.h end
        if hit(self._nb_plus) then self:nbAddPage(); return true end
        if hit(self._nb_prev) then self:nbGo(-1); return true end
        if hit(self._nb_next) then self:nbGo(1); return true end
        if hit(self._nb_count) then self:openPageMenu(); return true end
        -- swallow taps anywhere on the strip so they never fall through to drawing
        local v = self.view
        if p.y >= v.area_y + v.area_h then return true end
    end
    if self.selecting_crop then return self:cropRelease(ges and ges.pos) end
    if self.rotating then return self:rotateEnd() end
    -- Open the edit menu on the TAP (a touch just selected + armed a drag); doing
    -- it here, on the completed gesture, avoids the tap closing the fresh dialog.
    if p and self.tool == "pan" then
        if self.active_image and self:imageZone(p.x, p.y) ~= "outside" then
            self:openImageMenu(self.active_image); return true
        end
        if self.selected and self:pointOnShape(self.selected.op, p.x, p.y) then
            self:openShapeMenu(self.selected); return true
        end
    end
    if self.tool == "text" then return self:textToolRelease(ges and ges.pos) end
    if self.tool == "lasso" then return self:lassoTap(ges and ges.pos) end
    if self.tool == "fill" then return true end   -- fill already happened on touch
    if self.tool == "shape" then return self:shapeRelease(ges and ges.pos) end
    -- A tap inside the area finishes the dot started by the preceding touch.
    if self.capturing then
        if ges and ges.pos then self:addScreenPoint(ges.pos.x, ges.pos.y, false) end
        self:scheduleFinalize(ges and ges.pos and ges.pos.x or 0,
                              ges and ges.pos and ges.pos.y or 0)
        return true
    end
    return false
end

function InkAwayView:onIaHold(_, ges)
    if self:fingerRejected() then return true end
    if self._fab_press then self._fab_press = nil; return true end
    -- A hold on a placed image or shape picks it and opens its edit menu (a tap
    -- does the same via onIaTouch; hold is here for when the touch missed). We
    -- soak up other holds inside the area so they don't become a long press menu.
    if self.capturing or self.shape_drag or self.curve_stage
       or self.rotating or self.image_rotating then return true end
    local pos = ges and ges.pos
    if not (pos and self:inArea(pos.x, pos.y)) then return false end
    -- selecting only happens in Pan mode, so a hold never fights with drawing
    if self.tool == "pan" then
        if self.active_image then
            if self:imageZone(pos.x, pos.y) ~= "outside" then
                self._img_drag = nil     -- a hold cancels a pending move
                self:openImageMenu(self.active_image)
            end
            return true
        end
        local isel = self:hitTestImage(pos.x, pos.y)
        if isel then self:selectImage(isel); self:openImageMenu(self.active_image); return true end
        if self.selected then self.shape_move = nil; self:openShapeMenu(self.selected); return true end
        local sel = self:hitTestShape(pos.x, pos.y)
        if sel then self.selected = sel; self:openShapeMenu(sel) end
    end
    return true
end

-- Two finger pan works whatever tool is active. Commit any stroke in progress
-- first so no ink is lost, then pan by how far the midpoint between the two
-- fingers moved since the last step.
function InkAwayView:onIaTwoPan(_, ges)
    if self:fingerRejected() then return true end   -- palm splayed under the pen
    self:flushPending()
    self:cancelShape()   -- a two-finger pan drops any half-placed shape
    local pos = ges.pos
    if not self.pan_last then
        self.pan_last = { x = pos.x, y = pos.y }
    else
        self:panByScreen(pos.x - self.pan_last.x, pos.y - self.pan_last.y)
        self.pan_last.x, self.pan_last.y = pos.x, pos.y
    end
    return true
end

function InkAwayView:onIaTwoPanRel()
    self.pan_last = nil
    return true
end

------------------------------------------------------------------------------
-- Undo / exit
------------------------------------------------------------------------------

-- Apply one stored word-level step to a COMMITTED text box (the op at ops[idx]),
-- without re-opening it or bringing up the keyboard. `from` is the stack to pop,
-- `to` the stack to push the current state onto (undo <-> redo). Uses clone +
-- replace, like a placed-shape edit, so canvas snapshots that still reference the
-- old op are never mutated. Returns true if a step was applied.
function InkAwayView:commitTextStep(idx, from, to)
    local ops = self.canvas.ops
    local op = ops[idx]
    local h = op and self._text_hist[op]
    if not (h and from and #from > 0) then return false end
    local snap = table.remove(from)
    to[#to + 1] = { paras = Notebook.deepcopy(op.paras), cur = { p = 1, o = 0 } }
    local nop = self.canvas:cloneOp(op)   -- shallow copy; shares nothing we mutate
    nop.paras = snap.paras                -- a fresh, deep-copied paragraph list
    ops[idx] = nop
    self._text_hist[nop] = h              -- carry the history onto the new identity
    self._text_hist[op] = nil
    self._peel_op = nop                   -- we are actively peeling this box
    self.dirty = true
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    return true
end

-- Is the most recent op a committed text box that still has word-level history to
-- peel back (or, for redo, to replay)? Returns idx, hist or nil.
function InkAwayView:topTextHist()
    local ops = self.canvas.ops
    local top = ops[#ops]
    local h = top and top.kind == "text" and self._text_hist[top]
    if h then return #ops, h end
end

function InkAwayView:undo()
    if self.editing_text then return self:textUndo() end   -- undo within the box
    -- A committed text box peels back a word at a time, so one Undo never wipes a
    -- whole block. When its history is spent, fall through to the normal ops undo
    -- (which finally removes a new box / restores an edited box's previous text).
    local idx, h = self:topTextHist()
    if idx and #h.undo > 0 then
        self:commitTextStep(idx, h.undo, h.redo)
        return
    end
    self._peel_op = nil   -- leaving any text-peel sequence
    self:flushPending()
    if self.active_image then self:finishImageEdit() end
    if self.rotating then self:rotateEnd() end
    if not self.canvas:undo() then
        UIManager:show(InfoMessage:new{ text = _("Nothing to undo."), timeout = 1 })
        return
    end
    self.selected = nil
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self.dirty = true
    self:composeCanvas()   -- rebuild the master from the restored ops
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:redo()
    if self.editing_text then return self:textRedo() end   -- redo within the box
    -- Replay a peeled-back committed text box word by word (mirror of undo()), but
    -- only while we are actively peeling THAT box -- otherwise redo means "restore
    -- the op the last plain Undo removed", which is the normal ops redo below.
    local idx, h = self:topTextHist()
    if idx and h.redo and #h.redo > 0 and self.canvas.ops[idx] == self._peel_op then
        self:commitTextStep(idx, h.redo, h.undo)
        return
    end
    self._peel_op = nil
    self:flushPending()
    if self.active_image then self:finishImageEdit() end
    if not self.canvas:redo() then
        UIManager:show(InfoMessage:new{ text = _("Nothing to redo."), timeout = 1 })
        return
    end
    self.selected = nil
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self.dirty = true
    self:composeCanvas()
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:promptExit()
    local ConfirmBox = require("ui/widget/confirmbox")
    self:flushPending()
    if self.canvas:isEmpty() then
        UIManager:close(self)
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Leave Ink Away? Any unsaved drawing will be lost."),
        ok_text = _("Leave"),
        ok_callback = function() UIManager:close(self) end,
    })
end

------------------------------------------------------------------------------
-- Lasso select: loop around ink/shapes/fills to pick them, then drag the whole
-- group freely, or duplicate / delete them. Works the same on a plain canvas
-- and on a notebook page (both are just ops lists).
------------------------------------------------------------------------------

function InkAwayView:clearSelection()
    if self._sel_refresh_tick then self:stopSelRefresh() end
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Recompute the selection's bounding box (canvas coords) from its ops.
function InkAwayView:recomputeSelectionBBox()
    if not self.selection then return end
    local x0, y0, x1, y1
    for _, idx in ipairs(self.selection.idxs) do
        local op = self.canvas.ops[idx]
        if op then x0, y0, x1, y1 = accumBounds(op, x0, y0, x1, y1) end
    end
    self.selection.bbox = x0 and { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } or nil
end

-- Is a screen point inside the selection box (with a little slack for the finger)?
function InkAwayView:inSelBBoxScreen(sx, sy)
    local b = self.selection and self.selection.bbox
    if not b then return false end
    local x0, y0 = InkGeom.toScreen(self.view, b.x0, b.y0)
    local x1, y1 = InkGeom.toScreen(self.view, b.x1, b.y1)
    local pad = 24
    return sx >= x0 - pad and sx <= x1 + pad and sy >= y0 - pad and sy <= y1 + pad
end

-- Pick every op whose centroid lies inside the lasso polygon (canvas coords).
function InkAwayView:computeSelection(poly)
    local idxs = {}
    for i, op in ipairs(self.canvas.ops) do
        if op.kind ~= "erase" and opInPoly(op, poly) then idxs[#idxs + 1] = i end
    end
    if #idxs == 0 then self.selection = nil; return false end
    self.selection = { idxs = idxs }
    self:recomputeSelectionBBox()
    return true
end

-- Close the lasso loop, select what it encircled, and show the box.
function InkAwayView:lassoFinish()
    self.lassoing = false
    local scr = self.lasso_scr
    self.lasso_scr = nil
    if not scr or #scr < 6 then    -- need at least 3 points for an area
        self:renderView(); UIManager:setDirty(self, "ui", self:areaScreenRect())
        return
    end
    local poly = {}
    for i = 1, #scr, 2 do
        local cx, cy = InkGeom.toCanvas(self.view, scr[i], scr[i + 1])
        poly[#poly + 1] = cx; poly[#poly + 1] = cy
    end
    local got = self:computeSelection(poly)
    self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
    if not got then
        UIManager:show(InfoMessage:new{ text = _("Nothing inside the loop."), timeout = 2 })
    end
end

-- Commit a move of the selected ops by a screen delta.
function InkAwayView:selMoveCommit(sdx, sdy)
    if not self.selection then return end
    local dx = sdx / self.view.zoom
    local dy = sdy / self.view.zoom
    if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then
        self:renderView(); UIManager:setDirty(self, "ui", self:areaScreenRect()); return
    end
    self.canvas:pushHistory()
    for _, idx in ipairs(self.selection.idxs) do
        local op = self.canvas.ops[idx]
        if op then translateOp(op, dx, dy) end
    end
    self.dirty = true
    self:recomputeSelectionBBox()
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Duplicate / delete the current selection, from its tap-menu.
function InkAwayView:selDuplicate()
    if not self.selection then return end
    self.canvas:pushHistory()
    local off = math.floor(24 / self.view.zoom + 0.5)
    local new_idxs = {}
    for _, idx in ipairs(self.selection.idxs) do
        local op = self.canvas.ops[idx]
        if op then
            local c = self.canvas:cloneOp(op)
            translateOp(c, off, off)
            self.canvas.ops[#self.canvas.ops + 1] = c
            new_idxs[#new_idxs + 1] = #self.canvas.ops
        end
    end
    self.selection = { idxs = new_idxs }   -- the copies become the selection
    self:recomputeSelectionBBox()
    self.dirty = true
    self:composeCanvas(); self:renderView()
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

function InkAwayView:selDelete()
    if not self.selection then return end
    self.canvas:pushHistory()
    table.sort(self.selection.idxs, function(a, b) return a > b end)  -- remove high-to-low
    for _, idx in ipairs(self.selection.idxs) do self.canvas:removeOp(idx) end
    self.selection = nil
    self.dirty = true
    self:composeCanvas(); self:renderView()
    self:refresh(self, "full")
end

function InkAwayView:openSelectionMenu()
    if not self.selection then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    local dlg
    local n = #self.selection.idxs
    local buttons = {
        {{ text = string.format(_("%d item(s) selected"), n), enabled = false }},
        {{ text = _("Duplicate"), callback = function() UIManager:close(dlg); self:selDuplicate() end }},
        {{ text = _("Delete"), callback = function() UIManager:close(dlg); self:selDelete() end }},
        {{ text = _("Deselect"), callback = function() UIManager:close(dlg); self:clearSelection() end }},
        {{ text = _("Keep selection"), callback = function() UIManager:close(dlg) end }},
    }
    dlg = ButtonDialog:new{ title = _("Selection"), title_align = "center", buttons = buttons }
    self._shape_menu = dlg
    UIManager:show(dlg)
end

-- The selection box as a screen rect at drag offset (dx,dy), padded. Nil if none.
function InkAwayView:selBoxScreenRect(dx, dy)
    local b = self.selection and self.selection.bbox
    if not b then return nil end
    local v = self.view
    local x0, y0 = InkGeom.toScreen(v, b.x0, b.y0)
    local x1, y1 = InkGeom.toScreen(v, b.x1, b.y1)
    local pad = 8
    return { x = math.floor(math.min(x0, x1) + dx) - pad,
             y = math.floor(math.min(y0, y1) + dy) - pad,
             w = math.floor(math.abs(x1 - x0)) + pad * 2,
             h = math.floor(math.abs(y1 - y0)) + pad * 2 }
end

-- Refresh just the box's old and new footprints (a "fast" e-ink update), which
-- is far cheaper than the whole area and does not pile up refreshes.
function InkAwayView:selRefreshNow()
    self._sel_refresh_pending = false
    if not (self.sel_press and self.selection) then return end
    local cur = self:selBoxScreenRect(self.sel_press.dx, self.sel_press.dy)
    if not cur then return end
    local r = cur
    local last = self._sel_last_rect
    if last then
        local x0, y0 = math.min(r.x, last.x), math.min(r.y, last.y)
        local x1 = math.max(r.x + r.w, last.x + last.w)
        local y1 = math.max(r.y + r.h, last.y + last.h)
        r = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
    end
    self._sel_last_rect = cur
    local v = self.view
    local x0 = math.max(v.area_x, r.x)
    local y0 = math.max(v.area_y, r.y)
    local x1 = math.min(v.area_x + v.area_w, r.x + r.w)
    local y1 = math.min(v.area_y + v.area_h, r.y + r.h)
    if x1 > x0 and y1 > y0 then
        -- "ui" (not the A2 "fast" waveform) keeps the moving box clean with no
        -- smear trail; the region is small (just the box), so it never floods
        UIManager:setDirty(self, "ui", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    end
end

function InkAwayView:scheduleSelRefresh()
    if self._sel_refresh_pending then return end
    self._sel_refresh_pending = true
    UIManager:scheduleIn(0.15, self._sel_refresh_tick)   -- at most ~6 refreshes/sec
end

function InkAwayView:stopSelRefresh()
    UIManager:unschedule(self._sel_refresh_tick)
    self._sel_refresh_pending = false
    self._sel_last_rect = nil
end

-- Gesture entry points for the lasso tool, dispatched from the main handlers.
function InkAwayView:lassoTouch(pos)
    if self.selection and self:inSelBBoxScreen(pos.x, pos.y) then
        self.sel_press = { x = pos.x, y = pos.y, dx = 0, dy = 0, moved = false }
        self._sel_last_rect = self:selBoxScreenRect(0, 0)   -- seed for the union refresh
        return true
    end
    self:clearSelection()
    self.lassoing = true
    self.lasso_scr = { pos.x, pos.y }
    return true
end

function InkAwayView:lassoPan(pos)
    if self.sel_press then
        self.sel_press.moved = true
        self.sel_press.dx = pos.x - self.sel_press.x
        self.sel_press.dy = pos.y - self.sel_press.y
        self:scheduleSelRefresh()      -- throttled small refresh; never floods e-ink
        return true
    end
    if self.lassoing and self.lasso_scr then
        self.lasso_scr[#self.lasso_scr + 1] = pos.x
        self.lasso_scr[#self.lasso_scr + 1] = pos.y
        -- refresh only a small fixed box around the new point (never a whole
        -- segment, which on a fast stroke is huge and floods the e-ink queue);
        -- the trail from earlier points stays on the panel
        UIManager:setDirty(self, "fast", GeomUI:new{ x = pos.x - 14, y = pos.y - 14, w = 28, h = 28 })
        return true
    end
    return true
end

function InkAwayView:lassoRelease(pos)
    if self.sel_press then
        local moved = self.sel_press.moved
        local dx, dy = self.sel_press.dx, self.sel_press.dy
        self.sel_press = nil
        self:stopSelRefresh()
        if moved then self:selMoveCommit(dx, dy) end
        return true
    end
    if self.lassoing then
        if pos then self.lasso_scr[#self.lasso_scr + 1] = pos.x; self.lasso_scr[#self.lasso_scr + 1] = pos.y end
        self:lassoFinish()
        return true
    end
    return true
end

function InkAwayView:lassoTap(pos)
    self.sel_press = nil
    self:stopSelRefresh()
    if self.lassoing then self:lassoFinish(); return true end
    if self.selection then
        if pos and self:inSelBBoxScreen(pos.x, pos.y) then self:openSelectionMenu()
        else self:clearSelection() end
    end
    return true
end

------------------------------------------------------------------------------
-- Painting
------------------------------------------------------------------------------

------------------------------------------------------------------------------
-- Text notes: creating, editing and moving a text box. The box being edited is
-- kept off the ops list and drawn as a live overlay (like a shape preview), so
-- typing never recomposes the whole page -- only the box's rectangle refreshes.
-- On finish it is baked into the master bitmap and added to the ops, so it
-- saves, undoes and exports exactly like ink.
------------------------------------------------------------------------------

local TEXT_HANDLE = 40   -- touch target for the move / resize handles (screen px)

-- Lay the editing op out at the current zoom (so the overlay is crisp) and grow
-- an auto-height box to fit. Returns layout, ctx and the width-scaled proxy the
-- engine measured against.
-- Bump to invalidate the cached layout (call after any edit that changes the
-- text, the wrap width or the font/size).
function InkAwayView:invalidateLayout() self._lay_ver = (self._lay_ver or 0) + 1 end

-- Lay the editing op out at the current zoom, caching the result: the layout is
-- otherwise recomputed several times per keystroke (scroll-into-view, then the
-- paint, then the caret) which is O(text) each time. The cache is keyed on a
-- version bumped by edits, plus the op and zoom.
function InkAwayView:editTextLayout()
    local op = self.editing_text
    local zoom = self.view.zoom
    local ver = self._lay_ver or 0
    local c = self._lay_cache
    if c and c.op == op and c.ver == ver and c.zoom == zoom then
        return c.lay, c.ctx, c.proxy
    end
    local ctx = self:textCtx(op, zoom)
    local proxy = setmetatable({ w = op.w * zoom }, { __index = op })
    local lay = Text.layout(proxy, ctx)
    if op.auto_h then op.h = math.max(1, lay.height / zoom) end
    self._lay_cache = { op = op, ver = ver, zoom = zoom, lay = lay, ctx = ctx, proxy = proxy }
    return lay, ctx, proxy
end

-- The editing box rectangle on screen (clamped later by callers). InkGeom.toScreen
-- already includes the area origin, so we must NOT add area_x/area_y again -- doing
-- so shifted the editing overlay down by one toolbar height versus the committed
-- box (the "box jumps down a notch when reopened" bug).
function InkAwayView:textBoxScreenRect()
    local op, v = self.editing_text, self.view
    local sx, sy = InkGeom.toScreen(v, op.x, op.y)
    return { x = sx, y = sy, w = op.w * v.zoom, h = op.h * v.zoom }
end

-- The Format and Done pills (top-right of the drawing area), always visible
-- while editing. Sized to the label they hold so text never spills over the
-- border. Font sizes are logical (Font:getFace scales by DPI), so 18 is normal.
function InkAwayView:labelWidget(text)
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    return TextWidget:new{ text = text, face = Font:getFace("cfont", 18),
        fgcolor = Blitbuffer.COLOR_BLACK }
end

-- Lay out the two edit buttons: [ Format ][ ✓ Done ] pinned to the top-right.
-- The label sizes depend only on the (constant) labels and DPI, so measure them
-- once and cache: this method runs on every overlay paint and every touch, and
-- building throwaway TextWidgets each time was needless work on e-ink.
function InkAwayView:textEditButtons()
    local v = self.view
    local m = self._text_btn_metrics
    if not m then
        local dlabel = "\u{2713} " .. _("Done")
        local dw_ = self:labelWidget(dlabel)
        local ds = dw_:getSize(); dw_:free()
        local fw_ = self:labelWidget(_("Format"))
        local fs = fw_:getSize(); fw_:free()
        m = { ds = { w = ds.w, h = ds.h }, fs = { w = fs.w, h = fs.h }, dlabel = dlabel }
        self._text_btn_metrics = m
    end
    local ds, fs = m.ds, m.fs
    local pad = math.floor(ds.h * 0.5)
    local h = ds.h + 2 * math.floor(ds.h * 0.35)
    local dwid = ds.w + 2 * pad
    local fwid = fs.w + 2 * pad
    local y = v.area_y + 8
    local dx = v.area_x + v.area_w - dwid - 8
    local fx = dx - fwid - 10
    return {
        done   = { x = dx, y = y, w = dwid, h = h, label = m.dlabel },
        format = { x = fx, y = y, w = fwid, h = h, label = _("Format") },
    }
end

function InkAwayView:textDoneRect() return self:textEditButtons().done end

-- Which part of the box a screen point falls on: "resize", "move", "inside" or
-- "outside".
function InkAwayView:textZone(sx, sy)
    local r = self:textBoxScreenRect()
    if sx >= r.x + r.w - TEXT_HANDLE and sx <= r.x + r.w + TEXT_HANDLE
       and sy >= r.y + r.h - TEXT_HANDLE and sy <= r.y + r.h + TEXT_HANDLE then
        return "resize"
    end
    -- the move handle is a strip just above the box's top-left
    if sx >= r.x - TEXT_HANDLE and sx <= r.x + TEXT_HANDLE
       and sy >= r.y - TEXT_HANDLE and sy <= r.y + TEXT_HANDLE then
        return "move"
    end
    if sx >= r.x and sx <= r.x + r.w and sy >= r.y and sy <= r.y + r.h then
        return "inside"
    end
    return "outside"
end

-- Refresh just the box's rectangle (plus a margin for the frame / handles).
function InkAwayView:refreshTextBox(mode)
    local v = self.view
    local r = self:textBoxScreenRect()
    local pad = TEXT_HANDLE + 4
    local x0 = math.max(v.area_x, r.x - pad)
    local y0 = math.max(v.area_y, r.y - pad)
    local x1 = math.min(v.area_x + v.area_w, r.x + r.w + pad)
    local y1 = math.min(v.area_y + v.area_h, r.y + r.h + pad)
    if x1 > x0 and y1 > y0 then
        UIManager:setDirty(self, mode or "ui", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
    end
end

-- Every few edits, clear the fast-refresh ghosting the box leaves behind.
function InkAwayView:afterTextEdit()
    self:invalidateLayout()   -- the text just changed
    self:ensureCaretVisible()
    self._text_edits = (self._text_edits or 0) + 1
    if self._text_edits >= 24 then
        self._text_edits = 0
        self:refreshTextBox("flashui")
    else
        self:refreshTextBox("ui")
    end
end

-- Screen y of the top of the on-screen keyboard (or the screen bottom if none).
function InkAwayView:keyboardTop()
    local kb = self._text_kb
    if kb and kb.dimen and kb.dimen.h then return self.screen_h - kb.dimen.h end
    return self.screen_h
end

-- Scroll the page vertically so the caret line sits in the strip between the
-- toolbar and the keyboard (the keyboard otherwise hides the box you type in).
function InkAwayView:ensureCaretVisible()
    if not self.editing_text then return end
    local v = self.view
    local lay, ctx = self:editTextLayout()
    local c = Text.caret(self.editing_text, lay, self.text_cur, ctx)   -- op-local, scale=zoom
    local caret_top = self.editing_text.y + c.y / v.zoom               -- canvas coords
    local caret_bot = caret_top + c.h / v.zoom
    local margin = 12
    local top_lim = v.area_y + margin
    local bot_lim = self:keyboardTop() - margin
    local top_scr = v.area_y + (caret_top - v.pan_y) * v.zoom
    local bot_scr = v.area_y + (caret_bot - v.pan_y) * v.zoom
    local new_pan = v.pan_y
    if bot_scr > bot_lim then
        new_pan = caret_bot - (bot_lim - v.area_y) / v.zoom
    elseif top_scr < top_lim then
        new_pan = caret_top - (top_lim - v.area_y) / v.zoom
    end
    new_pan = math.max(0, math.min(math.max(0, v.canvas_h - 1), new_pan))
    if math.abs(new_pan - v.pan_y) >= 1 then
        v.pan_y = new_pan
        self:renderView()
        UIManager:setDirty(self, "ui")
    end
end

-- Default size and width for a new box on this device / page.
function InkAwayView:newTextAt(pos)
    local v = self.view
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    -- span the full page (the grid runs edge to edge) with only a small margin
    local margin = math.max(6, math.floor(v.canvas_w * 0.02))
    local size = self.text_size or math.max(16, math.floor(v.canvas_w / 32))
    local op = Text.new{ x = margin, y = cy, w = v.canvas_w - 2 * margin, size = size,
        font = self.text_font, align = "left", grid_snap = self.text_grid_snap }
    -- snap the box origin to the ruling if the user asked for grid alignment
    if self.text_grid_snap then self:snapTextBoxToGrid(op) end
    self:startTextEdit(op, { p = 1, o = 0 }, true, nil)
end

-- Build the on-screen keyboard and point it at this view's text methods.
function InkAwayView:showTextKeyboard()
    if self._text_kb then return end
    local VirtualKeyboard = require("ui/widget/virtualkeyboard")
    local view = self
    local inputbox = {
        parent = self,
        addChars = function(_, s) view:textAddChars(s) end,
        delChar = function() view:textDelChar() end,
        delWord = function() view:textDelChar() end,
        delToStartOfLine = function() view:textDelToBOL() end,
        leftChar = function() view:textMove(-1, 0) end,
        rightChar = function() view:textMove(1, 0) end,
        upLine = function() view:textMove(0, -1) end,
        downLine = function() view:textMove(0, 1) end,
        goToStartOfLine = function() view:textHome() end,
        goToEndOfLine = function() view:textEnd() end,
        scrollUp = function() end,
        scrollDown = function() end,
    }
    self._text_kb = VirtualKeyboard:new{ keyboard_layer = 2, inputbox = inputbox }
    -- With the keyboard on top of the window stack, UIManager only delivers
    -- gestures to lower widgets that are is_always_active. Without this the
    -- toolbar and canvas would go dead while typing (no way to switch tool or
    -- dismiss). We turn it back off when editing ends.
    self.is_always_active = true
    UIManager:show(self._text_kb)
end

function InkAwayView:hideTextKeyboard()
    self.is_always_active = false
    if self._text_kb then
        UIManager:close(self._text_kb)
        self._text_kb = nil
    end
end

-- Enter edit mode on `op`. For an existing op we edit a deep copy and hide the
-- original, so an Undo after editing restores the text as it was.
function InkAwayView:startTextEdit(op, cur, is_new, idx, hit_pos)
    self:flushPending(); self:flushShape()
    if self.selection or self.lassoing then self:clearSelection() end
    if is_new then
        self.editing_text = op
    else
        self._text_orig = self.canvas.ops[idx]
        -- copy BEFORE hiding the original, so the editable copy is not itself
        -- marked hidden (that made the box vanish after committing an edit)
        self.editing_text = Notebook.deepcopy(op)
        self.editing_text.hidden = nil
        self._text_orig.hidden = true
        self:composeCanvas()
    end
    self.editing_idx = idx
    self.editing_is_new = is_new
    self.text_cur = cur or { p = 1, o = 0 }
    self.text_sel = nil
    self._text_edits = 0
    self._text_undo, self._text_redo, self._text_coalesce = {}, {}, nil
    self:showTextKeyboard()
    -- Place the caret at the tapped point BEFORE the one scroll-into-view pass, so
    -- opening a box never pans (the tap is above the keyboard by construction) and
    -- there is no visible jump. We do not save/restore pan_y: leaving the scroll
    -- where the caret needs it means closing the keyboard never snaps back either.
    if hit_pos then
        local r = self:textBoxScreenRect()
        local lay = self:editTextLayout()
        self.text_cur = Text.hit(self.editing_text, lay, hit_pos.x - r.x, hit_pos.y - r.y,
            self:textCtx(self.editing_text, self.view.zoom))
    end
    self:ensureCaretVisible()           -- only pans if the caret is actually hidden
    self:renderView()
    self:refresh(self, "full")
end

-- Leave edit mode, baking the box in (commit) or dropping the edit (cancel).
function InkAwayView:finishTextEdit(commit)
    if not self.editing_text then return end
    if commit == nil then commit = true end
    local op = self.editing_text
    local committed_op   -- the op that ended up on the ops list (for undo history)
    if self.editing_is_new then
        if commit and not Text.isEmpty(op) then
            self.canvas:pushHistory()
            self.canvas.ops[#self.canvas.ops + 1] = op
            committed_op = op
        end
    else
        local orig = self._text_orig
        orig.hidden = nil
        if commit then
            if Text.isEmpty(op) then
                self.canvas:pushHistory()
                table.remove(self.canvas.ops, self.editing_idx)   -- emptied: delete it
            else
                op.hidden = nil   -- make sure the committed box is drawn
                self.canvas:pushHistory()
                self.canvas.ops[self.editing_idx] = op
                committed_op = op
            end
        end
    end
    -- Keep this box's word-level history alive so a later Undo peels it back a
    -- word at a time (see undo()), rather than deleting the whole block at once.
    if committed_op and self._text_undo and #self._text_undo > 0 then
        self._text_hist[committed_op] = { undo = self._text_undo, redo = self._text_redo or {} }
    end
    self._peel_op = nil
    self.editing_text, self._text_orig = nil, nil
    self.editing_idx, self.editing_is_new = nil, nil
    self.text_cur, self.text_sel = nil, nil
    self._text_pending_style = nil
    self._lay_cache = nil
    if self._text_fmt then UIManager:close(self._text_fmt); self._text_fmt = nil end
    self.dirty = true
    self:hideTextKeyboard()
    self:composeCanvas()
    self:renderView()
    self:refresh("all", "full")
end

-- ---- per-box undo / redo -------------------------------------------------
-- A text-local history so Undo/Redo work inside the box without recomposing the
-- whole page per keystroke. Snapshots coalesce: a run of typed letters is one
-- word, a run of deletions is one step, and each format change is its own step.
-- `kind` groups consecutive same-kind edits; a boundary (space/newline, a cursor
-- move, or a different kind) starts a new undo step.
function InkAwayView:pushTextHistory()
    if not self.editing_text then return end
    self._text_undo = self._text_undo or {}
    self._text_undo[#self._text_undo + 1] = {
        paras = Notebook.deepcopy(self.editing_text.paras),
        cur = { p = self.text_cur.p, o = self.text_cur.o },
    }
    if #self._text_undo > 80 then table.remove(self._text_undo, 1) end
    self._text_redo = {}
end

-- Call before a mutating edit. Pushes a snapshot only when a new undo step
-- should begin, so typing a word is a single step.
function InkAwayView:textMark(kind)
    if self._text_coalesce ~= kind then self:pushTextHistory() end
    self._text_coalesce = kind
end

function InkAwayView:textBreakCoalesce() self._text_coalesce = nil end

function InkAwayView:textRestore(stack, other)
    if not (self.editing_text and stack and #stack > 0) then return end
    other[#other + 1] = {
        paras = Notebook.deepcopy(self.editing_text.paras),
        cur = { p = self.text_cur.p, o = self.text_cur.o },
    }
    local snap = table.remove(stack)
    self.editing_text.paras = snap.paras
    local np = #self.editing_text.paras
    local cp = math.max(1, math.min(np, snap.cur.p))
    self.text_cur = { p = cp, o = math.min(snap.cur.o, Text.paraLen(self.editing_text.paras[cp])) }
    self.text_sel = nil
    self._text_coalesce = nil
    self:invalidateLayout()
    self:ensureCaretVisible()
    self:refreshTextBox("ui")
end

function InkAwayView:textUndo() self:textRestore(self._text_undo, self._text_redo) end
function InkAwayView:textRedo() self:textRestore(self._text_redo, self._text_undo) end

-- ---- text mutation (driven by the keyboard) ------------------------------
function InkAwayView:textDeleteSelIfAny()
    if self.text_sel and not Text.selEmpty(self.text_sel) then
        self.text_cur = Text.deleteRange(self.editing_text, self.text_sel)
        self.text_sel = nil
        return true
    end
    self.text_sel = nil
    return false
end

function InkAwayView:textAddChars(s)
    if not self.editing_text then return end
    -- a space / newline closes the current word so the next one is its own step
    self:textMark("type")
    if s == " " or s == "\n" then self._text_coalesce = nil end
    self:textDeleteSelIfAny()
    local style = self._text_pending_style or nil
    self.text_cur = Text.insert(self.editing_text, self.text_cur, s, style)
    self._text_pending_style = nil
    self:afterTextEdit()
end

function InkAwayView:textDelChar()
    if not self.editing_text then return end
    self:textMark("delete")
    if not self:textDeleteSelIfAny() then
        self.text_cur = Text.deleteBack(self.editing_text, self.text_cur)
    end
    self:afterTextEdit()
end

function InkAwayView:textDelToBOL()
    if not self.editing_text then return end
    self:textMark("delete")
    self.text_cur = Text.deleteRange(self.editing_text,
        { a = { p = self.text_cur.p, o = 0 }, b = self.text_cur })
    self.text_sel = nil
    self:afterTextEdit()
end

-- Move the caret. dx: -1/+1 by char; dy: -1/+1 by line.
function InkAwayView:textMove(dx, dy)
    if not self.editing_text then return end
    local op, cur = self.editing_text, self.text_cur
    self.text_sel = nil
    if dx ~= 0 then
        local o = cur.o + dx
        if o < 0 then
            if cur.p > 1 then cur = { p = cur.p - 1, o = Text.paraLen(op.paras[cur.p - 1]) } end
        elseif o > Text.paraLen(op.paras[cur.p]) then
            if cur.p < #op.paras then cur = { p = cur.p + 1, o = 0 } end
        else
            cur = { p = cur.p, o = o }
        end
    end
    if dy ~= 0 then
        local lay = self:editTextLayout()
        local c = Text.caret(op, lay, cur, self:textCtx(op, self.view.zoom))
        local ny = c.y + (dy > 0 and c.h * 1.5 or -c.h * 0.5)
        cur = Text.hit(op, lay, c.x, ny, self:textCtx(op, self.view.zoom))
    end
    self.text_cur = cur
    self:textBreakCoalesce()
    self:ensureCaretVisible()
    self:refreshTextBox("ui")
end

function InkAwayView:textHome()
    if not self.editing_text then return end
    self.text_cur = { p = self.text_cur.p, o = 0 }
    self.text_sel = nil
    self:refreshTextBox("ui")
end

function InkAwayView:textEnd()
    if not self.editing_text then return end
    self.text_cur = { p = self.text_cur.p, o = Text.paraLen(self.editing_text.paras[self.text_cur.p]) }
    self.text_sel = nil
    self:refreshTextBox("ui")
end

-- ---- styling of the selection (or of the next typing, with no selection) --
function InkAwayView:textHasSel()
    return self.text_sel and not Text.selEmpty(self.text_sel)
end

-- The word around the cursor, as a selection, or nil if the cursor is not on a
-- word. Lets you just tap a word and format it, without a precise drag-select.
function InkAwayView:wordSelAtCursor()
    local op, cur = self.editing_text, self.text_cur
    if not (op and cur) then return nil end
    local ch = Text.chars(Text.paraText(op.paras[cur.p]))
    local function isW(c) return c ~= nil and c:match("[%w'\u{2019}]") ~= nil end
    local lo, hi = cur.o, cur.o
    while lo > 0 and isW(ch[lo]) do lo = lo - 1 end          -- ch[lo] = char left of offset lo
    while hi < #ch and isW(ch[hi + 1]) do hi = hi + 1 end    -- ch[hi+1] = char right of offset hi
    if hi <= lo then return nil end
    return { a = { p = cur.p, o = lo }, b = { p = cur.p, o = hi } }
end

-- What a format action targets: an explicit selection, else the word under the
-- cursor. nil means "no target" -> the style applies to the next typing instead.
function InkAwayView:textEffectiveSel()
    if self:textHasSel() then return self.text_sel end
    return self:wordSelAtCursor()
end

function InkAwayView:textStyleActive(key)
    local sel = self:textEffectiveSel()
    if sel then return Text.styleCovers(self.editing_text, sel, key) end
    local st = self._text_pending_style or Text.styleAt(self.editing_text, self.text_cur)
    return st[key] and true or false
end

function InkAwayView:textToggleStyle(key)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local sel = self:textEffectiveSel()
    if sel then
        local on = not Text.styleCovers(op, sel, key)
        Text.applyStyle(op, sel, key, on or nil)
    else
        self._text_pending_style = self._text_pending_style or Text.styleAt(op, self.text_cur)
        self._text_pending_style[key] = (not self._text_pending_style[key]) or nil
    end
    self:refreshTextBox("ui")
end

function InkAwayView:textStepSize(dir)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local function stepped(st)
        return math.max(0.5, math.min(4, (st.sz or 1) * (dir > 0 and 1.2 or 1 / 1.2)))
    end
    local sel = self:textEffectiveSel()
    if sel then
        local a = Text.orderSel(sel)
        local nz = stepped(Text.styleAt(op, a))
        Text.applyStyle(op, sel, "sz", (math.abs(nz - 1) < 1e-3) and nil or nz)
    else
        self._text_pending_style = self._text_pending_style or Text.styleAt(op, self.text_cur)
        local nz = stepped(self._text_pending_style)
        self._text_pending_style.sz = (math.abs(nz - 1) < 1e-3) and nil or nz
    end
    self:refreshTextBox("ui")
end

function InkAwayView:textToggleBullet(kind)
    local op = self.editing_text
    self:pushTextHistory(); self:textBreakCoalesce(); self:invalidateLayout()
    local sel = self.text_sel or { a = self.text_cur, b = self.text_cur }
    local a = Text.orderSel(sel)
    Text.setBullet(op, sel, op.paras[a.p].bullet == kind and nil or kind)
    self:refreshTextBox("ui")
end

-- A menu to style the word / selection (or the next typing). The keyboard is
-- hidden while it is open -- you are not typing then anyway -- which frees the
-- screen and lets the dialog own the input cleanly (an anchored dialog over the
-- keyboard had its buttons' tap regions in the wrong place).
function InkAwayView:openTextFormatMenu()
    if not self.editing_text then return end
    local ButtonDialog = require("ui/widget/buttondialog")
    if self._text_fmt then UIManager:close(self._text_fmt); self._text_fmt = nil end
    self:hideTextKeyboard()
    local sel = self:textEffectiveSel()
    local target = sel and _("word / selection") or _("new text")
    -- close the menu and bring the keyboard back so the styled result shows
    local function close()
        if self._text_fmt then UIManager:close(self._text_fmt); self._text_fmt = nil end
        if self.editing_text then self:showTextKeyboard() end
    end
    local function mk(label, key)
        return { text = (self:textStyleActive(key) and "\u{2713} " or "") .. label,
                 callback = function() self:textToggleStyle(key); close() end }
    end
    local buttons = {
        {{ text = _("Format: ") .. target, enabled = false }},
        { mk(_("Bold"), "b"), mk(_("Italic"), "i"), mk(_("Underline"), "u") },
        { mk(_("Strike"), "s"), mk(_("Highlight"), "hl"),
          { text = "A-", callback = function() self:textStepSize(-1); close() end },
          { text = "A+", callback = function() self:textStepSize(1); close() end } },
        { { text = "\u{2022} " .. _("List"), callback = function() self:textToggleBullet("disc"); close() end },
          { text = "1. " .. _("List"), callback = function() self:textToggleBullet("number"); close() end } },
        { { text = _("Close"), callback = close } },
    }
    local dlg = ButtonDialog:new{ buttons = buttons,
        -- restore the keyboard if the menu is dismissed by tapping outside it
        tap_close_callback = function()
            self._text_fmt = nil
            if self.editing_text then self:showTextKeyboard() end
        end }
    self._text_fmt = dlg
    UIManager:show(dlg)
end

-- ---- touch handling for the text tool ------------------------------------
-- Find a committed text op under a canvas point (topmost first).
function InkAwayView:textOpAt(cx, cy)
    for i = #self.canvas.ops, 1, -1 do
        local op = self.canvas.ops[i]
        if op.kind == "text" and cx >= op.x and cx <= op.x + op.w
           and cy >= op.y and cy <= op.y + (op.h or 0) then
            return op, i
        end
    end
end

-- A gesture that lands on the on-screen keyboard must never reach the canvas.
-- The view is is_always_active while editing (so the toolbar keeps working), so
-- key taps the keyboard doesn't fully swallow would otherwise fall through here
-- and be treated as taps that create / commit boxes.
function InkAwayView:inKeyboard(pos)
    return self._text_kb ~= nil and pos ~= nil and pos.y >= self:keyboardTop()
end

function InkAwayView:textToolTouch(pos)
    if self:inKeyboard(pos) then return true end
    if self.editing_text then
        local function inRect(rr) return pos.x >= rr.x and pos.x <= rr.x + rr.w
            and pos.y >= rr.y and pos.y <= rr.y + rr.h end
        local btns = self:textEditButtons()
        if inRect(btns.done) then self:finishTextEdit(true); return true end
        if inRect(btns.format) then
            -- defer to release: opening on the final tap event (as the drag-select
            -- path already does) stops the same tap from immediately closing the
            -- menu as an outside-tap, which made the button flaky
            self._text_drag = { kind = "format" }
            return true
        end
        local zone = self:textZone(pos.x, pos.y)
        if zone == "resize" then
            self._text_drag = { kind = "resize", sx = pos.x, sy = pos.y,
                w0 = self.editing_text.w, h0 = self.editing_text.h }
            return true
        elseif zone == "move" then
            self._text_drag = { kind = "move", sx = pos.x, sy = pos.y,
                x0 = self.editing_text.x, y0 = self.editing_text.y }
            return true
        elseif zone == "inside" then
            -- place the caret; a following pan turns it into a selection
            local r = self:textBoxScreenRect()
            local lay = self:editTextLayout()
            local cur = Text.hit(self.editing_text, lay, pos.x - r.x, pos.y - r.y,
                self:textCtx(self.editing_text, self.view.zoom))
            self.text_cur = cur
            self.text_sel = nil
            self._text_drag = { kind = "select", anchor = cur }
            self:textBreakCoalesce()   -- typing at a new spot is a new undo step
            self:refreshTextBox("ui")
            return true
        else
            self:finishTextEdit(true)   -- tapped away: commit and leave
            -- fall through to maybe start a new box at this point
        end
    end
    -- not editing (or just finished): edit an existing box, or start a new one
    local cx, cy = self:toCanvasClamped(pos.x, pos.y)
    local op, idx = self:textOpAt(cx, cy)
    if op then
        -- pass the tap so the caret lands there before the first scroll pass
        self:startTextEdit(op, { p = 1, o = 0 }, false, idx, pos)
    else
        self:newTextAt(pos)
    end
    return true
end

function InkAwayView:textToolPan(pos)
    if self:inKeyboard(pos) and not self._text_drag then return true end
    local d = self._text_drag
    if not d then return true end
    if d.kind == "move" then
        local dx = (pos.x - d.sx) / self.view.zoom
        local dy = (pos.y - d.sy) / self.view.zoom
        local old = self:textBoxScreenRect()
        self.editing_text.x = d.x0 + dx
        self.editing_text.y = d.y0 + dy
        -- refresh the union of the old and new positions so no ghost is left
        local new = self:textBoxScreenRect()
        local v = self.view
        local pad = TEXT_HANDLE + 4
        local x0 = math.max(v.area_x, math.min(old.x, new.x) - pad)
        local y0 = math.max(v.area_y, math.min(old.y, new.y) - pad)
        local x1 = math.min(v.area_x + v.area_w, math.max(old.x + old.w, new.x + new.w) + pad)
        local y1 = math.min(v.area_y + v.area_h, math.max(old.y + old.h, new.y + new.h) + pad)
        if x1 > x0 and y1 > y0 then
            UIManager:setDirty(self, "fast", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
        end
    elseif d.kind == "resize" then
        local dw = (pos.x - d.sx) / self.view.zoom
        local old = self:textBoxScreenRect()
        -- only the width is dragged; height stays automatic so the box always
        -- grows to fit its (re-wrapped) text and the text can never overflow it
        self.editing_text.w = math.max(40, d.w0 + dw)
        self:invalidateLayout()   -- width changed -> re-wrap (and auto-grow height)
        self:editTextLayout()     -- recompute now so op.h reflects the new wrap
        -- refresh the union of the old and new box (shrinking would otherwise
        -- leave the old, larger outline and text behind as ghost pixels)
        local new = self:textBoxScreenRect()
        local v = self.view
        local pad = TEXT_HANDLE + 4
        local x0 = math.max(v.area_x, math.min(old.x, new.x) - pad)
        local y0 = math.max(v.area_y, math.min(old.y, new.y) - pad)
        local x1 = math.min(v.area_x + v.area_w, math.max(old.x + old.w, new.x + new.w) + pad)
        local y1 = math.min(v.area_y + v.area_h, math.max(old.y + old.h, new.y + new.h) + pad)
        if x1 > x0 and y1 > y0 then
            UIManager:setDirty(self, "fast", GeomUI:new{ x = x0, y = y0, w = x1 - x0, h = y1 - y0 })
        end
    elseif d.kind == "select" then
        local r = self:textBoxScreenRect()
        local lay = self:editTextLayout()
        local cur = Text.hit(self.editing_text, lay, pos.x - r.x, pos.y - r.y,
            self:textCtx(self.editing_text, self.view.zoom))
        self.text_cur = cur
        self.text_sel = { a = d.anchor, b = cur }
        self:refreshTextBox("ui")
    end
    return true
end

function InkAwayView:textToolRelease(pos)
    if self:inKeyboard(pos) and not self._text_drag then return true end
    local d = self._text_drag
    self._text_drag = nil
    if not d then return true end
    if d.kind == "format" then
        -- open the format menu on release (not on touch) so the same tap can't be
        -- seen as an outside-tap on the just-shown menu, which would close it again
        self:openTextFormatMenu()
    elseif d.kind == "move" or d.kind == "resize" then
        -- re-align to the ruling once the drag ends (grid-snap boxes only); the
        -- small settle can leave A2 residue, so clear it with a flashing refresh
        if d.kind == "move" and self.editing_text and self.editing_text.grid_snap then
            self:snapTextBoxToGrid(self.editing_text)
            self:invalidateLayout()
            self:refreshTextBox("flashui")
        else
            self:refreshTextBox("ui")
        end
    elseif d.kind == "select" then
        if self.text_sel and Text.selEmpty(self.text_sel) then
            self.text_sel = nil
        elseif self:textHasSel() then
            self:openTextFormatMenu()   -- a real selection: offer the format menu
        end
    end
    return true
end

-- ---- overlay painting ----------------------------------------------------
function InkAwayView:paintTextOverlay(bb, x, y)
    local op = self.editing_text
    local lay, ctx = self:editTextLayout()
    local r = self:textBoxScreenRect()   -- area-relative screen rect
    local ox, oy = r.x + x, r.y + y      -- add the widget's paint origin
    local BLACKC = Blitbuffer.COLOR_BLACK
    -- selection highlight (behind the glyphs)
    if self.text_sel and not Text.selEmpty(self.text_sel) then
        local a, b = Text.orderSel(self.text_sel)
        for _, ln in ipairs(lay.lines) do
            local lo = (ln.para > a.p or (ln.para == a.p and ln.o_end >= a.o)) and true or false
            local hi = (ln.para < b.p or (ln.para == b.p and ln.o_start <= b.o)) and true or false
            if lo and hi and ln.para >= a.p and ln.para <= b.p then
                local xa = (ln.para == a.p) and math.max(ln.text_x, self:caretXHelper(ctx, ln, a)) or ln.text_x
                local xb = (ln.para == b.p) and self:caretXHelper(ctx, ln, b) or (ln.text_x + self:lineContentW(ln))
                if xb > xa then
                    bb:paintRect(math.floor(ox + xa), math.floor(oy + ln.top),
                        math.ceil(xb - xa), math.ceil(ln.height), Blitbuffer.COLOR_LIGHT_GRAY)
                end
            end
        end
    end
    -- the glyphs
    Text.render(op, lay, bb, ox, oy, ctx, { color = BLACKC })
    -- the frame
    local fx, fy, fw, fh = math.floor(ox), math.floor(oy), math.ceil(r.w), math.ceil(r.h)
    bb:paintRect(fx, fy, fw, 1, BLACKC); bb:paintRect(fx, fy + fh - 1, fw, 1, BLACKC)
    bb:paintRect(fx, fy, 1, fh, BLACKC); bb:paintRect(fx + fw - 1, fy, 1, fh, BLACKC)
    -- handles: move (top-left), resize (bottom-right)
    bb:paintRect(fx - 6, fy - 6, 12, 12, BLACKC)
    bb:paintRect(fx + fw - 6, fy + fh - 6, 12, 12, BLACKC)
    -- caret
    if not (self.text_sel and not Text.selEmpty(self.text_sel)) then
        local c = Text.caret(op, lay, self.text_cur, ctx)
        bb:paintRect(math.floor(ox + c.x), math.floor(oy + c.y), 2, math.ceil(c.h), BLACKC)
    end
    -- the always-visible Format and Done buttons (above the keyboard)
    local btns = self:textEditButtons()
    local function drawBtn(rr)
        local bx, by = rr.x + x, rr.y + y
        bb:paintRect(bx, by, rr.w, rr.h, Blitbuffer.COLOR_WHITE)
        bb:paintRect(bx, by, rr.w, 2, BLACKC); bb:paintRect(bx, by + rr.h - 2, rr.w, 2, BLACKC)
        bb:paintRect(bx, by, 2, rr.h, BLACKC); bb:paintRect(bx + rr.w - 2, by, 2, rr.h, BLACKC)
        local w = self:labelWidget(rr.label)
        local sz = w:getSize()
        w:paintTo(bb, math.floor(bx + (rr.w - sz.w) / 2), math.floor(by + (rr.h - sz.h) / 2))
        w:free()
    end
    drawBtn(btns.format)
    drawBtn(btns.done)
end

-- helpers used by the selection highlight above (ctx passed in to avoid
-- rebuilding the measuring context once per selected line)
function InkAwayView:caretXHelper(ctx, ln, cur)
    local x = ln.text_x
    for _, sg in ipairs(ln.segs) do
        local segEnd = sg.o0 + Text.ulen(sg.t)
        if cur.o >= segEnd then x = sg.x + sg.w
        elseif cur.o <= sg.o0 then return x
        else return sg.x + ctx.measure(Text.usub(sg.t, 0, cur.o - sg.o0), sg.style) end
    end
    return x
end

function InkAwayView:lineContentW(ln)
    local w = 0
    for _, sg in ipairs(ln.segs) do w = w + sg.w end
    return w
end

function InkAwayView:paintTo(bb, x, y)
    local v = self.view
    -- White background. The drawing area is repainted from area_bb below (which is
    -- already white where there is no ink), so painting the whole screen white here
    -- would just be overwritten -- clear only the strips OUTSIDE the area: the
    -- toolbar above and any notebook bar (or letterbox) below/around it.
    local ay0, ay1 = v.area_y, v.area_y + v.area_h
    local ax0, ax1 = v.area_x, v.area_x + v.area_w
    if ay0 > 0 then bb:paintRect(x, y, self.screen_w, ay0, WHITE) end
    if ay1 < self.screen_h then bb:paintRect(x, y + ay1, self.screen_w, self.screen_h - ay1, WHITE) end
    if ax0 > 0 then bb:paintRect(x, y + ay0, ax0, ay1 - ay0, WHITE) end
    if ax1 < self.screen_w then bb:paintRect(x + ax1, y + ay0, self.screen_w - ax1, ay1 - ay0, WHITE) end
    -- toolbar (each button paints its icon; the active tool's button paints a grey
    -- pill background), then the hairline under the bar -- unless collapsed for
    -- immersive drawing, when the paper fills the freed space
    if not self._toolbar_hidden then
        self:drawActiveToolPill(bb, x, y)   -- black pill behind the active tool
        self.toolbar:paintTo(bb, x, y)
        self:drawToolbarIcons(bb)
    end
    -- drawing area (the committed strokes, at the current zoom/pan). While a live
    -- stroke is drawing, only a small sub-rect of area_bb changed since the last
    -- paint (dirtyAreaRect accumulated it), so blit ONLY that region rather than the
    -- whole surface on every point -- the whole-area blit was a big per-point cost.
    -- Everything else here is cheap and stays unconditional so it never goes stale.
    local br = self.capturing and self._blit_rect
    if br then
        local rx0 = math.max(0, math.floor(br.x0)); local ry0 = math.max(0, math.floor(br.y0))
        local rx1 = math.min(v.area_w, math.ceil(br.x1)); local ry1 = math.min(v.area_h, math.ceil(br.y1))
        if rx1 > rx0 and ry1 > ry0 then
            bb:blitFrom(self.area_bb, x + v.area_x + rx0, y + v.area_y + ry0, rx0, ry0, rx1 - rx0, ry1 - ry0)
        end
    else
        bb:blitFrom(self.area_bb, x + v.area_x, y + v.area_y, 0, 0, v.area_w, v.area_h)
    end
    self._blit_rect = nil   -- consumed; default back to a full blit next paint
    -- grid guides on top, straight onto the screen buffer so they never mix into
    -- the drawing: the eraser can't rub them out and they stay out of the export
    -- the canvas grid overlay is a canvas-mode guide; a notebook has its own
    -- printed ruling, so never draw both (they would overlap)
    if self.grid_on and not self.notebook then self:drawGrid(bb, x + v.area_x, y + v.area_y) end
    -- Page edge indicator: only for edges that fall STRICTLY inside the drawing
    -- area (i.e. the reader has pinched out so the page is smaller than the
    -- screen). At the default fill-width zoom the page edges sit on the screen's
    -- own border, so nothing is drawn -- no frame, and the whole screen paints.
    local ax0, ay0 = x + v.area_x, y + v.area_y
    local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
    local fx0, fy0 = InkGeom.toScreen(v, 0, 0)
    local fx1, fy1 = InkGeom.toScreen(v, v.canvas_w, v.canvas_h)
    fx0, fy0 = math.floor(fx0 + x), math.floor(fy0 + y)
    fx1, fy1 = math.floor(fx1 + x), math.floor(fy1 + y)
    local top = math.max(fy0, ay0)
    local bot = math.min(fy1, ay1)
    if fx0 > ax0 and fx0 < ax1 and bot > top then bb:paintRect(fx0, top, 1, bot - top, FRAME) end
    if fx1 < ax1 and fx1 > ax0 and bot > top then bb:paintRect(fx1, top, 1, bot - top, FRAME) end
    local lft = math.max(fx0, ax0)
    local rgt = math.min(fx1, ax1)
    if fy0 > ay0 and fy0 < ay1 and rgt > lft then bb:paintRect(lft, fy0, rgt - lft, 1, FRAME) end
    if fy1 < ay1 and fy1 > ay0 and rgt > lft then bb:paintRect(lft, fy1, rgt - lft, 1, FRAME) end

    -- live shape preview drawn on top of the (untouched) drawing, clipped to
    -- the area so it never spills onto the toolbar
    if self.shape_preview then
        local sw = self.screen_w
        local cy0, cy1 = y + v.area_y, y + v.area_y + v.area_h
        local mirror = self.symmetry ~= "off"
        local axsx, axsy
        if mirror then
            axsx = v.area_x + (v.canvas_w / 2 - v.pan_x) * v.zoom
            axsy = v.area_y + (v.canvas_h / 2 - v.pan_y) * v.zoom
        end
        local function makePut(color)
            local put = function(px, py, len)
                py = py + y
                if py < cy0 or py >= cy1 then return end
                px = px + x
                if px < x then len = len + (px - x); px = x end
                if px + len > x + sw then len = x + sw - px end
                if len > 0 then bb:paintRect(px, py, len, 1, color) end
            end
            -- mirror the preview too, so a symmetric shape shows before it is placed
            if mirror then
                put = Symmetry.wrap(put, self.symmetry,
                    function(px, len) return 2 * axsx - px - len end,
                    function(py) return 2 * axsy - py end)
            end
            return put
        end
        local sp = self.shape_preview
        if sp.fill_color and not sp.fill then
            Shapes.fill(sp, makePut(displayColor(sp.fill_color, sp.fill_alpha)))
        end
        Shapes.render(sp, makePut(displayColor(sp.color, sp.alpha)))
    end

    -- export-area selection: dim the page and draw the chosen rectangle
    if self.selecting_crop and self._crop_screen then
        local c = self._crop_screen
        local cx0 = math.max(x + v.area_x, math.min(x + v.area_x + v.area_w, c.x0))
        local cy0 = math.max(y + v.area_y, math.min(y + v.area_y + v.area_h, c.y0))
        local cx1 = math.max(x + v.area_x, math.min(x + v.area_x + v.area_w, c.x1))
        local cy1 = math.max(y + v.area_y, math.min(y + v.area_y + v.area_h, c.y1))
        if cx1 < cx0 then cx0, cx1 = cx1, cx0 end
        if cy1 < cy0 then cy0, cy1 = cy1, cy0 end
        local BLACKC = Blitbuffer.COLOR_BLACK
        bb:paintRect(cx0, cy0, cx1 - cx0, 2, BLACKC)
        bb:paintRect(cx0, cy1 - 2, cx1 - cx0, 2, BLACKC)
        bb:paintRect(cx0, cy0, 2, cy1 - cy0, BLACKC)
        bb:paintRect(cx1 - 2, cy0, 2, cy1 - cy0, BLACKC)
    end

    -- lasso overlay: the loop being drawn, and the box around a live selection
    if self.lassoing or (self.selection and self.selection.bbox) then
        local BLACKC = Blitbuffer.COLOR_BLACK
        local ax0, ay0 = x + v.area_x, y + v.area_y
        local ax1, ay1 = ax0 + v.area_w, ay0 + v.area_h
        if self.lassoing and self.lasso_scr then
            local pts = self.lasso_scr
            local function dot(px, py)
                if px >= ax0 and px < ax1 - 3 and py >= ay0 and py < ay1 - 3 then
                    bb:paintRect(px, py, 3, 3, BLACKC)
                end
            end
            dot(pts[1], pts[2])
            for i = 3, #pts, 2 do           -- draw each segment as a connected line
                local x0s, y0s = pts[i - 2], pts[i - 1]
                local dxs, dys = pts[i] - x0s, pts[i + 1] - y0s
                local steps = math.max(1, math.floor(math.max(math.abs(dxs), math.abs(dys)) / 3))
                for s = 1, steps do
                    dot(math.floor(x0s + dxs * s / steps), math.floor(y0s + dys * s / steps))
                end
            end
        end
        if self.selection and self.selection.bbox then
            local b = self.selection.bbox
            local odx = (self.sel_press and self.sel_press.dx) or 0
            local ody = (self.sel_press and self.sel_press.dy) or 0
            local s0x, s0y = InkGeom.toScreen(v, b.x0, b.y0)
            local s1x, s1y = InkGeom.toScreen(v, b.x1, b.y1)
            local bx0 = math.max(ax0, math.min(ax1, x + s0x + odx))
            local by0 = math.max(ay0, math.min(ay1, y + s0y + ody))
            local bx1 = math.max(ax0, math.min(ax1, x + s1x + odx))
            local by1 = math.max(ay0, math.min(ay1, y + s1y + ody))
            if bx1 > bx0 and by1 > by0 then
                bb:paintRect(bx0, by0, bx1 - bx0, 2, BLACKC)
                bb:paintRect(bx0, by1 - 2, bx1 - bx0, 2, BLACKC)
                bb:paintRect(bx0, by0, 2, by1 - by0, BLACKC)
                bb:paintRect(bx1 - 2, by0, 2, by1 - by0, BLACKC)
            end
        end
    end

    -- text box being edited: live glyphs, its frame, caret and any selection
    if self.editing_text then self:paintTextOverlay(bb, x, y) end

    -- image selected: its live overlay, frame, corner handles and Delete/Done pills
    if self.active_image then self:paintImageOverlay(bb, x, y) end

    -- notebook page-nav strip along the bottom (only in notebook mode). Styled to
    -- match the top toolbar exactly: same bar height, the same icon size, and real
    -- icon glyphs (not ad-hoc chevrons) so the two bars read as one consistent UI.
    if self.notebook and self.nb_bar_h > 0 then
        local Font = require("ui/font")
        local TextWidget = require("ui/widget/textwidget")
        local nb = self.notebook
        local h = self.nb_bar_h
        local w = self.screen_w
        local sy0 = y + v.area_y + v.area_h
        local cy = sy0 + math.floor(h / 2)
        local BLACKC = Blitbuffer.COLOR_BLACK
        bb:paintRect(x, sy0, w, h, WHITE)
        bb:paintRect(x, sy0, w, 1, FRAME)   -- divider above the strip
        local isz = self._icon_sz or math.max(20, math.floor(h * 0.66))
        -- blit one nav icon (isz x isz, exactly a toolbar icon) centred at cx
        local function icon(name, cx)
            local im = self:navImage(name, isz)
            if not im then return end
            local iw, ih = im:getWidth(), im:getHeight()
            bb:blitFrom(im, math.floor(cx - iw / 2), math.floor(cy - ih / 2), 0, 0, iw, ih)
        end
        local pad = math.floor(isz * 0.4)              -- comfort padding around each tap zone
        local zone = isz + 2 * pad
        -- Prev (far left) and Next (far right), icon-sized like the toolbar
        local prev_cx = x + math.floor(zone / 2)
        local next_cx = x + w - math.floor(zone / 2)
        icon("nav_prev", prev_cx)
        icon("nav_next", next_cx)
        self._nb_prev = { x = math.floor(prev_cx - zone / 2), y = sy0, w = zone, h = h }
        self._nb_next = { x = math.floor(next_cx - zone / 2), y = sy0, w = zone, h = h }
        -- Page counter, dead centre: "index / count", with a hand-drawn slash (the
        -- font's own "/" is noticeably taller than the digits). Every element in the
        -- bar must share the same top and bottom. faceAt renders at an exact pixel
        -- size (dividing out the DPI factor Font:getFace would re-apply), so the digit
        -- size is identical on Kindle, colour Kobo and Android; ~0.95*isz matches the
        -- visible icon-glyph height. A TextWidget's box has empty ascent/descent, so
        -- box-centring makes the number sit high -- we MEASURE the digits' real ink
        -- extent (cached per size) and centre THAT on cy, and size the slash to it, so
        -- the number lines up with the icons instead of floating above them.
        local face = self:faceAt("cfont", math.max(10, math.floor(isz * 0.95)))
        local idxw = TextWidget:new{ text = tostring(nb.index), face = face, fgcolor = BLACKC }
        local cntw = TextWidget:new{ text = tostring(nb:count()), face = face, fgcolor = BLACKC }
        local iw, ih = idxw:getSize().w, idxw:getSize().h
        local ink = self:digitInkMetric(face, isz, ih)
        local ty = math.floor(cy - ink.mid)                -- centre the digit INK on cy
        local slh = ink.h                                  -- slash spans the digit ink height
        local cw = cntw:getSize().w
        local slw = math.max(2, math.floor(slh * 0.42))    -- slash horizontal span
        local stk = math.max(2, math.floor(isz * 0.09))    -- slash thickness
        local g = math.floor(isz * 0.30)
        local counter_w = iw + g + slw + g + cw
        local x0 = math.floor(x + w / 2 - counter_w / 2)
        idxw:paintTo(bb, x0, ty); idxw:free()
        local sx = x0 + iw + g
        do  -- diagonal slash, bottom-left to top-right, centred on cy
            local steps = math.max(slw, slh)
            for i = 0, steps do
                local t = i / steps
                bb:paintRect(math.floor(sx + t * slw) - math.floor(stk / 2),
                    math.floor(cy + slh / 2 - t * slh) - math.floor(stk / 2), stk, stk, BLACKC)
            end
        end
        cntw:paintTo(bb, sx + slw + g, ty); cntw:free()
        -- add-page icon, just right of the counter, same icon size, clamped clear of Next
        local margin = math.floor(isz * 0.5)
        local icx = math.floor(x + w / 2 + counter_w / 2 + margin + isz / 2)
        local max_icx = (next_cx - math.floor(zone / 2)) - margin - math.floor(isz / 2)
        if icx > max_icx then icx = max_icx end
        icon("newpage", icx)
        self._nb_plus = { x = math.floor(icx - zone / 2), y = sy0, w = zone, h = h }
        -- the counter is its own tap target (opens the page menu), spanning the
        -- clear gap between the Prev zone and the add-page icon so nothing overlaps
        local count_x = self._nb_prev.x + self._nb_prev.w
        self._nb_count = { x = count_x, y = sy0, w = math.max(1, self._nb_plus.x - count_x), h = h }
    end

    -- the floating immersive controls (zoom pill + toolbar toggle), on top
    self:drawFabs(bb, x, y)
end

-- A nav-strip icon rendered from ink/icons onto an opaque white tile (the strip
-- is white), cached by name+size, freed in free(). Returns nil if unavailable.
function InkAwayView:navImage(name, sz)
    self._nav_img = self._nav_img or {}
    local key = name .. "@" .. sz
    local c = self._nav_img[key]
    if c == nil then
        local ok, raw, straight = pcall(function()
            local RenderImage = require("ui/renderimage")
            return RenderImage:renderSVGImageFile(self:pluginDir() .. "ink/icons/" .. name .. ".svg", sz, sz)
        end)
        if ok and raw then
            local w, h = raw:getWidth(), raw:getHeight()
            local tile = Blitbuffer.new(w, h, Blitbuffer.TYPE_BBRGB32)
            tile:fill(Blitbuffer.COLOR_WHITE)
            if straight then tile:alphablitFrom(raw, 0, 0, 0, 0, w, h)
            else tile:pmulalphablitFrom(raw, 0, 0, 0, 0, w, h) end
            raw:free()
            c = tile
        else
            c = false
        end
        self._nav_img[key] = c
    end
    return c or nil
end

------------------------------------------------------------------------------
-- Save workflow: format -> destination folder -> filename -> encode
------------------------------------------------------------------------------

-- One compact dialog for the whole save: pick the format, optionally the area,
-- and (when a background is loaded) whether to include it, then Save. The rows
-- are toggles so it never turns into a wizard.
function InkAwayView:onSave()
    self:flushPending()
    if self.active_image then self:finishImageEdit() end   -- bake it so the export includes it
    if self.notebook then return self:exportNotebookPDF() end
    if self.canvas:isEmpty() and not self.bg_bb then
        UIManager:show(InfoMessage:new{ text = _("The canvas is empty."), timeout = 2 })
        return
    end
    self.save_fmt = self.save_fmt or "png"
    if self._save_dialog then UIManager:close(self._save_dialog); self._save_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    self:ensureUserIcons()
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local halfW = math.floor((content_w - gap) / 2)
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._save_dialog then UIManager:close(self._save_dialog); self._save_dialog = nil end
    end
    local area_label = self.save_area
        and string.format(_("Area: %d\u{00D7}%d (tap for whole page)"), self.save_area.w, self.save_area.h)
        or _("Area: whole page (tap to choose)")
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Save drawing"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(TextWidget:new{ text = _("Format"), face = Font:getFace("cfont", 15), bold = true,
            fgcolor = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF) })
        add(vspan(6))
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("PNG (transparent)"), halfW, function()
                self.save_fmt = "png"; self:onSave() end, self.save_fmt == "png"),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("JPEG (white)"), halfW, function()
                self.save_fmt = "jpg"; self:onSave() end, self.save_fmt == "jpg") })
        add(vspan(12))
        add(self:actionButton(area_label, content_w, function()
            if self.save_area then self.save_area = nil; self:onSave()
            else closeSelf(); self:beginCropSelect() end
        end))
        if self.bg_bb then
            add(vspan(12))
            add(ToggleRow:new{ label = _("Include background"), is_on = self.export_bg,
                width = content_w, parent = menu,
                callback = function(on) self.export_bg = on end })
        end
        add(vspan(16))
        add(self:actionButton(_("Save"), content_w, function()
            closeSelf(); self:chooseDestination(self.save_fmt) end, true))
        -- One-tap save straight into the bookshelf plugin's ornament folder, only
        -- when that plugin is in use. Always a transparent PNG (an ornament needs
        -- its transparency), so it ignores the format toggle above.
        if self:ornamentsDir() then
            add(vspan(10))
            add(self:actionButton(_("Save as bookshelf ornament"), content_w, function()
                closeSelf(); self:saveOrnament() end))
        end
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._save_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._save_dialog = nil end }
    UIManager:show(self._save_dialog)
end

-- Enter the area-selection mode: the next drag marks the export rectangle.
function InkAwayView:beginCropSelect()
    self.selecting_crop = true
    self._crop_screen = nil
    UIManager:show(InfoMessage:new{
        text = _("Drag a box around the part to export. A single tap keeps the whole page."), timeout = 3 })
    UIManager:setDirty(self, "ui", self:areaScreenRect())
end

-- Set up koreader/ink away/{drawings,projects} once and remember both paths:
-- drawings holds the exported PNG/JPEG images, projects holds the editable
-- .inkaway files. Returns the drawings path (the image default), or a fallback.
-- Also tidies away the old flat "ink away drawings" folder from earlier
-- versions, but only if it is empty, so nothing you saved there is ever removed.
-- Four clearly separated folders under "ink away/": drawings (PNG/JPEG images),
-- drawing projects (editable .inkaway canvases), notebooks (exported PDFs), and
-- notebook projects (editable .inkaway notebooks). Returns the images path.
function InkAwayView:ensureDefaultDir()
    local ok, DataStorage = pcall(require, "datastorage")
    local base = (ok and DataStorage and DataStorage:getDataDir()) or "/"
    local parent    = base .. "/ink away"
    local drawings  = parent .. "/drawings"
    local dproj     = parent .. "/drawing projects"
    local notebooks = parent .. "/notebooks"
    local nproj     = parent .. "/notebook projects"
    self.dproj_dir, self.nproj_dir, self.notebooks_dir = base, base, base
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lok and lfs then
        local function mk(d)
            if lfs.attributes(d, "mode") ~= "directory" then pcall(lfs.mkdir, d) end
            return lfs.attributes(d, "mode") == "directory"
        end
        mk(parent); mk(drawings)
        if mk(dproj) then self.dproj_dir = dproj end
        if mk(nproj) then self.nproj_dir = nproj end
        if mk(notebooks) then self.notebooks_dir = notebooks end
        -- remove the very old flat folder if it is now empty (never if it holds files)
        local oldflat = base .. "/ink away drawings"
        if lfs.attributes(oldflat, "mode") == "directory" then pcall(lfs.rmdir, oldflat) end
        if self:getSetting("inkaway_last_dir") == oldflat then self:setSetting("inkaway_last_dir", drawings) end
        -- One-time: sort the old mixed "projects/" folder into the two new ones.
        -- Deferred to the next tick so opening the plugin is never blocked by it.
        if not self:getSetting("inkaway_folders_v2") then
            UIManager:nextTick(function() self:migrateProjectFolders(parent) end)
        end
        if lfs.attributes(drawings, "mode") == "directory" then return drawings end
    end
    return base
end

-- Move each .inkaway in the old "projects/" folder into "drawing projects/" or
-- "notebook projects/" by type. Non-destructive: os.rename (atomic on the same
-- drive, never deletes), everything pcall-guarded, unreadable files left alone,
-- and it runs off the open path so there is no startup slowdown. Runs once.
function InkAwayView:migrateProjectFolders(parent)
    if self:getSetting("inkaway_folders_v2") then return end
    self:setSetting("inkaway_folders_v2", true)   -- set first, so a fault never re-runs it
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (lok and lfs) then return end
    local old = parent .. "/projects"
    if lfs.attributes(old, "mode") ~= "directory" then return end
    local dproj, nproj = parent .. "/drawing projects", parent .. "/notebook projects"
    local moved = 0
    pcall(function()
        for entry in lfs.dir(old) do
            if entry ~= "." and entry ~= ".." and entry:lower():match("%.inkaway$") then
                local src = old .. "/" .. entry
                if lfs.attributes(src, "mode") == "file" then
                    -- classify cheaply: a notebook (v2) carries a "pages" key; a
                    -- drawing (v1) does not. Read a bounded head so a huge file
                    -- can never stall this. Default to drawing (v1.4 had only those).
                    local dest_dir = dproj
                    local f = io.open(src, "rb")
                    if f then
                        local head = f:read(256 * 1024) or ""
                        f:close()
                        if head:find('"pages"', 1, true) then dest_dir = nproj end
                    end
                    local dest = dest_dir .. "/" .. entry
                    if lfs.attributes(dest, "mode") then    -- never clobber a same-named file
                        local stem = entry:gsub("%.[^.]+$", "")
                        local i = 1
                        repeat
                            dest = dest_dir .. "/" .. stem .. "-" .. i .. "." .. Project.EXT
                            i = i + 1
                        until not lfs.attributes(dest, "mode")
                    end
                    if os.rename(src, dest) then moved = moved + 1 end
                end
            end
        end
    end)
    pcall(function() lfs.rmdir(old) end)   -- succeeds only if it is now empty
    if moved > 0 then
        UIManager:show(InfoMessage:new{ timeout = 5, text = string.format(
            _("Ink Away tidied your saved work:\n%d project(s) sorted into 'drawing projects' and 'notebook projects'."),
            moved) })
    end
end

-- Return `p` if it is an existing directory, else nil.
local function existingDir(p)
    if not p then return nil end
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (lok and lfs) or lfs.attributes(p, "mode") == "directory" then return p end
    return nil
end

-- Where the image save dialog starts: last image folder used, else drawings.
function InkAwayView:defaultDir()
    return existingDir(self:getSetting("inkaway_last_dir")) or self.default_dir or "/"
end

-- Where the project open/save dialogs start: the folder for the current kind of
-- project (drawing vs notebook), last-used location remembered separately for
-- each so the two never get mixed up again.
function InkAwayView:projectDirKey()
    return self.notebook and "inkaway_last_nproj_dir" or "inkaway_last_dproj_dir"
end

function InkAwayView:projectDir()
    local def = self.notebook and self.nproj_dir or self.dproj_dir
    return existingDir(self:getSetting(self:projectDirKey())) or def or self.default_dir or "/"
end

-- Remember the last image folder used, for next time.
function InkAwayView:rememberDir(dir)
    last_save_dir = dir
    self:setSetting("inkaway_last_dir", dir)
end

-- Remember the last project folder used (per project kind), for next time.
function InkAwayView:rememberProjectDir(dir)
    self:setSetting(self:projectDirKey(), dir)
end

------------------------------------------------------------------------------
-- Notebook mode: a fixed-size, multi-page canvas. Each page is an ops list,
-- exactly like the single drawing, so every tool works unchanged. The current
-- page stays loaded in self.canvas; navigation syncs it back to the page model
-- (Notebook) and loads the next one, so only one page is ever composed at once.
------------------------------------------------------------------------------

-- Height of the bottom page-nav strip in notebook mode.
function InkAwayView:nbBarHeight()
    if self._nb_collapsed then return 0 end   -- hidden via the bottom-bar toggle
    -- Snug around the icon row (the icon size + a little padding) so the bar is only
    -- as tall as it needs to be -- shorter than the top toolbar, freeing screen space.
    local isz = self._icon_sz or math.max(20, Screen:scaleBySize(26))
    return isz + 2 * Screen:scaleBySize(4)
end

-- Recompute the drawing area (it shrinks by nb_bar_h in notebook mode) and the
-- fit zoom, then reallocate the on-screen buffer to the new height.
function InkAwayView:recomputeArea()
    local v = self.view
    local th = self.toolbar:getSize().h
    v.area_y = th
    v.area_h = self.screen_h - th - self.nb_bar_h
    if self.area_bb then self.area_bb:free() end
    self.area_bb = Blitbuffer.new(v.area_w, v.area_h, Screen.bb:getType())
    self.zoom_min = InkGeom.fitZoom(v)
    -- fill the full width (no side letterbox), exactly like a flat canvas; this is
    -- what keeps notebooks as wide as the device instead of fit-to-page centred
    v.zoom = math.max(self.zoom_min, v.area_w / v.canvas_w)
    InkGeom.clampPan(v)
end

-- Save the on-screen canvas back into the current notebook page.
function InkAwayView:nbSyncOut()
    if self.notebook then self.notebook:setCurrentOps(self.canvas.ops) end
end

-- Load the current notebook page into the canvas and repaint.
function InkAwayView:nbLoad()
    if not self.notebook then return end
    -- Drop the previous page's placed-image decode caches (`_img_*`): only the
    -- visible page's images need to be resident, and composeCanvas below re-decodes
    -- whatever this page uses. Without this, every page with pictures leaves its
    -- full-size decodes behind, so memory climbs across a long multi-page session.
    -- (`_nav_img` is the tiny nav-bar icon cache, not per-page, so it is untouched.)
    self:freeImageCache()
    self:loadNotebookPageBackground()   -- swap in this page's PDF image (if any)
    self.canvas:setOps(self.notebook:currentOps())
    self.selected, self.rotating = nil, nil
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self:composeCanvas(); self:renderView()
    -- A page turn must not fire a full-screen colour FLASH every time: on a Kaleido
    -- panel that costs ~1-2s even for a blank page. On colour, use a non-flashing
    -- partial refresh and only flash occasionally to clear accumulated ghosting; on
    -- grey e-ink this stays a plain full refresh, exactly as before.
    if self:colourPanel() then
        self._turns_since_full = (self._turns_since_full or 0) + 1
        local every = (self.ghost_clean and self.ghost_clean > 0) and self.ghost_clean or 8
        if self._turns_since_full >= every then
            self._turns_since_full = 0
            UIManager:setDirty(self, "full")
        else
            self:refresh(self, "full")   -- -> non-flashing "ui" on colour
        end
    else
        UIManager:setDirty(self, "full")
    end
end

-- Keep one open handle to the source PDF for the whole session, so page turns
-- render straight away (KOReader caches the rendered pages) instead of paying
-- the open cost each time.
function InkAwayView:ensureNotebookPDF()
    local t = self.notebook and self.notebook.template
    if not (t and t.pdf_path) then return end
    if self._nb_pdf_doc and self._nb_pdf_path == t.pdf_path then return end
    self:closeNotebookPDF()
    local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(t.pdf_path) end)
    self._nb_pdf_doc = ok and doc or nil
    self._nb_pdf_path = t.pdf_path
end

function InkAwayView:closeNotebookPDF()
    if self._nb_pdf_doc then pcall(function() self._nb_pdf_doc:close() end) end
    self._nb_pdf_doc, self._nb_pdf_path = nil, nil
end

-- For a PDF-backed notebook, put the current page's rendered PDF image behind
-- the ink. Only the visible page is ever rendered or resident, so opening the
-- PDF and turning pages stay fast no matter how many pages it has.
function InkAwayView:loadNotebookPageBackground()
    local nb = self.notebook
    local t = nb and nb.template
    if not (t and t.pdf_path) then return end
    self:ensureNotebookPDF()
    local src = nb:currentSrc()      -- which source page this notebook page shows
    local img = src and self:renderPdfPage(self._nb_pdf_doc, src) or nil
    if self.bg_bb then self.bg_bb:free() end
    self.bg_bb = img            -- canvas-sized already; nil if the render failed
    self.bg_rgba = nil          -- built on demand at export, never per page turn
    self.bg_path = t.pdf_path
    self.export_bg = true
end

-- Step to another page (delta -1/+1). Syncs the current page out first.
function InkAwayView:nbGo(delta)
    if not self.notebook then return end
    if self.active_image then self:finishImageEdit() end   -- bake it onto this page first
    local nb = self.notebook
    local target = nb.index + delta
    if target < 1 or target > nb:count() then return end
    self:nbSyncOut()
    nb:gotoPage(target)
    self:nbLoad()
    self.dirty = true
end

-- Jump to an absolute page number (1-based).
function InkAwayView:nbGoTo(target)
    if not self.notebook or type(target) ~= "number" then return end
    if self.active_image then self:finishImageEdit() end   -- bake it onto this page first
    target = math.floor(target)
    local nb = self.notebook
    if target < 1 or target > nb:count() or target == nb.index then return end
    self:nbSyncOut()
    nb:gotoPage(target)
    self:nbLoad()
    self.dirty = true
end

-- Go to a page: a new-style sheet with quick First/Last jumps and a "type a
-- number" button that opens the stock number keypad (kept as a stock InputDialog,
-- the device-safe way to type -- the sheet gives the chrome, the keypad the entry).
function InkAwayView:nbJumpPrompt()
    local nb = self.notebook
    if not nb then return end
    if self._goto_dialog then UIManager:close(self._goto_dialog); self._goto_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local halfW = math.floor((content_w - gap) / 2)
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._goto_dialog then UIManager:close(self._goto_dialog); self._goto_dialog = nil end
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Go to page"), content_w, _("Close"), closeSelf))
        add(vspan(6))
        add(TextWidget:new{ text = string.format(_("Page %d of %d"), nb.index, nb:count()),
            face = Font:getFace("cfont", 15), fgcolor = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF) })
        add(vspan(12))
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("First page"), halfW, function() closeSelf(); self:nbGoTo(1) end),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("Last page"), halfW, function() closeSelf(); self:nbGoTo(nb:count()) end),
        })
        add(vspan(8))
        add(self:actionButton(_("Type a page number\u{2026}"), content_w,
            function() closeSelf(); self:promptGotoNumber() end, true))
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    local v = self.view
    self._goto_dialog = IconMenu:new{ build = build, bottom_y = v.area_y + v.area_h,
        on_close = function() self._goto_dialog = nil end }
    UIManager:show(self._goto_dialog)
end

-- The actual page-number entry, reached from the Go-to-page sheet. A stock
-- InputDialog with the number keypad -- the proven, device-safe way to type.
function InkAwayView:promptGotoNumber()
    local nb = self.notebook
    if not nb then return end
    local InputDialog = require("ui/widget/inputdialog")
    local d
    d = InputDialog:new{
        title = string.format(_("Go to page (1\u{2013}%d)"), nb:count()),
        input = tostring(nb.index),
        input_type = "number",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(d) end },
            { text = _("Go"), is_enter_default = true, callback = function()
                local n = tonumber(d:getInputText())
                UIManager:close(d)
                if n then self:nbGoTo(n) end
            end },
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

-- Duplicate / reorder the current page.
function InkAwayView:nbDuplicatePage()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:duplicatePage()
    self:nbLoad()
    self.dirty = true
end

function InkAwayView:nbMovePage(dir)
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:movePage(dir)
    self:nbLoad()
    self.dirty = true
end

-- The page menu, opened by tapping the page counter in the nav strip: jump,
-- overview, duplicate, reorder, delete -- everything about pages in one place.
function InkAwayView:openPageMenu()
    local nb = self.notebook
    if not nb then return end
    if self._page_dialog then UIManager:close(self._page_dialog); self._page_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._page_dialog then UIManager:close(self._page_dialog); self._page_dialog = nil end
    end
    local function act(label, cb)
        return self:actionButton(label, content_w, function() closeSelf(); cb() end)
    end
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Page"), content_w, _("Close"), closeSelf))
        add(vspan(6))
        add(TextWidget:new{ text = string.format(_("Page %d of %d"), nb.index, nb:count()),
            face = Font:getFace("cfont", 15), fgcolor = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF) })
        add(vspan(12))
        add(act(_("Go to page\u{2026}"), function() self:nbJumpPrompt() end))
        add(vspan(8))
        add(act(_("Page overview\u{2026}"), function() self:openPageGrid() end))
        add(vspan(8))
        add(act(_("Duplicate page"), function() self:nbDuplicatePage() end))
        add(vspan(8))
        add(act(_("Delete page"), function() self:nbDeletePage() end))
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    -- Move earlier / later are omitted: the bottom bar's arrows already do that. The
    -- sheet's bottom is pinned to the top of the notebook bottom bar (bottom_y).
    local v = self.view
    self._page_dialog = IconMenu:new{ build = build,
        bottom_y = v.area_y + v.area_h,
        on_close = function() self._page_dialog = nil end }
    UIManager:show(self._page_dialog)
end

-- Render one notebook page to a small thumbnail bitmap fitting maxw x maxh,
-- through the shared compositor so it matches the page exactly. A full-size
-- scratch is composed then scaled down and freed, so memory stays flat.
function InkAwayView:renderPageThumb(index, maxw, maxh)
    local nb = self.notebook
    if not nb or not nb.pages[index] then return nil end
    local W, H = self.view.canvas_w, self.view.canvas_h
    local bbtype = self.canvas_bb and self.canvas_bb:getType() or Screen.bb:getType()
    local scratch = Blitbuffer.new(W, H, bbtype)
    local page = nb.pages[index]
    local bg
    if nb.template.pdf_path and page.src then
        self:ensureNotebookPDF()
        bg = self:renderPdfPage(self._nb_pdf_doc, page.src)
    end
    self:composeInto(scratch, page.ops, bg, nb.template)
    if bg then bg:free() end
    local scale = math.min(maxw / W, maxh / H)
    local tw = math.max(1, math.floor(W * scale))
    local th = math.max(1, math.floor(H * scale))
    local thumb = RenderImage:scaleBlitBuffer(scratch, tw, th, false)
    scratch:free()
    return thumb
end

-- The page overview grid: tap a thumbnail to jump to that page.
function InkAwayView:openPageGrid()
    local nb = self.notebook
    if not nb then return end
    self:nbSyncOut()      -- so the current page's latest ink is in its thumbnail
    local PageGrid = require("ink/pagegrid")
    local grid = PageGrid:new{
        count = nb:count(),
        current = nb.index,
        render = function(i, w, h) return self:renderPageThumb(i, w, h) end,
        on_pick = function(i) self:nbGoTo(i) end,
    }
    self._settings_dialog = grid
    UIManager:show(grid)
end

-- Insert a blank page after the current one and move to it.
function InkAwayView:nbAddPage()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:addPage()
    self:nbLoad()
    self.dirty = true
end

-- Remove the current page (with a confirm; never drops below one page).
function InkAwayView:nbDeletePage()
    if not self.notebook then return end
    if self.notebook:count() <= 1 then
        UIManager:show(InfoMessage:new{ text = _("A notebook keeps at least one page."), timeout = 2 })
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Delete this page?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self.notebook:deletePage()
            self:nbLoad()
            self.dirty = true
        end,
    })
end

-- Enter notebook mode with a fresh notebook using `template`
-- ({ style = "lines"|"grid"|"dots"|"blank", size = px }).
function InkAwayView:startNotebook(template)
    self:clearBackground()
    self.save_area = nil
    self.notebook = Notebook.new(self.screen_w, self.screen_h, template)
    self.nb_bar_h = self:nbBarHeight()
    self:recomputeArea()
    self:nbLoad()
    self.dirty = false
    self:resetTransientMemory()     -- reclaim the previous work's memory now
    -- persist the fresh notebook straight away so a close before the next
    -- autosave tick still brings it back as a notebook, not the old drawing
    if self.autosave ~= "off" then self:saveSession() end
end

-- Rebuild notebook mode from a loaded v2 project.
function InkAwayView:openNotebookData(data)
    self:closeNotebookPDF()
    self:clearBackground()
    self.save_area = nil
    self.notebook = Notebook.fromData(data)
    -- pages were drawn at their own screen size; treat them at this screen size
    self.notebook.w, self.notebook.h = self.screen_w, self.screen_h
    self.nb_bar_h = self:nbBarHeight()
    self:recomputeArea()
    self:nbLoad()
    self.dirty = false
    self:resetTransientMemory()     -- reclaim the previous work's memory now
    -- warn clearly if this was a PDF-backed notebook but the source PDF is gone
    -- (the ink is safe; only the page images are missing until it is restored)
    if self.notebook.template.pdf_path and not self._nb_pdf_doc then
        UIManager:show(InfoMessage:new{ text = string.format(
            _("The source PDF could not be opened:\n%s\n\nYour notes are intact, but the page images will be blank until the PDF is back in that location."),
            self.notebook.template.pdf_path) })
    end
end

-- Leave notebook mode and return to the single-canvas layout.
function InkAwayView:exitNotebook()
    if not self.notebook then return end
    self:closeNotebookPDF()
    self.notebook = nil
    self.nb_bar_h = 0
    self:recomputeArea()
end

-- Open an entire PDF as a notebook: one page per PDF page, each with the PDF
-- page as its background to write on. Pages are rendered lazily on demand.
function InkAwayView:startPdfNotebook(path)
    local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(path) end)
    if not ok or not doc then
        UIManager:show(InfoMessage:new{ text = _("Could not open that PDF.") })
        return
    end
    local pages = 1
    pcall(function() pages = doc:getPageCount() or 1 end)
    if not pages or pages < 1 then pages = 1 end
    self:closeNotebookPDF()
    self._nb_pdf_doc, self._nb_pdf_path = doc, path
    self:clearBackground()
    self.save_area = nil
    self.notebook = Notebook.new(self.screen_w, self.screen_h, {
        style = "blank", size = self.grid_size or 40, strength = self.grid_strength or 45, pdf_path = path,
    })
    local list = {}
    for i = 1, pages do list[i] = { ops = {}, src = i } end   -- one ink layer per PDF page
    self.notebook.pages = list
    self.notebook.index = 1
    self.nb_bar_h = self:nbBarHeight()
    self:recomputeArea()
    self:nbLoad()
    self.dirty = false
    self:resetTransientMemory()     -- reclaim the previous work's memory now
    if self.autosave ~= "off" then self:saveSession() end
end

-- Pick a PDF and open it as a notebook (confirming first if there is work open).
function InkAwayView:openPdfAsNotebook()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:defaultDir(),
        onConfirm = function(path)
            if not path:lower():match("%.pdf$") then
                UIManager:show(InfoMessage:new{ text = _("Please choose a PDF file.") })
                return
            end
            local function go() self:startPdfNotebook(path) end
            if self.notebook or not self.canvas:isEmpty() then
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Open this PDF as a notebook? The current work will be cleared."),
                    ok_text = _("Open"), ok_callback = go,
                })
            else
                go()
            end
        end,
    })
end

-- Remove any loaded background image (used when switching into notebook mode).
function InkAwayView:clearBackground()
    if self.bg_bb then pcall(function() self.bg_bb:free() end) end
    self.bg_bb, self.bg_rgba, self.bg_path = nil, nil, nil
    self.export_bg = true
end

-- Start a new notebook: ask which ruling to use, then enter notebook mode.
function InkAwayView:newNotebook()
    local function begin(style)
        self.notebook_template_style = style
        self.nb_style = style
        self:setSetting("inkaway_nb_style", style)
        -- start from the ruling the user last set on a notebook (falling back to
        -- the drawing-grid spacing/strength), so a new notebook matches the last one
        self:startNotebook({ style = style,
            size = self.nb_size or self.grid_size or 40,
            strength = self.nb_strength or self.grid_strength or 45 })
    end
    local function go(style)
        if self.notebook or not self.canvas:isEmpty() then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Start a new notebook? The current work will be cleared."),
                ok_text = _("New"), ok_callback = function() begin(style) end,
            })
        else
            begin(style)
        end
    end
    if self._chooser_dialog then UIManager:close(self._chooser_dialog); self._chooser_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local closeSelf = function()
        if self._chooser_dialog then UIManager:close(self._chooser_dialog); self._chooser_dialog = nil end
    end
    local styles = { { "lines", _("Lined") }, { "grid", _("Grid") }, { "dots", _("Dotted") },
        { "margin", _("Margin ruled") }, { "cornell", _("Cornell") }, { "blank", _("Blank") } }
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("New notebook"), content_w, _("Cancel"), closeSelf))
        add(vspan(10))
        for i, s in ipairs(styles) do
            add(self:actionButton(s[2], content_w, function() closeSelf(); go(s[1]) end))
            if i < #styles then add(vspan(8)) end
        end
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._chooser_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._chooser_dialog = nil end }
    UIManager:show(self._chooser_dialog)
end

-- The notebook page indices chosen by the current export scope: all pages,
-- only pages that have ink, or a page range.
function InkAwayView:selectedNotebookPages()
    local nb = self.notebook
    local sel = {}
    if self.nb_scope == "ink" then
        for i = 1, nb:count() do
            if nb.pages[i].ops and #nb.pages[i].ops > 0 then sel[#sel + 1] = i end
        end
    elseif self.nb_scope == "range" and self.nb_range then
        local a = math.max(1, math.min(nb:count(), self.nb_range.from or 1))
        local b = math.max(a, math.min(nb:count(), self.nb_range.to or nb:count()))
        for i = a, b do sel[#sel + 1] = i end
    else
        for i = 1, nb:count() do sel[#sel + 1] = i end
    end
    return sel
end

-- Export the notebook to a single PDF, with paper colour, page-scope, page
-- numbers and (for imported PDFs) a sharp-text option, then offer to open it.
function InkAwayView:exportNotebookPDF()
    self:nbSyncOut()
    local nb = self.notebook
    local is_pdf = nb.template and nb.template.pdf_path
    self.nb_paper = self.nb_paper or "white"
    self.nb_scope = self.nb_scope or "all"
    if self._save_dialog then UIManager:close(self._save_dialog); self._save_dialog = nil end
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local TextWidget = require("ui/widget/textwidget")
    local Font = require("ui/font")
    local gap = Screen:scaleBySize(12)
    local target = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    local content_w = 4 * math.floor((target - 3 * gap) / 4) + 3 * gap
    local halfW = math.floor((content_w - gap) / 2)
    local vspan = function(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end
    local GREY = Blitbuffer.ColorRGB32(0x66, 0x66, 0x66, 0xFF)
    local SCOPE_LABEL = { all = _("All pages"), ink = _("Pages with ink"), range = _("Range") }
    local closeSelf = function()
        if self._save_dialog then UIManager:close(self._save_dialog); self._save_dialog = nil end
    end
    local reopen = function() self:exportNotebookPDF() end   -- rebuild after a choice changes the layout
    local build = function(menu)
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Export notebook"), content_w, _("Cancel"), closeSelf))
        add(vspan(16))
        add(TextWidget:new{ text = _("Paper"), face = Font:getFace("cfont", 15), bold = true, fgcolor = GREY })
        add(vspan(6))
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("White"), halfW, function() self.nb_paper = "white"; reopen() end, self.nb_paper == "white"),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("Sandpaper"), halfW, function() self.nb_paper = "sand"; reopen() end, self.nb_paper == "sand") })
        if self.bg_bb and not is_pdf then   -- an imported PDF always prints its own pages
            add(vspan(12))
            add(ToggleRow:new{ label = _("Include background"), is_on = self.export_bg,
                width = content_w, parent = menu, callback = function(on) self.export_bg = on end })
        end
        add(vspan(12))
        add(TextWidget:new{ text = _("Pages"), face = Font:getFace("cfont", 15), bold = true, fgcolor = GREY })
        add(vspan(6))
        add(self:actionButton(_("Pages: ") .. (SCOPE_LABEL[self.nb_scope] or SCOPE_LABEL.all), content_w, function()
            self.nb_scope = (self.nb_scope == "all" and "ink") or (self.nb_scope == "ink" and "range") or "all"
            if self.nb_scope == "range" and not self.nb_range then self.nb_range = { from = 1, to = nb:count() } end
            reopen()
        end))
        if self.nb_scope == "range" then
            add(vspan(8))
            add(self:actionButton(string.format(_("Range: %d\u{2013}%d (tap to set)"),
                (self.nb_range and self.nb_range.from) or 1, (self.nb_range and self.nb_range.to) or nb:count()),
                content_w, function() closeSelf(); self:promptExportRange() end))
        end
        add(vspan(12))
        add(ToggleRow:new{ label = _("Page numbers"), is_on = self.nb_numbers and true or false,
            width = content_w, parent = menu, callback = function(on) self.nb_numbers = on end })
        add(vspan(16))
        local n = #self:selectedNotebookPages()
        add(self:actionButton(string.format(_("Export %d page(s) to PDF"), n), content_w, function()
            if n > 0 then closeSelf(); self:chooseNotebookDestination() end
        end, true))
        return FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, bordersize = Size.border.window,
            radius = Screen:scaleBySize(28), padding = Screen:scaleBySize(18), content }
    end
    self._save_dialog = IconMenu:new{ build = build, top_y = self:sheetTopY(),
        on_close = function() self._save_dialog = nil end }
    UIManager:show(self._save_dialog)
end

-- Ask for the first and last page of the export range.
function InkAwayView:promptExportRange()
    local nb = self.notebook
    local InputDialog = require("ui/widget/inputdialog")
    local d
    d = InputDialog:new{
        title = string.format(_("Page range (1\u{2013}%d), e.g. 3-8"), nb:count()),
        input = string.format("%d-%d", self.nb_range.from or 1, self.nb_range.to or nb:count()),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(d); self:exportNotebookPDF() end },
            { text = _("Set"), is_enter_default = true, callback = function()
                local s = d:getInputText() or ""
                local a, b = s:match("(%d+)%s*[%-\u{2013}to,%s]+(%d+)")
                if not a then a = s:match("(%d+)"); b = a end
                if a then self.nb_range = { from = tonumber(a), to = tonumber(b) } end
                UIManager:close(d)
                self:exportNotebookPDF()
            end },
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function InkAwayView:chooseNotebookDestination()
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true, select_file = false, show_files = true,
        path = existingDir(self:getSetting("inkaway_last_notebook_dir"))
            or self.notebooks_dir or self.default_dir or "/",
        onConfirm = function(dir)
            self:setSetting("inkaway_last_notebook_dir", dir)
            self:promptNotebookFilename(dir)
        end,
    })
end

function InkAwayView:promptNotebookFilename(dir)
    local InputDialog = require("ui/widget/inputdialog")
    local name = os.date("notebook-%Y%m%d-%H%M%S")
    local d
    d = InputDialog:new{
        title = _("PDF name"),
        input = name,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(d) end },
            { text = _("Export"), is_enter_default = true, callback = function()
                local n = d:getInputText()
                UIManager:close(d)
                if not n or n == "" then n = name end
                n = n:gsub("[/\\]", "_")
                if not n:lower():match("%.pdf$") then n = n .. ".pdf" end
                local sep = (dir:sub(-1) == "/") and "" or "/"
                self:doNotebookExport(dir .. sep .. n)
            end },
        }},
    }
    UIManager:show(d)
    d:onShowKeyboard()
end

function InkAwayView:doNotebookExport(path)
    local nb = self.notebook
    self:nbSyncOut()
    -- copy the template so the export tint/strength never sticks to the working
    -- notebook, and bake the ruling grey from the paper strength
    local template = {}
    for k, v in pairs(nb.template) do template[k] = v end
    template.paper = PAPERS[self.nb_paper or "white"] or PAPERS.white
    template.gray = strengthToLevel(template.strength)
    local ok, DataStorage = pcall(require, "datastorage")
    local tmp_dir = (ok and DataStorage and DataStorage:getSettingsDir()) or "/tmp"

    -- resolve the export scope to a concrete list of notebook pages
    local sel = self:selectedNotebookPages()
    if #sel == 0 then
        UIManager:show(InfoMessage:new{ text = _("No pages match the chosen range."), timeout = 3 })
        return
    end
    local pages_ops = {}
    for j = 1, #sel do pages_ops[j] = nb.pages[sel[j]].ops end

    local is_pdf = template.pdf_path
    local scale = 1
    local quality = is_pdf and 90 or 85

    -- background per selected page: a PDF-backed notebook renders each source
    -- page on the fly at the export resolution (one at a time, so memory stays
    -- flat); otherwise a single loaded picture is shared by every page.
    local bg
    if is_pdf then
        self:ensureNotebookPDF()
        local doc = self._nb_pdf_doc
        bg = function(j, s)
            s = s or 1
            local src = nb.pages[sel[j]] and nb.pages[sel[j]].src
            local img = src and self:renderPdfPage(doc, src, nb.w * s, nb.h * s) or nil
            if not img then return nil end
            local rgba = bbToRGBA(img, nb.w * s, nb.h * s)
            img:free()
            return rgba
        end
    elseif self.export_bg and self.bg_bb then
        bg = self.bg_rgba or self:buildBgRGBA()
    end

    -- Rendering every page to JPEG is synchronous and can take a moment on a
    -- long notebook, so show a wait message and let it paint before we block.
    local wait = InfoMessage:new{ text = string.format(_("Exporting %d page(s)\u{2026}"), #sel) }
    UIManager:show(wait)
    UIManager:nextTick(function()
        local eok, err = Export.notebookToPDF(pages_ops, nb.w, nb.h, template, path, quality, tmp_dir, bg,
            { footer = self.nb_numbers and true or nil, scale = scale })
        UIManager:close(wait)
        if not eok then
            UIManager:show(InfoMessage:new{ text = _("Could not export PDF.\n") .. tostring(err) })
            return
        end
        -- Also keep the editable notebook: save a project with the same name in
        -- the projects folder, so closing right after exporting never loses the
        -- work (people export the PDF and may not think to also "Save project").
        local proj_saved = self:autoSaveNotebookProject(path)
        -- make the PDF open as a full page with no auto-crop the first time
        self:seedPdfView(path)
        local ConfirmBox = require("ui/widget/confirmbox")
        local msg = string.format(_("Notebook exported:\n%s"), path)
        if proj_saved then msg = msg .. string.format(_("\n\nEditable copy kept in:\n%s"), proj_saved) end
        UIManager:show(ConfirmBox:new{
            text = msg .. _("\n\nOpen the PDF now?"),
            ok_text = _("Open"),
            ok_callback = function() self:openExportedPDF(path) end,
        })
    end)
end

-- Save the current notebook as an editable .inkaway project in the notebook
-- projects folder, using the PDF's base name. Returns the path or nil.
function InkAwayView:autoSaveNotebookProject(pdf_path)
    if not self.notebook then return nil end
    local base = pdf_path:match("([^/\\]+)%.[Pp][Dd][Ff]$") or pdf_path:match("([^/\\]+)$") or "notebook"
    local dir = self.nproj_dir or self.default_dir
    if not dir then return nil end
    local sep = (dir:sub(-1) == "/") and "" or "/"
    local proj = dir .. sep .. base .. "." .. Project.EXT
    self:nbSyncOut()
    local ok = Project.saveNotebook(self.notebook, proj)
    return ok and proj or nil
end

-- Pre-seed a freshly exported PDF's sidecar so KOReader opens it as a whole
-- page with no margin auto-crop (its defaults are page-width + auto-crop, which
-- would zoom into the ink and clip it). Best effort; harmless if it fails.
function InkAwayView:seedPdfView(path)
    local dok, DocSettings = pcall(require, "docsettings")
    if not (dok and DocSettings) then return end
    pcall(function()
        local ds = DocSettings:open(path)
        if not ds then return end
        ds:saveSetting("kopt_trim_page", 3)         -- 3 = "none": no margin cropping at all
        ds:saveSetting("kopt_zoom_mode_genus", 4)   -- 4 = "page"
        ds:saveSetting("kopt_zoom_mode_type", 2)    -- 2 = full (not width/height)
        ds:flush()
    end)
end

-- Hand a freshly exported PDF to KOReader's reader, closing the plugin view.
function InkAwayView:openExportedPDF(path)
    local rok, ReaderUI = pcall(require, "apps/reader/readerui")
    if not (rok and ReaderUI) then
        UIManager:show(InfoMessage:new{ text = _("Saved. Open it from your library."), timeout = 3 })
        return
    end
    self.closing = true
    self:saveSession()
    UIManager:close(self)
    UIManager:nextTick(function() ReaderUI:showReader(path) end)
end

function InkAwayView:chooseDestination(fmt)
    local PathChooser = require("ui/widget/pathchooser")
    local chooser
    chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = true,
        path = self:defaultDir(),
        onConfirm = function(dir)
            self:rememberDir(dir)
            self:promptFilename(fmt, dir)
        end,
    }
    UIManager:show(chooser)
end

function InkAwayView:promptFilename(fmt, dir)
    local ext = (fmt == "png") and "png" or "jpg"
    local default_name = os.date("ink-%Y%m%d-%H%M%S")
    local dialog
    dialog = InputDialog:new{
        title = _("File name"),
        input = default_name,
        input_hint = default_name,
        description = string.format(_("Saving to:\n%s\n\nExtension .%s will be added."), dir, ext),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if not name or name == "" then name = default_name end
                    self:writeFile(fmt, dir, name, ext)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function InkAwayView:writeFile(fmt, dir, name, ext)
    -- strip any path separators the user typed, keep it a simple filename
    name = name:gsub("[/\\]", "_")
    if not name:lower():match("%." .. ext .. "$") then
        name = name .. "." .. ext
    end
    local sep = (dir:sub(-1) == "/") and "" or "/"
    local path = dir .. sep .. name

    local opts = {
        rect = self.save_area,
        bg = (self.export_bg and self.bg_rgba) or nil,
    }
    local ok, err
    if fmt == "png" then
        ok, err = Export.savePNG(self.canvas, path, opts)
    else
        ok, err = Export.saveJPEG(self.canvas, path, 90, opts)
    end

    local ow = self.save_area and self.save_area.w or self.canvas.w
    local oh = self.save_area and self.save_area.h or self.canvas.h
    if ok then
        -- also keep an editable project of the same name, so people who never
        -- find the "Save project" button can still come back to this drawing
        local proj = self:autoSaveDrawingProject(name)
        local msg = string.format(_("Saved %d × %d image:\n%s"), ow, oh, path)
        if proj then msg = msg .. string.format(_("\n\nEditable copy kept in:\n%s"), proj) end
        UIManager:show(InfoMessage:new{ text = msg })
    else
        logger.warn("InkAway: save failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not save the image.\n%s"), tostring(err)),
            icon = "notice-warning",
        })
    end
end

-- Is the bookshelf plugin present? Prefer KOReader's loaded-plugin registry (so
-- it is found wherever it is installed), then fall back to a directory probe next
-- to this plugin and in the user plugins folder. Cached for the session.
function InkAwayView:bookshelfInstalled()
    if self._bookshelf_seen ~= nil then return self._bookshelf_seen end
    local seen = false
    pcall(function()
        local PluginLoader = require("pluginloader")
        local groups = { PluginLoader.enabled_plugins }
        for _, group in ipairs(groups) do
            if type(group) == "table" then
                for _, p in ipairs(group) do
                    local path = type(p) == "table" and p.path
                    if type(path) == "string" and path:lower():find("bookshelf%.koplugin") then
                        seen = true; return
                    end
                end
            end
        end
    end)
    if not seen then
        pcall(function()
            local lfs = require("libs/libkoreader-lfs")
            local cand = { self:pluginDir() .. "../bookshelf.koplugin" }
            local ok, DataStorage = pcall(require, "datastorage")
            if ok and DataStorage then
                cand[#cand + 1] = DataStorage:getDataDir() .. "/plugins/bookshelf.koplugin"
            end
            for _, d in ipairs(cand) do
                if lfs.attributes(d, "mode") == "directory" then seen = true; break end
            end
        end)
    end
    self._bookshelf_seen = seen
    return seen
end

-- The bookshelf plugin's ornament folder (koreader/icons/bookshelf.ornaments),
-- or nil when the bookshelf plugin isn't in use. A saved ornament is just a
-- transparent PNG dropped in here -- the bookshelf plugin picks up any *.png or
-- *.svg it finds. KOReader never creates icons/ itself, so callers make the tree.
-- "In use" means the folder already exists (the user keeps ornaments there) or
-- the bookshelf plugin is installed, so the option also shows before the first
-- ornament is saved.
function InkAwayView:ornamentsDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not (ok and DataStorage) then return nil end
    local dir = DataStorage:getDataDir() .. "/icons/bookshelf.ornaments"
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lok and lfs and lfs.attributes(dir, "mode") == "directory" then return dir end
    if self:bookshelfInstalled() then return dir end
    return nil
end

-- Save the canvas straight into the bookshelf ornament folder as a transparent
-- PNG. The destination is fixed, so this skips the folder chooser and only asks
-- for a name; it makes icons/ and the ornaments folder if they aren't there yet.
function InkAwayView:saveOrnament()
    local dir = self:ornamentsDir()
    if not dir then return end
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local icons = DataStorage:getDataDir() .. "/icons"
        if lfs.attributes(icons, "mode") ~= "directory" then lfs.mkdir(icons) end
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    end)
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not (lok and lfs and lfs.attributes(dir, "mode") == "directory") then
        UIManager:show(InfoMessage:new{
            text = _("Could not create the bookshelf ornaments folder."),
            icon = "notice-warning" })
        return
    end
    self:promptOrnamentName(dir)
end

-- Ask for an ornament name, then write it. A trailing ".invert" is kept (the
-- bookshelf plugin reads name.invert.png as the dark-mode variant); the ".png"
-- extension is added when the name doesn't already end in it.
function InkAwayView:promptOrnamentName(dir)
    local default_name = os.date("ornament-%Y%m%d-%H%M%S")
    local dialog
    dialog = InputDialog:new{
        title = _("Ornament name"),
        input = default_name,
        input_hint = default_name,
        description = _("Saved as a transparent PNG in the bookshelf ornaments folder.\nEnd the name with .invert for a dark-mode version."),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local name = dialog:getInputText()
                    UIManager:close(dialog)
                    if not name or name == "" then name = default_name end
                    self:writeOrnament(dir, name)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function InkAwayView:writeOrnament(dir, name)
    name = name:gsub("[/\\]", "_")               -- keep it a plain filename
    if not name:lower():match("%.png$") then name = name .. ".png" end
    local sep = (dir:sub(-1) == "/") and "" or "/"
    local path = dir .. sep .. name
    local opts = { rect = self.save_area, bg = (self.export_bg and self.bg_rgba) or nil }
    local ok, err = Export.savePNG(self.canvas, path, opts)
    if ok then
        UIManager:show(InfoMessage:new{ text = string.format(_("Saved bookshelf ornament:\n%s"), path) })
    else
        logger.warn("InkAway: ornament save failed:", err)
        UIManager:show(InfoMessage:new{
            text = string.format(_("Could not save the ornament.\n%s"), tostring(err)),
            icon = "notice-warning" })
    end
end

-- Save the current canvas as an editable .inkaway project in the drawing
-- projects folder, using the image's base name. Returns the path or nil (and
-- skips a blank canvas, since there is nothing to come back to).
function InkAwayView:autoSaveDrawingProject(image_name)
    if self.canvas:isEmpty() then return nil end
    local base = image_name:gsub("%.[^.]+$", "")
    if base == "" then base = "ink" end
    local dir = self.dproj_dir or self.default_dir
    if not dir then return nil end
    local sep = (dir:sub(-1) == "/") and "" or "/"
    local proj = dir .. sep .. base .. "." .. Project.EXT
    local ok = Project.save(self.canvas, proj)
    return ok and proj or nil
end

-- Expose the internal sheet widgets for headless tests (they are file-locals).
InkAwayView._SliderRow, InkAwayView._ToggleRow = SliderRow, ToggleRow

return InkAwayView
