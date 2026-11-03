-- YourPlugin/main.lua -- illustrative mock, NOT an installable KOReader plugin.
-- Event-only consumer: handles both before-ready and after-ready registration.
-- No viewer, surface, rendering provider or rendering injection is required.
-- A real plugin wires these mock methods into its reader-scoped lifecycle.
local YourPlugin = {}

-- MOCK signature: ui is this reader's UI. There are no viewer arguments.
function YourPlugin:init(ui)
    self.ui = ui
    self.closed, self.annotation_open = false, false
    self.status = "Waiting for Ink Away"
    if ui.inkAwayIntegrationAPI then
        -- INK-AWAY has INITIALIZED: configure immediately using the ready instance.
        self:configureInkAway(ui.inkAwayIntegrationAPI)
    else
        -- BEFORE INK-AWAY IS INITIALIZED: share the queue without overwriting other consumers
        -- in case there are other plugins installed which integrate with ink-away as well!
        ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
        ui.inkAwayPendingIntegrations[self] = true
    end
end

function YourPlugin:configureInkAway(ink)
    if self.closed or self.stop_open then
        return
    end
    -- Event consumers only need the event API, not document_surface_version.
    if
        ink.integration_api_version ~= 1
        or type(ink.onAnnotationOpened) ~= "function"
        or type(ink.onAnnotationClosed) ~= "function"
    then
        self.status = "This Ink Away version does not support the event API"
        return
    end

    -- Observe all annotation sessions on this reader, including the native view.
    self.stop_open = ink:onAnnotationOpened(function(event)
        self.annotation_open = true
        self.annotation_document = event.document
        self.status = "Annotation opened"
        -- MOCK: pause your plugin's own work while annotation is active.
        -- event.surface may be nil (native viewer) or an external surface.
    end)
    self.stop_close = ink:onAnnotationClosed(function(event)
        self.last_annotation_document = event.document
        self.annotation_open = false
        self.annotation_document = nil
        self.status = "Annotation closed"
        -- MOCK: resume your plugin's work. This does not confirm a disk save.
    end)
    self.status = "Listening for annotation events"
end

-- Call when this plugin's reader-scoped instance is disposed.
function YourPlugin:dispose()
    if self.closed then
        return
    end
    self.closed = true
    local pending = self.ui.inkAwayPendingIntegrations
    if pending and pending[self] == true then
        pending[self] = nil
        if next(pending) == nil then
            self.ui.inkAwayPendingIntegrations = nil
        end
    end
    if self.stop_open then
        self.stop_open()
    end
    if self.stop_close then
        self.stop_close()
    end
    -- An observer owns no annotation surface and must not release someone else's.
    self.stop_open, self.stop_close = nil, nil
    self.annotation_open, self.annotation_document = false, nil
    self.status = "Disposed"
end

return YourPlugin
