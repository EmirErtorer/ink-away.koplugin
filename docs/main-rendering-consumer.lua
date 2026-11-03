-- YourPlugin/main.lua -- illustrative mock, NOT an installable KOReader plugin.
-- Rendering consumer: handles both before-ready and after-ready registration.
-- A plugin may also be an event-only consumer; the roles are independent.
-- Your own viewer setup supplies ui, viewer_widget and a valid surface. Rendering and
-- surface geometry are deliberately omitted; see Plugin-integration.md.
local YourPlugin = {}

-- MOCK signature: your plugin creates its own viewer and surface.
-- viewer_widget is that actual KOReader viewer object, not a standard plugin field.
function YourPlugin:init(ui, viewer_widget, surface)
    self.ui, self.viewer_widget, self.surface = ui, viewer_widget, surface
    self.closed, self.annotation_open = false, false
    self.status = "Waiting for Ink Away"

    if ui.inkAwayIntegrationAPI then
        -- Also works if Ink Away happened to finish first.
        self:configureInkAway(ui.inkAwayIntegrationAPI)
    else
        -- Queue this consumer instance; do not replace another plugin's queue entries.
        ui.inkAwayPendingIntegrations = ui.inkAwayPendingIntegrations or {}
        ui.inkAwayPendingIntegrations[self] = true
    end
end

function YourPlugin:configureInkAway(ink)
    if self.closed or self.cleanup then return end
    if ink.integration_api_version ~= 1 or ink.document_surface_version ~= 1
            or type(ink.installPluginIntegration) ~= "function" then
        self.status = "This Ink Away version does not support the integration"
        return
    end

    -- Ink Away passes itself here; ui["ink-away"] may not exist yet.
    -- One call installs a provider plus callbacks scoped to this surface.
    self.cleanup = ink:installPluginIntegration(self.viewer_widget, self.surface, {
        on_open = function(event)
            self.annotation_open = true
            self.status = "Annotating"
            self.annotation_document = event.document
            -- YourPlugin can disable its own navigation controls here.
        end,
        on_close = function(event)
            self.last_annotation_document = event.document
            self.annotation_open = false
            self.annotation_document = nil
            self.status = "Previewing"
            -- Restore YourPlugin's controls; event.document identifies the book.
            -- This event does not confirm that saving to disk succeeded.
        end,
        on_error = function(err)
            self.last_error = tostring(err)
            self.status = "Annotation integration error"
            -- Display or log the error using YourPlugin's own UI.
        end,
    })
    self.ink = ink
    self.status = "Previewing"
end

-- Example viewer paint hook. The viewer must already be in the window stack
-- when annotation starts. Its background uses absolute screen coordinates.
function YourPlugin:paintTo(bb)
    self:paintBackground(bb)
    if not self.closed and self.ink and self.ui.inkAwayIntegrationAPI == self.ink then
        self.ink:paintDocumentSurface(self.surface, bb)
    end
end

-- Example handler for YourPlugin's "Annotate" button/menu action.
function YourPlugin:onAnnotate()
    if self.closed or not self.ink or self.ui.inkAwayIntegrationAPI ~= self.ink then
        self.status = "Ink Away is not ready"
        return
    end
    -- Requests opening; on_open above confirms that the editor actually opened.
    self.ink:onInkAwayAnnotate()
end

-- Called BEFORE destroying the viewer_widget or its surface resources.
function YourPlugin:onCloseWidget()
    if self.closed then return end
    self.closed = true

    -- Closing before readiness must cancel setup, not leave a stale viewer_widget queued.
    local pending = self.ui.inkAwayPendingIntegrations
    if pending and pending[self] == true then
        pending[self] = nil
        if next(pending) == nil then self.ui.inkAwayPendingIntegrations = nil end
    end

    if self.cleanup then
        -- Saves/closes this surface's editor, unregisters, and unsubscribes.
        -- Its close callback remains connected until release completes.
        self.cleanup()
    end
    self.cleanup, self.ink = nil, nil
    self.annotation_open = false
    self.status = "Closed"
end

function YourPlugin:paintBackground(_bb)
    -- MOCK: YourPlugin's existing renderer paints its content here.
    -- surface:snapshot(bb) must use background-only painting, not paintTo(bb),
    -- otherwise the ink overlay would be included recursively in its snapshot.
end

return YourPlugin
