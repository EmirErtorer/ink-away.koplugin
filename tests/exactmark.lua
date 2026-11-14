-- Exact markers (ink/reader/exactmark.lua): crengine xpointers parsed and written,
-- a place found in an XHTML file the way crengine reads it (entities, comments,
-- CDATA, spaces, namespaces, unclosed tags), words wrapped in marker spans with
-- refusals where that is not safe, several marks in one file, and xpointers moved
-- between the book and its edited copy.
--   luajit tests/exactmark.lua
package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local E = require("ink/reader/exactmark")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end

-- An XHTML file around a body.
local function page(body, head)
    return '<?xml version="1.0" encoding="utf-8"?>\n<!DOCTYPE html>\n<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
        .. "<head><title>t</title>" .. (head or "") .. "</head>\n<body>\n" .. body .. "\n</body></html>"
end

-- Steps from a short path like "div[2]/p[3]".
local function steps(path)
    local out = {}
    for name, idx in path:gmatch("([%w_%-]+)%[(%d+)%]") do out[#out + 1] = { name = name, idx = tonumber(idx) } end
    return out
end

-- The modelled element at path.
local function elemAt(doc, path)
    local el = doc.body
    for _, st in ipairs(steps(path)) do
        local n, found = 0, nil
        for _, k in ipairs(el.kids) do
            if not k.t and k.name == st.name then
                n = n + 1
                if n == st.idx then found = k; break end
            end
        end
        el = found
    end
    return el
end

-- The text nodes of the element at path, as crengine would hold them.
local function texts(x, path)
    local doc = E.model(x)
    local el = doc.body
    for _, st in ipairs(steps(path)) do
        local n = 0
        for _, k in ipairs(el.kids) do
            if not k.t and k.name == st.name then
                n = n + 1
                if n == st.idx then el = k; break end
            end
        end
    end
    local out = {}
    for _, t in ipairs(E.textsOf(doc, el)) do out[#out + 1] = t.text or ("?" .. tostring(t.why)) end
    return out, doc
end

-- ---- xpointers ------------------------------------------------------------------
do
    local p = E.parse("/body[1]/DocFragment[3]/body[1]/div[2]/p[12]/text()[2].57")
    ok(p and p.frag == 3 and #p.steps == 2 and p.steps[1].name == "div" and p.steps[1].idx == 2
        and p.steps[2].name == "p" and p.steps[2].idx == 12 and p.text == 2 and p.off == 57, "parse: a text xpointer")
    p = E.parse("/body/DocFragment[14]/body/div/p[152]/text().5")
    ok(p and p.frag == 14 and p.steps[1].idx == 1 and p.steps[2].idx == 152 and p.text == 1 and p.off == 5,
        "parse: unindexed steps and text().off are the first")
    p = E.parse("/body[1]/DocFragment[2]/body[1]/p[3]")
    ok(p and p.text == nil and p.off == nil and #p.steps == 1, "parse: an element xpointer has no text")
    p = E.parse("/body[1]/DocFragment[2]/body[1]/p[3]/img[1].0")
    ok(p and p.point == 0 and p.steps[2].name == "img", "parse: an element point")
    p = E.parse("/body[1]/DocFragment[2]/body[1]/svg[1]/text[1]/text()[1].0")
    ok(p and p.steps[2].name == "text" and p.text == 1, "parse: an svg <text> element is a step, not a text node")
    ok(E.parse("/body/DocFragment[1]/body/autoBoxing/p/text().0") == nil, "parse: old xpointers with boxing elements are refused")
    ok(E.parse("/FictionBook/body/p[1]") == nil and E.parse("nonsense") == nil and E.parse(nil) == nil, "parse: not an EPUB xpointer")
    ok(E.parse("/body[1]/DocFragment[2]/body[1]/p[3]/text()[1]") == nil, "parse: a text step needs an offset")
    ok(E.format(E.parse("/body/DocFragment[3]/body/div/p/text().7")) == "/body[1]/DocFragment[3]/body[1]/div[1]/p[1]/text()[1].7",
        "format: every index explicit")
end

-- ---- reading files the way crengine does ----------------------------------------------
do
    local t = texts(page("<p>Hello   world\n   again\tand\r\nmore </p>"), "p[1]")
    ok(#t == 1 and t[1] == "Hello world again and more ", "text: runs of spaces and newlines are one space")
    t = texts(page("<p>a &amp; b&nbsp;c &#8217;d &#x2019;e &#150;f &hellip;g</p>"), "p[1]")
    ok(t[1] == "a & b\194\160c \226\128\153d \226\128\153e \226\128\147f \226\128\166g", "text: entities, cp1252 numbers")
    t = texts(page("<p>before<!-- a comment -->after</p>"), "p[1]")
    ok(#t == 2 and t[1] == "before" and t[2] == "after", "text: a comment ends a text node")
    t = texts(page("<p><![CDATA[cdata & <raw>]]> following</p>"), "p[1]")
    ok(#t == 2 and t[1] == "cdata & <raw>" and t[2] == " following", "text: CDATA is its own node")
    t = texts(page("<p>\n    leading ws</p>"), "p[1]")
    ok(#t == 1 and t[1] == " leading ws", "text: leading newline and spaces before text become a space")
    t = texts(page("<p>\n  <em>first</em>\n   <em>second</em> end</p>"), "p[1]")
    ok(#t == 2 and t[1] == " " and t[2] == " end", "text: spaces first in a block are dropped, between inlines kept")
    t = texts(page("<p><span>\n   inside</span></p>"), "p[1]/span[1]")
    ok(#t == 1 and t[1] == " inside", "text: an inline element keeps its leading space")
    t = texts(page("<p>one<br/>two<br />three</p>"), "p[1]")
    ok(#t == 3 and t[3] == "three", "text: self-closed br")
    t = texts(page("<p>one<br>two<br>three</p>"), "p[1]/br[1]")
    ok(#t == 1 and t[1] == "two", "text: br without a slash holds what follows (as crengine)")
    t = texts(page("<p>Türkçe “quoted” ğüşiöç İı</p>"), "p[1]")
    ok(t[1] == "Türkçe “quoted” ğüşiöç İı", "text: UTF-8 kept")
    t = texts(page("<div>\n  <p>in div</p>\n  tail text\n  <p>two</p>\n</div>"), "div[1]")
    ok(#t == 1 and t[1] == " tail text ", "text: spaces between blocks are dropped by the layout")
    t = texts(page("<div>\n<p>a</p>\n<span epub:type=\"pagebreak\" id=\"p5\"/>\n<p>b</p> tail</div>"), "div[1]")
    ok(#t == 1 and t[1] == " tail", "text: a hidden page break is no inline neighbour")
    t = texts(page("<p>a <ns:foo>x</ns:foo> b <foo>y</foo></p>"), "p[1]/foo[2]")
    ok(t[1] == "y", "text: a namespace prefix is dropped from the name")
    t = texts(page("<p class=x title='a>b'>quoted gt</p>"), "p[1]")
    ok(t[1] == "b'>quoted gt", "text: '>' in a quoted attribute ends the tag (as crengine)")
    t = texts(page("<P CLASS='U'>Upper</P>"), "p[1]")
    ok(t[1] == "Upper", "text: tag names are lowercase")
    local long = {}
    for i = 1, 1800 do long[#long + 1] = "word" .. i end
    t = texts(page("<p>" .. table.concat(long, " ") .. "</p>"), "p[1]")
    ok(#t == 2 and #t[1] == 8190 and t[1]:sub(-1) == " ", "text: a run over 8192 characters splits after a space")
    t = texts(page("<p>AT & T</p>"), "p[1]")
    ok(t[1] == "?entity", "text: a bare ampersand is refused, not guessed")
    local _, doc = texts(page("<p\tclass='x'>tab</p>"), "")
    ok(doc.anomaly == "tag", "model: a tab after a tag name is an anomaly")
    _, doc = texts('<html><body><p>a</p></body><body><p>b</p></body></html>', "")
    ok(doc.bodies == 2, "model: two bodies counted")
    _, doc = texts('<?xml version="1.0" encoding="iso-8859-1"?><html><body><p>a</p></body></html>', "")
    ok(doc.anomaly == "encoding", "model: another encoding is refused")
    t = texts(page('<p>a</p><style>p { x: "</p>" }</style><script>var a = "<p>";</script><p>after</p>'), "p[2]")
    ok(t[1] == "after", "model: style and script are raw text")
end

-- ---- locate ---------------------------------------------------------------------------
do
    local x = page("<p>x <em>em</em> tail &amp; t&#233;xt</p>")
    local pos, info = E.locate(x, steps("p[1]"), 2, 0)
    ok(pos and x:sub(pos, pos + 4) == " tail" and info.text == " tail & téxt" and info.chars == 12, "locate: second text node after an inline")
    pos = E.locate(x, steps("p[1]"), 2, 6)
    ok(pos and x:sub(pos, pos + 4) == "&amp;", "locate: an entity is one character, at its '&'")
    pos = E.locate(x, steps("p[1]"), 2, 9)
    ok(pos and x:sub(pos, pos + 5) == "&#233;", "locate: offsets count characters, not bytes")
    pos = E.locate(x, steps("p[1]"), 2, 12)
    ok(pos and x:sub(pos, pos + 3) == "</p>", "locate: the end of the node")
    ok(E.locate(x, steps("p[1]"), 2, 13) == nil, "locate: past the end")
    ok(select(2, E.locate(x, steps("p[2]"), 1, 0)) == "path", "locate: no such element")
    ok(select(2, E.locate(x, steps("p[1]"), 3, 0)) == "text", "locate: no such text node")
    x = page("<p>a   <!-- c -->  b  c</p>")
    pos = E.locate(x, steps("p[1]"), 2, 3)
    ok(pos and x:sub(pos, pos) == "c", "locate: spaces made one before counting")
    x = page("<pre>\n a  b</pre>")
    ok(select(2, E.locate(x, steps("pre[1]"), 1, 0)) == "pre", "locate: pre is not modelled")
    x = page("<p>Türkçe ğüş word</p>")
    pos = E.locate(x, steps("p[1]"), 1, 11)
    ok(pos and x:sub(pos, pos + 3) == "word", "locate: UTF-8 text")
end

-- ---- wrap ------------------------------------------------------------------------------
do
    local x = page("<p class=\"c\">The quick brown fox</p>")
    local at = x:find("quick", 1, true)
    local new, info = E.wrap(x, at + 2, 4)
    ok(new and new:find('The <span class="iar" id="iar4">quick</span> brown', 1, true) ~= nil, "wrap: the word holding pos")
    ok(info and info.word == "quick" and #info.steps == 2 and info.steps[2].name == "span" and info.steps[2].idx == 1,
        "wrap: the span's path")
    ok(info.split.text == 1 and info.split.off == 4 and info.split.len == 5 and info.split.tail == 10 and info.split.span == 1,
        "wrap: the split")
    new = E.wrap(x, at + 2, 4, { exact = true })
    ok(new and new:find('qu<span class="iar" id="iar4">ick</span>', 1, true) ~= nil, "wrap: exact starts at pos")
    ok(select(2, E.wrap(x, x:find("class", 1, true), 1)) == "not text", "wrap: never inside a tag")
    ok(select(2, E.wrap(x, at - 1, 1)) == "space", "wrap: not on a space")
    local function refusedIn(body, word)
        local y = page(body)
        local ok2, why = E.wrap(y, y:find(word, 1, true), 1)
        return ok2 == nil and why
    end
    ok(refusedIn("<pre>a word</pre>", "word") == "pre", "wrap: not in pre")
    ok(refusedIn("<p>x<script>var word;</script></p>", "word"), "wrap: not in script")
    ok(refusedIn("<p>x <math><mi>word</mi></math></p>", "word") == "math", "wrap: not in math")
    ok(refusedIn("<svg><text>word</text></svg>", "word") == "svg", "wrap: not in svg")
    ok(refusedIn('<p>a <span class="iar">word</span></p>', "word") == "marker", "wrap: not in a marker")
    ok(refusedIn("<p>a<br>word</p>", "word") == "void", "wrap: not in text crengine put inside a void tag")
    ok(refusedIn("<div><p>a</p> word b<p>c</p></div>", "word") == "block-edge",
        "wrap: refused when the space before the word would vanish from the layout")
    x = page('<p id="iar4">x</p><p>some word</p>')
    new = E.wrap(x, x:find("word", 1, true), 4)
    ok(new and new:find('<span class="iar">word</span>', 1, true) ~= nil, "wrap: no clashing id")
    x = page("<p><em>a</em> <span>b</span> words</p>")
    new, info = E.wrap(x, x:find("words", 1, true), 1)
    ok(new and info.steps[2].idx == 2 and info.split.span == 2 and info.split.text == 2, "wrap: the span counted after other spans")
end

-- ---- several marks and moving xpointers -----------------------------------------------
do
    local x = page("<h1>T</h1>\n<p>alpha beta gamma delta epsilon</p>\n<div><span>s</span> one two three</div>")
    local spine = { "a.xhtml", "b.xhtml" }
    local function m(path, j, off, word, id) return { frag = 2, steps = steps(path), text = j, off = off, word = word, id = id } end
    local marks = {
        m("p[1]", 1, 17, "delta", "d"),
        m("p[1]", 1, 0, "alpha", "a"),
        m("p[1]", 1, 6, "beta", "b"),
        m("div[1]", 1, 5, "two", "t"),
        m("p[1]", 1, 18, "delta", "x"),     -- inside delta again
        m("p[1]", 1, 11, "gamut", "g"),     -- wrong word
        m("p[1]", 1, 31, "epsilon", "e"),   -- past the word
    }
    local out, res = E.apply({ ["b.xhtml"] = x, ["c.css"] = "x" }, marks, spine)
    local new = out["b.xhtml"]
    ok(res[1].applied and res[2].applied and res[3].applied and res[4].applied, "apply: four marks")
    ok(not res[5].applied and res[5].why == "duplicate", "apply: the same word twice is refused")
    ok(not res[6].applied and res[6].why == "mismatch" and res[6].word == "gamma", "apply: a wrong word is refused")
    ok(not res[7].applied and res[7].why == "offset", "apply: past the end is refused")
    ok(out["c.css"] == "x", "apply: other entries kept")
    ok(new:find('<p><span class="iar" id="iara">alpha</span> <span class="iar" id="iarb">beta</span> gamma <span class="iar" id="iard">delta</span> epsilon</p>', 1, true) ~= nil,
        "apply: spans in the paragraph")
    ok(res[1].xp == "/body[1]/DocFragment[2]/body[1]/p[1]/span[3]" and res[2].xp == "/body[1]/DocFragment[2]/body[1]/p[1]/span[1]"
        and res[3].xp == "/body[1]/DocFragment[2]/body[1]/p[1]/span[2]" and res[4].xp == "/body[1]/DocFragment[2]/body[1]/div[1]/span[2]",
        "apply: each span's xpointer counts every span in the edited chapter")
    local nres = { res[1], res[2], res[3], res[4] }
    ok(E.toNew("/body/DocFragment[2]/body/p/text().0", nres) == res[2].xp .. "/text()[1].0", "toNew: a marked word's start is its span's")
    ok(E.toNew("/body/DocFragment[2]/body/p/text().12", nres) == "/body[1]/DocFragment[2]/body[1]/p[1]/text()[2].2", "toNew: between marks")
    ok(E.toNew("/body/DocFragment[2]/body/div/text().9", nres) == "/body[1]/DocFragment[2]/body[1]/div[1]/text()[2].1", "toNew: after a mark")
    ok(E.toNew("/body/DocFragment[3]/body/p/text().12", nres) == "/body[1]/DocFragment[3]/body[1]/p[1]/text()[1].12", "toNew: another chapter")
    ok(E.toNew("/body/DocFragment[2]/body/h1/text().0", nres) == "/body[1]/DocFragment[2]/body[1]/h1[1]/text()[1].0", "toNew: another element")
    local back, flag = E.toOld(res[2].xp, nres)
    ok(back == "/body[1]/DocFragment[2]/body[1]/p[1]" and flag == "marker", "toOld: a marker span is its paragraph, flagged")
    ok(E.toOld(res[3].xp .. "/text()[1].2", nres) == "/body[1]/DocFragment[2]/body[1]/p[1]/text()[1].8", "toOld: inside a marker")
    ok(E.toOld("/body[1]/DocFragment[2]/body[1]/div[1]/span[1]/text()[1].0", nres) == "/body[1]/DocFragment[2]/body[1]/div[1]/span[1]/text()[1].0",
        "toOld: a span before the marker keeps its index")
    -- every place of the marked text nodes goes there and back
    local inverse, nodes = true, { { "p[1]", 1, 30 }, { "div[1]", 1, 14 } }
    for _, nd in ipairs(nodes) do
        for off = 0, nd[3] do
            local p = { frag = 2, steps = steps(nd[1]), text = nd[2], off = off }
            local old = E.format(p)
            local nx = E.toNew(old, nres)
            if E.toOld(nx, nres) ~= old then inverse = false; print("  inverse", old, nx, E.toOld(nx, nres)) end
        end
    end
    ok(inverse, "toNew and toOld are inverse on every offset of the marked nodes")
    -- and every place of the edited paragraph comes back to the same text
    local newDoc = E.model(new)
    local same = true
    local oldDoc = E.model(x)
    local oldText = E.textsOf(oldDoc, elemAt(oldDoc, "p[1]"))[1].text
    local function chars(s)
        local t = {}
        for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do t[#t + 1] = ch end
        return t
    end
    local oc = chars(oldText)
    local pEl = elemAt(newDoc, "p[1]")
    for j, t in ipairs(E.textsOf(newDoc, pEl)) do
        local tc = chars(t.text)
        for off = 0, #tc - 1 do
            local xp = "/body[1]/DocFragment[2]/body[1]/p[1]/text()[" .. j .. "]." .. off
            local o = E.parse(E.toOld(xp, nres))
            if not o or oc[o.off + 1] ~= tc[off + 1] then same = false end
        end
    end
    for si = 1, 3 do
        local sp = elemAt(newDoc, "p[1]/span[" .. si .. "]")
        local w = chars(E.textsOf(newDoc, sp)[1].text)
        for off = 0, #w - 1 do
            local o = E.parse(E.toOld("/body[1]/DocFragment[2]/body[1]/p[1]/span[" .. si .. "]/text()[1]." .. off, nres))
            if not o or oc[o.off + 1] ~= w[off + 1] then same = false end
        end
    end
    ok(same, "toOld: every character of the edited paragraph maps to the same character")
    ok(marks[1].split and marks[1].split.seq < marks[2].split.seq and marks[5].split == false and marks[6].split == false,
        "apply: each mark keeps its split (spans go in from the end), false when not applied")
    ok(E.toNew("/body/DocFragment[2]/body/p/text().12", marks) == "/body[1]/DocFragment[2]/body[1]/p[1]/text()[2].2"
        and E.toOld(res[3].xp .. "/text()[1].2", marks) == "/body[1]/DocFragment[2]/body[1]/p[1]/text()[1].8",
        "toNew and toOld: the stored marks work as well as the results")
    local fresh = { { frag = 2, steps = steps("p[1]"), text = 1, off = 0, word = "alpha" } }
    ok(select(2, E.toNew("/body/DocFragment[2]/body/p/text().12", fresh)) == "nosplit", "toNew: a mark that never went through apply")
    -- affects
    local cand = { parent_steps = steps("p[1]"), text = 1, off = 6, frag = 2 }
    ok(E.affects("/body/DocFragment[2]/body/p/text().7", cand) and not E.affects("/body/DocFragment[2]/body/p/text().5", cand),
        "affects: after the split, not before")
    ok(E.affects("/body/DocFragment[2]/body/p/text()[2].0", cand) and E.affects("/body/DocFragment[2]/body/p/span[1]", cand),
        "affects: later text nodes and spans of the paragraph")
    ok(not E.affects("/body/DocFragment[2]/body/p[2]/text().7", cand) and not E.affects("/body/DocFragment[3]/body/p/text().7", cand)
        and not E.affects("/body/DocFragment[2]/body/p/em/text().0", cand), "affects: other paragraphs, chapters and elements are safe")
    ok(E.affects("/body/DocFragment[2]/body/p/span[2]/text().0", { parent_steps = steps("p[1]"), text = 1, off = 6, span = 2 })
        and not E.affects("/body/DocFragment[2]/body/p/span[1]/text().0", { parent_steps = steps("p[1]"), text = 1, off = 6, span = 2 }),
        "affects: spans counted from the split")
    ok(E.affects("/body/DocFragment[2]/body/p/text().20", { res[1], res[2] }), "affects: apply results")
end

-- ---- needs the engine's text where CSS could move the index --------------------------------
do
    local x = page("<p><span>x</span> <span>y</span> words here</p>")
    local spine = { "a.xhtml" }
    local _, res = E.apply({ ["a.xhtml"] = x }, { { frag = 1, steps = steps("p[1]"), text = 2, off = 1, word = "words" } }, spine)
    ok(not res[1].applied and res[1].why == "needs node_text", "apply: a space between elements before the word needs node_text")
    _, res = E.apply({ ["a.xhtml"] = x }, { { frag = 1, steps = steps("p[1]"), text = 2, off = 1, word = "words", node_text = " words here" } }, spine)
    ok(res[1].applied, "apply: with the engine's node text it goes in")
    _, res = E.apply({ ["a.xhtml"] = x }, { { frag = 1, steps = steps("p[1]"), text = 2, off = 1, word = "words", node_text = " " } }, spine)
    ok(not res[1].applied and res[1].why == "node-text", "apply: the engine holding other text refuses")
    _, res = E.apply({ ["a.xhtml"] = x }, { { frag = 2, steps = steps("p[1]"), text = 2, off = 1, word = "words" } }, spine)
    ok(res[1].why == "frag", "apply: a fragment past the spine")
end

-- ---- words as the engine gives them ----------------------------------------------------------
do
    local x = page("<p>He said, “come here” to exam-\nple and examples</p>")
    local spine = { "a.xhtml" }
    local function one(off, word, exact)
        local out, res = E.apply({ ["a.xhtml"] = x }, { { frag = 1, steps = steps("p[1]"), text = 1, off = off, word = word, exact = exact } }, spine)
        return res[1], out["a.xhtml"]
    end
    local r, new = one(3, "said")
    ok(r.applied and r.word == "said," and new:find('<span class="iar">said,</span>', 1, true), "apply: the engine's word without its punctuation")
    r = one(9, "“come")
    ok(r.applied and r.word == "“come", "apply: a word with a curly quote")
    r = one(30, "ple")
    ok(r.applied and r.word == "ple", "apply: a line after a hyphen starts a word of its own")
    r = one(41, "mples")
    ok(r.applied and r.word == "mples" and r.split.off == 41, "apply: a mark inside a word wraps from there when only that matches")
    r = one(41, "examples")
    ok(r.applied and r.word == "examples" and r.split.off == 38, "apply: a mark inside a word wraps the whole word")
    r = one(39, "xamples", true)
    ok(r.applied and r.word == "xamples" and r.split.off == 39, "apply: exact starts at the offset")
    r = one(3, "sad")
    ok(not r.applied and r.why == "mismatch", "apply: a word that is not there")
end

-- ---- the spine ------------------------------------------------------------------------------
do
    local files = {
        ["META-INF/container.xml"] = '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OPS/pkg.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        ["OPS/pkg.opf"] = [[<package><manifest>
            <item id="c1" href="text/c1.xhtml" media-type="application/xhtml+xml"/>
            <item id="img" href="../img/a.jpg" media-type="image/jpeg"/>
            <item id="c2" href="text/c%202.xhtml" media-type="application/xhtml+xml"/>
            <opf:item id="c3" href="text/c3&amp;x.html" media-type="text/html"/>
            <item id="two" href="two.xhtml" media-type="application/xhtml+xml"/>
        </manifest><spine toc="ncx"><itemref idref="c1"/><itemref idref="img"/><itemref idref="nosuch"/>
            <itemref idref="c2" linear="no"/><opf:itemref idref="c3"/><itemref idref="two"/></spine></package>]],
        ["OPS/two.xhtml"] = "<html><body><p>a</p></body><body><p>b</p></body></html>",
    }
    local read = function(p) return files[p] end
    local sp, info = E.spine(read)
    ok(sp and #sp == 5 and sp[1] == "OPS/text/c1.xhtml" and sp[2] == "img/a.jpg" and sp[3] == "OPS/text/c 2.xhtml"
        and sp[4] == "OPS/text/c3&x.html" and sp[5] == "OPS/two.xhtml", "spine: every item found, paths resolved and decoded")
    ok(info[3].linear == false and info[2].media == "image/jpeg", "spine: item details")
    sp = E.spine(read, { bodies = true })
    ok(#sp == 6 and sp[6] == "OPS/two.xhtml", "spine: a file with two bodies makes two fragments")
    sp = E.spine(read, { dom_version = 20230101 })
    ok(#sp == 3 and sp[2] == "OPS/text/c 2.xhtml" and sp[3] == "OPS/two.xhtml", "spine: older books count only XHTML items")
    ok(E.spine(function() return nil end) == nil, "spine: no container")
end

-- ---- lead spans, the split cache, node hashes -------------------------------------------
do
    local xhtml = page("<p>One two three four, five six.</p>")
    local spine = { "c.xhtml" }
    local function run(marks) return E.apply({ ["c.xhtml"] = xhtml }, marks, spine) end
    -- "four," at offset 14 (One two three |four,): lead takes the space before it
    local marks = { { id = "a", frag = 1, steps = steps("p[1]"), text = 1, off = 14, word = "four,", lead = true } }
    local out, res = run(marks)
    ok(res[1].applied and out["c.xhtml"]:find('three<span class="iar" id="iara"> four,</span> five', 1, true) ~= nil,
        "lead: the span starts at the space before the word")
    ok(res[1].split and res[1].split.off == 13 and res[1].split.len == 6, "lead: the split takes the space in")
    -- the word itself is in the span after its space; the text after moves on
    ok(E.toNew("/body[1]/DocFragment[1]/body[1]/p[1]/text()[1].14", marks) == "/body[1]/DocFragment[1]/body[1]/p[1]/span[1]/text()[1].1",
        "lead: the word's start is the span's second character")
    ok(E.toNew("/body[1]/DocFragment[1]/body[1]/p[1]/text()[1].21", marks) == "/body[1]/DocFragment[1]/body[1]/p[1]/text()[2].2",
        "lead: a place after the word moves to the text after the span")
    for _, o in ipairs({ 0, 5, 12, 13, 14, 17, 19, 20, 21, 25 }) do
        local xp = "/body[1]/DocFragment[1]/body[1]/p[1]/text()[1]." .. o
        ok(E.toOld(E.toNew(xp, marks), marks) == xp, "lead: there and back at offset " .. o)
    end
    -- no space before the word in its node: "must" refuses, true wraps the word alone
    local x2 = page("<p>well-known words</p>")
    local m2 = { { id = "b", frag = 1, steps = steps("p[1]"), text = 1, off = 5, word = "known", lead = "must", exact = true } }
    local _o2, r2 = E.apply({ ["c.xhtml"] = x2 }, m2, spine)
    ok(not r2[1].applied and r2[1].why == "no-space", "lead must: refused without a space before the word")
    m2[1].lead = true
    _o2, r2 = E.apply({ ["c.xhtml"] = x2 }, m2, spine)
    ok(r2[1].applied and r2[1].split.off == 5, "lead true: the word alone when no space is before it")
    -- the split list is kept with the marks, and asked again gives the same places
    local a1 = E.toNew("/body[1]/DocFragment[1]/body[1]/p[1]/text()[1].25", marks)
    local a2 = E.toNew("/body[1]/DocFragment[1]/body[1]/p[1]/text()[1].25", marks)
    ok(a1 == a2 and a1 ~= nil, "splits: the kept list gives the same answer")
    ok(E.toNew("/body[1]/DocFragment[2]/body[1]/p[1]/text()[1].25", marks) == "/body[1]/DocFragment[2]/body[1]/p[1]/text()[1].25",
        "splits: another chapter is left alone")
    -- node_md5 in place of node_text, with a hash function set
    local saved = E.hash
    E.hash = function(str) return "h" .. #str end
    local m3 = { { id = "c", frag = 1, steps = steps("p[1]"), text = 1, off = 14, word = "four,", lead = true, node_md5 = "h" .. #"One two three four, five six." } }
    local _o3, r3 = run(m3)
    ok(r3[1].applied, "node_md5: the hash of the right node is accepted")
    m3 = { { id = "c", frag = 1, steps = steps("p[1]"), text = 1, off = 14, word = "four,", node_md5 = "h1" } }
    _o3, r3 = run(m3)
    ok(not r3[1].applied and r3[1].why == "node-text", "node_md5: a wrong hash is refused")
    E.hash = saved
end

print(("exactmark: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
