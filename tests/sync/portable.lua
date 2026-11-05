-- Finding a notebook's pictures and PDF on another reader (ink/sync/portable.lua),
-- and the hook in Project.deserialize. Needs KOReader's SHA-2 code (KO_SRC).
--   luajit tests/sync/portable.lua
local KO = os.getenv("KO_SRC") or (os.getenv("HOME") .. "/koreader-emulator")
package.path = "./?.lua;./tests/mock/?.lua;" .. KO .. "/base/?.lua;" .. package.path
require("testenv")
local Portable = require("ink/sync/portable")
local Project = require("ink/project")
local Refs = require("ink/sync/refs")

local checks, fails = 0, 0
local function eq(a, b, what)
    checks = checks + 1
    if a ~= b then fails = fails + 1; print("FAIL: " .. what .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")") end
end

local here = {
    ["/lib/Images/a.png"] = true, ["/lib/Imported/doc.pdf"] = true, ["/lib/b.png"] = true,
    ["/lib/.attachments/" .. Portable.attachId("/sdcard/Pics/c.png") .. "/c.png"] = true,
    ["/elsewhere/exists.png"] = true,
}
local has = function(p) return here[p] == true end

eq(Portable.resolve("/elsewhere/exists.png", "/lib", has), "/elsewhere/exists.png", "a path that exists is used as it is")
eq(Portable.resolve("/mnt/us/koreader/ink away/Images/a.png", "/lib", has), "/lib/Images/a.png", "found by its ending under the library")
eq(Portable.resolve("/mnt/onboard/.adds/koreader/ink away/Imported/doc.pdf", "/lib", has), "/lib/Imported/doc.pdf", "a PDF too")
eq(Portable.resolve("/sdcard/Pics/c.png", "/lib", has), "/lib/.attachments/" .. Portable.attachId("/sdcard/Pics/c.png") .. "/c.png", "a file from outside the library is among the attachments")
eq(Portable.resolve("/other/place/b.png", "/lib", has), "/other/place/b.png", "a bare name alone is too loose a match: left as it was")
eq(Portable.resolve("/nowhere/x.png", "/lib", has), "/nowhere/x.png", "nothing found: unchanged")
eq(Portable.resolve("/nowhere/x.png", nil, has), "/nowhere/x.png", "no library: unchanged")
eq(Portable.resolve(nil, "/lib", has), nil, "no path")
eq(Portable.attachId("/a/b.png") == Portable.attachId("/a/b.png"), true, "the same path gives the same id on every reader")
eq(Portable.attachId("/a/b.png") ~= Portable.attachId("/a/c.png"), true, "other paths, other ids")

-- a whole notebook
local data = {
    w = 1, h = 1, ops = { { kind = "image", path = "/mnt/us/koreader/ink away/Images/a.png" }, { kind = "ink", pts = {} } },
    pages = { { ops = { { kind = "image", path = "/x/ink away/Images/a.png", src_path = "/y/Imported/doc.pdf" } } } },
    template = { pdf_path = "/q/Imported/doc.pdf" }, bg = "/z/ink away/Images/a.png",
}
Portable.apply(data, "/lib", has)
eq(data.ops[1].path, "/lib/Images/a.png", "a picture on the page")
eq(data.pages[1].ops[1].path, "/lib/Images/a.png", "a picture in a notebook page")
eq(data.pages[1].ops[1].src_path, "/lib/Imported/doc.pdf", "its source")
eq(data.template.pdf_path, "/lib/Imported/doc.pdf", "the PDF the notebook writes on")
eq(data.bg, "/lib/Images/a.png", "the background")
eq(data.ops[2].pts ~= nil, true, "other strokes are untouched")

-- the references in a notebook's text
local text = 'return {["pdf_path"]="/a/b c.pdf",["x"]={["kind"]="image",["path"]="/a/p.png",["src_path"]="/a/p.png"},["bg"]="/a/bg.png",["path"]="bad\\\\path",}'
local paths = Refs.paths(text)
eq(#paths, 3, "each path once, the odd one left out")
eq(table.concat(paths, ","), "/a/p.png,/a/b c.pdf,/a/bg.png", "in the order found by kind")

-- the hook in Project.deserialize does nothing until a library folder is set
local src = 'return {["w"]=1,["h"]=1,["ops"]={{["kind"]="image",["path"]="/old/ink away/Images/a.png"}}}'
Portable.root = nil
eq(Project.deserialize(src).ops[1].path, "/old/ink away/Images/a.png", "unchanged without a library")
local tmp = os.tmpname(); os.remove(tmp); os.execute("mkdir -p '" .. tmp .. "/Images'")
local f = io.open(tmp .. "/Images/a.png", "wb"); f:write("x"); f:close()
Portable.root = function() return tmp end
eq(Project.deserialize(src).ops[1].path, tmp .. "/Images/a.png", "with one, the picture is found")
Portable.root = function() error("broken") end
eq(Project.deserialize(src).ops[1].path, "/old/ink away/Images/a.png", "a failure in the hook never stops a notebook from opening")
Portable.root = nil
os.execute("rm -rf '" .. tmp .. "'")

print(string.format("portable: %d checks, %d failed", checks, fails))
os.exit(fails == 0 and 0 or 1)
