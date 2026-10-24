-- Real fork/IPC and native PNG work, with only the UI scheduler substituted.
local REPO = arg[1] or "."
require("setupkoenv")
package.path = REPO .. "/?.lua;" .. package.path
local socket = require("socket")
local pending = {}
package.loaded["ui/uimanager"] = { scheduleIn = function(_, _, fn) pending[#pending + 1] = fn end }
local Job = require("ink/ocr/job")
local Image = require("ink/ocr/image")
local Canvas = require("ink/canvas")
local c = Canvas.new(200, 150)
c.ops = { { kind = "ink", width = 4, pts = { 30, 50, 150, 50 } } }
local snapshot = assert(Image.snapshot(c, c.ops))
local received
assert(Job.start(function()
    local png = assert(Image.png(snapshot))
    assert(png:sub(1, 8) == "\137PNG\13\10\26\10")
    return "native background result"
end, function(text, err) assert(not err, err); received = text end))
assert(not Job.start(function() end, function() end), "one job globally before child completes")
local function drain()
    local deadline = socket.gettime() + 5
    while #pending > 0 and socket.gettime() < deadline do
        table.remove(pending, 1)()
        socket.sleep(0.01)
    end
    assert(#pending == 0, "native child finished and was collected")
end
drain()
assert(received == "native background result", "real worker returned PNG-processing result through private IPC")
local called = false
local cancel = assert(Job.start(function() socket.sleep(0.05); return "discard" end,
    function() called = true end))
cancel()
assert(not Job.start(function() end, function() end), "cancel retains active slot")
drain()
assert(not called, "cancelled native result never calls UI")
received = nil
assert(Job.start(function() return "next" end, function(text) received = text end))
drain()
assert(received == "next", "slot reusable only after native reap")
print("native OCR job: fork, PNG worker, private IPC, single-flight, cancel and reap passed")
