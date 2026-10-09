--[[
The narrow toolbar down the left side that Ink Away uses over a book: in the
annotation mode (ink/reader/inkview.lua), down the whole screen, and in the
book notes window (ink/reader/notesview.lua), down the window. Mixed into a
view class with VBar.into(Class); the view gives the buttons (buildVBar) and
says which tool is active (vbarActive), and paintTo places the column at
self._bar_x, self._bar_y.
]]

local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Accent = require("ink/accent")
local Paint = require("ink/paint")

local Screen = Device.screen

local VBar = {}

-- The column of buttons, `h` tall: specs are { id, icon, tool, cb }.
function VBar:buildVBar(specs, h)
    self:ensureUserIcons()
    local n = #specs
    local btn_h = math.floor(h / n)
    local bar_w = math.max(Screen:scaleBySize(36), math.min(Screen:scaleBySize(50), math.floor(btn_h * 1.15)))
    local isz = math.max(18, math.min(math.floor(bar_w * 0.6), math.floor(btn_h * 0.62)))
    self._btn_h, self._bar_w, self._icon_sz, self._vbar_h = btn_h, bar_w, isz, h
    self.tool_buttons, self._toolbar_icons = {}, {}
    local col = VerticalGroup:new{ align = "center" }
    for i, s in ipairs(specs) do
        local bh = (i == n) and (h - btn_h * (n - 1)) or btn_h
        local raw = s.cb
        local b = Button:new{ icon = "inkaway." .. s.icon, icon_width = isz, icon_height = isz,
            callback = function()
                local ok, err = xpcall(raw, debug.traceback)
                if not ok then logger.warn("Ink Away book toolbar '" .. s.id .. "' failed: " .. tostring(err)) end
            end,
            width = bar_w, height = bh, bordersize = 0, radius = 0, background = nil,
            margin = 0, padding = 0, show_parent = self }
        local path = self:pluginDir() .. "ink/icons/" .. s.icon .. ".svg"
        local ok_icon, icon = pcall(function() return IconWidget:new{ file = path, width = isz, height = isz } end)
        if ok_icon and icon then self:setButtonLabel(b, icon) end
        if b.frame then b.frame.background = nil end
        if s.tool then self.tool_buttons[s.id] = { button = b } end
        self._toolbar_icons[i] = { button = b, id = s.id, tool = s.tool == true,
            icon = ok_icon and icon or nil, path = path, size = isz }
        table.insert(col, b)
    end
    self.toolbar = FrameContainer:new{ background = nil, bordersize = 0, padding = 0, margin = 0, col }
    self._bar_h = nil        -- the canvas's horizontal-bar measures do not apply
    self:updateToolbarActive()
end

-- The active tool's button shows it (tinted on a colour screen, inverted on grey).
function VBar:updateToolbarActive()
    if not self._toolbar_icons then return end
    local active = self:vbarActive()
    self._active_btn_idx = nil
    for i, e in ipairs(self._toolbar_icons) do
        if e.tool and e.button then
            local on = (e.id == active)
            if on then self._active_btn_idx = i end
            local tinted = on and e.path and Accent.icon(e.path, e.size)
            if tinted then
                self:setButtonLabel(e.button, ImageWidget:new{ image = tinted, width = e.size, height = e.size,
                    image_disposable = false })
            elseif e.icon then
                if e.button.label_widget ~= e.icon then self:setButtonLabel(e.button, e.icon) end
                e.icon.invert = on
            end
        end
    end
end

-- Which tool's button is active (the shape button stands for the fill too).
function VBar:vbarActive()
    return (self.tool == "fill") and "shape" or self.tool
end

-- The rounded pill behind the active tool; (ox, oy) is the column's top-left.
function VBar:drawActiveToolPill(bb, ox, oy)
    if not (self._active_btn_idx and self._btn_h and self._bar_w) then return end
    local m = Screen:scaleBySize(5)
    local cy = oy + self._btn_h * (self._active_btn_idx - 1)
    Accent.paintRounded(bb, ox + m, cy + m, self._bar_w - 2 * m, self._btn_h - 2 * m, Screen:scaleBySize(9))
end

-- The hairline between the column and the page, and the pen in hand's colour
-- under its button (the highlighter's, when it is the highlighter).
function VBar:drawToolbarIcons(bb, ox, oy)
    if not self._bar_w then return end
    ox, oy = ox or 0, oy or 0
    bb:paintRect(ox + self._bar_w - 1, oy, 1, self._vbar_h or self.screen_h, Paint.HAIRLINE)
    local want = self.pen_style == "highlighter" and "highlight" or "pen"
    for i, e in ipairs(self._toolbar_icons or {}) do
        if e.id == want or (want == "highlight" and e.id == "pen" and not self:vbarHas("highlight")) then
            self:paintPenMark(bb, ox, oy + self._btn_h * (i - 1), self._bar_w, self._btn_h)
            break
        end
    end
end

-- Is there a button `id` in the column?
function VBar:vbarHas(id)
    for _i, e in ipairs(self._toolbar_icons or {}) do if e.id == id then return true end end
    return false
end

-- Add these to a view class.
function VBar.into(Class)
    for k, f in pairs(VBar) do
        if k ~= "into" then Class[k] = f end
    end
end

return VBar
