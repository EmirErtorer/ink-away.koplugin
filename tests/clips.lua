-- The screen clips folder (ink/clips.lua): which files are clips, the settings, the
-- sweep by age, deleting all, and keeping a clip that is put on a page.
--   luajit tests/clips.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local Storage = require("ink/storage")
local Clips = require("ink/clips")
local TestEnv = require("testenv")

local root = TestEnv.libraryDir() .. "/ink away"
os.execute("mkdir -p '" .. root .. "'")
Storage.appRootPath = function() return root end
Storage.appDir = function(name)
    local d = root .. "/" .. name
    os.execute("mkdir -p '" .. d .. "'")
    return d
end

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function put(path, text)
    local f = assert(io.open(path, "wb")); f:write(text or "png"); f:close()
end

-- names
ok(Clips.isClipName("clip-1793613595-1.png") and Clips.isClipName("clip-5-12.png"), "a clip's name")
ok(not Clips.isClipName("notes.png") and not Clips.isClipName("clip-1.png") and not Clips.isClipName("clip-1-2.jpg")
    and not Clips.isClipName(nil), "other names are not clips")
ok(Clips.isClipsDir(root .. "/screen clips") and Clips.isClipsDir(root .. "/screen clips/") and not Clips.isClipsDir(root)
    and not Clips.isClipsDir(root .. "/screen clips old") and not Clips.isClipsDir(nil), "which folder is the clips folder")

-- settings
local store = {}
local function get(k) return store[k] end
local o = Clips.options(get)
ok(o.auto == true and o.days == 7, "by default clips go after a week")
store[Clips.AUTO], store[Clips.DAYS] = false, 14
o = Clips.options(get)
ok(o.auto == false and o.days == 14, "the person's choices")
store[Clips.DAYS] = "nonsense"
ok(Clips.options(get).days == 7, "a setting of the wrong kind is the default")
store[Clips.DAYS] = 0
ok(Clips.options(get).days == 7, "zero days is the default")
store[Clips.DAYS] = 9999
ok(Clips.options(get).days == 365, "days are capped")
ok(Clips.options(nil).auto and Clips.options(nil).days == 7, "no settings at all is fine")

-- the sweep
local dir = Clips.dir()
ok(dir == root .. "/screen clips", "the clips folder is made")
put(dir .. "/clip-100-1.png"); put(dir .. "/clip-100-2.png"); put(dir .. "/mine.png"); put(dir .. "/clip-x.png")
ok(Clips.count(dir) == 2, "two clips counted, other files not")
local now = os.time()
ok(Clips.sweep(dir, 7, now + 6 * 86400) == 0 and Clips.count(dir) == 2, "clips younger than the limit stay")
ok(Clips.sweep(dir, 7, now + 8 * 86400) == 2 and Clips.count(dir) == 0, "clips older than the limit go")
ok(Storage.exists(dir .. "/mine.png") and Storage.exists(dir .. "/clip-x.png"), "files that are not clips are never touched")
ok(Clips.sweep(nil, 7) == 0, "no folder, nothing")

-- automatic by the settings
put(dir .. "/clip-200-1.png")
store = { [Clips.AUTO] = false }
ok(Clips.sweepAuto(get, now + 40 * 86400) == 0 and Clips.count(dir) == 1, "off: nothing goes however old")
store = { [Clips.DAYS] = 3 }
ok(Clips.sweepAuto(get, now + 2 * 86400) == 0, "on, three days: a two day old clip stays")
ok(Clips.sweepAuto(get, now + 4 * 86400) == 1 and Clips.count(dir) == 0, "on, three days: a four day old clip goes")

-- delete all
put(dir .. "/clip-300-1.png"); put(dir .. "/clip-300-2.png")
ok(Clips.deleteAll(dir) == 2 and Clips.count(dir) == 0, "delete all removes every clip, new ones too")

-- keeping a clip that is put to use
put(dir .. "/clip-400-1.png", "picture one")
local kept = Clips.keep(dir .. "/clip-400-1.png")
ok(kept ~= dir .. "/clip-400-1.png" and kept:find("clipped images", 1, true), "a clip is copied to the kept folder: " .. tostring(kept))
local f = io.open(kept, "rb"); local data = f and f:read("*a"); if f then f:close() end
ok(data == "picture one", "the copy is the same picture")
ok(Clips.keep(dir .. "/clip-400-1.png") == kept, "a second use finds the copy")
Clips.deleteAll(dir)
ok(not Storage.exists(dir .. "/clip-400-1.png") and Storage.exists(kept), "the copy outlasts the clips folder")
ok(Clips.keep(kept) == kept, "a path already kept is as it is")
ok(Clips.keep("/somewhere/else/picture.png") == "/somewhere/else/picture.png", "other pictures are as they are")
ok(Clips.keep(dir .. "/notaclip.png") == dir .. "/notaclip.png", "a file in the folder that is not a clip is as it is")
ok(Clips.keep(nil) == nil, "no path, no path")
put(dir .. "/clip-500-1.png")
os.execute("rm -rf '" .. root .. "/clipped images'; touch '" .. root .. "/clipped images'")   -- (a file where the folder should be)
local stuck = Clips.keep(dir .. "/clip-500-1.png")
ok(stuck == dir .. "/clip-500-1.png", "a copy that cannot be made leaves the path as it was")

os.execute("rm -rf '" .. root .. "'")
print(("clips: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
