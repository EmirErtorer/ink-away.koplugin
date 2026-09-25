--[[
Online image search for the image tool -- a tiny, offline-optional client over
keyless image APIs. Ink Away never *needs* a network; this is used only when the
reader explicitly chooses to browse online.

The pure pieces (URL building, query encoding, JSON normalising) live at the top
and are unit-tested without a KOReader environment. The network fetch and image
decoding lazily require KOReader modules, so the file still loads for the tests.

Providers (both keyless, HTTPS, safe-for-work):
  * openverse -- api.openverse.org, openly/CC-licensed media, filters to PNG with
    extension=png, mature=false by default. The default.
  * commons   -- Wikimedia Commons MediaWiki API, filters to PNG with
    filemime:image/png. The fallback; proven on-device (KOReader's own Wikipedia
    lookup uses this same API).

A "transparent only" search maps to a PNG-format filter: these catalogues'
PNG results are dominated by transparent graphics (icons, stickers, clip-art).
Format is all an API can filter on -- true per-pixel alpha is only knowable after
decoding the full image, which is too costly for a grid, so we don't claim more.
]]

local ImageSearch = {}

ImageSearch.PAGE_SIZE = 6        -- results per page (a snappy 3-wide, 2-tall grid;
                                 -- fetched one image at a time in the main loop, so
                                 -- a smaller page stays responsive)
ImageSearch.THUMB_MAX = 240      -- px, longest side of a grid thumbnail
ImageSearch.FULL_MAX  = 1400     -- px cap on the added image when "full res" is off
ImageSearch.USER_AGENT = "InkAway/3 KOReader plugin (https://github.com/EmirErtorer/ink-away.koplugin)"

-- Commons first: its MediaWiki API returns real, small, reliable thumbnails
-- (iiurlwidth), which keeps the grid snappy; Openverse (CC/SFW) is the fallback.
-- Openverse's own thumbnail proxy is unreliable (frequent 424), so it is only
-- reached when Commons returns nothing.
ImageSearch.PROVIDERS = { "commons", "openverse" }

-- URL-encode one component (keep RFC 3986 unreserved, percent-escape the rest).
function ImageSearch.urlencode(s)
    return (tostring(s or ""):gsub("[^%w%-%_%.%~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- Build the search request URL.
--   opts = { png_only = bool, page = N (1-based), page_size = N }
function ImageSearch.buildURL(provider, query, opts)
    opts = opts or {}
    local page = math.max(1, tonumber(opts.page) or 1)
    local size = tonumber(opts.page_size) or ImageSearch.PAGE_SIZE
    if provider == "commons" then
        local search = query or ""
        if opts.png_only then search = search .. " filemime:image/png" end
        local offset = (page - 1) * size
        return table.concat({
            "https://commons.wikimedia.org/w/api.php",
            "?action=query&format=json&generator=search",
            "&gsrsearch=", ImageSearch.urlencode(search),
            "&gsrnamespace=6&gsrlimit=", tostring(size),
            "&gsroffset=", tostring(offset),
            "&prop=imageinfo&iiprop=url|size|mime",
            "&iiurlwidth=", tostring(ImageSearch.THUMB_MAX),
        })
    end
    -- default: Openverse
    local url = table.concat({
        "https://api.openverse.org/v1/images/",
        "?q=", ImageSearch.urlencode(query or ""),
        "&mature=false",
        "&page=", tostring(page),
        "&page_size=", tostring(size),
    })
    if opts.png_only then url = url .. "&extension=png" end
    return url
end

-- The JSON decoder: rapidjson if present (fast C), else KOReader's bundled json.
-- Cached. Tests pass their own decoder to parse() and never hit this.
function ImageSearch._decoder()
    if ImageSearch.__decode then return ImageSearch.__decode end
    local ok, rj = pcall(require, "rapidjson")
    if ok and type(rj) == "table" and rj.decode then
        ImageSearch.__decode = function(s) return rj.decode(s) end
    else
        local j = require("json")
        ImageSearch.__decode = function(s) return j.decode(s) end
    end
    return ImageSearch.__decode
end

-- Normalise a provider's JSON body into a uniform shape:
--   { results = { { thumb, full, w, h, mime, title, license, source } ... },
--     page_count = N or nil, total = N }
-- `decode` is optional (an injected decoder for tests). Returns nil, err on
-- failure. Never throws.
function ImageSearch.parse(provider, body, decode)
    if type(body) ~= "string" or body == "" then return nil, "empty response" end
    decode = decode or ImageSearch._decoder()
    local ok, data = pcall(decode, body)
    if not ok or type(data) ~= "table" then return nil, "bad json" end
    local out = { results = {}, total = 0 }
    if provider == "commons" then
        local pages = data.query and data.query.pages
        if type(pages) == "table" then
            for _, pg in pairs(pages) do
                local ii = pg.imageinfo and pg.imageinfo[1]
                if type(ii) == "table" and ii.thumburl and ii.url then
                    out.results[#out.results + 1] = {
                        thumb = ii.thumburl, full = ii.url,
                        w = tonumber(ii.width), h = tonumber(ii.height), mime = ii.mime,
                        title = pg.title, source = ii.descriptionurl,
                    }
                end
            end
        end
        return out   -- commons has no clean page_count; caller pages until empty
    end
    -- openverse
    out.total = tonumber(data.result_count) or 0
    out.page_count = tonumber(data.page_count)
    if type(data.results) == "table" then
        for _, r in ipairs(data.results) do
            if type(r) == "table" and r.url then
                out.results[#out.results + 1] = {
                    thumb = r.thumbnail or r.url, full = r.url,
                    w = tonumber(r.width), h = tonumber(r.height),
                    mime = r.filetype and ("image/" .. tostring(r.filetype)) or nil,
                    title = r.title, license = r.license, source = r.foreign_landing_url,
                }
            end
        end
    end
    return out
end

------------------------------------------------------------------------------
-- Network + decoding (lazy KOReader requires; not exercised by the unit tests).
------------------------------------------------------------------------------

-- Blocking-but-bounded HTTPS GET into memory. Returns body, or nil, err. Mirrors
-- KOReader's Wikipedia fetch: socket.http auto-routes https, socketutil bounds
-- the time. A curl fallback covers platforms where LuaSec is flaky (some Android).
function ImageSearch.httpGet(url, block_to, total_to)
    local ok_http, http = pcall(require, "socket/http")
    local ok_su, socketutil = pcall(require, "socketutil")
    local ok_sk, socket = pcall(require, "socket")
    if ok_http and ok_su and ok_sk and http and socketutil and socket then
        local sink_t = {}
        socketutil:set_timeout(block_to or socketutil.LARGE_BLOCK_TIMEOUT,
            total_to or socketutil.LARGE_TOTAL_TIMEOUT)
        local ok, code = pcall(function()
            return socket.skip(1, http.request{
                url = url, method = "GET",
                headers = { ["User-Agent"] = ImageSearch.USER_AGENT, ["Accept"] = "*/*" },
                sink = socketutil.table_sink(sink_t),
            })
        end)
        socketutil:reset_timeout()
        if ok and type(code) == "number" then          -- a real HTTP response arrived
            local body = table.concat(sink_t)
            if code >= 200 and code <= 299 and body ~= "" then return body end
            return nil, "http " .. tostring(code)       -- a valid non-2xx: no point trying curl
        end
        -- only a genuine socket/SSL failure (threw, or no numeric code) falls through
    end
    return ImageSearch._curlGet(url)
end

-- Last-resort GET via the system curl (guards platforms where LuaSec fails). All
-- pcall/io.popen-guarded, so it degrades to nil on sandboxes without a shell.
function ImageSearch._curlGet(url)
    local ok, body = pcall(function()
        local cmd = string.format(
            "curl -fsSL --connect-timeout 10 --max-time 30 -A %q %q 2>/dev/null",
            ImageSearch.USER_AGENT, url)
        local h = io.popen(cmd, "r")
        if not h then return nil end
        local data = h:read("*a")
        h:close()
        return data
    end)
    if ok and type(body) == "string" and body ~= "" then return body end
    return nil, "network unavailable"
end

-- Decode image bytes to a BlitBuffer, scaled so its longest side is <= max_side
-- (nil = no scaling). pcall-guarded; returns the buffer or nil.
function ImageSearch.decode(bytes, max_side)
    if type(bytes) ~= "string" or bytes == "" then return nil end
    local ok_ri, RenderImage = pcall(require, "ui/renderimage")
    if not ok_ri or not RenderImage then return nil end
    local ok, bb = pcall(function() return RenderImage:renderImageData(bytes, #bytes, false) end)
    if not ok or not bb then return nil end
    if max_side then
        local w, h = bb:getWidth(), bb:getHeight()
        local m = math.max(w, h)
        if m > max_side and m > 0 then
            local s = max_side / m
            local sok, sbb = pcall(function()
                return RenderImage:scaleBlitBuffer(bb, math.max(1, math.floor(w * s)),
                    math.max(1, math.floor(h * s)), true)
            end)
            if sok and sbb then return sbb end
        end
    end
    return bb
end

-- Fetch and parse one page of search results in the CALLER's process, under
-- Trapper. Tries the default provider then the fallback. Returns
--   { net_ok, provider, page_count, results = { {thumb, full, w, h, mime,
--     title, source} ... } }  with plain URLs; the caller downloads thumbnails.
-- Deliberately NOT run in a forked subprocess: LuaSec's SSL crashes hard inside a
-- fork on some builds (which pcall can't catch), and a small subprocess return is
-- also silently dropped -- so the network is done in the main loop, kept
-- responsive by a small page and short per-request timeouts with a cancel check
-- between each.
function ImageSearch.searchPage(query, opts)
    opts = opts or {}
    local any_response = false
    for _, provider in ipairs(ImageSearch.PROVIDERS) do
        local body = ImageSearch.httpGet(ImageSearch.buildURL(provider, query, opts))
        if type(body) == "string" then
            any_response = true
            local parsed = ImageSearch.parse(provider, body)
            if parsed and #parsed.results > 0 then
                return { net_ok = true, provider = provider,
                    page_count = parsed.page_count, results = parsed.results }
            end
        end
    end
    return { net_ok = any_response, results = {} }
end

return ImageSearch
