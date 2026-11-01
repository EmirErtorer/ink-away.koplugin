--[[
Low-latency ink on Supernote (the Ratta A5X2 family: Nomad, Manta). The
firmware itself has its own ink daemon that draws EMR pen strokes straight to
the panel's EPDC overlay, by far lower latency than any refresh KOReader asks
for could manage, over a raw Binder call (see ink/supernoteink.lua) -- no
koreader-base or launcher changes needed.

While driven, Ink Away hands that overlay a pen roughly matching the one in
hand (needle, highlighter or eraser; its nearest fixed grey tier; its width in
the firmware's own EMR unit) and lets it show the stroke live. The firmware
can't match Ink Away's own brushes -- texture, taper, pressure, true colour --
so this is only ever a rough preview: the real stroke is still drawn and
reconciled onto the screen the way every grey panel's live ink settles (see
fastLive, queueReconcile in ink/view/display.lua), and the overlay is cleared
once that reconciling refresh has gone out, so the firmware's preview never
lingers over or under the real ink.

The protocol is undocumented and reverse-engineered, so it's a toggle a reader
can turn off (inkaway_supernote_fast) if a firmware update ever misbehaves.

Plain Lua: the mapping and lifecycle rules here take an injectable binder
client, so they're testable without real JNI (see tests/supernotedrive.lua).
ink/supernoteink.lua is the real one, used when none is given.
]]

local SupernoteInk = require("ink/supernoteink")

local SupernoteDrive = {}

local state = nil    -- the claimed overlay, shared by every open view
local detected = nil -- SupernoteInk.isAvailable()'s answer, once known

-- Firmware pen kinds the pen in hand can look like: a highlighter-style mark
-- for the "Mark" group of pens (semi-transparent, wide), the needle (a plain
-- uniform line) for everything else that isn't the eraser.
local MARK_STYLES = { highlighter = true, felttip = true, wash = true }

-- Luminance -> the firmware's nearest fixed grey tier (it has no true RGB).
local function colorTier(rgb)
    local r = (rgb and rgb[1]) or 0
    local g = (rgb and rgb[2]) or 0
    local b = (rgb and rgb[3]) or 0
    local lum = 0.299 * r + 0.587 * g + 0.114 * b
    if lum < 64 then return SupernoteInk.Color.BLACK end
    if lum < 128 then return SupernoteInk.Color.DARK_GRAY end
    if lum < 192 then return SupernoteInk.Color.GRAY end
    return SupernoteInk.Color.LIGHT_GRAY
end

-- A stroke width in screen px -> the firmware's EMR size unit. There's no
-- documented exact mapping, just a usable range (also used by
-- penannotate.koplugin, which recovered the same protocol).
local function widthToEmr(px)
    local emr = math.floor((px or 3) * 100)
    if emr < 200 then emr = 200 end
    if emr > 2400 then emr = 2400 end
    return emr
end
local function eraserToEmr(px)
    return math.max(400, math.floor((px or 12) * 50))
end

-- Is the Supernote ink binder present on this device? A tri-state cache, like
-- EinkDrive.detect; `ink` lets tests inject a fake client instead of probing
-- the real one.
function SupernoteDrive.detect(ink)
    if detected ~= nil and not ink then return detected or nil end
    local SI = ink or SupernoteInk
    local ok, is_available = pcall(SI.isAvailable)
    local found = (ok and is_available) or false
    if not ink then detected = found end
    return found or nil
end

-- Claim the firmware's ink overlay for an open view (every open view shares
-- one claim; the last one out releases it). `log` warns if it fails midway.
function SupernoteDrive.acquire(ink, log)
    local SI = ink or SupernoteInk
    if state then
        if state.ink ~= SI then return false end
        state.users = state.users + 1
        return true
    end
    if not SupernoteDrive.detect(SI) then return false end
    local ok1 = pcall(SI.sendWriteAppInfo)
    local ok2 = pcall(SI.enableFullUiAuto, true)
    local ok3 = pcall(SI.clearDisableAreas)
    if not (ok1 and ok2 and ok3) then
        if log then log("Ink Away: Supernote ink overlay failed to claim, disabling") end
        return false
    end
    state = { ink = SI, users = 1, last = nil, clear_cb = nil }
    return true
end

-- One view is done with the overlay; the last one out disables it screen-wide
-- (so no stray firmware ink shows once Ink Away isn't open to reconcile it),
-- clears whatever it was showing, and gives full-UI ink back off.
function SupernoteDrive.release(width, height)
    local s = state
    if not s then return end
    s.users = s.users - 1
    if s.users > 0 then return end
    state = nil
    pcall(s.ink.setFullScreenDisable, width or 0, height or 0)
    pcall(s.ink.clearAll)
    pcall(s.ink.enableFullUiAuto, false)
end

-- Is the overlay claimed right now?
function SupernoteDrive.active()
    return state ~= nil
end

-- Push the pen in hand to the firmware overlay, only if it actually differs
-- from the last one pushed (most strokes are the same pen as the one before).
-- `style` is the ink-away pen style name (nil/"solid" for a plain line); it
-- only decides needle vs. mark, never the firmware's own look.
function SupernoteDrive.setPen(is_erase, style, width_px, rgb)
    local s = state
    if not s then return end
    local desc
    if is_erase then
        desc = { erase = true, size = eraserToEmr(width_px) }
    else
        local pen_type = MARK_STYLES[style] and SupernoteInk.Pen.MARK or SupernoteInk.Pen.NEEDLE
        desc = { pen = pen_type, size = widthToEmr(width_px), color = colorTier(rgb) }
    end
    local last = s.last
    if last and last.erase == desc.erase and last.pen == desc.pen
            and last.size == desc.size and last.color == desc.color then
        return
    end
    s.last = desc
    if desc.erase then
        pcall(s.ink.setEraser, false, desc.size)
    else
        pcall(s.ink.setPen, desc.pen, desc.size, desc.color)
    end
end

-- The real stroke has just been handed to UIManager for its reconciling
-- refresh (see runReconcile): clear the firmware's rough preview `delay_sec`
-- later, once that refresh has actually had time to reach the panel, so the
-- preview is never visible alongside or under the real ink. `uim` is
-- KOReader's UIManager (tests give a fake with the same scheduleIn/unschedule).
function SupernoteDrive.clearSoon(uim, delay_sec)
    local s = state
    if not s then return end
    if s.clear_cb then uim:unschedule(s.clear_cb) end
    s.clear_cb = s.clear_cb or function()
        local st = state
        if st then pcall(st.ink.clearAll) end
    end
    uim:scheduleIn(delay_sec or 0.3, s.clear_cb)
end

-- Forget what detect() found (tests).
function SupernoteDrive.reset()
    detected = nil
end

return SupernoteDrive
