#!/bin/sh
set -eu
REPO="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
RUNTIME=${KO_EMU:?Set KO_EMU to the built KOReader runtime directory}
FIXTURE=$(mktemp -d /tmp/inkaway-tls-fixture.XXXXXX)
SERVER_PID=
cleanup() {
    if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi
    rm -rf "$FIXTURE"
}
trap cleanup EXIT INT TERM
mkdir -p "$FIXTURE/common/ssl" "$FIXTURE/data"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$FIXTURE/ca.key" \
    -out "$FIXTURE/data/ca-bundle.crt" -days 2 -subj '/CN=OCR Fixture Root' \
    -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' >/dev/null 2>&1
for NAME in valid mismatch; do
    openssl req -newkey rsa:2048 -nodes -keyout "$FIXTURE/$NAME.key" \
        -out "$FIXTURE/$NAME.csr" -subj "/CN=$NAME.test" >/dev/null 2>&1
    if [ "$NAME" = valid ]; then SAN=localhost; else SAN=wrong.test; fi
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:%s\n' "$SAN" > "$FIXTURE/$NAME.ext"
    openssl x509 -req -in "$FIXTURE/$NAME.csr" -CA "$FIXTURE/data/ca-bundle.crt" \
        -CAkey "$FIXTURE/ca.key" -CAcreateserial -out "$FIXTURE/$NAME.crt" \
        -days 2 -extfile "$FIXTURE/$NAME.ext" >/dev/null 2>&1
done
cat > "$FIXTURE/server.py" <<'PY'
import os, socket, ssl, threading
root = os.environ['TLS_FIXTURE']
body = b'{"choices":[{"message":{"content":"fixture OCR"},"finish_reason":"stop"}]}'
def listener(cert, key, count):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(root, cert), os.path.join(root, key))
    sock = socket.socket()
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('127.0.0.1', 0))
    sock.listen()
    sock.settimeout(15)
    return sock, ctx, count
valid = listener('valid.crt', 'valid.key', 2)
mismatch = listener('mismatch.crt', 'mismatch.key', 1)
with open(os.path.join(root, 'ports'), 'w') as f:
    f.write('%d %d' % (valid[0].getsockname()[1], mismatch[0].getsockname()[1]))
def serve(item):
    sock, ctx, count = item
    for _ in range(count):
        try: raw, _ = sock.accept()
        except TimeoutError: break
        try:
            conn = ctx.wrap_socket(raw, server_side=True)
            request = b''
            while b'\r\n\r\n' not in request:
                chunk = conn.recv(65536)
                if not chunk: break
                request += chunk
            if b'\r\n\r\n' not in request:
                conn.close()
                continue
            headers, request_body = request.split(b'\r\n\r\n', 1)
            length = int(next(line.split(b':', 1)[1] for line in headers.split(b'\r\n')
                              if line.lower().startswith(b'content-length:')))
            while len(request_body) < length:
                chunk = conn.recv(65536)
                if not chunk: break
                request_body += chunk
            if len(request_body) < length:
                conn.close()
                continue
            print('server received request bytes:', len(request), flush=True)
            conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ' + str(len(body)).encode() + b'\r\nConnection: close\r\n\r\n' + body)
            print('server sent fixture response', flush=True)
            conn.close()
        except (ssl.SSLError, OSError) as exc:
            print('server TLS fixture error:', repr(exc), flush=True)
            raw.close()
    sock.close()
a = threading.Thread(target=serve, args=(valid,)); b = threading.Thread(target=serve, args=(mismatch,))
a.start(); b.start(); a.join(); b.join()
PY
TLS_FIXTURE="$FIXTURE" python3 "$FIXTURE/server.py" &
SERVER_PID=$!
for ATTEMPT in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$FIXTURE/ports" ] && break
    sleep 0.1
done
[ -s "$FIXTURE/ports" ] || { echo 'fixture server did not bind'; exit 1; }
set -- $(cat "$FIXTURE/ports")
cd "$RUNTIME"
OCR_REPO="$REPO" TLS_FIXTURE="$FIXTURE" TLS_VALID_PORT="$1" TLS_MISMATCH_PORT="$2" \
"$RUNTIME/luajit" -e '
local root = os.getenv("TLS_FIXTURE")
package.path = os.getenv("OCR_REPO") .. "/?.lua;./common/?.lua;./common/?/init.lua;./frontend/?.lua;./ffi/?.lua;" .. package.path
package.cpath = "./common/?.so;./libs/?.so;" .. package.cpath
local http = require("socket.http")
local https = require("ssl.https")
local ssl = require("ssl")
local real_wrap = ssl.wrap
ssl.wrap = function(...)
    local tls, err = real_wrap(...)
    if tls then
        local methods = getmetatable(tls).__index
        for _, method_name in ipairs({"dohandshake", "send", "receive", "settimeout", "close"}) do
            local name = method_name
            local method = methods[method_name]
            methods[method_name] = function(sock, ...)
                local a, b, c = method(sock, ...)
                io.stderr:write("TLS " .. name .. ": " .. tostring(a) .. ", " .. tostring(b) .. "\n")
                return a, b, c
            end
        end
    end
    return tls, err
end
local raw_request = http.request
http.request = function(req)
    local a, b, c = raw_request(req)
    io.stderr:write("loopback HTTP result: " .. tostring(a) .. ", " .. tostring(b) .. "\n")
    return a, b, c
end
package.loaded["socketutil"] = {
    set_timeout = function(_, block_timeout) http.TIMEOUT = block_timeout; https.TIMEOUT = block_timeout end,
    reset_timeout = function() http.TIMEOUT = 60; https.TIMEOUT = 60 end,
}
local Api = require("ink/ocr/api")
local png = "\137PNG\r\n\26\n12345678IEND\174B\96\130"
local valid_url = "https://localhost:" .. os.getenv("TLS_VALID_PORT") .. "/proxy/v1"
local valid_config = assert(Api.validate({url=valid_url,key="dummy-key",model="fixture"}))
local denied = Api.request(valid_config, png)
assert(denied == nil, "self-signed/untrusted cert was accepted")
local fixture_https = assert(loadstring("return {request=function() end}", "@" .. root .. "/common/ssl/https.lua"))()
package.loaded["ssl.https"] = fixture_https
local recognized, err = Api.request(valid_config, png)
assert(recognized == "fixture OCR", "fixture-CA trusted SAN request failed: " .. tostring(err))
local mismatch_url = "https://localhost:" .. os.getenv("TLS_MISMATCH_PORT") .. "/proxy/v1"
local mismatch_config = assert(Api.validate({url=mismatch_url,key="dummy-key",model="fixture"}))
local rejected = Api.request(mismatch_config, png)
assert(rejected == nil, "trusted certificate with wrong SAN was accepted")
print("native_tls_loopback: untrusted rejected; fixture-CA trusted SAN accepted; SAN mismatch rejected")
'
wait "$SERVER_PID"
SERVER_PID=
