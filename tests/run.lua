-- Run the whole Ink Away test suite:  luajit tests/run.lua
-- (core logic under real FFI, then the view against a mock KOReader env)
local suites = { "tests/core.lua", "tests/library.lua", "tests/raster_identity.lua", "tests/text.lua", "tests/recognize.lua", "tests/stylus.lua", "tests/imagesearch.lua", "tests/hwr.lua", "tests/wipe.lua", "tests/view.lua", "tests/rawfinger.lua", "tests/hwrnet.lua", "tests/hwrwords.lua", "tests/search.lua", "tests/trash.lua", "tests/transform.lua", "tests/links.lua", "tests/pentest.lua", "tests/pens.lua", "tests/wash.lua", "tests/smudge.lua", "tests/penset.lua", "tests/actions.lua", "tests/bookink.lua", "tests/cut.lua", "tests/readerview.lua", "tests/einkdrive.lua", "tests/guide.lua" }
-- Some suites need a KOReader checkout with the emulator built in it:
-- ~/koreader-emulator unless KO_SRC says otherwise (see tests/README.md).
local KO_SRC = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
local function exists(path)
    local f = io.open(path)
    if f then f:close() end
    return f ~= nil
end
-- The Scribe pen/palm replay needs KOReader's real input code from the checkout.
if exists(KO_SRC .. "/frontend/device/input.lua") then
    suites[#suites + 1] = "tests/scribe/replay.lua"
    suites[#suites + 1] = "tests/gestures.lua"
end
-- Pixel-level checks on KOReader's real C blitter, run with the emulator's luajit.
-- The emulator's koreader folder is found in the checkout, or set with KO_EMU.
local EMU = os.getenv("KO_EMU")
if not EMU then
    local p = io.popen("ls -d '" .. KO_SRC .. "'/koreader-emulator-*/koreader 2>/dev/null")
    EMU = p:read("*l") or ""
    p:close()
end
local REAL = {}
if exists(EMU .. "/luajit") then
    local here = io.popen("pwd"):read("*l")
    for _, t in ipairs({ "tests/realbb/eraser.lua", "tests/realbb/colour.lua", "tests/realbb/pdfexport.lua",
        "tests/realbb/wipe.lua", "tests/realbb/accent.lua", "tests/realbb/selection.lua",
        "tests/realbb/android.lua", "tests/realbb/wash.lua", "tests/realbb/smudge.lua" }) do
        suites[#suites + 1] = t
        REAL[t] = "cd '" .. EMU .. "' && ./luajit '" .. here .. "/" .. t .. "' '" .. here .. "' 2>&1 | grep -v -e '^ffi\\.' -e '^lib_' -e '^Has monolibtic'"
    end
end
local fail = 0
-- Lint: any global read/write in the plugin outside the standard library is a
-- typo or a local used before its definition (Lua resolves it as a nil global).
do
    local allowed = {}
    for n in ("_G assert bit collectgarbage coroutine debug error getmetatable io ipairs jit load "
        .. "loadstring math next os pairs pcall print rawequal rawget rawlen rawset require select "
        .. "setfenv getfenv setmetatable string table tonumber tostring type unpack xpcall "
        .. "G_reader_settings"):gmatch("%S+") do allowed[n] = true end
    local bad = 0
    for f in io.popen("find ink -name '*.lua' | sort; echo main.lua"):lines() do
        for line in io.popen("luajit -bl " .. f):lines() do
            local name = line:match('G[GS]ET%s.-; "([%a_][%w_]*)"')
            if name and not allowed[name] then
                bad = bad + 1; print("LINT: global '" .. name .. "' in " .. f)
            end
        end
    end
    print(("lint: %d unexpected globals"):format(bad))
    if bad > 0 then fail = fail + 1 end
end
for _, s in ipairs(suites) do
    print("== " .. s .. " ==")
    local rc = os.execute(REAL[s] and ("set -o pipefail; " .. REAL[s]) or ("luajit " .. s))
    -- os.execute returns true/exit code depending on Lua version
    if rc ~= true and rc ~= 0 then fail = fail + 1 end
end
os.exit(fail == 0 and 0 or 1)
