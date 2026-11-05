-- KOReader's InputDialog: keeps its options; the text is `input`, and the
-- last one made is InputDialog.last so a test can type into it.
local D = {}
D.__index = D
function D:new(o)
    o = o or {}; setmetatable(o, self); D.last = o
    o.button_table = { getButtonById = function(_, id)
        for _, row in ipairs(o.buttons or {}) do
            for _, b in ipairs(row) do
                if b.id == id then
                    b.setText = function(this, t) this.text = t end
                    b.refresh = function() end
                    return b
                end
            end
        end
    end }
    return o
end
function D:getInputText() return self.input end
function D:onShowKeyboard() self.keyboard_shown = true end
return D
