# Changelog

## 1.0.0-rc.2 (unreleased)

- Move the HotMicPlayer dependency to the public `hotmic-wp/hotmic-player-ios` repository, requiring `from: "1.0.0-rc.3"`; update package identities, examples and documentation, and remove private dependency credentials from CI.

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

## 1.0.0-rc.1

- Require HotMicPlayer `from: "1.0.0-rc.1"`; retain HotMicCore `from: "1.0.2"` and iOS 17+.
- Stabilize streams and optional engagement adapters; add `HotMicPlayerConnect.version`.
- Move injectable stream/session transports, fixture projections and retry controls into the optional `HotMicPlayerConnectTesting` product; keep the runtime API focused on authenticated integrations.
- Remove the interim deprecated `skipFailedHotMicItems(using:)` helper at 1.0; migrate to `HMPlayerConfiguration.failedItemPolicy`.
- Recover bounded raw chat/poll history after late duration or origin arrives. Preserve sends at the viewer’s media position while duration is unknown.
- Stop observing item duration hints after the first usable duration.
- Add partner DocC guides, separate Streams and StreamsAndEngagement examples, and macOS PR/main validation.

## 0.1.0

Initial integration:

- Resolve `.hotmicStream(id)` and page VOD summaries with stable playlist identities and filtering.
- Add optional session-backed chat, message reactions and polls with current/next lifecycle, dwell debounce, retry and moderation handling.
- Provide an initial combined demo and integration notes.
