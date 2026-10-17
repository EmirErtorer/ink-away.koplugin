--[[
The plain parts of Send to phone or computer's web page, kept apart from the
sockets so the headless tests drive them: reading a request, the reply's
headers, safe paths and names, and the secret in the address.
]]

local Http = {}

-- The kinds of file the page hands out.
Http.TYPES = {
    html = "text/html; charset=utf-8",
    txt = "text/plain; charset=utf-8",
    pdf = "application/pdf",
    png = "image/png",
    jpg = "image/jpeg",
    inkaway = "application/octet-stream",
}

local REASONS = { [200] = "OK", [400] = "Bad Request", [404] = "Not Found", [405] = "Method Not Allowed",
    [500] = "Internal Server Error", [503] = "Service Unavailable" }

-- The content type for file name `name`, by its extension.
function Http.typeOf(name)
    local ext = tostring(name):match("%.([%w]+)$")
    return Http.TYPES[ext and ext:lower()] or "application/octet-stream"
end

function Http.urlDecode(s)
    s = tostring(s or ""):gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- Encode `s` for a query value or a path part (letters, digits and -_.~ stay).
function Http.urlEncode(s)
    return (tostring(s or ""):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function Http.html(s)
    return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;",
        ['"'] = "&quot;", ["'"] = "&#39;" }))
end

-- The request in `head` (its request line and headers, as read): { method,
-- path (decoded), query = { name = value } }, or nil when it isn't one.
function Http.parseRequest(head)
    local method, target = tostring(head or ""):match("^(%u+) (%S+) HTTP/%d%.%d")
    if not method then return nil end
    local path, qs = target:match("^([^?#]*)%??([^#]*)")
    local query = {}
    for pair in (qs or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k and k ~= "" then query[Http.urlDecode(k)] = Http.urlDecode(v) end
    end
    return { method = method, path = Http.urlDecode(path), query = query }
end

-- The reply's status line and headers. `length` may be nil (the reply then
-- ends when the connection closes); `extra` is a list of header lines.
function Http.header(code, ctype, length, extra)
    local h = { string.format("HTTP/1.1 %d %s", code, REASONS[code] or "OK") }
    if ctype then h[#h + 1] = "Content-Type: " .. ctype end
    if length then h[#h + 1] = "Content-Length: " .. length end
    h[#h + 1] = "Cache-Control: no-store"
    h[#h + 1] = "X-Content-Type-Options: nosniff"
    h[#h + 1] = "Referrer-Policy: no-referrer"
    h[#h + 1] = "Connection: close"
    for _, line in ipairs(extra or {}) do h[#h + 1] = line end
    return table.concat(h, "\r\n") .. "\r\n\r\n"
end

-- A header that saves the reply as file `name`: a plain ASCII name for old
-- browsers, the real one (any language) for the rest.
function Http.disposition(name, inline)
    name = tostring(name or "file")
    local plain = name:gsub("[\128-\255]+", "_"):gsub("[^%w%-_%. ()]", "_")   -- (a letter outside ASCII: one _)
    return string.format('Content-Disposition: %s; filename="%s"; filename*=UTF-8\'\'%s',
        inline and "inline" or "attachment", plain, Http.urlEncode(name))
end

-- `rel` as a path inside the library (parts joined by "/"), or nil when it
-- could lead anywhere else: an absolute path, "..", a hidden part, a
-- backslash or a NUL. "" is the library itself.
function Http.safeRel(rel)
    rel = tostring(rel or "")
    if rel:find("[%z\\]") or rel:sub(1, 1) == "/" then return nil end
    local parts = {}
    for part in rel:gmatch("[^/]+") do
        if part == ".." or part:sub(1, 1) == "." then return nil end
        parts[#parts + 1] = part
    end
    return table.concat(parts, "/")
end

-- A secret for the page's address: `n` letters and digits from `bytes` (a
-- string of random bytes), ambiguous ones left out so it can be typed.
local ALPHABET = "abcdefghijkmnpqrstuvwxyz23456789"
function Http.token(bytes, n)
    n = n or 10
    local out = {}
    for i = 1, n do
        local b = bytes:byte((i - 1) % #bytes + 1) or 0
        out[i] = ALPHABET:sub(b % #ALPHABET + 1, b % #ALPHABET + 1)
    end
    return table.concat(out)
end

-- Random bytes from the system, or from Lua's generator when there is none.
function Http.randomBytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(n)
        f:close()
        if s and #s == n then return s end
    end
    local t = {}
    math.randomseed(os.time() + math.floor(os.clock() * 1e6))
    for i = 1, n do t[i] = string.char(math.random(0, 255)) end
    return table.concat(t)
end

-- A readable size: 532 KB, 3.4 MB.
function Http.size(bytes)
    bytes = tonumber(bytes) or 0
    if bytes < 1024 * 1024 then return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5))) end
    return string.format("%.1f MB", bytes / (1024 * 1024))
end

return Http
