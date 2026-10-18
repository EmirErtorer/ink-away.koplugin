--[[
Highlighting while reading, with the pen's button: no need to open the
annotation mode. Hold the part of the pen set to the Highlighter in Gestures and
pen buttons (by default a side button) and run the pen over a line of text: it
becomes the reader's own highlight of that text, as the smart highlighter makes
it in the annotation mode (see Book:highlight).

The pen is watched through KOReader's pen callback for as long as the book is
open, and only a contact made with that button held on the page itself is
taken; every other frame goes on to whatever had the pen before (another
plugin), or to KOReader as a touch, so the pen turns pages and selects text as
it always did. An Ink Away view opened over the book takes the pen and gives
it back as it closes (see InkAwayView:takeStylus).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Actions = require("ink/actions")
local Stylus = require("ink/stylus")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK

local SETTING = "inkaway_reader_pen_highlight"

local PenHighlight = {}
PenHighlight.__index = PenHighlight

local function setting(key)
    local G = rawget(_G, "G_reader_settings")
    return G and G.readSetting and G:readSetting(key)
end

-- Is highlighting with the pen's button on (it is unless turned off)?
function PenHighlight.enabled()
    return setting(SETTING) ~= false
end

function PenHighlight.setEnabled(on)
    local G = rawget(_G, "G_reader_settings")
    if G and G.saveSetting then G:saveSetting(SETTING, on and true or false) end
end

-- Can this KOReader hand a plugin the pen? (2026.07 or newer; on Android only
-- once it tells the pen from a finger, see InkAwayView:penCapable)
function PenHighlight.supported(input)
    input = input or Device.input
    if not (input and type(input.registerStylusCallback) == "function") then return false end
    if Device.isAndroid and Device:isAndroid() then
        local ok, r = pcall(function() return require("android").lib.AMOTION_EVENT_TOOL_TYPE_STYLUS ~= nil end)
        return ok and r == true
    end
    return true
end

-- Does this reader have a pen, as far as can be told: a Wacom pen (Kindle
-- Scribe, reMarkable), a Kobo made for one, or a reader Ink Away has seen a pen
-- on. (Only these get the menu entry; the watch itself costs nothing without.)
function PenHighlight.penReader(input)
    input = input or Device.input
    if not PenHighlight.supported(input) then return false end
    if input.wacom_protocol or Stylus.PEN_KOBOS[Device.model] then return true end
    return setting("inkaway_pen_seen") == true
end

-- `book`: the Book over the reader (ink/reader/book.lua). `input` is KOReader's
-- Input (the tests give their own).
function PenHighlight.new(book, input)
    local o = setmetatable({ book = book, ui = book.ui, input = input or Device.input }, PenHighlight)
    o.cb = function(inp, slot) return o:onSlot(inp, slot) end
    return o
end

-- Watch the pen, keeping what had it before to hand every other frame on to.
function PenHighlight:attach()
    if self.attached or not PenHighlight.supported(self.input) or not PenHighlight.enabled() then return false end
    local inp = self.input
    local cur = inp.stylus_callback
    self.prev = cur ~= self.cb and cur or nil
    inp:registerStylusCallback(self.cb)
    self.attached = true
    return true
end

-- Stop watching, giving the pen back to what had it, unless something took it
-- since (it keeps it).
function PenHighlight:detach()
    if not self.attached then return end
    self.attached = false
    self:dropStroke()
    local inp = self.input
    if inp.stylus_callback == self.cb then
        if self.prev then inp:registerStylusCallback(self.prev) else inp:unregisterStylusCallback() end
    end
    self.prev = nil
end

-- Is the page itself on top (no menu, dialog or Ink Away view over it)? Notices
-- that close by themselves are looked past.
function PenHighlight:pageOnTop()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and not w.invisible and not w.toast and not w.timeout then return w == self.ui end
    end
    return false
end

-- The highlighter pen of the pen case: its width and colour.
function PenHighlight:highlighter()
    local Penset = require("ink/penset")
    local Raster = require("ink/raster")
    local dpi = Screen.getDPI and Screen:getDPI() or 300
    local colour = Device.hasColorScreen and Device:hasColorScreen() and true or false
    local ok, case = pcall(Penset.load, setting, { colour = colour, pxmm = (dpi or 300) / 25.4 },
        function(style) return Raster.STYLES[style] ~= nil end)
    local p = ok and case and (case.types.highlighter or Penset.default("highlighter", case.opts)) or nil
    return { width = p and p.width or 24, color = p and p.color or nil }
end

-- What the part of the pen touching down does, from Gestures and pen buttons.
function PenHighlight:action(slot, facts)
    local trigger = Stylus.TRIGGER[Stylus.penAction(slot, facts)]
    if not trigger then return nil end
    return Actions.load(setting)[trigger]
end

-- The pen's frames: the start, the points and the lift of a highlight are
-- taken (true); everything else goes on.
function PenHighlight:onSlot(inp, slot)
    local ok, taken = pcall(self.frame, self, inp or self.input, slot)
    if not ok then
        logger.warn("Ink Away: pen highlight:", taken)
        self:dropStroke()
        taken = false
    end
    if taken then return true end
    if self.prev then return self.prev(inp, slot) end
    return false
end

function PenHighlight:frame(inp, slot)
    local facts = Stylus.facts(inp, self.learned_slot, Device.isAndroid and Device:isAndroid())
    local role = Stylus.classify(slot, facts)
    local sn = slot.slot or 0
    -- the pen's slot, learned from a plain pen frame (see InkAwayView:watchPen)
    if role == Stylus.ROLE_PEN and slot.tool == Stylus.TOOL_PEN and slot.slot ~= nil then
        self.learned_slot = slot.slot
    end
    local s = self.stroke
    if s then
        if sn ~= s.slot then return false end   -- (another contact: not ours)
        if role == Stylus.ROLE_PEN_OUT or slot.id == nil or slot.id < 0 then
            self:finish()
            return true
        end
        if slot.x and slot.y then self:addPoint(Stylus.screenXY(slot, Screen)) end
        return true
    end
    -- a new contact: ours only with the Highlighter's button held, on the page,
    -- and once the pen's slot is known only there (a palm the panel numbers as
    -- the eraser looks like the pen while the eraser end is held)
    if role ~= Stylus.ROLE_PEN or slot.id == nil or slot.id < 0 then return false end
    if self.learned_slot ~= nil and sn ~= self.learned_slot and slot.tool ~= Stylus.TOOL_PEN then return false end
    if self:action(slot, facts) ~= "highlighter" then return false end
    if not (slot.x and slot.y) or not self:pageOnTop() then return false end
    local pen = self:highlighter()
    self.stroke = { slot = sn, pts = {}, width = pen.width, color = pen.color,
        x0 = math.huge, y0 = math.huge, x1 = -math.huge, y1 = -math.huge }
    self:addPoint(Stylus.screenXY(slot, Screen))
    return true
end

-- How thick the line showing the stroke is, in screen pixels.
local function lineWidth() return math.max(2, math.floor(Screen:scaleBySize(2) + 0.5)) end

-- Add a point to the stroke and show it: a thin line from the last one, drawn
-- straight on the screen (the page is drawn again at the lift).
function PenHighlight:addPoint(x, y)
    local s = self.stroke
    local pts = s.pts
    local n = #pts
    local px, py = pts[n - 1], pts[n]
    if px and math.abs(x - px) + math.abs(y - py) < 2 then return end
    pts[n + 1], pts[n + 2] = x, y
    px, py = px or x, py or y
    local t = lineWidth()
    local bb = Screen.bb
    local steps = math.max(1, math.ceil(math.max(math.abs(x - px), math.abs(y - py))))
    for i = 0, steps do
        local cx, cy = px + (x - px) * i / steps, py + (y - py) * i / steps
        bb:paintRect(math.floor(cx - t / 2), math.floor(cy - t / 2), t, t, BLACK)
    end
    local rx0, ry0 = math.floor(math.min(x, px) - t), math.floor(math.min(y, py) - t)
    local rx1, ry1 = math.ceil(math.max(x, px) + t), math.ceil(math.max(y, py) + t)
    s.x0, s.y0 = math.min(s.x0, rx0), math.min(s.y0, ry0)
    s.x1, s.y1 = math.max(s.x1, rx1), math.max(s.y1, ry1)
    UIManager:setDirty(nil, "fast", Geom:new{ x = rx0, y = ry0, w = rx1 - rx0, h = ry1 - ry0 })
end

-- The pen lifted: make the stroke the highlight of the text it ran over, and
-- draw the page again where the line was (with the highlight, if there is one).
function PenHighlight:finish()
    local s = self.stroke
    self.stroke = nil
    if not s then return end
    local op = { kind = "ink", style = "highlighter", width = s.width, color = s.color, pts = s.pts }
    local ok, item = pcall(self.book.highlight, self.book, op)
    if not ok then logger.warn("Ink Away: pen highlight:", item) end
    self:repaint(s)
    return ok and item or nil
end

-- A stroke abandoned (the book closing, a failure): only the screen is put right.
function PenHighlight:dropStroke()
    local s = self.stroke
    self.stroke = nil
    if s then self:repaint(s) end
end

function PenHighlight:repaint(s)
    if s.x1 < s.x0 then return end
    local pad = math.ceil((s.width or 0) / 2) + 4
    UIManager:setDirty(self.ui, "ui", Geom:new{ x = s.x0 - pad, y = s.y0 - pad,
        w = s.x1 - s.x0 + 2 * pad, h = s.y1 - s.y0 + 2 * pad })
end

return PenHighlight
