package.path = "./?.lua;" .. package.path
local Api = require("ink/ocr/api")

local checks, failures = 0, 0
local function ok(value, message)
    checks = checks + 1
    if not value then failures = failures + 1; print("FAIL: " .. message) end
end

local valid = { url = "https://api.example.test/v1", key = "secret", model = "vision" }
local config = Api.validate(valid)
ok(config and config.url == "https://api.example.test/v1/chat/completions", "base URL gets one endpoint suffix")
ok(config and config.host == "api.example.test", "normalized config keeps the TLS host")
for _, url in ipairs({
    "http://api.example.test/v1", "https://user@api.example.test/v1",
    "https://api.example.test/v1?x=1", "https://api.example.test/v1#part",
    "https://api.example.test/v1/chat/completions/chat/completions",
    "https://api..example.test/v1", "https://api.example.test:0/v1",
    "https://api.example.test/v1\nHost: evil",
}) do
    ok(Api.validate({ url = url, key = "k", model = "m" }) == nil, "rejects unsafe URL " .. url:gsub("\n", "\\n"))
end
ok(Api.validate({ url = valid.url, key = "bad\nheader", model = "vision" }) == nil, "rejects control characters in key")
ok(Api.validate({ url = valid.url, key = "secret", model = "" }) == nil, "rejects empty model")
ok(Api.validate({ url = "https://api.example.test/v1/chat/completions", key = "k", model = "m" })
    .url == "https://api.example.test/v1/chat/completions", "full endpoint is not duplicated")
ok(Api.validate({ url = "https://api.example.test/openai/v1", key = "k", model = "m" })
    .url == "https://api.example.test/openai/v1/chat/completions", "preserves provider base paths")
ok(Api.validate({ url = "https://api.example.test/proxy/", key = "k", model = "m" })
    .url == "https://api.example.test/proxy/chat/completions", "normalizes a trailing slash")
ok(Api.validate({ url = "https://api.example.test/proxy/chat/completions/", key = "k", model = "m" })
    .url == "https://api.example.test/proxy/chat/completions", "normalizes full endpoint trailing slash")
ok(Api.validate({ url = "https://api.example.test/proxy/tenant/openai/v1/", key = "k", model = "m" })
    .url == "https://api.example.test/proxy/tenant/openai/v1/chat/completions",
    "preserves nested arbitrary provider base paths")

local runtime_root = "/tmp/inkaway-ocr-api-test"
os.execute("mkdir -p " .. runtime_root .. "/common/ssl " .. runtime_root .. "/data")
local ca = assert(io.open(runtime_root .. "/data/ca-bundle.crt", "wb")); ca:write("test-ca"); ca:close()
local https = assert(io.open(runtime_root .. "/common/ssl/https.lua", "wb")); https:write("return { request = function() end }\n"); https:close()
local old_path = package.path
package.path = runtime_root .. "/common/?.lua;" .. package.path
package.loaded["ssl.https"] = nil
package.loaded["ssl.https"] = dofile(runtime_root .. "/common/ssl/https.lua")
local state
local function installMocks()
    state = { response = '{"choices":[{"message":{"content":"read this"}}]}', code = 200,
        headers = nil, host_match = true, peer_verify = true, finish_reason = "stop",
        dns_ip_name = false, ip_match = false, tls_timeouts = {}, sni_hosts = {} }
    local tls_index = {
        -- Bundled LuaSec's sni() successfully sets the name but returns nil.
        sni = function(_, host) state.sni_hosts[#state.sni_hosts + 1] = host; return nil end,
        settimeout = function(_, timeout, mode)
            state.tls_timeouts[#state.tls_timeouts + 1] = { timeout, mode }
            return true
        end,
        dohandshake = function() return state.peer_verify end,
        getpeercertificate = function()
            return { extensions = function()
                local dns = { state.host_match and "api.example.test" or "wrong.example.test" }
                if state.dns_ip_name then dns[#dns + 1] = "127.0.0.1" end
                return { ["2.5.29.17"] = { dNSName = dns,
                    iPAddress = state.ip_match and { "127.0.0.1" } or {} } }
            end }
        end,
        close = function() end,
        send = function() return true end,
        receive = function() return "" end,
    }
    package.loaded["socket"] = {
        gettime = function() return 1 end,
        tcp = function()
            return {
                settimeout = function() return true end,
                connect = function(_, host) state.tcp_host = host; return true end,
                close = function() end,
            }
        end,
    }
    package.loaded["ssl"] = {
        wrap = function(_, params)
            state.tls_params = params
            return setmetatable({}, { __index = tls_index })
        end,
    }
    package.loaded["socketutil"] = {
        set_timeout = function(_, connect, total) state.timeouts = { connect, total } end,
        reset_timeout = function() state.reset = true end,
    }
    package.loaded["mime"] = { b64 = function(bytes) state.png = bytes; return "cG5n" end }
    package.loaded["json"] = {
        encode = function(payload) state.payload = payload; return "request-json" end,
        decode = function(body)
            if body ~= state.response or state.malformed then error("malformed") end
            if state.bad_shape then return { choices = 4 } end
            return { choices = { { finish_reason = state.finish_reason,
                message = { content = "read this" } } } }
        end,
    }
    package.loaded["ltn12"] = { source = { string = function(body) state.body = body; return function() return body end end } }
    package.loaded["socket.http"] = {
        request = function(req)
            state.request = req
            local conn = req.create()
            assert(conn:settimeout(15))
            local host = req.url:match("^https://%[([^%]]+)%]")
                    or req.url:match("^https://([^/:]+)")
            assert(conn:connect(host, 443))
            assert(conn:send("request"))
            local _, sink_error = req.sink(state.response)
            if sink_error then state.sink_error = sink_error end
            local headers = state.headers or { ["content-length"] = tostring(#state.response) }
            return 1, state.code, headers
        end,
    }
end
installMocks()
local png = "\137PNG\r\n\26\n" .. "12345678" .. "IEND\174B\96\130"
local function request()
    return Api.request(config, png)
end
local text = request()
ok(text == "read this", "returns OCR text from a valid response")
ok(state.request.method == "POST" and state.request.redirect == false, "uses POST and disables redirects")
ok(state.request.headers.Authorization == "Bearer secret", "sends a Bearer key")
ok(state.payload.messages[1].content[1].text == "OCR:", "sends the OCR prompt")
ok(state.payload.messages[1].content[2].image_url.url == "data:image/png;base64,cG5n", "sends base64 PNG data URI")
ok(state.png == png, "base64 encodes the supplied PNG bytes")
ok(state.payload.stream == false and state.payload.max_tokens == 2048, "uses bounded non-streaming completion")
ok(state.tls_params.verify[1] == "peer" and state.tls_params.cafile:match("ca%-bundle%.crt$"),
    "requires peer and bundled CA verification")
ok(state.tls_timeouts[1][1] == 15 and state.tls_timeouts[1][2] == "b"
    and state.tls_timeouts[2][1] == 90 and state.tls_timeouts[2][2] == "t",
    "reapplies block and total timeouts on the wrapped TLS socket")
ok(state.timeouts[1] == 15 and state.timeouts[2] == 90 and state.reset, "bounds and resets socket timeouts")

local ip_config = assert(Api.validate({ url = "https://127.0.0.1/v1", key = "secret", model = "vision" }))
state.host_match, state.dns_ip_name, state.ip_match = true, true, false
local sni_count = #state.sni_hosts
local result = Api.request(ip_config, png)
ok(result == nil, "does not accept an IP address appearing only in dNSName SAN")
state.ip_match = true
result = Api.request(ip_config, png)
ok(result == "read this", "matches numeric IP hosts against iPAddress SAN")
ok(#state.sni_hosts == sni_count, "does not send DNS SNI for numeric IP hosts")
state.host_match, state.dns_ip_name, state.ip_match = true, false, false

state.host_match = false
local err
result, err = request()
ok(result == nil and err == "OCR request failed.", "rejects a certificate for another host")
state.host_match = true
state.peer_verify = false
result = request()
ok(result == nil, "rejects an unverified certificate chain")
state.peer_verify = true
state.code = 429
result, err = request()
ok(result == nil and err == "OCR service returned HTTP 429.", "returns safe HTTP status only")
state.code = 200
state.headers = { ["content-length"] = tostring(#state.response + 1) }
result = request()
ok(result == nil, "rejects truncated response length")
state.headers = { ["content-encoding"] = "gzip" }
result = request()
ok(result == nil, "rejects unsupported response filters")
state.headers = nil
state.response = "not-json"
state.malformed = true
result = request()
ok(result == nil, "rejects malformed JSON")
state.malformed, state.bad_shape = false, true
state.response = "{}"
result = request()
ok(result == nil, "rejects malformed response structure")
state.bad_shape = false
state.response = ""
result = request()
ok(result == nil, "rejects an empty response")
state.response = '{"choices":[{"message":{"content":"partial"}}]}'
state.finish_reason = "length"
result = request()
ok(result == nil, "rejects a nonempty response truncated by the token limit")
state.finish_reason = "content_filter"
result = request()
ok(result == nil, "rejects a nonempty content-filtered response")
state.finish_reason = "stop"
state.response = string.rep("x", 256 * 1024 + 1)
result, err = request()
ok(result == nil and err == "OCR response was too large.", "caps the response sink")
result = Api.request(config, "")
ok(result == nil, "rejects empty PNG")
result = Api.request(config, "not a PNG")
ok(result == nil, "rejects malformed PNG input")
result = Api.request(config, string.rep("x", 4 * 1024 * 1024 + 1))
ok(result == nil, "caps PNG size before networking")

package.path = old_path
package.loaded["ssl.https"] = nil
package.loaded["socket"] = nil
package.loaded["ssl"] = nil
package.loaded["socketutil"] = nil
package.loaded["mime"] = nil
package.loaded["json"] = nil
package.loaded["ltn12"] = nil
package.loaded["socket.http"] = nil
os.remove(runtime_root .. "/common/ssl/https.lua")
os.remove(runtime_root .. "/data/ca-bundle.crt")
os.execute("rmdir " .. runtime_root .. "/common/ssl " .. runtime_root .. "/common " .. runtime_root .. "/data " .. runtime_root)
print(("ocr_api: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
