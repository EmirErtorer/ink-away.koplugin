--[[
Editable projects: new, open and save, the autosaved session, and the folders
files are offered in.
Part of InkAwayView (see ink/view.lua).
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local Project = require("ink/project")
local Storage = require("ink/storage")

local existingDir = Storage.existingDir

local InkAwayView = {}

------------------------------------------------------------------------------
-- Session and autosave
------------------------------------------------------------------------------

-- Path of the kept "last session" file.
function InkAwayView:sessionPath()
    return Storage.settingsDir() .. "/inkaway_session." .. Project.EXT
end

-- Replace the drawing with `ops`, dropping every selection and cached image.
function InkAwayView:loadOps(ops)
    self.canvas:setOps(ops)
    self.selected, self.rotating = nil, nil
    self.active_image, self._img_drag = nil, nil
    self:freeImageCache()
    self:resetLasso()
    self.dirty = false
end

-- Load a project's ops into the canvas. Returns false when there are none.
function InkAwayView:loadProjectData(data)
    if not data or not data.ops then return false end
    self:loadOps(data.ops)
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
-- Projects: new, open and save (the editable drawing, not the image export)
------------------------------------------------------------------------------

-- Run `fn`, asking first with `text` when there is work it would clear.
function InkAwayView:confirmDiscard(text, ok_text, fn)
    if self.canvas:isEmpty() and not self.notebook then fn(); return end
    UIManager:show(ConfirmBox:new{ text = text, ok_text = ok_text, ok_callback = fn })
end

function InkAwayView:newDrawing()
    self:confirmDiscard(_("Start a new drawing? The current one will be cleared."), _("New"), function()
        self:exitNotebook()
        self:loadOps({})
        os.remove(self:sessionPath())   -- so reopening does not restore the previous drawing
        self:composeCanvas(); self:renderView()
        self:resetTransientMemory()     -- reclaim the previous drawing's memory now
        UIManager:setDirty(self, "full")
    end)
end

function InkAwayView:openProject()
    self:pickFile(self:projectDir(), function(path)
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
    end)
end

function InkAwayView:saveProject()
    self:pickFolder(self:projectDir(), function(dir)
        self:rememberProjectDir(dir)
        local name = os.date(self.notebook and "notebook-%Y%m%d-%H%M%S" or "ink-%Y%m%d-%H%M%S")
        self:promptText{ title = _("Project name"), input = name, default = name, ok_text = _("Save"),
            on_ok = function(text)
                local path = Storage.join(dir, Storage.fileName(text, Project.EXT))
                local ok, e
                if self.notebook then
                    self:nbSyncOut()
                    ok, e = Project.saveNotebook(self.notebook, path)
                else
                    ok, e = Project.save(self.canvas, path)
                end
                UIManager:show(InfoMessage:new{
                    text = ok and (_("Project saved:\n") .. path)
                                or (_("Could not save project.\n") .. tostring(e)) })
            end }
    end)
end

------------------------------------------------------------------------------
-- Folders
------------------------------------------------------------------------------

-- Four folders under "ink away/": drawings (PNG and JPEG images), drawing projects
-- (editable .inkaway canvases), notebooks (exported PDFs) and notebook projects
-- (editable .inkaway notebooks). Returns the images path.
function InkAwayView:ensureDefaultDir()
    local base = Storage.dataDir() or "/"
    self.dproj_dir = Storage.appDir("drawing projects") or base
    self.nproj_dir = Storage.appDir("notebook projects") or base
    self.notebooks_dir = Storage.appDir("notebooks") or base
    return Storage.appDir("drawings") or base
end

-- Where the image save dialog starts: last image folder used, else drawings.
function InkAwayView:defaultDir()
    return existingDir(self:getSetting("inkaway_last_dir")) or self.default_dir or "/"
end

-- The settings key for the last folder of the current project kind.
function InkAwayView:projectDirKey()
    return self.notebook and "inkaway_last_nproj_dir" or "inkaway_last_dproj_dir"
end

-- Where the project open and save dialogs start: the last folder used for the
-- current kind (drawing or notebook, kept apart), else that kind's folder.
function InkAwayView:projectDir()
    local def = self.notebook and self.nproj_dir or self.dproj_dir
    return existingDir(self:getSetting(self:projectDirKey())) or def or self.default_dir or "/"
end

-- Remember the last image folder used, for next time.
function InkAwayView:rememberDir(dir)
    self:setSetting("inkaway_last_dir", dir)
end

-- Remember the last project folder used (per kind), for next time.
function InkAwayView:rememberProjectDir(dir)
    self:setSetting(self:projectDirKey(), dir)
end

return InkAwayView
