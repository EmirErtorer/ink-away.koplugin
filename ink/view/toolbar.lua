--[[
The toolbar, switching tools, and the floating controls (the zoom pill and the
bar collapse chevrons) that fade while drawing near them.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local Paint = require("ink/paint")

local Screen = Device.screen
local HAIRLINE = Paint.HAIRLINE

local InkAwayView = {}

-- The floating zoom control. E-ink cannot reliably alpha-blend a rounded fill
-- (it paints opaque), so instead of a see-through charcoal box we use a light,
-- airy pill with a soft border and dark glyphs: it reads as a whisper-quiet
-- floating control rather than a heavy solid button, and its auto-hide (melting
-- away as the pen draws near) is what actually keeps the canvas reachable.
local FAB_FILL   = Blitbuffer.ColorRGB32(0xF0, 0xF0, 0xF0, 0xFF)
local FAB_BORDER = Blitbuffer.ColorRGB32(0xB4, 0xB4, 0xB4, 0xFF)
local FAB_GLYPH  = Blitbuffer.ColorRGB32(0x33, 0x34, 0x36, 0xFF)

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
        if ok_icon and file_icon then self:setButtonLabel(b, file_icon) end
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

-- The plugin's own directory, found from this file's path (it lives under ink/).
function InkAwayView:pluginDir()
    if self._plugin_dir then return self._plugin_dir end
    local src = debug.getinfo(1, "S").source
    self._plugin_dir = (src:match("^@(.*/)ink/")) or "./"
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
    -- This refreshes the TOOLBAR strip (the active pill moves), so the next paint
    -- must repaint the chrome -- clear any area-only flag a nested clearSelection/
    -- deselect set via areaScreenRect, or the pill move would be skipped.
    self._area_only = false
    UIManager:setDirty(self, "ui", GeomUI:new{
        x = 0, y = 0, w = self.screen_w, h = self.view.area_y })
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
    -- (not while a text box is open: the chevron would sit on its Done button)
    if not self._bar_toggle_hidden and not self.editing_text then
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

-- The zoom pill is a fixed grey rounded control. Its rounded-corner COLOUR fill is
-- a slow per-pixel path (the README's warning), and it was being redrawn on every
-- paint. Build it ONCE into a transparent-cornered alpha sprite and stamp that with
-- a cheap C alpha-blit each paint instead. Rebuilt only when its size, the screen
-- buffer type, or night-mode inversion changes -- i.e. essentially never.
function InkAwayView:zoomPillSprite(w, h)
    local typ = Screen.bb:getType()
    local inv = (Screen.bb.getInverse and Screen.bb:getInverse()) or 0
    local c = self._zoom_pill
    if c and c.w == w and c.h == h and c.type == typ and c.inv == inv then return c.bb end
    if c and c.bb then c.bb:free() end
    local S1 = math.max(1, Screen:scaleBySize(1))
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8A or typ)   -- alpha: starts transparent
    if bb.setInverse then bb:setInverse(inv) end   -- so software night mode still blits in C
    local rad = math.floor(w / 2)
    bb:paintRoundedRect(0, 0, w, h, FAB_FILL, rad)      -- fills only the rounded shape;
    bb:paintBorder(0, 0, w, h, S1, FAB_BORDER, rad)     -- corners stay transparent
    local midy = math.floor(h / 2)
    bb:paintRect(Screen:scaleBySize(10), midy, w - 2 * Screen:scaleBySize(10), S1, FAB_BORDER)
    local gw = math.floor(w * 0.34)
    local gt = math.max(2, Screen:scaleBySize(2))
    local cx = math.floor(w / 2)
    local cyTop, cyBot = math.floor(h / 4), math.floor(3 * h / 4)
    bb:paintRect(cx - math.floor(gw / 2), cyTop - math.floor(gt / 2), gw, gt, FAB_GLYPH)
    bb:paintRect(cx - math.floor(gt / 2), cyTop - math.floor(gw / 2), gt, gw, FAB_GLYPH)
    bb:paintRect(cx - math.floor(gw / 2), cyBot - math.floor(gt / 2), gw, gt, FAB_GLYPH)
    self._zoom_pill = { bb = bb, w = w, h = h, type = typ, inv = inv }
    return bb
end

-- Paint the floating controls onto the screen buffer (called last in paintTo so
-- they float on top). A light, airy pill so it never reads as a solid box.
function InkAwayView:drawFabs(bb, ox, oy)
    if self.selecting_crop then return end
    -- zoom pill (+ over -): stamp the cached sprite (the pricey rounded draw is done
    -- once, in zoomPillSprite, not per paint)
    if not self._zoom_hidden then
        local r = self:fabRect("zoom")
        if r then
            local sprite = self:zoomPillSprite(r.w, r.h)
            bb:alphablitFrom(sprite, ox + r.x, oy + r.y, 0, 0, r.w, r.h)
        end
    end
    -- toolbar toggle: a bare chevron (no pill) -- up to collapse, down to expand.
    -- Hidden while a text box is being edited, whose Done button sits in that corner.
    if not self._bar_toggle_hidden and not self.editing_text then
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

return InkAwayView
