--[[
Text rendering and formatting: fonts and the measuring context handed to the text
engine (ink/text.lua), styles and the format menu, and the clipboard.
Part of InkAwayView (see ink/view.lua).
]]

local ffi = require("ffi")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local InkGeom = require("ink/geom")
local Text = require("ink/text")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

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
    local FontMenu = require("ink/ui/fontmenu")
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
    self:closeSheet("_text_fmt")
    self:hideClipBubble()
    self:hideTextKeyboard()
    local gap = Screen:scaleBySize(10)
    local content_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.84)
    -- close the sheet and bring the keyboard back so the result shows while typing
    local function done()
        self:closeSheet("_text_fmt")
        if self.editing_text then self:showTextKeyboard() end
    end
    local build = function()
        local sel = self:textEffectiveSel()
        local has_clip = self:clipboardText() ~= nil
        -- a row of equal buttons filling content_w exactly
        local function row(items)
            local n = #items
            local bw = math.floor((content_w - (n - 1) * gap) / n)
            local g = HorizontalGroup:new{ align = "center" }
            for i, it in ipairs(items) do
                local w = (i == n) and (content_w - (n - 1) * (bw + gap)) or bw
                local enabled = it.enabled ~= false
                local b = self:actionButton(it.label, w, enabled and it.cb or function() end, it.active)
                if not enabled then
                    b.enabled = false                                   -- no tap flash either
                    if b.label_widget then b.label_widget.fgcolor = Blitbuffer.Color8(0xA0) end
                end
                g[#g + 1] = b
                if i < n then g[#g + 1] = HorizontalSpan:new{ width = gap } end
            end
            return g
        end
        local function style(label, key)
            return { label = label, active = self:textStyleActive(key),
                     cb = function() self:textToggleStyle(key); done() end }
        end
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) content[#content + 1] = w end
        add(self:sheetTitle(_("Format"), content_w, _("Done"), done))
        add(vspan(4))
        add(TextWidget:new{ text = sel and _("Applies to the selected word or text")
                or _("Applies to what you type next"),
            face = Font:getFace("cfont", 14), fgcolor = Blitbuffer.Color8(0x66) })
        add(vspan(12))
        add(row({ style(_("Bold"), "b"), style(_("Italic"), "i"), style(_("Underline"), "u") }))
        add(vspan(8))
        add(row({ style(_("Strike"), "s"), style(_("Highlight"), "hl"),
            { label = "A\u{2212}", cb = function() self:textStepSize(-1); done() end },
            { label = "A+", cb = function() self:textStepSize(1); done() end } }))
        add(vspan(8))
        add(row({ { label = "\u{2022} " .. _("List"), cb = function() self:textToggleBullet("disc"); done() end },
                  { label = "1. " .. _("List"), cb = function() self:textToggleBullet("number"); done() end } }))
        add(vspan(8))
        add(row({ { label = _("Copy"), enabled = sel ~= nil, cb = function() self:textCopy(false); done() end },
                  { label = _("Cut"), enabled = sel ~= nil, cb = function() self:textCopy(true); done() end },
                  { label = _("Paste"), enabled = has_clip, cb = function() self:textPaste(); done() end } }))
        return content
    end
    -- The keyboard is hidden while the sheet is open, so the sheet takes its place
    -- at the bottom of the drawing area, leaving the text box visible above it.
    local v = self.view
    self:showSheet("_text_fmt", build, { bottom_y = v.area_y + v.area_h,
        on_close = function() if self.editing_text then self:showTextKeyboard() end end })
end

-- ---- clipboard: paste bubble, copy / cut ---------------------------------
-- A long press inside the text box being edited shows a small "Paste" bubble
-- above the finger, the way phones do; tapping it inserts KOReader's clipboard
-- (whatever was copied in the reader, a dictionary, another text field...) at
-- the caret, replacing any selection. The format menu (a selection, or the Aa
-- button) also has Copy / Cut / Paste. The bubble is drawn by the canvas itself,
-- so the keyboard below keeps working while it shows.
local CLIP_MAX = 5000   -- longest paste, in characters (a huge one would stall the layout)

-- KOReader's clipboard text cleaned up for a text box (line breaks unified, tabs
-- as spaces, other control characters dropped, capped at CLIP_MAX characters).
-- Returns the text and whether it was shortened, or nil when there is none.
function InkAwayView:clipboardText()
    local inp = Device.input
    if not (inp and inp.getClipboardText) then return nil end
    local ok, s = pcall(inp.getClipboardText)
    if not ok or type(s) ~= "string" or s == "" then return nil end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    "):gsub("[%z\1-\8\11-\31\127]", "")
    if s == "" then return nil end
    if Text.ulen(s) > CLIP_MAX then return Text.usub(s, 0, CLIP_MAX), true end
    return s, false
end

function InkAwayView:textPaste()
    self:hideClipBubble()
    if not self.editing_text then return end
    local s, shortened = self:clipboardText()
    if not s then self:showNotice(_("The clipboard is empty.")); return end
    self:textBreakCoalesce()
    self:textMark("paste")            -- the whole paste is one undo step
    self:textDeleteSelIfAny()
    local style = self._text_pending_style or nil
    self.text_cur = Text.insert(self.editing_text, self.text_cur, s, style)
    self._text_pending_style = nil
    self:textBreakCoalesce()          -- typing after it starts a new step
    self:afterTextEdit()
    if shortened then
        self:showNotice(string.format(_("Pasted the first %d characters."), CLIP_MAX))
    end
end

-- Copy (or cut) the selection -- or the word under the caret -- to the clipboard.
function InkAwayView:textCopy(cut)
    self:hideClipBubble()
    if not self.editing_text then return end
    local sel = self:textEffectiveSel()
    if not sel or Text.selEmpty(sel) then return end
    local s = Text.plainRange(self.editing_text, sel)
    if s == "" then return end
    local inp = Device.input
    if inp and inp.setClipboardText then pcall(inp.setClipboardText, s) end
    if cut then
        self:textBreakCoalesce()
        self:textMark("delete")
        self.text_cur = Text.deleteRange(self.editing_text, sel)
        self.text_sel = nil
        self:textBreakCoalesce()
        self:afterTextEdit()
    else
        self:showNotice(_("Copied"))
    end
end

-- The bubble widget: a black pill with the clipboard icon and "Paste". Built
-- once and kept; only its position changes.
function InkAwayView:clipBubbleWidget()
    if self._clip_widget then return self._clip_widget end
    local isz = math.max(16, math.floor((self._icon_sz or Screen:scaleBySize(28)) * 0.8))
    local icon = IconWidget:new{ file = self:pluginDir() .. "ink/icons/clipboard.svg",
        width = isz, height = isz }
    icon.invert = true   -- renders on white; inverted it reads white on the black pill
    local label = TextWidget:new{ text = _("Paste"), face = self:faceAt("cfont", math.floor(isz * 0.85)),
        fgcolor = WHITE, bold = true }
    local pad = Screen:scaleBySize(10)
    local h = math.max(isz, label:getSize().h) + 2 * pad
    self._clip_widget = FrameContainer:new{
        background = Blitbuffer.COLOR_BLACK, bordersize = 0, radius = math.floor(h / 2),
        padding = pad, padding_left = math.floor(pad * 1.6), padding_right = math.floor(pad * 1.8),
        margin = 0,
        HorizontalGroup:new{ align = "center", icon, HorizontalSpan:new{ width = pad }, label },
    }
    return self._clip_widget
end

-- Show the bubble just above screen point (sx, sy), kept inside the drawing area
-- and above the keyboard; below the finger when there is no room above.
function InkAwayView:showClipBubble(sx, sy)
    if not self.editing_text then return end
    self:hideClipBubble()
    local sz = self:clipBubbleWidget():getSize()
    local w, h = sz.w, sz.h
    local v = self.view
    local gap, lift = Screen:scaleBySize(8), Screen:scaleBySize(40)
    local x = math.floor(sx - w / 2)
    x = math.max(v.area_x + gap, math.min(v.area_x + v.area_w - w - gap, x))
    local bottom = math.min(v.area_y + v.area_h, self:keyboardTop()) - gap
    local y = sy - lift - h
    if y < v.area_y + gap then y = sy + lift end
    y = math.max(v.area_y + gap, math.min(bottom - h, y))
    self._clip_bubble = { x = x, y = y, w = w, h = h }
    UIManager:setDirty(self, "ui", GeomUI:new{ x = x, y = y, w = w, h = h })
end

function InkAwayView:hideClipBubble()
    local b = self._clip_bubble
    if not b then return end
    self._clip_bubble, self._clip_press = nil, nil
    if not self.closing then
        UIManager:setDirty(self, "ui", GeomUI:new{ x = b.x, y = b.y, w = b.w, h = b.h })
    end
end

function InkAwayView:inClipBubble(pos)
    local b = self._clip_bubble
    return b and pos and InkGeom.inRect(pos.x, pos.y, b) or false
end

-- A long press at `pos` while a box is being edited: offer to paste there. The
-- touch that began it has already put the caret under the finger.
function InkAwayView:textHoldAt(pos)
    if not (self.editing_text and pos) then return false end
    if self:textZone(pos.x, pos.y) ~= "inside" then return false end
    if self:textHasSel() then return false end   -- a selection gets the format menu
    if not self:clipboardText() then
        self:showNotice(_("The clipboard is empty."))
        return true
    end
    self:showClipBubble(pos.x, pos.y)
    return true
end

return InkAwayView
