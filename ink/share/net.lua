--[[
The reader on its network, for Send to phone or computer: the address other
devices on the same Wi-Fi reach it at, and on a Kindle a hole in its firewall
for the page's port while it is open (as KOReader's SSH server makes one).
]]

local Net = {}

local function isLan(ip)
    return type(ip) == "string" and ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
        and ip ~= "0.0.0.0" and not ip:match("^127%.") and not ip:match("^169%.254%.")
end
Net.isLan = isLan

local function run(cmd)
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return "" end
    local out = p:read("*a") or ""
    p:close()
    return out
end

-- The reader's address on its network, or nil without one. The address the
-- system would send from (a UDP socket only picks its route: nothing is sent),
-- else what the system's tools list.
function Net.localIP(socket, runner)
    runner = runner or run
    if socket and socket.udp then
        local udp = socket.udp()
        if udp then
            local ok, ip = pcall(function()
                udp:setpeername("192.0.2.1", 9)   -- a documentation address: never reached
                return udp:getsockname()
            end)
            pcall(udp.close, udp)
            if ok and isLan(ip) then return ip end
        end
    end
    local ip = runner("ip -4 route get 192.0.2.1"):match("%ssrc%s+(%d+%.%d+%.%d+%.%d+)")
    if isLan(ip) then return ip end
    for cand in runner("ip -4 addr"):gmatch("inet%s+(%d+%.%d+%.%d+%.%d+)") do
        if isLan(cand) then return cand end
    end
    for _, pat in ipairs({ "inet addr:(%d+%.%d+%.%d+%.%d+)", "inet%s+(%d+%.%d+%.%d+%.%d+)" }) do
        for cand in runner("ifconfig"):gmatch(pat) do
            if isLan(cand) then return cand end
        end
    end
    return nil
end

-- The Kindle's firewall turns away connections from other devices: let them
-- reach `port` while the page is open, and close it again after.
local function firewall(action, port, runner)
    runner = runner or run
    runner(string.format("iptables -%s INPUT -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT",
        action, port))
    runner(string.format("iptables -%s OUTPUT -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT",
        action, port))
end
function Net.openFirewall(port, runner) firewall("A", port, runner) end
function Net.closeFirewall(port, runner) firewall("D", port, runner) end

return Net
