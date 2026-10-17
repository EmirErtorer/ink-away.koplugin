-- Send to phone or computer's plain parts (ink/share/http.lua, page.lua,
-- net.lua): reading requests, keeping every path inside the library, the
-- address's secret, the page's escaping, and finding the reader's address.
-- Run from the plugin root with:  luajit tests/share.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path

local Http = require("ink/share/http")
local Page = require("ink/share/page")
local Net = require("ink/share/net")

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
local outputs = { ["ip -4 route get 192.0.2.1"] = "", ["ip -4 addr"] = "inet 127.0.0.1/8\n    inet 10.1.2.3/24 brd",
    ifconfig = "" }
ok(Net.localIP(no_route, function(cmd) return outputs[cmd] or "" end) == "10.1.2.3", "else what the system lists")
ok(Net.localIP(nil, function(cmd) return cmd == "ifconfig" and "inet addr:192.168.0.9  Bcast" or "" end) == "192.168.0.9",
    "old ifconfig output too (Kindle, Kobo)")
ok(Net.localIP(nil, function() return "" end) == nil, "no network, no address")
local ran = {}
Net.openFirewall(8642, function(cmd) ran[#ran + 1] = cmd end)
Net.closeFirewall(8642, function(cmd) ran[#ran + 1] = cmd end)
ok(#ran == 4 and ran[1]:find("^iptables %-A INPUT") and ran[1]:find("8642") and ran[3]:find("^iptables %-D INPUT"),
    "the Kindle's firewall opened for the port, then closed")

print(("share: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
