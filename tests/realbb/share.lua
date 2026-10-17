-- Send to phone or computer's server (ink/share/server.lua) on KOReader's real
-- LuaSocket, as a browser meets it: a page, a big file sent in pieces while
-- the reader's loop keeps turning, a reply that waits for a PDF being made,
-- requests it turns away, a browser that leaves mid-download, and stopping.
-- Run (the test runner does this):  cd <emulator>/koreader && ./luajit <repo>/tests/realbb/share.lua <repo>
local REPO = arg[1] or "."
require("setupkoenv")
package.path = REPO .. "/?.lua;" .. package.path
local socket = require("socket")
local Server = require("ink/share/server")
local Http = require("ink/share/http")

local checks, failures = 0, 0
local function ok(c, what) checks = checks + 1; if not c then failures = failures + 1; print("FAIL: " .. what) end end

local tmp = os.tmpname()
local big = {}
for i = 1, 3 * 1024 do local n = tostring(i); big[i] = n .. string.rep(".", 1023 - #n) .. "\n" end
big = table.concat(big)   -- 3 MB
local f = io.open(tmp, "wb"); f:write(big); f:close()

local waiting, sent_after, events = nil, 0, 0
local srv = Server.new{
    socket = socket, ports = { 18642, 18643, 18644 }, head_timeout = 0.6,
    make_event = function() events = events + 1; return "InputEvent" end,
    handler = function(req, reply)
        if req.path == "/t/" then return reply.send(200, Http.TYPES.html, "<p>hello " .. (req.query.d or "") .. "</p>") end
        if req.path == "/t/big" then return reply.file(tmp, Http.TYPES.pdf, "Big.pdf", function() sent_after = sent_after + 1 end) end
        if req.path == "/t/wait" then waiting = reply; return reply.wait() end
        if req.path == "/t/boom" then error("kaboom") end
    end,
}
local port = srv:start()
ok(port ~= nil, "it listens (" .. tostring(port) .. ")")
-- a second one takes the next port
local srv2 = Server.new{ socket = socket, ports = { port, port + 1, port + 2 }, handler = function() end }
local port2 = srv2:start()
ok(port2 and port2 ~= port, "a taken port is skipped")
srv2:stop()

-- KOReader's loop: waitEvent until it gives nothing, as UIManager:processZMQs
local function turn()
    for _ in srv.waitEvent, srv do end
end

-- a browser: send a request, then read while the loop turns
local function fetch(path, method, raw, max_turns)
    local c = socket.tcp()
    c:settimeout(1)
    assert(c:connect("127.0.0.1", port))
    c:send(raw or ((method or "GET") .. " " .. path .. " HTTP/1.1\r\nHost: reader\r\n\r\n"))
    c:settimeout(0)
    local parts, turns = {}, 0
    while turns < (max_turns or 4000) do
        turn()
        turns = turns + 1
        local data, err, partial = c:receive(65536)
        local got = data or partial
        if got and #got > 0 then parts[#parts + 1] = got end
        if err == "closed" then break end
    end
    c:close()
    local all = table.concat(parts)
    local head, body = all:match("^(.-)\r\n\r\n(.*)$")
    return head or "", body or "", turns
end

local head, body = fetch("/t/?d=School%2FMath")
ok(head:match("^HTTP/1%.1 200") and body == "<p>hello School/Math</p>", "a page, with its query")
ok(head:find("Content-Length: " .. #body, 1, true), "its length")
ok(events > 0, "a request keeps the reader awake (an event for KOReader's loop)")

local turns
head, body, turns = fetch("/t/big")
ok(#body == #big and body == big, ("a 3 MB file arrives whole (%d bytes)"):format(#body))
ok(head:find('filename="Big.pdf"', 1, true) and head:find("application/pdf", 1, true), "as a download, named")
ok(turns > 3, ("sent over several turns of the loop, not all at once (%d)"):format(turns))
ok(sent_after == 1 and srv.files_sent == 1, "counted once it is all sent")

-- a reply that waits: the PDF is made, then sent
local c = socket.tcp(); c:settimeout(1); assert(c:connect("127.0.0.1", port))
c:send("GET /t/wait HTTP/1.1\r\n\r\n"); c:settimeout(0)
for _ = 1, 20 do turn() end
ok(waiting ~= nil and waiting.open(), "a reply can wait")
local d = c:receive(1)
ok(d == nil, "and nothing goes out meanwhile")
waiting.send(200, Http.TYPES.txt, "made")
local got = {}
for _ = 1, 50 do
    turn()
    local data, err, partial = c:receive(4096)
    if data or partial then got[#got + 1] = data or partial end
    if err == "closed" then break end
end
c:close()
ok(table.concat(got):find("\r\n\r\nmade$"), "then goes out when ready")

head = fetch("/t/nothing")
ok(head:match("^HTTP/1%.1 404"), "a page nobody answers is not found")
head, body = fetch("/t/boom")
ok(head:match("^HTTP/1%.1 500") and body:find("kaboom"), "a mistake on the reader is a 500, and the server goes on")
head = fetch("/t/", "POST")
ok(head:match("^HTTP/1%.1 405"), "nothing can be sent to the reader")

-- a browser that sends its request a byte at a time (by mistake, or to hold
-- the reader): each turn of the loop stays quick, and it is dropped in time
local slow = socket.tcp(); slow:settimeout(1); assert(slow:connect("127.0.0.1", port))
local req, worst = "GET /t/ HTTP/1.1\r\nHost: reader\r\n", 0
local t_start = socket.gettime()
for k = 1, #req do
    slow:send(req:sub(k, k))
    local t0 = socket.gettime()
    turn()
    worst = math.max(worst, socket.gettime() - t0)
    socket.sleep(0.01)
end
ok(worst < 0.02, ("a slow browser never holds a turn of the loop (longest %.1f ms)"):format(worst * 1000))
while socket.gettime() - t_start < 1 do turn(); socket.sleep(0.02) end
slow:settimeout(0.2)
local _, serr = slow:receive(1)
ok(serr == "closed", "and is dropped when its time is up, unanswered")
slow:close()

-- many connections that never send anything: at most 16 are kept, the rest
-- closed at once, and the loop stays quick
local idle = {}
for k = 1, 22 do
    local cc = socket.tcp(); cc:settimeout(1)
    if cc:connect("127.0.0.1", port) then idle[#idle + 1] = cc end
end
local t0 = socket.gettime()
for _ = 1, 5 do turn() end
ok(socket.gettime() - t0 < 0.05, "22 idle connections don't slow the loop")
ok(srv:connections() <= 16, ("no more than 16 kept (%d)"):format(srv:connections()))
local closed_now = 0
for _, cc in ipairs(idle) do
    cc:settimeout(0.05)
    local _, e = cc:receive(1)
    if e == "closed" then closed_now = closed_now + 1 end
end
ok(closed_now >= 6, ("the ones over the limit are closed at once (%d)"):format(closed_now))
t0 = socket.gettime()
while socket.gettime() - t0 < 0.8 do turn(); socket.sleep(0.02) end
ok(srv:connections() == 0, "the idle ones go when their time is up")
for _, cc in ipairs(idle) do cc:close() end
head, body = fetch("/t/")
ok(head:match("^HTTP/1%.1 200"), "and the reader answers again")

-- a browser that leaves while its reply waits is noticed
c = socket.tcp(); c:settimeout(1); assert(c:connect("127.0.0.1", port))
c:send("GET /t/wait HTTP/1.1\r\n\r\n")
for _ = 1, 10 do turn() end
local left = waiting
c:close()
for _ = 1, 10 do turn() end
ok(left.gone == true and not left.open(), "a browser that left while waiting is noticed")

-- a download's progress, and the reader's Cancel
c = socket.tcp(); c:settimeout(1); assert(c:connect("127.0.0.1", port))
c:send("GET /t/big HTTP/1.1\r\n\r\n"); c:settimeout(0)
local seen
for _ = 1, 40 do
    turn()
    local tr = srv:transfers()
    if tr[1] and tr[1].sent > 0 and tr[1].sent < tr[1].total then seen = tr[1] end
    if seen then break end
end
ok(seen and seen.name == "Big.pdf" and seen.total == #big, "a download's progress: its name, how much of how much")
srv:cancelTransfers()
ok(#srv:transfers() == 0 and not srv:busy(), "Cancel stops it")
local rest = {}
c:settimeout(0.5)
while true do
    local data, e, partial = c:receive(65536)
    if data or partial then rest[#rest + 1] = data or partial end
    if e == "closed" or e == "timeout" then break end
end
ok(#table.concat(rest) < #big, "and the browser gets no more of it")
c:close()
head = fetch(nil, nil, "this is not http\r\n\r\n")
ok(head:match("^HTTP/1%.1 400"), "garbage is a bad request")
head = fetch(nil, nil, "GET /t/ HTTP/1.1\r\nX: " .. string.rep("a", 9000) .. "\r\n\r\n")
ok(head:match("^HTTP/1%.1 400") or head == "", "a request too big is turned away")

-- a browser that leaves mid-download
c = socket.tcp(); c:settimeout(1); assert(c:connect("127.0.0.1", port))
c:send("GET /t/big HTTP/1.1\r\n\r\n"); c:settimeout(0)
for _ = 1, 3 do turn(); c:receive(4096) end
c:close()
for _ = 1, 200 do turn() end
ok(not srv:busy(), "a download whose browser left is dropped")
ok(srv.files_sent == 1, "and not counted as sent")

-- stopping, with a reply still waiting
c = socket.tcp(); c:settimeout(1); assert(c:connect("127.0.0.1", port))
c:send("GET /t/wait HTTP/1.1\r\n\r\n")
for _ = 1, 10 do turn() end
srv:stop()
c:settimeout(1)
local _, err = c:receive(1)
ok(err == "closed", "stopping closes a reply still waiting")
c:close()
local probe = socket.tcp(); probe:settimeout(0.5)
ok(not probe:connect("127.0.0.1", port), "and nothing listens any more")
probe:close()
waiting.send(200, Http.TYPES.txt, "late")   -- a PDF finished after stopping: nothing happens
ok(not srv:busy(), "a reply after stopping goes nowhere")

os.remove(tmp)
print(("realbb share: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
