-- Real delegate with no KOReader dependencies.
package.path = "./?.lua;" .. package.path
local Delegate = require("ink/delegate")
local checks = 0
local function check(value, message) checks = checks + 1; assert(value, message) end
local errors, calls = {}, {}
---@type InkDelegate<{ value: integer }>
local event = Delegate.new(function(err) errors[#errors + 1] = err end)
local off_second, off_added
local first = true
local off_first = event:subscribe(function(payload)
    calls[#calls + 1] = 1
    payload.value = 99
    off_second()
    if first then
        first = false
        off_added = event:subscribe(function(p)
            check(p.value == 7, "new observer receives its own payload")
            calls[#calls + 1] = 4
        end)
    end
    error("observer failed")
end)
off_second = event:subscribe(function() calls[#calls + 1] = 2 end)
event:subscribe(function(p)
    check(p.value == 7, "payload mutation is isolated")
    calls[#calls + 1] = 3
end)
local function payload() return { value = 7 } end
event:emit(payload)
check(table.concat(calls) == "13", "order, immediate unsubscribe and deferred subscribe")
check(#errors == 1, "callback failure reported without stopping dispatch")
calls = {}
event:emit(payload)
check(table.concat(calls) == "134", "new listener participates in the next emission")
off_first(); off_first(); off_added()
---@type InkDelegate<{ value: integer }>
local disposing = Delegate.new(function() error("unexpected observer error") end)
local later = false
disposing:subscribe(function() disposing:dispose() end)
local off_later = disposing:subscribe(function() later = true end)
disposing:emit(payload)
check(not later, "dispose cancels listeners in an active snapshot")
disposing:dispose(); off_later(); off_later()
disposing:emit(payload)
check(not later, "disposed emission is empty")
check(not pcall(disposing.subscribe, disposing, function() end), "cannot subscribe after disposal")
check(not pcall(event.subscribe, event, 42), "invalid callbacks rejected")
event:dispose()
print(("delegate: %d checks, 0 failures"):format(checks))
