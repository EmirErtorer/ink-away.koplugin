-- Scripted driver for Ink Away in the real emulator. Runs the scenario named by
-- INKAWAY_DRIVE_SCRIPT, logs to INKAWAY_DRIVE_OUT/drive.log, then quits
-- KOReader. Dev only: emulator/run.sh copies it into a throwaway KOReader home,
-- and it does nothing unless that variable is set.
local Device = require("device")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Drive = WidgetContainer:extend{ name = "inkawaydrive", is_doc_only = false }

function Drive:init()
    local script = os.getenv("INKAWAY_DRIVE_SCRIPT")
    if not script or Drive._ran then return end
    Drive._ran = true
    local out = os.getenv("INKAWAY_DRIVE_OUT")
    local log = io.open(out .. "/drive.log", "w")
    local H = { pass = 0, fail = 0, out = out, home = os.getenv("KO_HOME") }
    function H.say(...)
        local t = {}
        for i = 1, select("#", ...) do t[#t + 1] = tostring((select(i, ...))) end
        log:write(table.concat(t, " "), "\n"); log:flush()
    end
    function H.check(c, what)
        if c then H.pass = H.pass + 1 else H.fail = H.fail + 1 end
        H.say(c and "PASS" or "FAIL", what)
    end
    function H.shot(name) Device.screen:shot(out .. "/" .. name .. ".png") end
    function H.find(name)
        local s = UIManager._window_stack
        for i = #s, 1, -1 do
            local w = s[i].widget
            if w.name == name then return w end
        end
    end
    function H.view() return H.find("inkaway_view") end
    function H.top() local s = UIManager._window_stack; return s[#s] and s[#s].widget end
    function H.stack()
        local t = {}
        for _, e in ipairs(UIManager._window_stack) do t[#t + 1] = tostring(e.widget.name or e.widget.id or "?") end
        return table.concat(t, ",")
    end
    function H.open()
        local fm = require("apps/filemanager/filemanager").instance
        local plugin = fm["ink-away"] or fm.inkaway
        plugin:openCanvas()
    end
    -- a finger stroke in drawing-area coordinates
    function H.stroke(v, x0, y0, x1, y1)
        local ay = v.view.area_y
        v:onIaTouch(nil, { pos = { x = x0, y = ay + y0 } })
        for k = 1, 6 do
            local t = k / 6
            v:onIaPan(nil, { pos = { x = x0 + (x1 - x0) * t, y = ay + y0 + (y1 - y0) * t } })
        end
        v:onIaPanRelease(nil, { pos = { x = x1, y = ay + y1 } })
    end
    function H.load(path) return require("ink/project").load(path) end
    -- a real tap, sent through KOReader's own gesture dispatch
    function H.tap(x, y)
        local Event = require("ui/event")
        local Geom = require("ui/geometry")
        local ges = { ges = "tap", pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = require("ui/time").now() }
        local ok, err = xpcall(function() UIManager:sendEvent(Event:new("Gesture", ges)) end, debug.traceback)
        if not ok then H.say("TAP ERROR: " .. tostring(err)) end
        return ok
    end
    -- a real hold
    function H.hold(x, y)
        local Event = require("ui/event")
        local Geom = require("ui/geometry")
        local ges = { ges = "hold", pos = Geom:new{ x = x, y = y, w = 0, h = 0 }, time = require("ui/time").now() }
        local ok, err = xpcall(function() UIManager:sendEvent(Event:new("Gesture", ges)) end, debug.traceback)
        if not ok then H.say("HOLD ERROR: " .. tostring(err)) end
        return ok
    end
    -- the text shown in a widget tree, joined
    function H.textOf(w, seen)
        seen = seen or {}
        if type(w) ~= "table" or seen[w] then return "" end
        seen[w] = true
        local t = (type(w.text) == "string") and w.text or ""
        for k, v in pairs(w) do
            if type(v) == "table" and k ~= "show_parent" and k ~= "parent" and k ~= "ui" then t = t .. H.textOf(v, seen) end
        end
        return t
    end
    -- the painted Button in widget `w` whose label shows `text`
    function H.findButton(w, text)
        for _, b in ipairs(H.buttons(w)) do
            if H.textOf(b.label_widget or b) :find(text, 1, true) then return b end
        end
    end
    -- tap the middle of a Button
    function H.tapButton(b)
        if not b then H.say("no such button"); return false end
        return H.tap(b.dimen.x + b.dimen.w / 2, b.dimen.y + b.dimen.h / 2)
    end
    -- every Button in a widget tree, with the rect it was last painted at
    function H.buttons(w, out, seen)
        out, seen = out or {}, seen or {}
        if type(w) ~= "table" or seen[w] then return out end
        seen[w] = true
        if w.callback and w.dimen and w.dimen.w then out[#out + 1] = w end
        for k, v in pairs(w) do
            if type(v) == "table" and k ~= "show_parent" and k ~= "parent" and k ~= "ui" then H.buttons(v, out, seen) end
        end
        return out
    end
    function H.exists(path) return require("libs/libkoreader-lfs").attributes(path, "mode") ~= nil end
    local steps = {}
    function H.step(delay, fn) steps[#steps + 1] = { delay, fn } end
    local chunk, err = loadfile(script)
    if not chunk then H.say("ERROR loading scenario: " .. tostring(err)) end
    if chunk then chunk(H) end
    local function run(i)
        if i > #steps then
            H.say(string.format("DONE %d passed, %d failed", H.pass, H.fail))
            log:close()
            UIManager:scheduleIn(0.5, function() UIManager:quit() end)
            return
        end
        UIManager:scheduleIn(steps[i][1], function()
            local ok, e = pcall(steps[i][2])
            if not ok then H.fail = H.fail + 1; H.say("ERROR step " .. i .. ": " .. tostring(e)) end
            run(i + 1)
        end)
    end
    UIManager:scheduleIn(2, function() run(1) end)
end

return Drive
