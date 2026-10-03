-- Shared by the test harnesses: a scratch library folder, so the view's saving
-- never touches a real KOReader folder, and settings to go with it.
local TestEnv = {}

local dir

-- A fresh empty folder for this run, made once.
function TestEnv.libraryDir()
    if not dir then
        dir = os.tmpname()
        os.remove(dir)
        os.execute("mkdir -p '" .. dir .. "'")
    end
    return dir
end

-- Whether the settings keep the last document. Off by default, so every view a
-- test opens starts on a new drawing; the tests of reopening turn it on.
TestEnv.remember_last_doc = false

-- Settings data for a test run: the scratch library and no old session to adopt.
function TestEnv.settings(extra)
    local data = { inkaway_session_migrated = true, inkaway_library_dir = TestEnv.libraryDir() }
    for k, v in pairs(extra or {}) do data[k] = v end
    return setmetatable(data, { __newindex = function(t, k, v)
        if k ~= "inkaway_last_doc" or TestEnv.remember_last_doc then rawset(t, k, v) end
    end })
end

-- Remove the scratch folder and everything saved in it.
function TestEnv.cleanup()
    if dir then os.execute("rm -rf '" .. dir .. "'"); dir = nil end
end

return TestEnv
