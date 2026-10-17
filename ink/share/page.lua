--[[
The web page Send to phone or computer shows in the other device's browser: a
library folder's subfolders and documents, each document with its picture and
its downloads, and the files already exported. Plain HTML and CSS in one
reply, no scripts, light or dark as the device is set.
]]

local Http = require("ink/share/http")

local Page = {}
local esc = Http.html

local CSS = [[
:root{--bg:#f6f7f4;--card:#fff;--ink:#1d1f1b;--mute:#6b7066;--line:#e3e6df;--acc:#9fd665;--acc-ink:#1a1a1a;--chip:#eef1ea}
@media (prefers-color-scheme:dark){:root{--bg:#141613;--card:#1f221d;--ink:#eef0ea;--mute:#a3a89c;--line:#30342d;--chip:#2a2e27}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.4 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}
header{background:var(--card);border-bottom:1px solid var(--line);padding:14px 16px;position:sticky;top:0;z-index:1}
header .brand{font-weight:700;font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--mute)}
header h1{margin:2px 0 0;font-size:22px}
nav{margin-top:6px;font-size:14px;color:var(--mute)}
nav a{color:var(--mute)}
main{max-width:1100px;margin:0 auto;padding:16px}
h2{font-size:15px;color:var(--mute);margin:22px 0 10px;text-transform:uppercase;letter-spacing:.05em}
.folders{display:flex;flex-wrap:wrap;gap:10px}
.folder{display:flex;align-items:center;gap:10px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:10px 14px;color:inherit;text-decoration:none;font-weight:600}
.folder i{width:22px;height:17px;border-radius:3px 3px 4px 4px;background:var(--dot,#c4c4c4);position:relative}
.folder i:before{content:"";position:absolute;left:0;top:-4px;width:10px;height:5px;border-radius:2px 2px 0 0;background:inherit;filter:brightness(.85)}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:14px}
.doc{background:var(--card);border:1px solid var(--line);border-radius:14px;overflow:hidden;display:flex;flex-direction:column}
.doc img{width:100%;aspect-ratio:3/4;object-fit:contain;background:#fff;border-bottom:1px solid var(--line)}
.doc .meta{padding:10px 12px 4px}
.doc .name{font-weight:650;word-break:break-word}
.doc .kind{font-size:13px;color:var(--mute)}
.doc .dl{display:flex;flex-wrap:wrap;gap:6px;padding:8px 12px 12px;margin-top:auto}
.btn{display:inline-block;padding:7px 12px;border-radius:999px;background:var(--chip);color:inherit;text-decoration:none;font-size:14px;font-weight:600}
.btn.main{background:var(--acc);color:var(--acc-ink)}
.files{background:var(--card);border:1px solid var(--line);border-radius:14px}
.files a{display:flex;justify-content:space-between;gap:12px;padding:12px 14px;color:inherit;text-decoration:none;border-top:1px solid var(--line)}
.files a:first-child{border-top:0}
.files span{color:var(--mute);font-size:14px;white-space:nowrap}
.empty{color:var(--mute)}
footer{color:var(--mute);font-size:13px;text-align:center;padding:24px 16px 32px}
]]

-- The page for `o`: { title, crumbs = { { label, href } }, folders = { { name,
-- href, color = "#rrggbb" } }, docs = { { name, kind, thumb, links = { { label,
-- href, main } } } }, exports = { { name, href, size } }, note }.
function Page.render(o)
    local h = {}
    local function add(s) h[#h + 1] = s end
    add('<!doctype html><html lang="en"><head><meta charset="utf-8">')
    add('<meta name="viewport" content="width=device-width,initial-scale=1">')
    add('<meta name="robots" content="noindex">')
    add("<title>" .. esc(o.title) .. " · Ink Away</title><style>" .. CSS .. "</style></head><body>")
    add('<header><div class="brand">Ink Away</div><h1>' .. esc(o.title) .. "</h1>")
    if o.crumbs and #o.crumbs > 0 then
        local parts = {}
        for _, c in ipairs(o.crumbs) do
            parts[#parts + 1] = c.href and ('<a href="' .. esc(c.href) .. '">' .. esc(c.label) .. "</a>") or esc(c.label)
        end
        add("<nav>" .. table.concat(parts, " › ") .. "</nav>")
    end
    add("</header><main>")
    if #(o.folders or {}) > 0 then
        add('<h2>Folders</h2><div class="folders">')
        for _, f in ipairs(o.folders) do
            local dot = f.color and (' style="--dot:' .. esc(f.color) .. '"') or ""
            add('<a class="folder" href="' .. esc(f.href) .. '"><i' .. dot .. "></i>" .. esc(f.name) .. "</a>")
        end
        add("</div>")
    end
    if #(o.docs or {}) > 0 then
        add('<h2>Notebooks and drawings</h2><div class="grid">')
        for _, d in ipairs(o.docs) do
            add('<div class="doc">')
            if d.thumb then add('<img loading="lazy" alt="" src="' .. esc(d.thumb) .. '">') end
            add('<div class="meta"><div class="name">' .. esc(d.name) .. '</div><div class="kind">'
                .. esc(d.kind or "") .. "</div></div>")
            add('<div class="dl">')
            for _, l in ipairs(d.links or {}) do
                add('<a class="btn' .. (l.main and " main" or "") .. '" href="' .. esc(l.href) .. '">'
                    .. esc(l.label) .. "</a>")
            end
            add("</div></div>")
        end
        add("</div>")
    elseif #(o.folders or {}) == 0 then
        add('<p class="empty">Nothing here yet.</p>')
    end
    if #(o.exports or {}) > 0 then
        add('<h2>Already exported</h2><div class="files">')
        for _, e in ipairs(o.exports) do
            add('<a href="' .. esc(e.href) .. '">' .. esc(e.name) .. "<span>" .. esc(e.size or "") .. "</span></a>")
        end
        add("</div>")
    end
    add("</main><footer>" .. esc(o.note or "") .. "</footer></body></html>")
    return table.concat(h)
end

-- The page shown for an old or mistyped address.
function Page.gone()
    return Page.render{ title = "This link has expired",
        note = "On your reader, open Send to phone or computer again and scan the new code." }
end

return Page
