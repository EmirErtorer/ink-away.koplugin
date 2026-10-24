package.path = "./?.lua;./tests/mock/?.lua;" .. package.path
local UI = require("ui/uimanager")
local Canvas = require("ink/canvas")
local V = {}
for _, part in ipairs({ "handwriting", "ocrapi" }) do
    for k, fn in pairs(require("ink/view/" .. part)) do V[k] = fn end
end
local saved = {}
function V:getSetting(k) return saved[k] end
function V:setSetting(k, value) saved[k] = value end
function V:closeSheet() end
function V:sheetHint(text) return { text = text } end
function V:actionButton(text, _, cb) return { text = text, callback = cb } end

function V:promptText(options) self.prompt = options end
-- the switch, as the Text sheet's ToggleRow: tapping flips it and calls back
package.loaded["ink/ui/controls"] = { ToggleRow = { new = function(_, o)
    function o:onTap() self.is_on = not self.is_on; self.callback(self.is_on) end
    return o
end } }
function V:openTextSettings()
    self.fields = {}
    self:addOcrApiRows(function(w) if w.is_on ~= nil or w.callback then self.fields[#self.fields + 1] = w end end, {}, 600)
end
local view = setmetatable({}, { __index = V })
view:openTextSettings()
assert(#view.fields == 1 and not view.fields[1].is_on, "default off; all configuration hidden")
view.fields[1]:onTap()
assert(#view.fields == 4 and view.fields[1].is_on, "the switch immediately reveals three fields")
assert(view.fields[2].text == "Set the address", "an empty field says what to do")
for i, text in ipairs({ "https://example.test/v1", "private-test-key", "paddleocr-vl" }) do
    view.fields[i + 1].callback()
    assert(view.prompt.description and view.prompt.description ~= "", "each field explains where its value comes from")
    assert((view.prompt.text_type == "password") == (i == 2), "key editor is masked")
    view.prompt.on_ok(" " .. text .. " ")
end
assert(view.fields[3].text == "Key: ********" and view:ocrApiConfig().key == "private-test-key", "key never shown on the sheet")
view.fields[1]:onTap()
assert(#view.fields == 1 and view:ocrApiConfig().key == "private-test-key", "switching off hides and retains values")
local reopened = setmetatable({}, { __index = V })
assert(reopened:ocrApiConfig().model == "paddleocr-vl" and not reopened:ocrApiConfig().enabled,
    "settings survive view recreation")

local ink = { kind = "ink", pts = { 30, 40, 80, 40 }, width = 2 }
view.canvas, view.view = Canvas.new(200, 200), { canvas_w = 200, canvas_h = 200 }
view.canvas:setOps({ ink }); view.selection = { idxs = { 1 } }
view.showNotice = function(self, text) self.notice = text end
view.tell = function(self, text) self.notice = text end
view.resetLasso = function(self) self.selection = nil end
view.replaceWithText = function(self, text) self.applied = text end
view.hwrModels = function() return {}, {} end
view.readWriting = function() return "local result" end
local starts, done, work, cancelled = 0
package.loaded["ink/ocr/api"] = {
    validate = function(config) if config.url == "" then return nil, "Incomplete configuration" end; return config end,
    request = function() error("No test may issue a real request") end,
}
package.loaded["ink/ocr/job"] = { start = function(fn, cb)
    starts, work, done = starts + 1, fn, cb
    return function() cancelled = true end
end }
package.loaded["ui/network/manager"] = { isOnline = function() return true end }
local function review() return view.prompt and view.prompt.field == "_hwr_review" and view.prompt end
function V:closeSheet(field) if field == "_hwr_review" and view.prompt and view.prompt.field == field then view.prompt = nil end end
local function press(label)
    local d = assert(review(), "no review sheet")
    local edited = d.edited or d.input
    view.prompt = nil
    if label == "Convert" then return d.on_ok(edited) end
    if d.on_cancel then d.on_cancel() end
end
view:convertSelectionToTextNow()
assert(starts == 0 and review().input == "local result" and review().lines, "disabled means zero API jobs; a multiline review")
press("Cancel"); assert(not view.applied, "cancel preview preserves ink")
saved.inkaway_ocr_api.enabled = true
view.showProgress = function(_, o) return { close = function() end, options = o } end
view:convertSelectionToTextNow()
assert(starts == 1 and work and not view.applied, "API starts asynchronously without replacing ink")
done("first line\nsecond line")
assert(review().input == "first line\nsecond line", "multiline API response is editable")
review().edited = "edited result"
press("Convert"); assert(view.applied == "edited result", "only edited Apply replaces ink")
view.applied, view.selection = nil, { idxs = { 1 } }
view:convertSelectionToTextNow()
view.doc_path = "another.inkaway"
done("stale")
assert(not review() and not view.applied, "changed document rejects remote result")
view.doc_path = nil
view:convertSelectionToTextNow()
view.selection = nil
done("stale selection")
assert(not review(), "changed selection rejects remote preview")
view.selection = { idxs = { 1 } }
view:convertSelectionToTextNow()
done("review then mutate")
view.canvas.rev = view.canvas.rev + 1
press("Convert"); assert(not view.applied, "revision change rejects Convert")
view:convertSelectionToTextNow()
view:cancelOcrApi()
assert(cancelled and not review() and not view._ocr_progress, "cancel/close drops OCR UI")
view:convertSelectionToTextNow()
done(nil, "OCR service returned HTTP 503.")
assert(not view.applied and not review() and view.notice:find("503"), "API error preserves ink, without local fallback")
view:convertSelectionToTextNow()
local review = view.reviewWriting
view.reviewWriting = function() error("preview constructor failure") end
done("recognized")
assert(not view.applied and view.notice:find("preview"), "preview constructor failure preserves ink with a message")
view.reviewWriting = review
saved.inkaway_ocr_api.url = ""
local n = starts
view:convertSelectionToTextNow()
assert(starts == n and view.fields[1].is_on, "incomplete configuration opens the Text sheet without network")
UI.reset()
print("ocr_view: opt-in, conditional settings, key masking, routing, preview, stale results and cancellation passed")
