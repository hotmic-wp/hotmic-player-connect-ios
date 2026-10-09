# HotMicPlayerCore 1.0 API review

Reviewed against player `1.0.0-rc.1` (tag resolves to `f03b5a4c7163e09675fd2e3791b446d449c34ba7`)
and Core `1.0.2`. Minimum iOS 17, Swift tools 6.0, Swift 5 language mode.

## Stable surface and decisions

| Surface | Decision / contract |
| --- | --- |
| `CoreItemResolver` actor | HotMic references only; successful bounded LRU cache, cancellation propagation, Core errors unchanged. Actor isolation satisfies the Sendable resolver protocol. |
| `HMMediaItem.hotmicStream(_:)` | Stable `hotmic:<id>` playlist identity; namespace/provenance metadata shared with paged items. |
| `CorePlaylistSource` | Sendable through `HMPlaylistSource`; its stored client is Sendable and query is a Core Sendable value. Query-preserving numbered pagination; no per-item requests. |
| `CoreInteractionSource` | Main-actor observable class; one per player/user, current/next session budget, default dwell debounce. No stream emoji capability. All hooks/actions/accessors stay on the main actor. |
| `ConnectionState`, errors and projected values | Explicit Sendable value types; named Core transport values remain separate from the player’s media-time values. Mutable values require exclusive ownership. Enum cases and all public declarations have doc comments. |
| Injected clients | Promote the existing `CoreStreamClient`, `CoreSessionFactory` / `CoreSession` seams and their necessary summaries, pages, snapshot, events, chat/reaction/poll values from Testing SPI to ordinary public API. Core’s binary models lack public initializers and the client lacks transport injection. This is the smallest existing seam that lets partners test the real adapters offline without secrets or SPI. No preview subsystem or second session lifecycle added. |
| Constructors | Keep authenticated `HotMicClient` overloads as the primary path; injectable overloads are additive. `retryBaseDelay` constructor remains Testing SPI, excluded from stable API. |
| `HotMicPlayerCore.version` | Add a namespace enum with immutable, task-safe `1.0.0-rc.1` version. |
| `HMPlayer.skipFailedHotMicItems(using:)` | **Keep deprecated.** Only tests used it in this checkout; the prior README publicly documented it and external consumers cannot be ruled out from this repo. Removing it before 1.0 would silently break a possible existing integration. Deprecation points to native `HMPlayerConfiguration.failedItemPolicy` (default `.skip`). Examples do not use it. Its classifier remains Testing SPI. |

Live implementations, timeline/cache/session slots and failure classification stay internal/private.
No secret/token management API, moderator UI, logging or global configuration is introduced. Existing names
and authenticated signatures remain compatible. No new unchecked Sendable conformance is added.

## Replay carry-over

Raw history is retained while duration/origin is unavailable (latest 2,000 chat values and 100 polls).
Stream updates and resolved-item hints remap it; viewer send offsets are retained without upper clamping
until duration is known. The timeline observes the engagement’s resolved item hint and schedules remapping, since the player
updates that item without necessarily asking the source for its timeline again. Queries stay read-only. Known out-of-window history
stays invisible; moderation removes raw values and newly mapped events pass the player’s moderation guard.

## Validation scope

Both example targets compile ordinary imports and the injectable overloads, proving the stable fake-client
boundary without `@testable` or SPI. The existing interaction test is extended for delayed timing via stream
and resolved item, deletion before mapping, sends before duration, and raw retention bounds. No new test
method or repeated full-suite pass is added. See `MILESTONE_7B_VALIDATION.md` for release evidence.
