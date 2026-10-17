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
    socket = socket, ports = { 18642, 18643, 18644 },
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
