# Ink Away extension architecture

Ink Away owns annotation tools, toolbar, undo, storage and export. A viewer
owns its document presentation: background, page coordinates, crop, zoom,
rotation and navigation. Plugins integrate through the public API described in
[Plugin-integration.md](Plugin-integration.md); they do not replace Ink Away
methods or access its book/editor objects.

## Overview

```text
                                                                                 1. ADDITIONS                                            2. LIMITED CORE CHANGES
                                                                                 New public extension boundary                           Wire existing behavior to abstractions
                                                                                                       |                                                     |
                                                                                                       v                                                     v
                                                                             +----------------------------------------------------------------------------------------------------------+
                                                                             |                                                                                                          |
                                                                             |                                             INK AWAY - PR SCOPE                                          |
                                                                             |                                                                                                          |
+----------------------------------------+                                   | +---------------------------------------------------+   +----------------------------------------------+ |
|                                        |                                   | |                                                   |   |                                              | |
|         GENERIC PLUGIN                 |                                   | | PUBLIC API                                        |   | PRIVATE API / EXISTING CORE                  | |
|                                        |                                   | | New extension points                              |   | Keep changes focused                         | |
|   Consumer of the public API           |                                   | |                                                   |   |                                              | |
|                                        |    subscribe to events            | |                                                   |   |                                              | |
|   Registers its own callbacks          +-------------------------------------> EVENT SUBSCRIPTIONS (observer pattern)            |   | Book / annotation editor                     | |
|                                        |                                   | |                                                   |   |                                              | |
|                                        |                                   | | onAnnotationOpened(callback)                      |   | Tools, toolbar, undo, storage, export        | |
|                                        |      event data                   | |                                                   |   |                                              | |
|   Reacts using its own code            <-------------------------------------+ onAnnotationClosed(callback)                      |   |                                              | |
|                                        |                                   | |                                                   |   | Depends on one viewer contract               | |
|                                        |                                   | | Payload: document + selected surface              |   |                     |                        | |
|                                        |                                   | |                                                   +-->+                     v                        | |
|                                        |                                   | |                                                   |   | +------------------------------------------+ | |
|                                        |   register viewer provider        | |                                                   |   | |                                          | | |
|   Supplies its own viewer              +-------------------------------------> DEPENDENCY REGISTRATION                           |   | |  INTERNAL VIEWER CONTRACT                | | |
|                                        |                                   | |                                                   |   | |                                          | | |
|                                        |    returns cleanup()              | | installPluginIntegration(widget, surface,         |   | |  +--> Native KOReader adapter (default)  | | |
|                                        <-------------------------------------+                          options)                 |   | |                                          | | |
| +------------------------------------+ |                                   | |                                                   |   | |  +--> External surface adapter           | | |
| |                                    | |                                   | | Factory supplies a versioned surface.             |   | |                                          | | |
| |    < Plugin internals >            | |                                   | | Registration affects the next session.            |   | +------------------------------------------+ | |
| |                                    | |                                   | |                                                   |   |                                              | |
| |  Own rendering and geometry        | |                                   | | No provider? Use the default reader.              |   |                                              | |
| |                                    | |                                   | |                                                   |   | Native document coordinates stay intact.     | |
| |  Outside the Ink Away PR           | |                                   | |                                                   |   |                                              | |
| |                                    | |                                   | | SAVED INK AND RESOURCE RELEASE                    |   | Existing annotation behavior is retained.    | |
| |  No private-core access            | |                                   | |                                                   |   |                                              | |
| |                                    | |                                   | | paintDocumentSurface(surface, bb)                 |   | Provider identity stays outside the core.    | |
| +------------------------------------+ |                                   | |                                                   |   |                                              | |
|                                        |                                   | | releaseDocumentSurface(surface)                   |   |                                              | |
|                                        |                                   | |                                                   |   | Adapters are private implementation.         | |
+----------------------------------------+                                   | | No consumer-specific implementation here.         |   |                                              | |
                                                                             | |                                                   |   |                                              | |
                                                                             | +---------------------------------------------------+   +----------------------------------------------+ |
                                                                             |                                                                                                          |
                                                                             +----------------------------------------------------------------------------------------------------------+
```

The two numbered areas distinguish public additions from focused private-core
adaptation; they do not indicate published PRs. The generic plugin stays outside
the Ink Away PR scope.

The core calls the same viewer contract for either adapter. The external
adapter delegates presentation to the consumer's surface; Ink Away retains
annotation behavior and persistence. Lifecycle subscribers do not need to
register a rendering provider.

## Public boundary

The Ink Away instance offers composite integration installation, widget-owned
rendering-provider registration and independent open/close subscriptions.
Consumers call `consumer:configureInkAway(ink)` immediately when
`ui.inkAwayIntegrationAPI` is ready, or queue their instance with
`ui.inkAwayPendingIntegrations[consumer] = true`. Ink Away calls that method
when ready. Consumers may be plugin instances or viewer objects; each must
expose the method. A plugin can serve both event and rendering roles. Initialization
installs working defaults, publishes the ready instance and drains the queue.
Consumer methods receive that instance directly, even before KOReader assigns the
plugin's directory-name UI key. Either loading order is supported.

`installPluginIntegration(widget, surface, options)` registers a provider and
optional surface-scoped observers together. Repeat installation of the same
widget/surface reuses its cleanup function. A closing widget cancels pending
setup or cleans up the installed integration. Reader closure clears readiness
and disposes integrations. A failing configuration cannot block other consumers.

Opening a session selects the top eligible visible provider for the current
document. An unrelated fullscreen widget blocks providers below it. Duplicate
registration for one widget is rejected. Separate viewers can register without
replacing each other. Registering/unregistering changes future selection;
it never changes the geometry of an active session.

The selected provider supplies a versioned surface. Version-1 widget discovery
through `getAnnotationSurface()` remains a compatibility path. With no eligible
provider, or a failed factory/activation, Ink Away uses the native KOReader view.

## Private implementation

The annotation model depends on one internal viewer contract: document placement,
current/visible pages, layout key, point lookup, reading direction, navigation,
snapshot and repaint. The default adapter retains KOReader's existing paging
and reflowing behavior. The external adapter implements the same contract using
the consumer's surface. Selection is centralized; tools and storage do not need
consumer identities. These adapters and the model are private implementation,
not additional public API.

The session saves edits against the old geometry before navigation or reflow,
paints the new background before querying new widget bounds, then reloads editable
operations. Asynchronous navigation keeps the toolbar stationary and blocks edits
until handoff. Late completions cannot revive a closed session. Closing attempts
the normal save, releases provider resources, restores the native adapter and
notifies close observers. Listener exceptions do not prevent other listeners.

Saved ink remains in native document coordinates and uses the existing sidecar
schema. Export renders original pages independently of the selected viewer.
The public boundary does not expose canvas, toolbar, cache or sidecar internals.

## Extending

Implement the existing surface contract for another fixed-page viewer without
changing Ink Away's core. Observe lifecycle events without supplying a viewer.
Keep new extension capabilities optional when possible; incompatible contracts
need a new interface version. Panels+ is one consumer, with its geometry and
animation code living entirely in Panels+.
