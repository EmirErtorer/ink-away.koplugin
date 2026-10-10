-- What gestures and pen buttons do (ink/actions.lua): the defaults keep 4.0's
-- gestures and highlight with a held side button, a pen button is offered only
-- actions that make sense while held, overlaps are found before they are made,
-- and the choices are kept.
--   luajit tests/actions.lua
package.path = "./?.lua;" .. package.path
local Actions = require("ink/actions")

local checks, failures = 0, 0
local function ok(cond, what)
    checks = checks + 1
    if not cond then failures = failures + 1; print("FAIL: " .. what) end
end
local data = {}
local get, set = function(k) return data[k] end, function(k, v) data[k] = v end

local b = Actions.load(get)
ok(b.two_tap == "undo" and b.two_double_tap == "redo" and b.two_swipe_up == "browse",
    "defaults: 4.0's two-finger gestures")
ok(b.pen_side == "highlighter" and b.pen_side2 == "highlighter" and b.pen_eraser == "eraser",
    "defaults: the side buttons highlight while held, the eraser end erases")

-- pen buttons are offered only what makes sense held
local pen_ids = {}
for _i, a in ipairs(Actions.choices("pen_side")) do pen_ids[a.id] = true end
ok(pen_ids.highlighter and pen_ids.lasso and pen_ids.eraser and pen_ids.nothing, "pen: highlighter, lasso, eraser, nothing")
ok(not pen_ids.undo and not pen_ids.next_page, "pen: no undo or page turns on a held button")
ok(not Actions.set(b, "pen_side", "undo"), "pen: undo cannot be set on a button")
ok(Actions.set(b, "pen_side", "lasso") and b.pen_side == "lasso", "pen: lasso can")
ok(#Actions.choices("two_tap") == #Actions.LIST, "fingers: every action")

-- overlaps
local info = Actions.preview(b, "two_swipe_down", "undo")
ok(#info.also == 1 and info.also[1] == "two_tap", "overlap: undo is already on the two-finger tap")
ok(info.replaced == nil, "overlap: the swipe down did nothing before")
info = Actions.preview(b, "two_tap", "redo")
ok(info.replaced == "undo" and info.also[1] == "two_double_tap", "overlap: replacing undo, and redo is on the double tap")
Actions.set(b, "two_swipe_down", "undo", true)
ok(b.two_swipe_down == "undo" and b.two_tap == "nothing", "move: only the new gesture undoes")
Actions.set(b, "two_tap", "undo", false)
ok(b.two_tap == "undo" and b.two_swipe_down == "undo", "both: two gestures undo")

-- notes
ok(#Actions.notes(b, "two_swipe_left") == 1, "notes: sideways swipes and zoom")
Actions.set(b, "two_tap", "lasso")
ok(#Actions.notes(b, "two_tap") == 1, "notes: a single tap waits when a double tap is set")

-- kept, and reset
Actions.save(b, set)
local back = Actions.load(get)
ok(back.two_tap == "lasso" and back.pen_side == "lasso", "save: the choices come back")
data.inkaway_gestures.pen_side = "undo"          -- a hand-edited bad value
ok(Actions.load(get).pen_side == "highlighter", "load: a choice that is not allowed falls back to the default")
Actions.reset(back)
ok(back.two_tap == "undo" and back.pen_side == "highlighter", "reset: back to the usual")

print(("actions: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
