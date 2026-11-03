--[[
What the cloud sync needs to know about Ink Away's own registration with each
service. The app key of a service is public (it identifies the app, it is not a
secret: the sign-in uses PKCE and holds no secret). Dropbox's key is the one
Ink Away is registered under; a person who runs their own copy of the plugin
can enter their own in the sync settings, and that one wins.
]]

local Config = {}

-- Ink Away's Dropbox app key. Register an app at dropbox.com/developers with the
-- "App folder" access type and the permissions files.content.read,
-- files.content.write and account_info.read, then put its key here.
Config.DROPBOX_APP_KEY = ""

Config.KEY_SETTING = "inkaway_sync_dropbox_key"

-- The app key to use: the person's own if they entered one, else Ink Away's.
-- `get(key)` reads a setting. Returns nil when there is none.
function Config.appKey(provider_id, get)
    if provider_id ~= "dropbox" then return nil end
    local own = get and get(Config.KEY_SETTING)
    if type(own) == "string" and own:match("^%w+$") and #own >= 8 and #own <= 64 then return own end
    if Config.DROPBOX_APP_KEY ~= "" then return Config.DROPBOX_APP_KEY end
    return nil
end

return Config
