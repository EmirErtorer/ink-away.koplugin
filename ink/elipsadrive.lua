--[[
Fast ink on the original Kobo Elipsa. Each update of its screen holds KOReader
until the panel has taken it, and meanwhile no pen or finger frame is read, so
the ink trailed well behind the nib (#45). While Ink Away is open there, its
fast updates go to a helper process instead (ink/elipsaworker.lua), which waits
on the panel while KOReader goes on reading the pen.

One update is with the helper at a time. Everything drawn meanwhile becomes one
rectangle, sent next, so the screen catches up with the pen rather than
replaying where it was. Any other refresh (a menu, a full refresh), a turn of
the screen or KOReader closing the screen first waits for the helper, stops it
and shows what was left, so updates keep KOReader's order. The helper starts
again with the next fast update. If it fails, the updates are made as before.

Only on the Elipsa of 2021 (KOReader's Kobo_europa), not the Sage or the Elipsa
2E. Plain Lua: the screen and the helper are passed in, so the headless tests
drive it.
]]
local ElipsaDrive = {}
local state
local POLL_SEC = 0.01

-- Is this the original Elipsa, with the screen its helper needs?
function ElipsaDrive.supported(device, screen)
    return device.model == "Kobo_europa" and type(device.isSunxi) == "function" and device:isSunxi()
        and screen and screen.fd and screen.fd >= 0 and screen.data ~= nil
        and screen.layer ~= nil and screen.marker_data ~= nil and screen.waveform_fast ~= nil
        and type(screen.mech_refresh) == "function" and true or false
end

-- Keep all changed pixels while a slower driver call is in progress.
local function union(a, b)
    if not b then return a end
    if not a then return b end
    local x, y = math.min(a.x, b.x), math.min(a.y, b.y)
    a.w, a.h = math.max(a.x + a.w, b.x + b.w) - x, math.max(a.y + a.h, b.y + b.h) - y
    a.x, a.y = x, y
    return a
end

-- Take over the fast updates for an open view (the views open at once share
-- it). `uim` is KOReader's UIManager; `factory` starts the helper (the tests
-- give one that blocks like the panel, without forking).
function ElipsaDrive.acquire(device, screen, uim, log, factory)
    if state then
        if state.screen ~= screen or state.broken then return false end
        state.users = state.users + 1
        return true
    end
    if not ElipsaDrive.supported(device, screen) then return false end
    local s = { screen = screen, users = 1, uim = uim, log = log, hooks = {} }
    local refresh = screen.mech_refresh
    factory = factory or function() return require("ink/elipsaworker").start(screen, refresh) end

    -- A failed transport returns its outstanding rectangle to the caller for a
    -- synchronous repaint. Nothing is silently lost on startup or worker failure.
    local function stop(failed)
        uim:unschedule(s.tick)
        if s.worker then
            if not s.worker:close(failed) and log then log("Ink Away: Elipsa handwriting mode could not be disabled") end
            s.worker = nil
        end
        s.busy = nil
    end
    local function fail(reason)
        s.pending = union(s.pending, s.busy)
        s.broken = true
        stop(true)
        if log then log("Ink Away: Elipsa refresh worker failed; using normal refreshes", reason or "transport failed") end
    end
    local function complete(wait)
        if not s.busy then return true end
        local marker = s.worker:poll(wait)
        if marker == nil then return false end
        if marker == false then fail(); return false end
        screen.marker_data[0] = marker
        s.busy = nil
        return true
    end
    local function send()
        if not s.pending or s.busy or s.broken then return end
        if not s.worker then
            local ok, worker, err = pcall(factory)
            if not ok or not worker then fail(ok and err or worker); return end
            s.worker = worker
        end
        s.busy, s.pending = s.pending, nil
        if not s.worker:send(s.busy) then fail() end
    end
    local function repaint()
        local r = s.pending
        s.pending = nil
        if r then refresh(screen, false, false, screen.waveform_fast, r.x, r.y, r.w, r.h) end
    end

    -- Fence the worker before UI waveforms, rotation, waiting, or closing ION.
    function s.barrier()
        uim:unschedule(s.tick)
        if s.busy then complete(true) end
        if not s.broken then
            send()
            if s.busy then complete(true) end
        end
        stop(s.broken)
        repaint()
    end
    -- Poll without blocking the input loop and submit the newest pending union.
    function s.tick()
        if state ~= s then return end
        complete(false)
        send()
        if s.broken then repaint() end
        if s.busy then uim:scheduleIn(POLL_SEC, s.tick) end
    end

    -- Preserve other plugins' wrappers, including ones installed after this one.
    local function hook(name, wrapper)
        local orig = screen[name]
        if type(orig) ~= "function" then return end
        local h = { own = rawget(screen, name) }
        h.wrapper = function(fb, ...)
            if state ~= s then return orig(fb, ...) end
            return wrapper(orig, fb, ...)
        end
        s.hooks[name], screen[name] = h, h.wrapper
    end
    hook("mech_refresh", function(orig, fb, no_merge, flashing, mode, x, y, w, h, ...)
        if not s.broken and not no_merge and not flashing and mode == fb.waveform_fast
            and not fb._just_rotated and x and y and w and h and w > 1 and h > 1 then
            s.pending = union(s.pending, { x = x, y = y, w = w, h = h })
            uim:unschedule(s.tick)
            s.tick()
            return
        end
        s.barrier()
        return orig(fb, no_merge, flashing, mode, x, y, w, h, ...)
    end)
    for _, name in ipairs({ "setRotationMode", "reinit", "close", "refreshWaitForLastImp" }) do
        hook(name, function(orig, fb, ...)
            s.barrier()
            return orig(fb, ...)
        end)
    end
    state = s
    return true
end

-- Are the fast updates going to the helper?
function ElipsaDrive.active() return state ~= nil and not state.broken end

-- The last view out drains work and restores the screen before freeing buffers.
function ElipsaDrive.release()
    local s = state
    if not s then return end
    s.users = s.users - 1
    if s.users > 0 then return end
    s.barrier()
    state = nil
    for name, h in pairs(s.hooks) do
        if rawget(s.screen, name) == h.wrapper then s.screen[name] = h.own end
    end
end

return ElipsaDrive
