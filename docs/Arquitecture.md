# Introduction

Are you a new Ink-Away contributor or KOReader plugin dev and want a high level overview?
Below you can see the current arquitecture, pretty self-explanatory.

\[Public API\]:
Ink Awayoffers offers a public api which you can hook into and subcribe to events from Ink-away internals.
To see how to use this public api, check the official documentation here: <PENDING TO ADD DOCUMENTATION LINK HERE>
or if you prefer to the .md version (for you AI agent), feed your AI with:

- This .md
- Plugin-integration.md
- main-event-only.lua
- main-rendering-consumer.lua

All of these files are merely documentation content.

.md along the way.

# Ink Away Arquitecture

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


