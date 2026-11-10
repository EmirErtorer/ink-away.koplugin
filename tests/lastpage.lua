-- The page each notebook was left on (ink/lastpage.lua), headless.
--   luajit tests/lastpage.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local LastPage = require("ink/lastpage")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

local pages = { { id = 1 }, { id = 7 }, { id = 3 } }
ok(LastPage.indexOf(pages, 7) == 2 and LastPage.indexOf(pages, 9) == nil and LastPage.indexOf(pages, nil) == nil,
    "indexOf: by the page's id")
ok(LastPage.get(nil, "/a") == nil and LastPage.get({}, "/a") == nil, "get: nothing kept")
local m = LastPage.put(nil, "/lib/a.inkaway", 7, 100)
ok(m and LastPage.get(m, "/lib/a.inkaway") == 7, "put: kept")
ok(LastPage.put(m, "/lib/a.inkaway", 7, 200) == nil, "put: the same page again changes nothing")
local m2 = LastPage.put(m, "/lib/a.inkaway", 3, 200)
ok(m2 and LastPage.get(m2, "/lib/a.inkaway") == 3 and LastPage.get(m, "/lib/a.inkaway") == 7,
    "put: a new page, in a new table")
ok(LastPage.put(m, nil, 3) == nil and LastPage.put(m, "/x", nil) == nil, "put: needs a path and a page")
-- the oldest go past the limit
local big = {}
for i = 1, LastPage.MAX do big["/n" .. i] = { id = 1, t = i } end
local b2 = LastPage.put(big, "/new", 5, 10000)
local n = 0
for _k in pairs(b2) do n = n + 1 end
ok(n == LastPage.MAX and b2["/n1"] == nil and b2["/n2"] ~= nil and LastPage.get(b2, "/new") == 5,
    "put: past the limit, the oldest goes")
-- moved: a file, and every notebook in a folder
local mv = { ["/lib/a.inkaway"] = { id = 2 }, ["/lib/f/b.inkaway"] = { id = 4 }, ["/lib/fx.inkaway"] = { id = 6 } }
local r = LastPage.moved(mv, "/lib/a.inkaway", "/lib/z.inkaway")
ok(r and LastPage.get(r, "/lib/z.inkaway") == 2 and LastPage.get(r, "/lib/a.inkaway") == nil, "moved: a notebook")
r = LastPage.moved(mv, "/lib/f", "/lib/g")
ok(r and LastPage.get(r, "/lib/g/b.inkaway") == 4 and LastPage.get(r, "/lib/fx.inkaway") == 6,
    "moved: a folder's notebooks, not a file whose name starts the same")
ok(LastPage.moved(mv, "/elsewhere", "/x") == nil, "moved: none there, nothing changes")

print(("lastpage: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
