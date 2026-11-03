-- Headless sheets only need the container behavior. Real InputText/FocusManager
-- tap handling is exercised separately by tests/realbb/promptfocus.lua.
return require("ui/widget/container/inputcontainer"):extend{}
