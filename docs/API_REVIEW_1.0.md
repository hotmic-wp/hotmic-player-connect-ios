# HotMicPlayerConnect 1.0 API review

## Pre-1.0 rename map (1.0.0-rc.2)

Renamed the HotMicPlayerConnect add-on and its public/testing surface; no behavior change. No deprecated typealiases. HotMicCore / HotMic Core SDK remains the dependency. Nested types and members follow their enclosing renamed type. The repository publication rename is managed separately.

| Old | New |
| --- | --- |
| `hotmic-wp/hotmic-player-core-ios` | `hotmic-wp/hotmic-player-connect-ios` |
| `HotMicPlayerCore` | `HotMicPlayerConnect` |
| `HotMicPlayerCoreTesting` | `HotMicPlayerConnectTesting` |
| `HotMicPlayerCoreTests` | `HotMicPlayerConnectTests` |
| `HotMicPlayerCore.docc` | `HotMicPlayerConnect.docc` |
| `HotMicPlayerCoreTesting.docc` | `HotMicPlayerConnectTesting.docc` |
| `CoreItemResolver` | `HotMicItemResolver` |
| `CorePlaylistSource` | `HotMicPlaylistSource` |
| `CoreInteractionSource` | `HotMicInteractionSource` |
| `CoreStreamClient` | `HotMicStreamClient` |
| `CoreStreamSummary` | `HotMicFixtureStreamSummary` |
| `CoreStreamPage` | `HotMicFixtureStreamPage` |
| `CoreSessionFactory` | `HotMicSessionFactory` |
| `CoreSession` | `HotMicSession` |
| `CoreChat` | `HotMicChat` |
| `CoreMessageReaction` | `HotMicMessageReaction` |
| `CorePoll` | `HotMicFixturePoll` |
| `CoreSessionSnapshot` | `HotMicSessionSnapshot` |
| `CoreSessionEvent` | `HotMicSessionEvent` |
| `HotMicPlayerCoreError` | `HotMicPlayerConnectError` |
| `HotMicPlayerCore.version` | `HotMicPlayerConnect.version` = `1.0.0-rc.2` |
| `_CoreStreamClient` | `_HotMicStreamClient` |
| `_CoreStreamSummary` | `_HotMicStreamSummary` |
| `_CoreStreamPage` | `_HotMicStreamPage` |
| `_CoreSessionFactory` | `_HotMicSessionFactory` |
| `_CoreSession` | `_HotMicSession` |
| `_CoreChat` | `_HotMicChat` |
| `_CoreMessageReaction` | `_HotMicMessageReaction` |
| `_CorePoll` | `_HotMicPoll` |
| `_CoreSessionSnapshot` | `_HotMicSessionSnapshot` |
| `_CoreSessionEvent` | `_HotMicSessionEvent` |
| `CoreTimeline` | `HotMicTimeline` |
| `LiveCoreStreamClient` | `LiveHotMicStreamClient` |
| `LiveCoreSessionFactory` | `LiveHotMicSessionFactory` |
| `LiveCoreSession` | `LiveHotMicSession` |
| `CoreInteractionTests` | `HotMicInteractionTests` |
| `CoreStreamsTests` | `HotMicStreamsTests` |

Reviewed against HotMicPlayer `1.0.0-rc.1` and HotMicCore `1.0.2`. Minimum iOS 17, Swift tools 6.0, Swift 5 language mode.

## Stable surface and decisions

| Surface | Decision / contract |
| --- | --- |
| `HotMicItemResolver` actor | HotMic references only; successful bounded LRU cache, cancellation propagation, Core errors unchanged. Actor isolation satisfies the Sendable resolver protocol. |
| `HMMediaItem.hotmicStream(_:)` | Stable `hotmic:<id>` playlist identity; namespace/provenance metadata shared with paged items. |
| `HotMicPlaylistSource` | Sendable through `HMPlaylistSource`; its stored client is Sendable and query is a Core Sendable value. Query-preserving numbered pagination; no per-item requests. |
| `HotMicInteractionSource` | Main-actor observable class; one per player/user, current/next session budget, default dwell debounce. No timed stream emoji capability. Item fire membership and comment paging are implemented, but HotMicCore 1.0.2 cannot serve them, so authenticated sessions omit `.toggleReaction` and `.loadComments`. All hooks/actions/accessors stay on the main actor. |
| `ConnectionState`, errors and projected values | Explicit Sendable value types; named Core transport values remain separate from the player’s media-time values. Mutable values require exclusive ownership. Enum cases and all public declarations have doc comments. |
| Injected clients | `HotMicStreamClient`, `HotMicSessionFactory`, `HotMicSession` and their fixture values live in the separate `HotMicPlayerConnectTesting` product. Runtime transport projections and bridging constructors use package access, so ordinary `import HotMicPlayerConnect` exposes none of this testing surface. |
| Constructors | The runtime exposes authenticated `HotMicClient` constructors only. Importing the optional testing product adds injectable constructors and accelerated retry controls for previews/tests. |
| `HotMicPlayerConnect.version` | Add a namespace enum with immutable, task-safe `1.0.0-rc.2` version. |
| `HMPlayer.skipFailedHotMicItems(using:)` | **Removed at 1.0.** Migrate to native `HMPlayerConfiguration.failedItemPolicy` (default `.skip`). The compatibility classifier and resolver failure bookkeeping are removed too. |

Live implementations, timeline/cache/session slots and failure classification stay internal/private.
No secret/token management API, moderator UI, logging or global configuration is introduced. Authenticated signatures retain their behavior; pre-1.0 names are replaced as listed above. No new unchecked Sendable conformance is added.

## Replay timing

Raw history is retained while duration/origin is unavailable (latest 2,000 chat values and 100 polls).
Stream updates and resolved-item hints remap it; viewer send offsets are retained without upper clamping
until duration is known. The timeline observes the engagement’s resolved item hint and schedules remapping, since the player
updates that item without necessarily asking the source for its timeline again. Observation is not rearmed
after a positive finite duration is obtained; pending callbacks become inert. Queries stay read-only. Known out-of-window history
stays invisible; moderation removes raw values and newly mapped events pass the player’s moderation guard.

## Integration compatibility

Both examples import `HotMicPlayerConnectTesting` using ordinary imports, so offline integrations can
exercise the real runtime adapters without `@testable` or SPI. Injected sessions supply raw wall-clock history; the adapter
owns media-time mapping, bounded retention and moderation. Production integrations can use the
`HotMicClient` constructors without implementing these protocols.
