# HotMicPlayerCore 1.0 API review

Reviewed against HotMicPlayer `1.0.0-rc.1` and HotMicCore `1.0.2`. Minimum iOS 17, Swift tools 6.0, Swift 5 language mode.

## Stable surface and decisions

| Surface | Decision / contract |
| --- | --- |
| `CoreItemResolver` actor | HotMic references only; successful bounded LRU cache, cancellation propagation, Core errors unchanged. Actor isolation satisfies the Sendable resolver protocol. |
| `HMMediaItem.hotmicStream(_:)` | Stable `hotmic:<id>` playlist identity; namespace/provenance metadata shared with paged items. |
| `CorePlaylistSource` | Sendable through `HMPlaylistSource`; its stored client is Sendable and query is a Core Sendable value. Query-preserving numbered pagination; no per-item requests. |
| `CoreInteractionSource` | Main-actor observable class; one per player/user, current/next session budget, default dwell debounce. No stream emoji capability. All hooks/actions/accessors stay on the main actor. |
| `ConnectionState`, errors and projected values | Explicit Sendable value types; named Core transport values remain separate from the player’s media-time values. Mutable values require exclusive ownership. Enum cases and all public declarations have doc comments. |
| Injected clients | `CoreStreamClient`, `CoreSessionFactory`, `CoreSession` and their fixture values live in the separate `HotMicPlayerCoreTesting` product. Runtime transport projections and bridging constructors use package access, so ordinary `import HotMicPlayerCore` exposes none of this testing surface. |
| Constructors | The runtime exposes authenticated `HotMicClient` constructors only. Importing the optional testing product adds injectable constructors and accelerated retry controls for previews/tests. |
| `HotMicPlayerCore.version` | Add a namespace enum with immutable, task-safe `1.0.0-rc.1` version. |
| `HMPlayer.skipFailedHotMicItems(using:)` | **Removed at 1.0.** Migrate to native `HMPlayerConfiguration.failedItemPolicy` (default `.skip`). The compatibility classifier and resolver failure bookkeeping are removed too. |

Live implementations, timeline/cache/session slots and failure classification stay internal/private.
No secret/token management API, moderator UI, logging or global configuration is introduced. Existing names
and authenticated signatures remain compatible. No new unchecked Sendable conformance is added.

## Replay timing

Raw history is retained while duration/origin is unavailable (latest 2,000 chat values and 100 polls).
Stream updates and resolved-item hints remap it; viewer send offsets are retained without upper clamping
until duration is known. The timeline observes the engagement’s resolved item hint and schedules remapping, since the player
updates that item without necessarily asking the source for its timeline again. Observation is not rearmed
after a positive finite duration is obtained; pending callbacks become inert. Queries stay read-only. Known out-of-window history
stays invisible; moderation removes raw values and newly mapped events pass the player’s moderation guard.

## Integration compatibility

Both examples import `HotMicPlayerCoreTesting` using ordinary imports, so offline integrations can
exercise the real runtime adapters without `@testable` or SPI. Injected sessions supply raw wall-clock history; the adapter
owns media-time mapping, bounded retention and moderation. Production integrations can use the
`HotMicClient` constructors without implementing these protocols.
