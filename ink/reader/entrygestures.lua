--[[
The two book gestures, set up once in KOReader's gesture manager: a one-finger
swipe up along the right edge opens the book's notes (Ink Away itself outside a
book), a swipe down along it annotates the book. A gesture is only taken when
it does nothing yet; one already in use is left as it is and listed in a note
shown the next time Ink Away opens, with where to change it.

The gesture manager keeps one table of gestures for the file browser and the
reader (gesture_fm, gesture_reader), shared by its instances, and writes it
out when told it changed.
]]

local EntryGestures = {}

-- What is wanted where. Swiping down outside a book does nothing, so it is left
-- alone there.
EntryGestures.WANT = {
    { section = "gesture_reader", ges = "one_finger_swipe_right_edge_up", action = "inkaway_booknotes" },
    { section = "gesture_fm", ges = "one_finger_swipe_right_edge_up", action = "inkaway_booknotes" },
    { section = "gesture_reader", ges = "one_finger_swipe_right_edge_down", action = "inkaway_annotate" },
}

local function empty(t)
    return t == nil or (type(t) == "table" and next(t) == nil)
end

-- Take the free gestures in `data` (the gesture manager's table). Returns the
-- ones set and the ones in use: { { want, current = <its actions> }, ... }.
function EntryGestures.apply(data)
    local set, taken = {}, {}
    for _i, w in ipairs(EntryGestures.WANT) do
        local section = data[w.section]
        if type(section) ~= "table" then
            section = {}
            data[w.section] = section
        end
        local cur = section[w.ges]
        if empty(cur) then
            section[w.ges] = { [w.action] = true }
            set[#set + 1] = w
        elseif not cur[w.action] then
            taken[#taken + 1] = { want = w, current = cur }
        end
    end
    return set, taken
end

return EntryGestures
