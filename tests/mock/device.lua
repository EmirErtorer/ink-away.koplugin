local BB = require("ffi/blitbuffer")
local screen_bb = BB.new(1072, 1448)
local rot = 0   -- current rotation mode: 0/2 portrait, 1/3 landscape
-- Off by default: the mock models a HARDWARE-rotation screen (Screen.bb rotation
-- stays 0, dims swap on a class flip), which the bulk of the tests assume. Turn it
-- on to model a SOFTWARE-rotation framebuffer (Screen.bb carries the rotation and
-- reports swapped logical dims) so the panel-order landscape render path runs.
local software_rotation = false
local function logicalW() return software_rotation and screen_bb:getWidth() or screen_bb.w end
local function logicalH() return software_rotation and screen_bb:getHeight() or screen_bb.h end
local Screen
Screen = {
    bb = screen_bb,
    getWidth = logicalW,
    getHeight = logicalH,
    getSize = function() return { x = 0, y = 0, w = logicalW(), h = logicalH() } end,
    scaleBySize = function(_, px) return math.floor(px * 1.4) end,
    setSize = function(_, w, h) screen_bb.w, screen_bb.h = w, h end,
    DEVICE_ROTATED_UPRIGHT = 0,
    DEVICE_ROTATED_CLOCKWISE = 1,
    DEVICE_ROTATED_UPSIDE_DOWN = 2,
    DEVICE_ROTATED_COUNTER_CLOCKWISE = 3,
    getRotationMode = function() return rot end,
    -- Test hook: choose which rotation model the mock uses (see software_rotation).
    setSoftwareRotation = function(_, on) software_rotation = on and true or false end,
    -- Track the rotation. Hardware model: swap the reported dims on a class flip.
    -- Software model: flip Screen.bb's own rotation (storage/panel dims stay put,
    -- getWidth/getHeight report the swapped logical size), matching a real e-ink
    -- reader whose framebuffer is rotated in software for landscape.
    setRotationMode = function(_, mode)
        if software_rotation then
            screen_bb:setRotation(mode)
        elseif (rot % 2) ~= (mode % 2) then
            screen_bb.w, screen_bb.h = screen_bb.h, screen_bb.w
        end
        rot = mode
    end,
    getTouchRotation = function() return rot end,
}
return {
    screen = Screen,
    isTouchDevice = function() return true end,
    hasKeys = function() return false end,
    input = {
        group = { Back = { "Back" } },
        -- Model a Wacom pen device (Kindle Scribe): the digitizer owns one pen slot
        -- and KOReader flags the protocol. Palm rejection classifies by slot, so
        -- tests must send pen frames on pen_slot and palm frames on another slot.
        wacom_protocol = true,
        main_finger_slot = 0,
        pen_slot = 4,
        stylus_eraser_active = false,
        stylus_highlighter_active = false,
        TOOL_TYPE_FINGER = 0,
        TOOL_TYPE_PEN = 1,
        TOOL_TYPE_ERASER = 2,
        TOOL_TYPE_HIGHLIGHTER = 3,
        -- Palm rejection registers a stylus callback here; the mock just stores it
        -- so tests can drive it directly (SDL never produces real stylus events).
        registerStylusCallback = function(self, cb) self.stylus_callback = cb end,
        unregisterStylusCallback = function(self) self.stylus_callback = nil end,
    },
}
