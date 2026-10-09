# Changelog

## 1.0.0-rc.1

- Require HotMicPlayer `from: "1.0.0-rc.1"`; retain HotMicCore `from: "1.0.2"` and iOS 17+.
- Stabilize streams and optional engagement adapters; add `HotMicPlayerCore.version`.
- Move injectable stream/session transports, fixture projections and retry controls into the optional `HotMicPlayerCoreTesting` product; keep the runtime API focused on authenticated integrations.
- Remove the interim deprecated `skipFailedHotMicItems(using:)` helper at 1.0; migrate to `HMPlayerConfiguration.failedItemPolicy`.
- Recover bounded raw chat/poll history after late duration or origin arrives. Preserve sends at the viewer’s media position while duration is unknown.
- Stop observing item duration hints after the first usable duration.
- Add partner DocC guides, separate Streams and StreamsAndEngagement examples, and macOS PR/main validation.

## 0.1.0

Initial integration:

- Resolve `.hotmicStream(id)` and page VOD summaries with stable playlist identities and filtering.
- Add optional session-backed chat, message reactions and polls with current/next lifecycle, dwell debounce, retry and moderation handling.
- Provide an initial combined demo and integration notes.
