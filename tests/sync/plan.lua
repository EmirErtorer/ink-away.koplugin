-- The decision table of the cloud sync (ink/sync/plan.lua), every case.
--   luajit tests/sync/plan.lua
package.path = "./?.lua;" .. package.path
local Plan = require("ink/sync/plan")
local checks, fails = 0, 0
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end

local BASE = { rev = "r1", lsize = 10, lmtime = 100, lhash = "h1" }
local function known(l, r) return Plan.decide(BASE, l, r) end

-- every pair for a file synced before
local T = {
    { "same", "same", "none" }, { "changed", "same", "upload" }, { "same", "changed", "download" },
    { "changed", "changed", "conflict" }, { "absent", "same", "delete_remote" },
    { "absent", "changed", "download" }, { "same", "absent", "delete_local" },
    { "changed", "absent", "upload" }, { "absent", "absent", "forget" },
}
for _i, t in ipairs(T) do eq(known(t[1], t[2]), t[3], "known " .. t[1] .. "/" .. t[2]) end

-- a file never synced
eq(Plan.decide(nil, "changed", "absent"), "upload", "new here goes up")
eq(Plan.decide(nil, "absent", "changed"), "download", "new in the cloud comes down")
eq(Plan.decide(nil, "absent", "absent"), "none", "nowhere is nothing")
eq(Plan.decide(nil, "changed", "changed", function() return true end), "adopt", "same bytes on both sides are adopted")
eq(Plan.decide(nil, "changed", "changed", function() return false end), "conflict", "different bytes are a conflict")
eq(Plan.decide(nil, "changed", "changed"), "conflict", "not knowing is a conflict, never an overwrite")
local asked = false
Plan.decide(BASE, "same", "same", function() asked = true end)
eq(asked, false, "the comparison is not asked when it does not matter")

-- no pair ever loses a change: a deletion is only acted on when the other side is unchanged
for _i, l in ipairs({ "absent", "same", "changed" }) do
    for _j, r in ipairs({ "absent", "same", "changed" }) do
        local a = known(l, r)
        if a == "delete_remote" then eq(r, "same", "never delete a remote edit") end
        if a == "delete_local" then eq(l, "same", "never delete a local edit") end
    end
end

-- the local state
eq(Plan.localState(BASE, nil), "absent", "gone")
eq(Plan.localState(nil, { size = 1, mtime = 1 }), "changed", "never synced is changed")
eq(Plan.localState(BASE, { size = 10, mtime = 100 }), "same", "same size and time")
eq(Plan.localState(BASE, { size = 11, mtime = 100 }, function() return "h2" end), "changed", "other size, other hash")
eq(Plan.localState(BASE, { size = 10, mtime = 200 }, function() return "h1" end), "same", "touched but the same bytes")
eq(Plan.localState(BASE, { size = 10, mtime = 200 }, function() return "h9" end), "changed", "same size, other bytes")
eq(Plan.localState(BASE, { size = 10, mtime = 200 }), "changed", "cannot tell is changed")

-- written in the second of the sync: the bytes decide, not the time
local fresh = { rev = "r1", lsize = 10, lmtime = 100, lhash = "h1", synced = 101 }
eq(Plan.localState(fresh, { size = 10, mtime = 100 }, function() return "h1" end), "same", "same second, same bytes")
eq(Plan.localState(fresh, { size = 10, mtime = 100 }, function() return "h2" end), "changed", "same second, other bytes")

-- the remote state
eq(Plan.remoteState(BASE, nil), "absent", "deleted in the cloud")
eq(Plan.remoteState(BASE, { rev = "r1" }), "same", "same revision")
eq(Plan.remoteState(BASE, { rev = "r2" }), "changed", "other revision")
eq(Plan.remoteState(nil, { rev = "r1" }), "changed", "unknown to us")

print(string.format("plan: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
