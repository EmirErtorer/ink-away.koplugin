package.path = "./?.lua;" .. package.path
local root = "/tmp/inkaway-ocr-job-test"
os.execute("mkdir -m 700 " .. root .. " >/dev/null 2>&1")
os.remove(root .. "/result")
os.remove(root .. "/result.part")

local scheduled, clock, child_fn, child_done, terminated, reaped = {}, 100, nil, false, false, false
local schedule_failure, kill_finishes = false, true
local callback_count = 0
local UIManager = { scheduleIn = function(_, _, fn)
    if schedule_failure then error("scheduler unavailable") end
    scheduled[#scheduled + 1] = fn
end }
local util = {
    runInSubProcess = function(fn) child_fn = fn; return 1234 end,
    isSubProcessDone = function(_, wait)
        assert(not wait, "process polling must not block")
        if child_done then reaped = true end
        return child_done
    end,
    terminateSubProcess = function() terminated = true; child_done = kill_finishes end,
}
package.loaded["ffi"] = {
    cdef = function() end,
    new = function() return {} end,
    C = { mkdtemp = function()
        os.execute("mkdir -m 700 " .. root .. " >/dev/null 2>&1")
        return root
    end },
    string = function() return root end,
}
package.loaded["libs/libkoreader-lfs"] = { attributes = function() return "directory" end }
package.loaded["ffi/util"] = util
package.loaded["ui/uimanager"] = UIManager
package.loaded["socket"] = { gettime = function() return clock end }
local Job = require("ink/ocr/job")
local checks, failures = 0, 0
local function ok(value, message)
    checks = checks + 1
    if not value then failures = failures + 1; print("FAIL: " .. message) end
end
local function tick()
    local fn = table.remove(scheduled, 1)
    assert(fn, "expected a scheduled poll")
    fn()
end

local received, received_err
local cancel, err = Job.start(function() return "recognized" end, function(text, why)
    received, received_err = text, why
end)
ok(cancel ~= nil and err == nil, "starts a background job")
child_fn()
local partial = assert(io.open(root .. "/result.part", "wb")); partial:write("unfinished"); partial:close()
child_done = true
tick()
ok(received == "recognized" and received_err == nil, "reads the completed result")
ok(io.open(root .. "/result", "rb") == nil and io.open(root .. "/result.part", "rb") == nil,
    "cleans result and partial IPC files")

child_done, received = false, nil
cancel = assert(Job.start(function() return "next serial job" end, function(text) received = text end))
child_fn()
child_done = true
tick()
ok(received == "next serial job", "starts the next job only after the previous job exits")

child_done, received, received_err = false, nil, nil
cancel = assert(Job.start(function() return "discard me" end, function(text, why)
    callback_count = callback_count + 1
    received, received_err = text, why
end))
child_fn()
local err_file = assert(io.open(root .. "/result", "rb"))
ok(err_file:read("*a"):find("discard me", 1, true) ~= nil, "worker publishes its private IPC result")
err_file:close()
cancel()
local second = Job.start(function() return "second" end, function() end)
ok(second == nil, "cancellation keeps the global slot until process completion")
child_done = true
tick()
ok(received == nil and received_err == nil and callback_count == 0,
    "cancellation discards the worker result without invoking the callback")

child_done, received, received_err, terminated, reaped = false, nil, nil, false, false
cancel = assert(Job.start(function() return "late" end, function(text, why)
    callback_count = callback_count + 1
    received, received_err = text, why
end))
local partial = assert(io.open(root .. "/result.part", "wb")); partial:write("unfinished"); partial:close()
clock = clock + 90
tick()
ok(terminated and reaped, "deadline terminates and reaps the process")
ok(received == nil and received_err == "OCR timed out.", "deadline reports a safe timeout")
ok(io.open(root .. "/result.part", "rb") == nil, "timeout cleanup removes partial IPC data")

schedule_failure, kill_finishes, child_done, terminated, reaped = true, false, false, false, false
local unavailable = Job.start(function() return "orphan" end, function()
    callback_count = callback_count + 1
end)
ok(unavailable == nil and terminated, "scheduler failure kills the child and returns safely")
ok(Job.start(function() return "blocked" end, function() end) == nil,
    "scheduler failure retains the slot until child reap")
child_done = true
schedule_failure, kill_finishes = false, true
local recovered = Job.start(function() return "after reap" end, function(text) received = text end)
ok(recovered ~= nil and reaped, "a later start nonblockingly reaps the orphan before reusing the slot")
child_done = false
child_fn()
child_done = true
tick()
ok(received == "after reap", "job scheduling recovers after orphan reap")

package.loaded["ffi"] = nil
package.loaded["ffi/util"] = nil
package.loaded["ui/uimanager"] = nil
package.loaded["socket"] = nil
os.remove(root .. "/result")
os.remove(root .. "/result.part")
print(("ocr_job: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
