-- Send to phone or computer's plain parts (ink/share/http.lua, page.lua,
-- net.lua): reading requests, keeping every path inside the library, the
-- address's secret, the page's escaping, and finding the reader's address.
-- Run from the plugin root with:  luajit tests/share.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local Http = require("ink/share/http")
local Page = require("ink/share/page")
local Net = require("ink/share/net")
local SafeData = require("ink/share/safedata")
local Project = require("ink/project")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

-- requests
local r = Http.parseRequest("GET /abc/pdf?p=School%2FMath%2FCalculus.inkaway&x=1+2 HTTP/1.1\r\nHost: x")
ok(r and r.method == "GET" and r.path == "/abc/pdf", "a request's method and path")
ok(r.query.p == "School/Math/Calculus.inkaway" and r.query.x == "1 2", "its query, decoded")
ok(Http.parseRequest("hello") == nil and Http.parseRequest("") == nil, "garbage is not a request")
ok(Http.parseRequest("GET /a%20b/ HTTP/1.0").path == "/a b/", "an encoded path")
ok(Http.urlDecode(Http.urlEncode("Ödev/Ünite 1 & 2?.inkaway")) == "Ödev/Ünite 1 & 2?.inkaway", "encoding comes back")
ok(not Http.urlEncode("a/b c&d"):find("[/ &]"), "slashes, spaces and ampersands are encoded")

-- paths stay inside the library
ok(Http.safeRel("") == "" and Http.safeRel(nil) == "", "the library itself")
ok(Http.safeRel("School/Math") == "School/Math", "a folder inside")
ok(Http.safeRel("School//Math/") == "School/Math", "doubled and trailing slashes")
for _, bad in ipairs({ "../x", "School/../../etc", "/etc/passwd", "a/./.hidden", ".inkaway-folder", "a\\b", "a\0b", "..", "School/.." }) do
    ok(Http.safeRel(bad) == nil, "refused: " .. bad:gsub("%z", "\\0"))
end

-- the secret
local t1 = Http.token(Http.randomBytes(12), 12)
local t2 = Http.token(Http.randomBytes(12), 12)
ok(#t1 == 12 and t1:match("^[a-z2-9]+$") and not t1:find("[lo01]"), "a 12 letter secret, easy to type (" .. t1 .. ")")
ok(t1 ~= t2, "a new one each time")
ok(#Http.randomBytes(16) == 16, "random bytes")

-- headers
local h = Http.header(200, Http.TYPES.pdf, 1234, { Http.disposition("Fizik ödevi.pdf") })
ok(h:match("^HTTP/1%.1 200 OK\r\n") and h:find("Content-Length: 1234\r\n", 1, true) and h:sub(-4) == "\r\n\r\n",
    "a reply's headers")
ok(h:find("Connection: close", 1, true) and h:find("Cache-Control: no-store", 1, true), "never kept or cached")
ok(h:find('filename="Fizik _devi.pdf"', 1, true) and h:find("filename*=UTF-8''Fizik%20%C3%B6devi.pdf", 1, true),
    "a download keeps its name in any language")
ok(Http.disposition("a.png", true):find("^Content%-Disposition: inline"), "a picture shown, not saved")
ok(Http.typeOf("x.PDF") == Http.TYPES.pdf and Http.typeOf("x.inkaway") == Http.TYPES.inkaway
    and Http.typeOf("noext") == "application/octet-stream", "types by extension")
ok(Http.size(500) == "1 KB" and Http.size(3.4 * 1024 * 1024) == "3.4 MB", "sizes")

-- the page
local html = Page.render{ title = "School", crumbs = { { label = "Library", href = "/t/" }, { label = "School" } },
    folders = { { name = "Math <b>", href = "/t/?d=School%2FMath", color = "#7cc474" } },
    docs = { { name = '<script>alert("x")</script>', kind = "Notebook", thumb = "/t/thumb?p=a",
        links = { { label = "PDF", href = "/t/pdf?p=a&b", main = true } } } },
    exports = { { name = "Physics.pdf", href = "/t/export?n=Physics.pdf", size = "1.2 MB" } },
    note = "Served by your reader" }
ok(not html:find("<script>", 1, true) and html:find("&lt;script&gt;", 1, true), "a document's name can't run on the page")
ok(html:find("Math &lt;b&gt;", 1, true), "nor a folder's")
ok(html:find('href="/t/pdf?p=a&amp;b"', 1, true), "links are escaped")
ok(html:find("--dot:#7cc474", 1, true), "a folder shows its colour")
ok(html:find("Already exported", 1, true) and html:find("1.2 MB", 1, true), "the exports, with sizes")
ok(html:find('name="viewport"', 1, true) and html:find("prefers-color-scheme:dark", 1, true), "fits a phone, light or dark")
ok(not html:find("<script", 1, true), "no scripts at all")
ok(Page.render{ title = "Empty" }:find("Nothing here yet", 1, true), "an empty folder says so")
ok(Page.gone():find("expired", 1, true), "an old address says what to do")

-- the reader's address
ok(Net.isLan("192.168.1.23") and Net.isLan("10.0.0.5"), "network addresses")
ok(not Net.isLan("127.0.0.1") and not Net.isLan("0.0.0.0") and not Net.isLan("169.254.3.4") and not Net.isLan(nil),
    "loopback, none and link-local are not")
local fake_sock = { udp = function() return {
    setpeername = function() return 1 end, getsockname = function() return "192.168.4.40", 50000 end, close = function() end } end }
ok(Net.localIP(fake_sock, function() return "" end) == "192.168.4.40", "the address the system sends from")
local no_route = { udp = function() return { setpeername = function() error("no route") end, close = function() end } end }
local IPADDR = "1: lo: <LOOPBACK,UP>\n    inet 127.0.0.1/8 scope host lo\n2: usb0: <UP>\n    inet 192.168.15.244/24 scope global usb0\n"
    .. "3: wlan0: <BROADCAST,UP>\n    inet 10.1.2.3/24 brd 10.1.2.255 scope global wlan0\n"
ok(Net.localIP(no_route, function(cmd) return cmd == "ip -4 addr" and IPADDR or "" end) == "10.1.2.3",
    "else what the system lists, Wi-Fi first: never a Kindle's USB network")
ok(Net.localIP(fake_sock, function(cmd) return cmd == "ip -4 addr" and IPADDR or "" end, "wlan0") == "10.1.2.3",
    "the interface KOReader uses for Wi-Fi comes first")
local usb_sock = { udp = function() return {
    setpeername = function() return 1 end, getsockname = function() return "192.168.15.244", 1 end, close = function() end } end }
ok(Net.localIP(usb_sock, function(cmd) return cmd == "ip -4 addr" and IPADDR or "" end) == "10.1.2.3",
    "a route out through USB is not taken for the Wi-Fi")
local IFCONFIG = "usb0      Link encap:Ethernet  HWaddr ee:\n          inet addr:192.168.15.244  Bcast:192.168.15.255\n"
    .. "wlan0     Link encap:Ethernet  HWaddr 00:\n          inet addr:192.168.0.9  Bcast:192.168.0.255\n"
ok(Net.localIP(nil, function(cmd) return cmd == "ifconfig" and IFCONFIG or "" end) == "192.168.0.9",
    "old ifconfig output too (Kindle, Kobo)")
ok(Net.localIP(nil, function() return "" end) == nil, "no network, no address")
ok(Net.localIP(nil, function(cmd) return cmd == "ip -4 addr" and "1: lo: <UP>\n    inet 127.0.0.1/8\n" or "" end) == nil,
    "only the loopback: no address")
local ran = {}
Net.openFirewall(8642, function(cmd) ran[#ran + 1] = cmd end)
Net.closeFirewall(8642, function(cmd) ran[#ran + 1] = cmd end)
ok(#ran == 4 and ran[1]:find("^iptables %-A INPUT") and ran[1]:find("8642") and ran[3]:find("^iptables %-D INPUT"),
    "the Kindle's firewall opened for the port, then closed")

-- files sent to the reader: their names
ok(Http.cleanName("../../etc/passwd", "pdf") == "passwd.pdf", "a name's folders are dropped")
ok(Http.cleanName("C:\\Users\\me\\Report.final.PDF", "pdf") == "Report.final.pdf", "Windows folders too, and its own extension replaced")
ok(Http.cleanName("..hidden.pdf", "pdf") == "hidden.pdf", "no leading dots (no hidden files)")
ok(Http.cleanName("a\0b\nc<d>:e.pdf", "pdf") == "abc_d__e.pdf", "no control or reserved characters")
ok(Http.cleanName("", "jpg") == "file.jpg" and Http.cleanName(nil, "png") == "file.png" and Http.cleanName("...", "pdf") == "file.pdf",
    "an empty name becomes file")
local long = Http.cleanName(string.rep("ö", 60), "pdf", 80)
ok(#long <= 84 and not long:find("[\192-\255]%.pdf$"), "a long name is cut on a letter, not inside one")
ok(Http.cleanName("Fizik ödevi.pdf", "pdf") == "Fizik ödevi.pdf", "any language is kept")

-- what a file is, by its first bytes
ok(Http.sniff("%PDF-1.7\n") == "pdf" and Http.sniff("\255\216\255\224") == "jpg", "PDF and JPEG")
ok(Http.sniff("\137PNG\r\n\26\n") == "png" and Http.sniff("RIFF\0\0\0\0WEBPVP8 ") == "webp", "PNG and WebP")
ok(Http.sniff('return {["ops"]={}}') == "inkaway" and Http.sniff("  return{") == "inkaway", "an Ink Away file")
ok(Http.sniff("<svg>") == nil and Http.sniff("#!/bin/sh") == nil and Http.sniff("PK\3\4") == nil
    and Http.sniff("os.execute('rm')") == nil, "anything else is nothing")

-- a picture's size, from its header
local function be32(n) return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256) end
local function be16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local png = "\137PNG\r\n\26\n" .. be32(13) .. "IHDR" .. be32(8064) .. be32(6048) .. "\8\6\0\0\0"
local w, h = Http.imageSize(png)
ok(w == 8064 and h == 6048, "a PNG's size")
local exif = "\255\225" .. be16(2 + 30000) .. string.rep("E", 30000)   -- a big EXIF block first, as phones write
local jpg = "\255\216" .. exif .. "\255\219" .. be16(67) .. string.rep("q", 65)
    .. "\255\192" .. be16(17) .. "\8" .. be16(4032) .. be16(3024) .. "\3" .. string.rep("c", 9)
w, h = Http.imageSize(jpg)
ok(w == 3024 and h == 4032, "a JPEG's size, past its EXIF (" .. tostring(w) .. " x " .. tostring(h) .. ")")
local prog = "\255\216\255\194" .. be16(17) .. "\8" .. be16(100) .. be16(200) .. "\3" .. string.rep("c", 9)
w, h = Http.imageSize(prog)
ok(w == 200 and h == 100, "a progressive JPEG's size")
ok(Http.imageSize("\255\216\255\218" .. be16(4) .. "xx") == nil, "a JPEG with no frame header has none")
ok(Http.imageSize("\255\216" .. string.rep("\0", 40)) == nil and Http.imageSize("junk") == nil, "garbage has none")
ok(Http.imageSize("\255\216\255\225" .. be16(65535)) == nil, "a cut-off JPEG has none (no reading past the end)")

-- requests carry their headers
r = Http.parseRequest("POST /t/upload?kind=pdf HTTP/1.1\r\nContent-Length: 1234\r\nExpect: 100-continue\r\nX-Bad Header: x")
ok(r.headers["content-length"] == "1234" and r.headers.expect == "100-continue" and r.headers["x-bad header"] == nil,
    "a request's headers, by lower-case name")

-- the page's security policy and its sending part
local csp = Page.csp("abc123")
ok(csp:find("default-src 'none'", 1, true) and csp:find("script-src 'nonce-abc123'", 1, true)
    and csp:find("frame-ancestors 'none'", 1, true) and csp:find("connect-src 'self'", 1, true),
    "nothing from anywhere else; only the page's own script, by its nonce")
ok(Page.csp(nil):find("script-src 'none'", 1, true), "pages without a script allow none")
local up = Page.render{ title = "L", upload = { allowed = true, url = '/t/upload"><script>', nonce = "n0nce",
    limits = { pdf = 1, image = 2, inkaway = 3 }, max_pixels = 16000000 } }
ok(up:find('<script nonce="n0nce">', 1, true) and select(2, up:gsub("<script", "")) == 1, "one script, with its nonce")
ok(not up:find('upload"><script>', 1, true), "the address in it is escaped")
ok(up:find('name="lv" value="small"', 1, true) and up:find("Original", 1, true), "picture sizes to pick from")
local off = Page.render{ title = "L", upload = { allowed = false } }
ok(not off:find("<script", 1, true) and off:find("Allow adding files", 1, true), "off on the reader: no script, and how to turn it on")

-- the page's theme colour
local acc = Page.accent({ 0x24, 0x57, 0xD6 }, false)
ok(acc.fill == "#2457d6" and acc.ink == "#ffffff", "a theme colour, with white text on it")
ok(Page.accent({ 0xF2, 0xC9, 0x4C }, true).ink == "#1a1a1a", "dark text on a light theme")
ok(Page.accent(nil) == nil and Page.accentCSS(nil) == "", "none: Ink Away's green stays")
ok(Page.accent({ 300, -5, "x" }, false).fill == "#ff0000", "a colour out of range is clamped")
local themed = Page.render{ title = "L", accent = acc }
ok(themed:find(":root{--acc:#2457d6;--acc-ink:#ffffff}", 1, true), "the page uses it")
ok(not Page.render{ title = "L" }:find("--acc:#2457d6", 1, true), "and only when given")

-- an Ink Away file from another device: data only, never code
local real = Project.serialize({ w = 1200, h = 1600, ops = { { kind = "ink", pts = { 1, 2.5, -3, 4e-7 }, width = 2,
    color = { 255, 0, 0 } }, { kind = "text", paras = { { spans = { { t = 'say "hi" while for function() .. os.exit()\n' } } } } } } })
ok(SafeData.isData(real), "a real drawing is data (code words inside its text are just text)")
local nb = Project.serializeNotebook(require("ink/notebook").new(1200, 1600, { style = "lines" }))
ok(SafeData.isData(nb), "a real notebook is data")
ok(SafeData.isData("return { a = 1, ['b'] = -inf, c = nan, d = nil, e = true, f = 0x1F, g = 1.5e+10 }"),
    "plain keys, odd numbers, true, nil")
for _, bad in ipairs({
    "return { x = os.execute('rm -rf /') }",
    "return { (function() while true do end end)() }",
    "while true do end return {}",
    "return { a = b }",
    "return { a = f{} }",
    "return { 'a' .. 'b' }",
    "local s = 'x' for i = 1, 40 do s = s .. s end return { s }",
    "return { #{} }",
    "return { [[long]] }",
    "return { a = 1 } -- comment",
    "return { a = 1 + 2 }",
    "return { x = getmetatable('').__index }",
    "return { a == 1 }",
    "return { 1 } return { 2 }",
    "{ a = 1 }",
    "return { 'unfinished }",
    "return { 1 2abc }",
    "",
}) do
    ok(not SafeData.isData(bad), "not data: " .. bad:sub(1, 50))
    ok(SafeData.decode(bad) == nil, "and never read: " .. bad:sub(1, 50))
end
local d = SafeData.decode(real)
ok(d and d.w == 1200 and d.ops[1].pts[2] == 2.5, "a real drawing reads back")
-- references to files elsewhere are dropped; Ink Away's own folders stay
local t = { template = { pdf_path = "/mnt/onboard/Private/taxes.pdf", style = "blank" }, bg = "/mnt/onboard/.kobo/screen.png",
    ops = { { kind = "image", path = "/mnt/us/documents/secret.jpg", src_path = "/etc/shadow" },
        { kind = "image", path = "/mnt/onboard/.adds/koreader/ink away/imported images/a.jpg" } },
    pages = { { ops = { { kind = "image", path = "/x/y.png" } } } } }
local inside = function(p) return p:sub(1, 37) == "/mnt/onboard/.adds/koreader/ink away/" end
ok(SafeData.dropOutside(t, inside) == 5, "five references outside Ink Away dropped")
ok(t.template.pdf_path == nil and t.bg == nil and t.ops[1].path == nil and t.ops[1].src_path == nil
    and t.pages[1].ops[1].path == nil, "pictures, background and PDF elsewhere are gone")
ok(t.ops[2].path ~= nil and t.template.style == "blank", "one in Ink Away's folders stays, and so does the rest")

print(("share: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
