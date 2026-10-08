--[[
The toolbar, switching tools, and the floating controls (the Pan button, the
zoom pill and the bar collapse chevrons) that fade while drawing near them.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Font = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Accent = require("ink/accent")
local InkGeom = require("ink/geom")
local Paint = require("ink/paint")

local Screen = Device.screen
local HAIRLINE = Paint.HAIRLINE

-- The floating zoom pill and Pan button: e-ink cannot show a see-through fill,
-- so they are light opaque shapes with a soft border and dark glyphs, and they
-- hide while drawing near them so the canvas underneath stays reachable.
local FAB_FILL   = Blitbuffer.ColorRGB32(0xF0, 0xF0, 0xF0, 0xFF)
local FAB_BORDER = Blitbuffer.ColorRGB32(0xB4, 0xB4, 0xB4, 0xFF)
local FAB_GLYPH  = Blitbuffer.ColorRGB32(0x33, 0x34, 0x36, 0xFF)

-- The floating controls: the fabRect name, the flag set while one is hidden, and
-- the callback (made by initFabs) that brings it back.
local FABS = {
    { rect = "zoom",  hidden = "_zoom_hidden",         show = "_show_zoom_fab" },
    { rect = "pan",   hidden = "_pan_hidden",          show = "_show_pan_fab" },
    { rect = "bar",   hidden = "_bar_toggle_hidden",   show = "_show_bar_toggle" },
    { rect = "nbbar", hidden = "_nbbar_toggle_hidden", show = "_show_nbbar_toggle" },
    { rect = "back",  hidden = "_back_hidden",         show = "_show_back_fab" },
}

local InkAwayView = {}

------------------------------------------------------------------------------
-- Toolbar
------------------------------------------------------------------------------

function InkAwayView:buildToolbar()
    local specs = {
        -- the first tap selects a tool; a tap on the active tool opens its options
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
            -- once the tool is active, a second tap opens the font and size options
            if self.editing_text then self:finishTextEdit(true)
            elseif self.tool == "text" then self:openTextSettings()
            else self:setTool("text") end
        end },
        -- placing an image, one tap away
        { id = "image", label = _("Image"), cb = function() self:chooseImage() end },
        -- Pan has its own button by the zoom pill (see drawPanFab)
        { id = "lasso", label = _("Lasso"), tool = true, cb = function() self:setTool("lasso") end },
        { id = "undo",  label = _("Undo"),  cb = function() self:undo() end },
        { id = "redo",  label = _("Redo"),  cb = function() self:redo() end },
        { id = "menu",  label = "\u{2699}", cb = function() self:openSettings() end },   -- gear
        { id = "library", label = _("Library"), cb = function() self:openLibrary() end },
        { id = "file",  label = _("File"),  cb = function() self:openDocumentSheet() end },
        { id = "exit",  label = _("Exit"),  cb = function() self:closeCanvas() end },
    }
    -- each tool id maps to an SVG in ink/icons (erase uses "eraser")
    local ICON = { pen = "pen", erase = "eraser", shape = "shape", text = "text",
        image = "image", lasso = "lasso",
        undo = "undo", redo = "redo", menu = "menu", library = "library", file = "file", exit = "exit" }
    self:ensureUserIcons()   -- so the Buttons can render the icons by name
    local n = #specs
    local btn_w = math.floor(Screen:getWidth() / n)
    -- the button height, which is also the active pill's; the toolbar is taller by
    -- twice the button margin, so the pill clears the top and bottom edges
    local bar_h = math.max(Screen:scaleBySize(32), math.min(Screen:scaleBySize(46), math.floor(btn_w * 0.66)))
    self._btn_w, self._bar_h = btn_w, bar_h   -- for the active-tool pill in paintTo
    -- centre of the last (Exit) button, so the collapse chevron lines up under it
    self._last_btn_center = math.floor(btn_w * (n - 1) + (Screen:getWidth() - btn_w * (n - 1)) / 2)
    -- every icon is centred in a cell of the same height, well inside it, so the
    -- active pill looks the same behind each tool
    local isz = math.max(20, math.floor(bar_h * 0.66))
    self._icon_sz = isz   -- the notebook bottom bar uses the same icon size
    self.tool_buttons = {}
    self._toolbar_icons = {}
    local row = {}
    for i, s in ipairs(specs) do
        local w = (i == n) and (Screen:getWidth() - btn_w * (n - 1)) or btn_w
        -- The icon belongs to the Button, so the Button repaints it itself,
        -- including its tap feedback (an inverted region). Each action is guarded:
        -- an error is shown, and the tap feedback still clears.
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
            -- borderless icons on a clean bar; the active tool gets a pill drawn
            -- behind it in paintTo (see drawActiveToolPill)
            bordersize = 0,
            radius = 0,
            background = nil,
            margin = Screen:scaleBySize(4),
            padding = 0,
            show_parent = self,
        }
        -- Load the icon from the plugin's own SVG by path. IconWidget's name lookup
        -- searches the user-icon dir only if it existed when KOReader started, so on
        -- a first run (ensureUserIcons creates it later) every name would resolve to
        -- the not-found triangle until a restart.
        local icon_path = self:pluginDir() .. "ink/icons/" .. ICON[s.id] .. ".svg"
        local ok_icon, file_icon = pcall(function()
            return IconWidget:new{ file = icon_path, width = isz, height = isz }
        end)
        if ok_icon and file_icon then self:setButtonLabel(b, file_icon) end
        -- no fill: KOReader gives a borderless button a white one, which would
        -- cover the active pill painted behind it
        if b.frame then b.frame.background = nil end
        if s.tool then self.tool_buttons[s.id] = { button = b } end
        self._toolbar_icons[i] = { button = b, id = s.id, tool = s.tool == true,
            icon = ok_icon and file_icon or nil, path = icon_path, size = isz }
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

-- Mark the active tool: remember its button index (paintTo draws the accent pill
-- behind it) and show its icon so it reads on the pill. The icon renders on an
-- opaque white ground: inverted, it shows white on black; on a chosen accent it
-- is swapped for one drawn on the accent.
function InkAwayView:updateToolbarActive()
    if not self._toolbar_icons then return end
    local active = (self.tool == "fill") and "shape" or self.tool
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
            elseif e.button.label_widget then
                e.button.label_widget.invert = on
            end
        end
    end
end

-- Paint the active tool's pill: an accent rounded rect inset within its cell.
-- Called from paintTo before the transparent toolbar, so the icon lands on top.
function InkAwayView:drawActiveToolPill(bb, ox, oy)
    if self._toolbar_hidden or not self._active_btn_idx or not self._btn_w or not self._bar_h then return end
    local m = Screen:scaleBySize(7)
    local cx = ox + self._btn_w * (self._active_btn_idx - 1)
    Accent.paintRounded(bb, cx + m, oy + m, self._btn_w - 2 * m, self._bar_h - 2 * m, Screen:scaleBySize(9))
end

-- Show the current tool as active: the toolbar, and the Pan button when Pan
-- comes or goes.
function InkAwayView:refreshToolLabels()
    self:updateToolbarActive()   -- move the pill to the current tool
    UIManager:setDirty(self, "ui", self.toolbar and self.toolbar.dimen or nil)
    local pan = self.tool == "pan"
    if pan ~= (self._pan_fab_on or false) then
        self._pan_fab_on = pan
        if not self._pan_hidden then self:refreshFabRegion(self:fabRect("pan")) end
    end
end

-- The plugin's own directory, found from this file's path (it lives under ink/).
function InkAwayView:pluginDir()
    if self._plugin_dir then return self._plugin_dir end
    local src = debug.getinfo(1, "S").source
    self._plugin_dir = (src:match("^@(.*/)ink/")) or "./"
    return self._plugin_dir
end

-- Copy the plugin's icons into KOReader's user-icon dir (refreshed when the
-- plugin ships newer ones), so a Button can show them by the name "inkaway.<id>".
function InkAwayView:ensureUserIcons()
    -- once per session: the plugin's files cannot change while it runs
    if self._icons_synced then return true end
    local ok = pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local DataStorage = require("datastorage")
        local dst_dir = DataStorage:getDataDir() .. "/icons"
        if lfs.attributes(dst_dir, "mode") ~= "directory" then lfs.mkdir(dst_dir) end
        local src_dir = self:pluginDir() .. "ink/icons/"
        for _, name in ipairs({ "pen", "eraser", "shape", "text", "image", "pan",
                                "undo", "redo", "menu", "library", "file", "exit",
                                "sh_line", "sh_rect", "sh_ellipse", "sh_triangle",
                                "sh_curve", "sh_arrow", "sh_darrow", "sh_carrow", "sh_cdarrow",
                                "bucket", "lasso", "caret", "highlighter", "booknotes", "nav_prev", "nav_next",
                                "newpage", "fullscreen" }) do
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

-- Paint the hairline that separates the toolbar from the canvas, after the icons.
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
    if self.selection or self.lassoing then self:dropSelection() end
    self.pan_last = nil
    if tool == "pan" then self._tool_before_pan = self.tool end   -- for the Pan button's second tap
    self.tool = tool
    self:refreshToolLabels()
    -- the toolbar strip changes too (the pill moves), so clear any area-only flag
    -- set by a nested deselect, or the next paint would skip the toolbar
    self._area_only = false
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
end

------------------------------------------------------------------------------
-- Floating controls: a zoom pill at the bottom right with the Pan button above
-- it, and chevrons that collapse
-- the toolbar (and, in a notebook, the bottom bar). They hide while drawing comes
-- near them and return shortly after, so the canvas beneath stays reachable.
-- They follow the drawing area, so they move when a bar collapses.
------------------------------------------------------------------------------

-- Make the callbacks that bring each control back once drawing near it has
-- stopped (bound once, so they can be unscheduled).
function InkAwayView:initFabs()
    for _, f in ipairs(FABS) do
        self[f.show] = function()
            if self[f.hidden] then
                self[f.hidden] = false
                self:refreshFabRegion(self:fabRect(f.rect))
            end
        end
    end
end

-- Cancel any control's pending return (on close).
function InkAwayView:cancelFabs()
    for _, f in ipairs(FABS) do
        if self[f.show] then UIManager:unschedule(self[f.show]) end
    end
end

-- Screen rect of a named control ("zoom", "pan", "bar", "nbbar" or "back"), or nil.
function InkAwayView:fabRect(which)
    if not self.view then return nil end
    local v = self.view
    local m = Screen:scaleBySize(16)
    local w = Screen:scaleBySize(46)
    if which == "back" then   -- after following a link: back to where it was followed from
        if not self._link_back then return nil end
        return { x = v.area_x + m, y = v.area_y + m, w = Screen:scaleBySize(96), h = Screen:scaleBySize(38) }
    elseif which == "zoom" then
        local h = Screen:scaleBySize(92)
        return { x = v.area_x + v.area_w - m - w, y = v.area_y + v.area_h - m - h, w = w, h = h }
    elseif which == "pan" then   -- a round button a little above the zoom pill
        local z = self:fabRect("zoom")
        return { x = z.x, y = z.y - Screen:scaleBySize(12) - w, w = w, h = w }
    elseif which == "nbbar" then -- notebook bottom-bar toggle: a bare chevron at the
        -- bar's top left, anchored to the area bottom so it sits on the bar's top
        -- edge when shown and near the screen bottom when collapsed
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

-- Repaint just a control's footprint (plus a margin): hiding reveals the canvas,
-- showing draws the control, both without a full redraw.
function InkAwayView:refreshFabRegion(r)
    if not r then return end
    self._blit_rect = nil   -- blit the whole area, so the canvas under the
                            -- control is restored, not just a stroke's rect
    local m = Screen:scaleBySize(4)
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = r.x - m, y = r.y - m, w = r.w + 2 * m, h = r.h + 2 * m })
end

-- What a point hits: "zoomin" or "zoomout" (halves of the pill), "pan", "bar" or
-- "nbbar" (the toggles), "back", or nil. Hidden controls cannot be hit, so drawing
-- passes through.
function InkAwayView:fabHit(px, py)
    if not self._zoom_hidden then
        local r = self:fabRect("zoom")
        if r and InkGeom.inRect(px, py, r) then
            return (py < r.y + r.h / 2) and "zoomin" or "zoomout"
        end
    end
    if not self._pan_hidden then
        local r = self:fabRect("pan")
        if r and InkGeom.inRect(px, py, r) then return "pan" end
    end
    -- (not while a text box is open: the chevron would sit on its Done button)
    if not self._bar_toggle_hidden and not self.editing_text then
        local r = self:fabRect("bar")
        if r and InkGeom.inRect(px, py, r) then
            return "bar"
        end
    end
    if self.notebook and not self._nbbar_toggle_hidden then
        local r = self:fabRect("nbbar")
        if r and InkGeom.inRect(px, py, r) then
            return "nbbar"
        end
    end
    if not self._back_hidden then
        local r = self:fabRect("back")
        if r and InkGeom.inRect(px, py, r) then return "back" end
    end
    return nil
end

-- Act on a completed tap of a control.
function InkAwayView:fabAction(kind)
    if kind == "zoomin" then self:zoomStep(1)
    elseif kind == "zoomout" then self:zoomStep(-1)
    elseif kind == "pan" then self:togglePan()
    elseif kind == "bar" then self:setToolbarHidden(not self._toolbar_hidden)
    elseif kind == "nbbar" then self:setNbBarHidden(not self._nb_collapsed)
    elseif kind == "back" then self:linkBack() end
end

-- The Pan button: the first tap picks Pan, a second goes back to the tool in use
-- before it.
function InkAwayView:togglePan()
    if self.tool ~= "pan" then return self:setTool("pan") end
    local back = self._tool_before_pan
    self:setTool((back and back ~= "pan") and back or "pen")
end

-- Called from the drawing handlers: if the active point comes near a control,
-- fade it out and keep pushing back its return until drawing there stops.
function InkAwayView:fabProximity(px, py)
    for _, f in ipairs(FABS) do
        local r = self:fabRect(f.rect)   -- nil for the notebook bar outside a notebook
        local m = r and r.w              -- "near" = within one control width
        if r and px >= r.x - m and px <= r.x + r.w + m and py >= r.y - m and py <= r.y + r.h + m then
            if not self[f.hidden] then self[f.hidden] = true; self:refreshFabRegion(r) end
            UIManager:unschedule(self[f.show]); UIManager:scheduleIn(0.6, self[f.show])
        end
    end
end

-- A small chevron centred in a w x h buffer: up = -1, down = 1.
local function chevron(bb, w, h, dir)
    local cx, cy = math.floor(w / 2), math.floor(h / 2)
    local half, tk = math.floor(w * 0.28), math.max(2, Screen:scaleBySize(2))
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

-- What each floating control shows, drawn into its sprite (w x h) over its light
-- shape, or on nothing when `bare`. The Pan button's icon is painted over its
-- sprite instead (see drawPanFab).
local FAB_GLYPHS = {
    zoom = { draw = function(bb, w, h, S1)   -- a divider, + over -
        local midy = math.floor(h / 2)
        bb:paintRect(Screen:scaleBySize(10), midy, w - 2 * Screen:scaleBySize(10), S1, FAB_BORDER)
        local gw = math.floor(w * 0.34)
        local gt = math.max(2, Screen:scaleBySize(2))
        local cx = math.floor(w / 2)
        local cyTop, cyBot = math.floor(h / 4), math.floor(3 * h / 4)
        bb:paintRect(cx - math.floor(gw / 2), cyTop - math.floor(gt / 2), gw, gt, FAB_GLYPH)
        bb:paintRect(cx - math.floor(gt / 2), cyTop - math.floor(gw / 2), gt, gw, FAB_GLYPH)
        bb:paintRect(cx - math.floor(gw / 2), cyBot - math.floor(gt / 2), gw, gt, FAB_GLYPH)
    end },
    pan = {},
    -- the bars' collapse toggles: a bare chevron, up (^) or down (v)
    chev_up = { bare = true, draw = function(bb, w, h) chevron(bb, w, h, -1) end },
    chev_down = { bare = true, draw = function(bb, w, h) chevron(bb, w, h, 1) end },
}

-- A floating control as an alpha sprite with transparent corners. A rounded
-- colour fill or a chevron's dots are slow per-pixel paths, so each is drawn once
-- and stamped with a C alpha-blit on each paint; it is rebuilt only when its
-- size, the screen buffer type or night mode changes.
function InkAwayView:fabSprite(name, w, h)
    local typ = Screen.bb:getType()
    local inv = (Screen.bb.getInverse and Screen.bb:getInverse()) or 0
    self._fab_sprites = self._fab_sprites or {}
    local c = self._fab_sprites[name]
    if c and c.w == w and c.h == h and c.type == typ and c.inv == inv then return c.bb end
    if c and c.bb then c.bb:free() end
    local S1 = math.max(1, Screen:scaleBySize(1))
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A or typ)   -- alpha: starts transparent
    if bb.setInverse then bb:setInverse(inv) end   -- so software night mode still blits in C
    local g = FAB_GLYPHS[name] or {}
    if not g.bare then
        local rad = math.floor(w / 2)
        bb:paintRoundedRect(0, 0, w, h, FAB_FILL, rad)      -- fills only the rounded shape;
        bb:paintBorder(0, 0, w, h, S1, FAB_BORDER, rad)     -- corners stay transparent
    end
    if g.draw then g.draw(bb, w, h, S1) end
    self._fab_sprites[name] = { bb = bb, w = w, h = h, type = typ, inv = inv }
    return bb
end

-- The Pan icon at `size`: dark on the light button, or for the active button
-- (on) white on black, as the toolbar shows its active tool. Kept until close.
function InkAwayView:panFabIcon(size, on)
    local c = self._pan_fab_icons
    if not c or c.size ~= size then
        self:freeFabSprites(true)
        local file = self:pluginDir() .. "ink/icons/pan.svg"
        local function icon(o)
            local ok, w = pcall(IconWidget.new, IconWidget, o)
            return ok and w or nil
        end
        c = { size = size, file = file,
              plain = icon{ file = file, width = size, height = size, alpha = true },
              inv = icon{ file = file, width = size, height = size, invert = true } }
        self._pan_fab_icons = c
    end
    return on and c.inv or c.plain, c.file
end

-- Paint the Pan button at (x, y), w wide: the light round shape, or the accent
-- while Pan is the tool, with the Pan icon centred on it.
function InkAwayView:drawPanFab(bb, x, y, w, on)
    local isz = math.floor(w * 0.56)
    local ix, iy = x + math.floor((w - isz) / 2), y + math.floor((w - isz) / 2)
    local icon, file = self:panFabIcon(isz, on)
    if on then
        Accent.paintRounded(bb, x, y, w, w, math.floor(w / 2))
        local tinted = Accent.icon(file, isz)   -- nil with the black accent
        if tinted then
            bb:blitFrom(tinted, ix, iy, 0, 0, isz, isz)
            return
        end
    else
        bb:alphablitFrom(self:fabSprite("pan", w, w), x, y, 0, 0, w, w)
    end
    if icon then icon:paintTo(bb, ix, iy) end
end

-- Free the controls' sprites and the Pan icons (on close); with icons_only,
-- just the icons.
function InkAwayView:freeFabSprites(icons_only)
    local c = self._pan_fab_icons
    if c then
        if c.plain then c.plain:free() end
        if c.inv then c.inv:free() end
        self._pan_fab_icons = nil
    end
    if icons_only then return end
    for _, sp in pairs(self._fab_sprites or {}) do if sp.bb then sp.bb:free() end end
    self._fab_sprites = nil
end

-- Paint the floating controls onto the screen buffer, last in paintTo so they
-- sit on top. With `br` (an area-local region paint) only the ones it reaches
-- are painted again; the rest of the screen is untouched.
function InkAwayView:drawFabs(bb, ox, oy, br)
    if self.selecting_crop then return end
    local v = self.view
    local function reached(r)
        if not r then return false end
        if not br then return true end
        return r.x < v.area_x + br.x1 and v.area_x + br.x0 < r.x + r.w
           and r.y < v.area_y + br.y1 and v.area_y + br.y0 < r.y + r.h
    end
    local function stamp(name, r)
        bb:alphablitFrom(self:fabSprite(name, r.w, r.h), ox + r.x, oy + r.y, 0, 0, r.w, r.h)
    end
    -- zoom pill (+ over -), stamped from the cached sprite
    if not self._zoom_hidden then
        local r = self:fabRect("zoom")
        if reached(r) then stamp("zoom", r) end
    end
    -- the Pan button above it, lit while Pan is the tool
    if not self._pan_hidden then
        local r = self:fabRect("pan")
        if reached(r) then
            self._pan_fab_on = self.tool == "pan"
            self:drawPanFab(bb, ox + r.x, oy + r.y, r.w, self._pan_fab_on)
        end
    end
    -- toolbar toggle: a bare chevron, up to collapse and down to expand; hidden
    -- while a text box is edited, as its Done button sits in that corner
    if not self._bar_toggle_hidden and not self.editing_text then
        local r = self:fabRect("bar")
        if reached(r) then stamp(self._toolbar_hidden and "chev_down" or "chev_up", r) end
    end
    -- notebook bottom-bar toggle: the same chevron at the bar's top left, down
    -- to collapse and up to bring it back
    if self.notebook and not self._nbbar_toggle_hidden then
        local r = self:fabRect("nbbar")
        if reached(r) then stamp(self._nb_collapsed and "chev_up" or "chev_down", r) end
    end
    -- the way back from a followed link: a dark pill
    if not self._back_hidden then
        local r = self:fabRect("back")
        if reached(r) then
            Accent.paintRounded(bb, ox + r.x, oy + r.y, r.w, r.h, math.floor(r.h / 2))
            local t = TextWidget:new{ text = "\u{2039} " .. _("Back"), face = Font:getFace("cfont", 15), bold = true,
                fgcolor = Accent.get().text }
            local sz = t:getSize()
            t:paintTo(bb, ox + r.x + math.floor((r.w - sz.w) / 2), oy + r.y + math.floor((r.h - sz.h) / 2))
            t:free()
        end
    end
end

return InkAwayView
