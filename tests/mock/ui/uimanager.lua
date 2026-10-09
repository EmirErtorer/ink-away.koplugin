local M = { refreshes = {}, shown = nil, closed = false, scheduled = {}, _window_stack = {} }
function M:setDirty(widget, mode, region)
    M.refreshes[#M.refreshes + 1] = { widget = widget, mode = mode, region = region }
end
function M:show(w)
    -- model the real UIManager: push onto the window stack (so leak tests can see a
    -- view that was never closed), then fire onShow.
    if w then M._window_stack[#M._window_stack + 1] = { widget = w } end
    M.shown = w
    if w and w.onShow then w:onShow() end
end
function M:close(w)
    -- remove EVERY stack entry for this widget (matches real UIManager close), then
    -- fire onCloseWidget once.
    for i = #M._window_stack, 1, -1 do
        if M._window_stack[i].widget == w then table.remove(M._window_stack, i) end
    end
    M.closed = true
    if w and w.onCloseWidget then w:onCloseWidget() end
end
-- Paint a widget in place (a sheet rebuilt): give it a size, as painting would.
function M:widgetRepaint(w)
    if w and w.movable and not w.movable.dimen then
        local ok, sz = pcall(function() return w.movable:getSize() end)
        w.movable.dimen = require("ui/geometry"):new{ x = 0, y = 0,
            w = ok and sz and sz.w or 0, h = ok and sz and sz.h or 0 }
    end
end
-- Store scheduled callbacks by identity so tests can fire the coalesce timer.
function M:scheduleIn(_, fn) M.scheduled[fn] = true end
function M:nextTick(fn) M.scheduled[fn] = true end
function M:unschedule(fn) M.scheduled[fn] = nil end
-- Run every pending scheduled callback (models the event loop firing timers).
function M.fireScheduled()
    local fns = {}
    for fn in pairs(M.scheduled) do fns[#fns + 1] = fn end
    M.scheduled = {}
    for _, fn in ipairs(fns) do fn() end
end
-- Count of still-pending scheduled callbacks (a leak check: closures over a closed
-- view that were never unscheduled keep the view alive and firing).
function M.pendingCount()
    local n = 0
    for _ in pairs(M.scheduled) do n = n + 1 end
    return n
end
function M.stackCount()
    return #M._window_stack
end
function M.reset()
    M.refreshes = {}; M.shown = nil; M.closed = false; M.scheduled = {}; M._window_stack = {}
end
function M.last() return M.refreshes[#M.refreshes] end
return M
