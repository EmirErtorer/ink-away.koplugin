-- KOReader's real text rendering (RenderText over FreeType, with the emulator's
-- Noto fonts) under the repo's mocks, for the realbb suites that check text
-- pixels. Run from the emulator's koreader folder, as the realbb suites are:
--   local RealText = dofile(REPO .. "/tests/realbb/realtext.lua"); RealText.install()
-- Every font name maps to Noto Sans (a path to a .ttf that exists is used as it
-- is), sized as KOReader's Font:getFace sizes it (by Screen:scaleBySize). The
-- on-screen keyboard is a stand-in RealText.keyboard_h px tall (300 by default).
local RealText = {}

function RealText.install()
    local here = io.popen("pwd"):read("*l")
    local Screen = require("device").screen
    local Freetype = require("ffi/freetype")
    local regular = here .. "/fonts/noto/NotoSans-Regular.ttf"
    local faces = {}
    local Font = { fallbacks = {} }
    function Font:getFace(name, size)
        size = size or 18
        local px = Screen:scaleBySize(size)
        local file = regular
        if type(name) == "string" and name:match("%.[ot]tf$") then
            local f = io.open(name)
            if f then f:close(); file = name end
        end
        local key = file .. "@" .. px
        local face = faces[key]
        if not face then
            face = { ftsize = Freetype.newFaceSize(file, px), size = px, orig_size = size,
                hash = key, realname = file }
            faces[key] = face
        end
        return face
    end
    package.loaded["ui/font"] = Font
    -- the real RenderText, with a plain table for its glyph cache
    local Cache = { new = function(_, _o)
        local c = { t = {} }
        function c:check(k) return self.t[k] end
        function c:insert(k, v) self.t[k] = v end
        return c
    end }
    local chunk = assert(loadfile(here .. "/frontend/ui/rendertext.lua"))
    local function req(n)
        if n == "cache" then return Cache end
        if n == "ui/font" then return Font end
        return require(n)
    end
    setfenv(chunk, setmetatable({ require = req }, { __index = _G }))
    package.loaded["ui/rendertext"] = chunk()
    -- a keyboard that only takes its place at the bottom of the screen
    package.loaded["ui/widget/virtualkeyboard"] = { new = function(_, o)
        o = o or {}
        local h = RealText.keyboard_h or 300
        o.dimen = { x = 0, y = Screen:getHeight() - h, w = Screen:getWidth(), h = h }
        return o
    end }
    RealText.Font = Font
    return Font
end

return RealText
