--[[
Elipsa-only live refreshes, using the handwriting ioctl and a display worker.
One refresh is in flight; everything drawn meanwhile becomes one pending union,
never a queue of old pen positions. Non-live refreshes and layout changes drain
and stop the worker first, preserving KOReader's ordering and marker tracking.
]]
local Drive = {}
local state
local POLL_SEC = 0.01

-- Restrict this experiment to the original Elipsa and its ION/sunxi backend.
function Drive.supported(device, screen)
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

-- Start sharing the screen hook between open drawing views. Factory injection
-- lets tests model a blocking driver without forking or needing the device.
function Drive.acquire(device, screen, ui, log, factory)
    if state then
        if state.screen ~= screen or state.broken then return false end
        state.users = state.users + 1
        return true
    end
    if not Drive.supported(device, screen) then return false end
    local s = { screen = screen, users = 1, ui = ui, log = log, hooks = {} }
    local refresh = screen.mech_refresh
    factory = factory or function() return require("ink/elipsaworker").start(screen, refresh) end

    -- A failed transport returns its outstanding rectangle to the caller for a
    -- synchronous repaint. Nothing is silently lost on startup or worker failure.
    local function stop(failed)
        ui:unschedule(s.tick)
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
        ui:unschedule(s.tick)
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
        if s.busy then ui:scheduleIn(POLL_SEC, s.tick) end
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
            ui:unschedule(s.tick)
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

-- Is the Elipsa experiment available for the open drawing views?
function Drive.active() return state ~= nil and not state.broken end

-- The last view out drains work and restores the screen before freeing buffers.
function Drive.release()
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

return Drive
