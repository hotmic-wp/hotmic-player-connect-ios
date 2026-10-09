# Changelog

## 1.0.0-rc.1

- Require HotMicPlayer `from: "1.0.0-rc.1"`; retain HotMicCore `from: "1.0.2"` and iOS 17+.
- Stabilize streams and optional engagement adapters; add `HotMicPlayerCore.version`.
- Expose documented injectable stream/session transports and value projections for public-only offline examples and partner tests. Retry timing controls remain Testing SPI.
- Retain `skipFailedHotMicItems(using:)` as deprecated compatibility; prefer the player’s native failed-item policy.
- Recover bounded raw chat/poll history after late duration or origin arrives. Preserve sends at the viewer’s media position while duration is unknown.
- Add partner DocC guides, separate Streams and StreamsAndEngagement examples, and macOS PR/main validation.

## 0.1.0

Initial integration:

- Resolve `.hotmicStream(id)` and page VOD summaries with stable playlist identities and filtering.
- Add optional session-backed chat, message reactions and polls with current/next lifecycle, dwell debounce, retry and moderation handling.
- Provide an initial combined demo and integration notes.
