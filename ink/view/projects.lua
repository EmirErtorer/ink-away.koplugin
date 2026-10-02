--[[
Editable projects: new, open and save, the autosaved session, and the folders
files are offered in.
Part of InkAwayView (see ink/view.lua).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local PathChooser = require("ui/widget/pathchooser")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Project = require("ink/project")
local Storage = require("ink/storage")

local existingDir = Storage.existingDir

local InkAwayView = {}

------------------------------------------------------------------------------
-- Projects and autosave
------------------------------------------------------------------------------

-- Path of the kept "last session" file.
function InkAwayView:sessionPath()
    local ok, DataStorage = pcall(require, "datastorage")
    local dir = (ok and DataStorage and DataStorage:getSettingsDir()) or "/tmp"
    return dir .. "/inkaway_session." .. Project.EXT
end

-- Load ops from a project into the canvas, if they fit this screen. Returns ok.
function InkAwayView:loadProjectData(data)
    if not data or not data.ops then return false end
    self.canvas:setOps(data.ops)
    self.selected, self.rotating = nil, nil
    self.active_image, self._img_drag = nil, nil
    self:freeImageCache()
    self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
    self.dirty = false
    return true
end

function InkAwayView:restoreSession()
    if self.autosave == "off" then return end
    local data = Project.load(self:sessionPath())
    if not data then return end
    if Project.isNotebook(data) then
        self:openNotebookData(data)      -- comes back as a notebook, not a flat canvas
    else
        self:loadProjectData(data)
    end
end

function InkAwayView:saveSession()
    if self.notebook then
        self:nbSyncOut()
        Project.saveNotebook(self.notebook, self:sessionPath())
        return
    end
    if self.canvas:isEmpty() then return end
    Project.save(self.canvas, self:sessionPath())
end

function InkAwayView:scheduleAutosave()
    UIManager:unschedule(self._autosave_tick)
    if self.autosave == "periodic" then
        UIManager:scheduleIn(180, self._autosave_tick)   -- every 3 minutes
    end
end

function InkAwayView:autosaveTick()
    if self.closing then return end
    -- never stall a stroke that is being drawn: try again shortly
    if self.capturing or (self._pen_state and self._pen_state.down) then
        UIManager:unschedule(self._autosave_tick)
        UIManager:scheduleIn(5, self._autosave_tick)
        return
    end
    if self.dirty then self:saveSession(); self.dirty = false end
    self:scheduleAutosave()
end

function InkAwayView:setAutosave(mode)
    self.autosave = mode
    self:setSetting("inkaway_autosave", mode)
    self:scheduleAutosave()
end

------------------------------------------------------------------------------
-- Projects: new / open / save (the editable drawing, not the image export).
------------------------------------------------------------------------------

function InkAwayView:newDrawing()
    local function fresh()
        self:exitNotebook()
        self.canvas:setOps({})
        self.selected, self.rotating = nil, nil
        self.active_image, self._img_drag = nil, nil
        self:freeImageCache()
        self.selection, self.sel_press, self.lassoing, self.lasso_scr = nil, nil, false, nil
        self.dirty = false
        os.remove(self:sessionPath())   -- so reopening does not restore the old drawing
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()     -- reclaim the old drawing's memory now
        UIManager:setDirty(self, "full")
    end
    if self.canvas:isEmpty() and not self.notebook then fresh(); return end
    UIManager:show(ConfirmBox:new{
        text = _("Start a new drawing? The current one will be cleared."),
        ok_text = _("New"), ok_callback = fresh,
    })
end

function InkAwayView:openProject()
    UIManager:show(PathChooser:new{
        select_directory = false, select_file = true, show_files = true,
        path = self:projectDir(),
        onConfirm = function(path)
            local data, err = Project.load(path)
            if data and Project.isNotebook(data) then
                self:openNotebookData(data)
            elseif data and self:loadProjectData(data) then
                self:exitNotebook()
                self:composeCanvas(); self:renderView()
                UIManager:setDirty(self, "full")
            else
                UIManager:show(InfoMessage:new{
                    text = _("Could not open that project.\n") .. tostring(err) })
            end
        end,
    })
end

function InkAwayView:saveProject()
    UIManager:show(PathChooser:new{
        select_directory = true, select_file = false, show_files = true,
        path = self:projectDir(),
        onConfirm = function(dir)
            self:rememberProjectDir(dir)
            local name = os.date(self.notebook and "notebook-%Y%m%d-%H%M%S" or "ink-%Y%m%d-%H%M%S")
            local d
            d = InputDialog:new{
                title = _("Project name"),
                input = name,
                buttons = {{
                    { text = _("Cancel"), id = "close", callback = function() UIManager:close(d) end },
                    { text = _("Save"), is_enter_default = true, callback = function()
                        local n = d:getInputText()
                        UIManager:close(d)
                        if not n or n == "" then n = name end
                        n = n:gsub("[/\\]", "_")
                        if not n:lower():match("%." .. Project.EXT .. "$") then n = n .. "." .. Project.EXT end
                        local sep = (dir:sub(-1) == "/") and "" or "/"
                        local ok, e
                        if self.notebook then
                            self:nbSyncOut()
                            ok, e = Project.saveNotebook(self.notebook, dir .. sep .. n)
                        else
                            ok, e = Project.save(self.canvas, dir .. sep .. n)
                        end
                        UIManager:show(InfoMessage:new{
                            text = ok and (_("Project saved:\n") .. dir .. sep .. n)
                                        or (_("Could not save project.\n") .. tostring(e)) })
                    end },
                }},
            }
            UIManager:show(d)
            d:onShowKeyboard()
        end,
    })
end

-- Four folders under "ink away/": drawings (PNG/JPEG images), drawing projects
-- (editable .inkaway canvases), notebooks (exported PDFs) and notebook projects
-- (editable .inkaway notebooks). Returns the images path.
function InkAwayView:ensureDefaultDir()
    local ok, DataStorage = pcall(require, "datastorage")
    local base = (ok and DataStorage and DataStorage:getDataDir()) or "/"
    local parent    = base .. "/ink away"
    local drawings  = parent .. "/drawings"
    local dproj     = parent .. "/drawing projects"
    local notebooks = parent .. "/notebooks"
    local nproj     = parent .. "/notebook projects"
    self.dproj_dir, self.nproj_dir, self.notebooks_dir = base, base, base
    local lok, lfs = pcall(require, "libs/libkoreader-lfs")
    if lok and lfs then
        local function mk(d)
            if lfs.attributes(d, "mode") ~= "directory" then pcall(lfs.mkdir, d) end
            return lfs.attributes(d, "mode") == "directory"
        end
        mk(parent); mk(drawings)
        if mk(dproj) then self.dproj_dir = dproj end
        if mk(nproj) then self.nproj_dir = nproj end
        if mk(notebooks) then self.notebooks_dir = notebooks end
        if lfs.attributes(drawings, "mode") == "directory" then return drawings end
    end
    return base
end

-- Where the image save dialog starts: last image folder used, else drawings.
function InkAwayView:defaultDir()
    return existingDir(self:getSetting("inkaway_last_dir")) or self.default_dir or "/"
end

-- Where the project open/save dialogs start: the folder for the current kind of
-- project (drawing vs notebook), last-used location remembered separately for
-- each so the two never get mixed up again.
function InkAwayView:projectDirKey()
    return self.notebook and "inkaway_last_nproj_dir" or "inkaway_last_dproj_dir"
end

function InkAwayView:projectDir()
    local def = self.notebook and self.nproj_dir or self.dproj_dir
    return existingDir(self:getSetting(self:projectDirKey())) or def or self.default_dir or "/"
end

-- Remember the last image folder used, for next time.
function InkAwayView:rememberDir(dir)
    self:setSetting("inkaway_last_dir", dir)
end

-- Remember the last project folder used (per project kind), for next time.
function InkAwayView:rememberProjectDir(dir)
    self:setSetting(self:projectDirKey(), dir)
end

return InkAwayView
