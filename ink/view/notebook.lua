--[[
Notebook mode: pages, navigation, imported PDF pages as page backgrounds, and the
page menus.
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local GeomUI = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local RenderImage = require("ui/renderimage")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")
local ImageProc = require("ink/imageproc")
local Notebook = require("ink/notebook")
local Storage = require("ink/storage")
local ThumbGrid = require("ink/ui/thumbgrid")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
local FRAME = Blitbuffer.COLOR_GRAY
local fitIntoCanvasBB = ImageProc.fitIntoCanvasBB

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

-- Where a digit's ink sits inside a TextWidget's box. The box includes empty
-- ascent and descent, so centring it makes digits look high next to an icon.
-- Renders the digits once per size and scans for the first and last inked rows,
-- caching {mid, h} (ink centre from the box top, ink height) so the page counter
-- can centre and size itself to the icons. Falls back to box metrics when the
-- scan is unavailable (in tests).
function InkAwayView:digitInkMetric(face, isz, box_h)
    if self._digit_ink and self._digit_ink.key == isz then return self._digit_ink end
    local res
    pcall(function()
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

-- Render one PDF page to a canvas-sized BlitBuffer, on demand, the way KOReader
-- renders cover thumbnails (cached in its DocCache). Returns a BlitBuffer or nil.
function InkAwayView:renderPdfPage(doc, pageno, tw, th)
    if not doc then return nil end
    local Document = require("document/document")
    local W, H = tw or self.view.canvas_w, th or self.view.canvas_h
    local img
    pcall(function()
        local native = Document.getNativePageDimensions(doc, pageno)
        if not (native and native.w and native.h) then return end
        local zoom = math.min(W / native.w, H / native.h)
        -- an explicit full-page rect: without one, a page too large for
        -- KOReader's tile cache (an A4 page at fit zoom) is refused and comes back
        -- blank, while a rect renders it uncached
        local rect = GeomUI:new{ x = 0, y = 0,
            w = math.floor(native.w * zoom + 0.5), h = math.floor(native.h * zoom + 0.5) }
        local tile = Document.renderPage(doc, pageno, rect, zoom, 0, 1.0, 1.0, false)
        if tile and tile.bb then img = fitIntoCanvasBB(tile.bb:copy(), W, H) end
    end)
    return img
end

-- A bottom-bar icon from ink/icons on an opaque white tile, cached by name and
-- size. Returns nil if unavailable.
function InkAwayView:navImage(name, sz)
    self._nav_img = self._nav_img or {}
    local key = name .. "@" .. sz
    local c = self._nav_img[key]
    if c == nil then
        local ok, raw, straight = pcall(function()
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
-- Notebook mode: a multi-page canvas. Each page is an op list like a drawing, so
-- every tool works unchanged. The current page lives in self.canvas; turning a
-- page syncs it back to the Notebook model and loads the next, so only one page
-- is composed at a time.
------------------------------------------------------------------------------

-- Height of the notebook bottom bar.
function InkAwayView:nbBarHeight()
    if self._nb_collapsed then return 0 end   -- hidden via the bottom-bar toggle
    -- snug around the icon row, so the bar is shorter than the toolbar
    local isz = self._icon_sz or math.max(20, Screen:scaleBySize(26))
    return isz + 2 * Screen:scaleBySize(4)
end

-- Save the on-screen canvas back into the current notebook page. A page whose
-- ops changed since it was loaded or last synced is stamped and dropped from the
-- save cache, so the next save writes it out again.
function InkAwayView:nbSyncOut()
    local nb = self.notebook
    if not nb then return end
    nb:setCurrentOps(self.canvas.ops)
    if self.canvas.rev ~= self._page_rev then
        self._page_rev = self.canvas.rev
        nb:touch()
        if self._page_cache then self._page_cache[nb.pages[nb.index]] = nil end
        self.dirty = true
    end
end

-- Load the current notebook page into the canvas and repaint.
function InkAwayView:nbLoad()
    if not self.notebook then return end
    -- drop the previous page's image decodes so memory stays flat over many
    -- pages; composeCanvas decodes what this page uses (the bar icon cache stays)
    self:freeImageCache()
    self:loadNotebookPageBackground()   -- swap in this page's PDF image (if any)
    self.canvas:setOps(self.notebook:currentOps())
    self._page_rev = self.canvas.rev
    self.selected, self.rotating = nil, nil
    self:resetLasso()
    self:composeCanvas(); self:renderView()
    -- Like KOReader's reader, turn pages with a non-flashing refresh ("partial" on
    -- grey, "ui" on colour, where a flash takes a second or two) and flash only
    -- every few turns to clear ghosting.
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

-- Keep one open handle to the source PDF for the session, so a page turn does not
-- pay the cost of opening it again.
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
-- the ink. Only the visible page and its neighbours are kept, so a long PDF opens
-- and turns as fast as a short one.
function InkAwayView:loadNotebookPageBackground()
    local nb = self.notebook
    local t = nb and nb.template
    if not (t and t.pdf_path) then return end
    self:ensureNotebookPDF()
    local src = nb:currentSrc()      -- which source page this notebook page shows
    -- Rendering is the slow part of a page turn, so the page just left is kept
    -- (turning back is instant) and the next is rendered ahead during a pause (see
    -- prefetchPdfPage). A buffer is either the background or in the cache, never
    -- both.
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

-- Render the next page (then the previous) ahead of time, after a short pause
-- following a page turn. Any touch or pen-down cancels a pending prefetch, so it
-- never gets in the way of writing.
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

-- Step to the previous (-1) or next (+1) page.
function InkAwayView:nbGo(delta)
    if self.notebook then self:nbGoTo(self.notebook.index + delta) end
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
end

-- Go to a page: a sheet with First and Last jumps and a button that opens the
-- number keypad.
function InkAwayView:nbJumpPrompt()
    local nb = self.notebook
    if not nb then return end
    self:closeSheet("_goto_dialog")
    local content_w, gap = self:sheetWidth()
    local halfW = math.floor((content_w - gap) / 2)
    local closeSelf = function() self:closeSheet("_goto_dialog") end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Go to page"), content_w, _("Close"), closeSelf))
        add(vspan(6))
        add(self:sheetLabel(string.format(_("Page %d of %d"), nb.index, nb:count())))
        add(vspan(12))
        add(HorizontalGroup:new{ align = "center",
            self:actionButton(_("First page"), halfW, function() closeSelf(); self:nbGoTo(1) end),
            HorizontalSpan:new{ width = gap },
            self:actionButton(_("Last page"), halfW, function() closeSelf(); self:nbGoTo(nb:count()) end),
        })
        add(vspan(8))
        add(self:actionButton(_("Type a page number\u{2026}"), content_w,
            function() closeSelf(); self:promptGotoNumber() end, true))
        return content
    end
    local v = self.view
    self:showSheet("_goto_dialog", build, { bottom_y = v.area_y + v.area_h })
end

-- The page-number entry, reached from the Go-to-page sheet: a stock InputDialog
-- with the number keypad, which types reliably on every device.
function InkAwayView:promptGotoNumber()
    local nb = self.notebook
    if not nb then return end
    self:promptText{
        title = string.format(_("Go to page (1\u{2013}%d)"), nb:count()),
        input = tostring(nb.index), input_type = "number", ok_text = _("Go"),
        on_ok = function(text)
            local n = tonumber(text)
            if n then self:nbGoTo(n) end
        end,
    }
end

-- Duplicate the current page.
function InkAwayView:nbDuplicatePage()
    if not self.notebook then return end
    self:nbSyncOut()
    self.notebook:duplicatePage()
    self:nbLoad()
    self:markDirty()
end

-- The page menu, opened by tapping the page counter in the bottom bar: go to a
-- page, the overview, duplicate and delete.
function InkAwayView:openPageMenu()
    local nb = self.notebook
    if not nb then return end
    self:closeSheet("_page_dialog")
    local content_w = self:sheetWidth()
    local closeSelf = function() self:closeSheet("_page_dialog") end
    local function act(label, cb)
        return self:actionButton(label, content_w, function() closeSelf(); cb() end)
    end
    local build = function()
        local content = VerticalGroup:new{ align = "left" }
        local function add(w) table.insert(content, w) end
        add(self:sheetTitle(_("Page"), content_w, _("Close"), closeSelf))
        add(vspan(6))
        add(self:sheetLabel(string.format(_("Page %d of %d"), nb.index, nb:count())))
        add(vspan(12))
        add(act(_("Go to page\u{2026}"), function() self:nbJumpPrompt() end))
        add(vspan(8))
        add(act(_("Page overview\u{2026}"), function() self:openPageGrid() end))
        add(vspan(8))
        add(act(_("Duplicate page"), function() self:nbDuplicatePage() end))
        add(vspan(8))
        add(act(_("Delete page"), function() self:nbDeletePage() end))
        return content
    end
    -- the sheet's bottom sits on the top of the notebook bottom bar
    local v = self.view
    self:showSheet("_page_dialog", build, { bottom_y = v.area_y + v.area_h })
end

-- Render one notebook page to a thumbnail fitting maxw x maxh, through the shared
-- compositor so it matches the page. A full-size scratch is composed, scaled down
-- and freed, so memory stays flat.
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
    local items = {}
    for i = 1, nb:count() do items[i] = { label = tostring(i), index = i, selected = (i == nb.index) } end
    local grid
    grid = ThumbGrid:new{
        title = string.format(_("Pages  (%d)"), nb:count()),
        items = items,
        start = nb.index,
        render = function(it, w, h) return self:renderPageThumb(it.index, w, h) end,
        on_pick = function(it) grid:close(); self:nbGoTo(it.index) end,
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
    self:markDirty()
end

-- Remove the current page (with a confirm; never drops below one page).
function InkAwayView:nbDeletePage()
    if not self.notebook then return end
    if self.notebook:count() <= 1 then
        UIManager:show(InfoMessage:new{ text = _("A notebook keeps at least one page."), timeout = 2 })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = _("Delete this page?"),
        ok_text = _("Delete"),
        ok_callback = function()
            self.notebook:deletePage()
            self:nbLoad()
            self:markDirty()
        end,
    })
end

-- Make `nb` the open notebook and show its current page.
function InkAwayView:enterNotebook(nb)
    self.notebook = nb
    self.nb_bar_h = self:nbBarHeight()
    self:recomputeArea()
    self:nbLoad()
    self:resetTransientMemory()     -- reclaim the previous work's memory now
end

-- Enter notebook mode with a fresh notebook using `template`
-- ({ style = "lines"|"grid"|"dots"|"blank", size = px }).
function InkAwayView:startNotebook(template)
    self:clearBackground()
    self.save_area = nil
    self:enterNotebook(Notebook.new(self.screen_w, self.screen_h, template))
end

-- Rebuild notebook mode from a loaded v2 project.
function InkAwayView:openNotebookData(data)
    self:closeNotebookPDF()
    self:clearBackground()
    self.save_area = nil
    local nb = Notebook.fromData(data)
    -- pages were drawn at their own screen size; treat them at this screen size
    nb.w, nb.h = self.screen_w, self.screen_h
    self:enterNotebook(nb)
    -- warn if the source PDF of a PDF-backed notebook is gone (the ink is safe;
    -- only the page images are missing until it is back)
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

-- Open an entire PDF as a new notebook in folder `dir`: one page per PDF page,
-- each with the PDF page as its background to write on. Pages are rendered
-- lazily on demand. It is saved at once, named after the PDF, so it is in the
-- library straight away.
function InkAwayView:startPdfNotebook(path, dir)
    local ok, doc = pcall(function() return require("document/documentregistry"):openDocument(path) end)
    if not ok or not doc then
        UIManager:show(InfoMessage:new{ text = _("Could not open that PDF.") })
        return
    end
    local pages = 1
    pcall(function() pages = doc:getPageCount() or 1 end)
    if not pages or pages < 1 then pages = 1 end
    self:beginDocument("notebook", Storage.stem(path), function()
        self:closeNotebookPDF()
        self._nb_pdf_doc, self._nb_pdf_path = doc, path
        self:clearBackground()
        self:enterNotebook(Notebook.forPdf(self.screen_w, self.screen_h, {
            style = "blank", size = self.grid_size or 40, strength = self.grid_strength or 45, pdf_path = path,
        }, pages))
    end, dir)
    self:saveDocument(true)
end

-- Pick a PDF (from KOReader's home folder) and open it as a new notebook in
-- folder `dir`.
function InkAwayView:openPdfAsNotebook(dir)
    self:pickFile(self:homeDir(), function(path)
        if not path:lower():match("%.pdf$") then
            UIManager:show(InfoMessage:new{ text = _("Please choose a PDF file.") })
            return
        end
        self:startPdfNotebook(path, dir)
    end)
end

-- The notebook paper styles, as { style, label } pairs for the choosers.
function InkAwayView:notebookStyles()
    return { { "lines", _("Lined") }, { "grid", _("Grid") }, { "dots", _("Dotted") },
        { "margin", _("Margin ruled") }, { "cornell", _("Cornell") }, { "blank", _("Blank") } }
end

-- The notebook's bottom bar, matching the toolbar's height and icons.
function InkAwayView:paintNotebookBar(bb, x, y)
    local v = self.view
    local nb = self.notebook
    local h = self.nb_bar_h
    local w = self.screen_w
    local sy0 = y + v.area_y + v.area_h
    local cy = sy0 + math.floor(h / 2)
    local BLACKC = Blitbuffer.COLOR_BLACK
    bb:paintRect(x, sy0, w, h, WHITE)
    bb:paintRect(x, sy0, w, 1, FRAME)   -- divider above the strip
    local isz = self._icon_sz or math.max(20, math.floor(h * 0.66))
    -- one nav icon (toolbar size) centred at cx
    local function icon(name, cx)
        local im = self:navImage(name, isz)
        if not im then return end
        local iw, ih = im:getWidth(), im:getHeight()
        bb:blitFrom(im, math.floor(cx - iw / 2), math.floor(cy - ih / 2), 0, 0, iw, ih)
    end
    local pad = math.floor(isz * 0.4)              -- comfort padding around each tap zone
    local zone = isz + 2 * pad
    -- Prev (far left) and Next (far right)
    local prev_cx = x + math.floor(zone / 2)
    local next_cx = x + w - math.floor(zone / 2)
    icon("nav_prev", prev_cx)
    icon("nav_next", next_cx)
    self._nb_prev = { x = math.floor(prev_cx - zone / 2), y = sy0, w = zone, h = h }
    self._nb_next = { x = math.floor(next_cx - zone / 2), y = sy0, w = zone, h = h }
    -- the page counter "index / count", centred; the slash is drawn (the font's
    -- is taller than the digits) and the digits are centred on their measured ink
    local face = self:faceAt("cfont", math.max(10, math.floor(isz * 0.95)))
    local idxw = TextWidget:new{ text = tostring(nb.index), face = face, fgcolor = BLACKC }
    local cntw = TextWidget:new{ text = tostring(nb:count()), face = face, fgcolor = BLACKC }
    local iw, ih = idxw:getSize().w, idxw:getSize().h
    local ink = self:digitInkMetric(face, isz, ih)
    local ty = math.floor(cy - ink.mid)                -- centre the digits' ink on cy
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
    -- add-page icon, just right of the counter, clamped clear of Next
    local margin = math.floor(isz * 0.5)
    local icx = math.floor(x + w / 2 + counter_w / 2 + margin + isz / 2)
    local max_icx = (next_cx - math.floor(zone / 2)) - margin - math.floor(isz / 2)
    if icx > max_icx then icx = max_icx end
    icon("newpage", icx)
    self._nb_plus = { x = math.floor(icx - zone / 2), y = sy0, w = zone, h = h }
    -- the counter opens the page menu; its tap zone spans the gap between Prev
    -- and the add-page icon
    local count_x = self._nb_prev.x + self._nb_prev.w
    self._nb_count = { x = count_x, y = sy0, w = math.max(1, self._nb_plus.x - count_x), h = h }
end

return InkAwayView
