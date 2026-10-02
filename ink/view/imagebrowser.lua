--[[
The online image browser: a paged grid over keyless image catalogues, used only
when the reader chooses to browse (the network side is ink/imagesearch.lua).
Part of InkAwayView (see ink/view.lua).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local logger = require("logger")
local _ = require("gettext")
local Paint = require("ink/paint")
local Storage = require("ink/storage")
local ToggleRow = require("ink/ui/controls").ToggleRow

local Screen = Device.screen
local TILE_BG = Paint.TILE_BG

local function vspan(px) return VerticalSpan:new{ width = Screen:scaleBySize(px) } end

local InkAwayView = {}

------------------------------------------------------------------------------
-- Online image browser: a small e-ink grid over keyless image APIs (Openverse,
-- Wikimedia Commons). Consistent with the tool sheets (rounded IconMenu, black
-- pills, sliding toggles), paged with Prev/Next rather than scrolling, and
-- entirely optional -- see ink/imagesearch.lua for the network/parse pieces.
------------------------------------------------------------------------------

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
    -- Don't stack the query editor over the open browser sheet. That sheet is a
    -- full-screen modal, and an InputDialog shown on top of it comes up with an
    -- on-screen keyboard that cannot reach the field -- you see the keyboard but
    -- can't type or re-search (which is why the FIRST search, with no sheet under
    -- it, worked, but refining did not). So close the sheet while editing and bring
    -- it straight back. Closing it this way (UIManager:close, not its tap-close)
    -- keeps the query, results and thumbnails, so nothing is refetched on Cancel.
    local reopen = false
    if not is_initial and self._image_browser_dialog then
        self:closeSheet("_image_browser_dialog")
        reopen = true
    end
    local function backToBrowser()
        if reopen and self._image_browser then self:showImageBrowserSheet() end
    end
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
            { text = _("Cancel"), id = "close", callback = function()
                self:closeImageSearchPrompt(); backToBrowser() end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local q = dialog:getInputText() or ""
                    self:closeImageSearchPrompt()
                    q = q:gsub("^%s+", ""):gsub("%s+$", "")
                    if q == "" then backToBrowser(); return end   -- nothing typed: just go back
                    if is_initial or not self._image_browser then
                        self:openImageBrowser(q)
                    else
                        self._image_browser.query = q
                        self._image_browser.page = 1
                        self:showImageBrowserSheet()   -- bring the sheet back first...
                        self:imageBrowserFetch()        -- ...then load the new query into it
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
    self:closeSheet("_img_search_dialog")
end

-- (Re)create and show the browser sheet from the CURRENT browser state, without
-- starting a new search. Used to open the browser and to bring it back after the
-- query editor closes. Closing the sheet with UIManager:close (below and in the
-- query editor) only repaints -- it does NOT run on_close -- so the browser state
-- (query, results, thumbnails) survives a close/reopen; only a tap-outside
-- (onCloseMenu) tears the session down.
function InkAwayView:showImageBrowserSheet()
    if not self._image_browser then return end
    self:closeSheet("_image_browser_dialog")
    self:showSheet("_image_browser_dialog", function(menu) return self:imageBrowserBuild(menu) end, {
        -- tap-outside close: tear the whole session down like the Done button does
        on_close = function()
            self:closeImageSearchPrompt(); self:freeThumbs()
            self._image_browser = nil
        end })
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
    self:showImageBrowserSheet()
    self:imageBrowserFetch()
end

-- Close the browser completely: the search box, the sheet, its thumbnails, and the
-- session state (so the next "Browse online" starts fresh, not with the old query).
function InkAwayView:onImageBrowserClose()
    self:closeImageSearchPrompt()
    self:closeSheet("_image_browser_dialog")
    self:freeThumbs()
    self._image_browser = nil
    UIManager:setDirty("all", "ui")   -- repaint the whole screen so nothing lingers
end

-- Build the browser sheet: title, a search bar, the source selector, the PNG/full-res toggles, the
-- thumbnail grid, and a Prev/Next footer.
function InkAwayView:imageBrowserBuild(menu)
    local st = self._image_browser or {}
    local GREY = Blitbuffer.ColorRGB32(0x80, 0x80, 0x80, 0xFF)
    local content_w, gap = self:sheetWidth()

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
    local frame_pad = Screen:scaleBySize(18)   -- the sheet panel's padding (ink/ui/iconmenu.lua)
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
                    row[#row + 1] = self:imageBrowserCell(st, i, cell_w, cell_h)
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
    return content
end

-- One grid cell: a rounded tappable tile holding the thumbnail. A tap and a
-- long-press do the same thing -- ask to add the image -- since a plain tap is
-- what most people try first (paging has its own buttons, so a tap can't page).
function InkAwayView:imageBrowserCell(st, index, cell_w, cell_h)
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
    if bb then
        local pad = Screen:scaleBySize(6)
        -- `fgcolor` is unused by ImageWidget, but Button's tap-highlight inverts
        -- `label_widget.fgcolor` whenever `text` is set (ours is ""), so it MUST be a
        -- real colour. Without it a plain tap crashed KOReader indexing a nil field
        -- (a long-press took a different feedback path, which is why only tapping a
        -- result crashed). Same fix as brushWaveTile.
        self:setButtonLabel(b, ImageWidget:new{ image = bb, width = cell_w - 2 * pad, height = cell_h - 2 * pad,
            scale_factor = 0, image_disposable = false, fgcolor = Blitbuffer.COLOR_BLACK })
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
    -- kept for good (unlike the thumbnails): projects refer to images by path
    local dir = Storage.appDir("online images")
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

return InkAwayView
