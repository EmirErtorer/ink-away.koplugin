-- Tests for the pure pieces of the online image search (ink/imagesearch): URL
-- building, query encoding, and JSON normalising. The network/decode functions
-- need KOReader and are not exercised here. Pure Lua under luajit.
--
--   luajit tests/imagesearch.lua

package.path = "./?.lua;" .. package.path
local IS = require("ink/imagesearch")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local function has(s, sub, what) ok(type(s) == "string" and s:find(sub, 1, true) ~= nil, what) end
local function hasnt(s, sub, what) ok(not (type(s) == "string" and s:find(sub, 1, true)), what) end

-- ---- urlencode ---------------------------------------------------------------
do
    ok(IS.urlencode("cat") == "cat", "urlencode: plain word unchanged")
    ok(IS.urlencode("black cat") == "black%20cat", "urlencode: space -> %20")
    ok(IS.urlencode("a&b=c") == "a%26b%3Dc", "urlencode: & and = escaped")
    ok(IS.urlencode("a.b-c_d~e") == "a.b-c_d~e", "urlencode: unreserved kept")
    ok(IS.urlencode(nil) == "", "urlencode: nil -> empty")
end

-- ---- buildURL: Openverse (default) ------------------------------------------
do
    local u = IS.buildURL("openverse", "black cat", { page = 1, page_size = 12 })
    has(u, "https://api.openverse.org/v1/images/", "openverse: base url")
    has(u, "q=black%20cat", "openverse: encoded query")
    has(u, "mature=false", "openverse: SFW default present")
    has(u, "page=1", "openverse: page param")
    has(u, "page_size=12", "openverse: page_size param")
    hasnt(u, "extension=png", "openverse: no png filter unless asked")

    local up = IS.buildURL("openverse", "cat", { png_only = true, page = 3 })
    has(up, "extension=png", "openverse: png_only adds extension=png")
    has(up, "page=3", "openverse: paging carries through")

    -- an unknown provider falls back to openverse
    local uf = IS.buildURL("bogus", "cat", {})
    has(uf, "api.openverse.org", "unknown provider -> openverse")

    -- defaults when opts omitted
    local ud = IS.buildURL("openverse", "cat")
    has(ud, "page=1", "openverse: default page 1")
    has(ud, "page_size=" .. tostring(IS.PAGE_SIZE), "openverse: default page size")
end

-- ---- buildURL: Wikimedia Commons (fallback) ---------------------------------
do
    local c = IS.buildURL("commons", "castle", { page = 1, page_size = 10 })
    has(c, "commons.wikimedia.org/w/api.php", "commons: base url")
    has(c, "generator=search", "commons: search generator")
    has(c, "gsrsearch=castle", "commons: query")
    has(c, "gsrnamespace=6", "commons: file namespace")
    has(c, "gsroffset=0", "commons: page 1 -> offset 0")
    has(c, "iiurlwidth=", "commons: requests a thumbnail width")
    hasnt(c, "filemime", "commons: no png filter unless asked")

    local c2 = IS.buildURL("commons", "castle", { png_only = true, page = 3, page_size = 10 })
    has(c2, "filemime%3Aimage%2Fpng", "commons: png filter encoded into gsrsearch")
    has(c2, "gsroffset=20", "commons: page 3 * 10 -> offset 20")
end

-- ---- parse: Openverse normalising (decoder injected) ------------------------
do
    local sample = {
        result_count = 57, page_count = 5, page = 1,
        results = {
            { id = "1", title = "Cat", url = "https://x/full1.png",
              thumbnail = "https://x/thumb1.jpg", width = 800, height = 600,
              filetype = "png", license = "cc0", foreign_landing_url = "https://x/land1" },
            { id = "2", url = "https://x/full2.png" },   -- minimal, no thumbnail
            { id = "3", title = "no url" },               -- dropped: no url
        },
    }
    local decode = function() return sample end
    local out = IS.parse("openverse", "IGNORED", decode)
    ok(out ~= nil, "openverse parse: returns a table")
    ok(#out.results == 2, "openverse parse: drops results with no url")
    ok(out.total == 57, "openverse parse: total from result_count")
    ok(out.page_count == 5, "openverse parse: page_count carried")
    ok(out.results[1].thumb == "https://x/thumb1.jpg", "openverse parse: thumbnail mapped")
    ok(out.results[1].full == "https://x/full1.png", "openverse parse: full url mapped")
    ok(out.results[1].mime == "image/png", "openverse parse: mime from filetype")
    ok(out.results[2].thumb == "https://x/full2.png", "openverse parse: thumb falls back to url")
end

-- ---- parse: Commons normalising ---------------------------------------------
do
    local sample = {
        query = { pages = {
            ["7"] = { title = "File:Castle.png", imageinfo = {
                { url = "https://c/full.png", thumburl = "https://c/thumb.png",
                  width = 1024, height = 768, mime = "image/png",
                  descriptionurl = "https://c/desc" } } },
            ["9"] = { title = "File:NoInfo.png" },   -- dropped: no imageinfo
        } },
    }
    local out = IS.parse("commons", "IGNORED", function() return sample end)
    ok(out ~= nil and #out.results == 1, "commons parse: one usable result")
    ok(out.results[1].full == "https://c/full.png", "commons parse: full url mapped")
    ok(out.results[1].thumb == "https://c/thumb.png", "commons parse: thumb url mapped")
    ok(out.results[1].source == "https://c/desc", "commons parse: description url as source")
end

-- ---- parse: bad input --------------------------------------------------------
do
    ok(select(1, IS.parse("openverse", "")) == nil, "parse: empty body -> nil")
    ok(select(1, IS.parse("openverse", "not json", function() error("boom") end)) == nil,
        "parse: decoder error -> nil (never throws)")
    local out = IS.parse("openverse", "{}", function() return {} end)
    ok(out ~= nil and #out.results == 0, "parse: empty object -> no results, no crash")
end

-- ---- buildURL: provider selection is exact --------------------------------
do
    -- searchPage builds a single-provider request when opts.provider is set; here
    -- we just confirm PROVIDERS is the two keyless catalogues, no web-engine.
    ok(#IS.PROVIDERS == 2, "providers: exactly two keyless catalogues")
    ok(IS.PROVIDERS[1] == "openverse" and IS.PROVIDERS[2] == "commons",
        "providers: openverse first, then commons")
    ok(IS.parseDDG == nil and IS._ddgSearch == nil, "no DuckDuckGo code remains")
end

print(string.format("imagesearch: %d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
