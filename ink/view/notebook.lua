--[[
Notebook mode: pages, navigation, imported PDF pages as page backgrounds, and the
page menus.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local RenderImage = require("ui/renderimage")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local ImageProc = require("ink/imageproc")
local Notebook = require("ink/notebook")
local IconMenu = require("ink/ui/iconmenu")

local Screen = Device.screen
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB

local InkAwayView = {}

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
    -- A page turn does not flash the whole screen every time (on a colour panel a
    -- flash costs ~1-2s even for a blank page, and on grey it is what made turning
    -- pages feel slow). Like KOReader's own reader, turn with a non-flashing refresh
    -- ("partial" on grey, which suits text pages; "ui" on colour) and flash only
    -- every few turns to clear accumulated ghosting.
    self._turns_since_full = (self._turns_since_full or 0) + 1
    local every = (self.ghost_clean and self.ghost_clean > 0) and self.ghost_clean or 6
    if self._turns_since_full >= every then
        self._turns_since_full = 0
        UIManager:setDirty(self, "full")
    elseif self:colourPanel() then
        self:refresh(self, "full")   -- -> non-flashing "ui" on colour
    else
        UIManager:setDirty(self, "partial")
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
    self:freePdfCache()
    self._bg_src = nil
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
    -- Rendering a PDF page is the slow part of a page turn, so the page just left
    -- is kept (turning back is instant) and the next one is rendered ahead while
    -- you read (see prefetchPdfPage). A buffer is either the background or in the
    -- cache, never both, so nothing else ever sees a cached buffer.
    local cache = self._pdf_cache or {}
    self._pdf_cache = cache
    if self.bg_bb and self._bg_src and self._bg_src ~= src and not cache[self._bg_src] then
        cache[self._bg_src] = self.bg_bb             -- keep the page we are leaving
    elseif self.bg_bb then
        self.bg_bb:free()
    end
    self.bg_bb = nil
    local img = src and cache[src]
    if img then cache[src] = nil
    elseif src then img = self:renderPdfPage(self._nb_pdf_doc, src) end
    self.bg_bb = img            -- canvas-sized already; nil if the render failed
    self._bg_src = img and src or nil
    self.bg_rgba = nil          -- built on demand at export, never per page turn
    self.bg_path = t.pdf_path
    self.export_bg = true
    self:trimPdfCache()
    UIManager:unschedule(self._pdf_prefetch_cb)
    UIManager:scheduleIn(1.0, self._pdf_prefetch_cb)
end

-- The source pages of the notebook pages either side of the current one.
function InkAwayView:pdfNeighbourSrcs()
    local nb = self.notebook
    local out = {}
    if not nb then return out end
    for _, d in ipairs({ 1, -1 }) do
        local pg = nb.pages[nb.index + d]
        if pg and pg.src then out[#out + 1] = pg.src end
    end
    return out
end

-- Keep only the neighbours of the current page (at most two pages) in the cache.
function InkAwayView:trimPdfCache()
    local cache = self._pdf_cache
    if not cache then return end
    local keep = {}
    for _, s in ipairs(self:pdfNeighbourSrcs()) do keep[s] = true end
    for s, bb in pairs(cache) do
        if not keep[s] then bb:free(); cache[s] = nil end
    end
end

-- Render the next page (then the previous) ahead of time, once the reader has been
-- idle a moment after a page turn. Any touch or pen-down cancels a pending
-- prefetch, so it never runs in the way of writing.
function InkAwayView:prefetchPdfPage()
    local nb = self.notebook
    if self.closing or not (nb and nb.template and nb.template.pdf_path and self._nb_pdf_doc) then return end
    if self.capturing or self.editing_text or (self._pen_state and self._pen_state.down)
            or self._export_job then
        return
    end
    local cache = self._pdf_cache or {}
    self._pdf_cache = cache
    for _, s in ipairs(self:pdfNeighbourSrcs()) do
        if not cache[s] and s ~= self._bg_src then
            local img = self:renderPdfPage(self._nb_pdf_doc, s)
            if img then cache[s] = img end
            -- one page per idle slot: if there is another to do, come back later
            UIManager:scheduleIn(0.5, self._pdf_prefetch_cb)
            return
        end
    end
end

function InkAwayView:freePdfCache()
    UIManager:unschedule(self._pdf_prefetch_cb)
    if self._pdf_cache then
        for _, bb in pairs(self._pdf_cache) do bb:free() end
        self._pdf_cache = nil
    end
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

-- Duplicate the current page.
function InkAwayView:nbDuplicatePage()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:duplicatePage()
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
    local PageGrid = require("ink/ui/pagegrid")
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

-- Start a new notebook: ask which ruling to use, then enter notebook mode.
function InkAwayView:newNotebook()
    local function begin(style)
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

return InkAwayView
