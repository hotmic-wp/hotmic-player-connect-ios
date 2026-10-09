# HotMicPlayerCore

Optional HotMic streams adapter for [HotMicPlayer](https://github.com/hotmic-wp/hotmic-player-sdk). iOS 17+, Swift 5 language mode with Swift tools 6.0+. The player stays dependency-free; this separate package adds the HotMicCore binary dependency. VOD only. Optional session-backed chat, message reactions and polls.

## Install

Add these packages in Xcode (or use the equivalent SwiftPM dependencies), and link `HotMicPlayer`, `HotMicPlayerUI` (for the overlay) and `HotMicPlayerCore` to your app target:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", from: "0.4.1"),
.package(url: "https://github.com/hotmic-wp/hotmic-player-core-ios", branch: "main")
```

The adapter is not tagged yet; use `main` after this milestone merges, or the reviewed commit for a reproducible integration. It transitively requires HotMicCore `from: "1.0.2"`. Import `HotMicCore` when constructing the shared authenticated client.

## Integration in 15 lines

```swift
import SwiftUI
import HotMicCore
import HotMicPlayer
import HotMicPlayerUI
import HotMicPlayerCore
@MainActor struct Feed: View {
    @State private var player: HMPlayer
    init(client: HotMicClient) {
        let player = HMPlayer(resolver: CoreItemResolver(client: client),
                              interactions: CoreInteractionSource(client: client))
        player.playlistSource = CorePlaylistSource(client: client)
        _player = State(initialValue: player)
    }
    var body: some View { HMVerticalFeedView(player: player, layout: HMOverlayLayout.self).task { await player.start() } }
}
```

Create `HotMicClient(apiKey:accessToken:)` with credentials delivered securely to your host app. For by-ID playback, call `player.replaceAll([.hotmicStream(streamID)])` on the main actor. Keep the client and adapters scoped to the signed-in user; replace them when credentials change.

## Slots and public contract

| API | Behavior |
| --- | --- |
| `CoreItemResolver(client:cacheCapacity:)` | `HMItemResolver` actor; accepts only namespace `hotmic`, calls `fetchStream(id:)`, requires `.vod` and `vodURL`, returns `.auto` URL, thumbnail poster, title and duration. Success-only LRU cache, default 32 entries, 60-second lifetime; zero capacity disables it. Player owns request de-duplication and retries. Cancellation is propagated and cancelled results are not cached. |
| `HMMediaItem.hotmicStream(_:)` | Reference with playlist identity `hotmic:<id>`. Uses the same identity as source items, allowing the player to drop overlaps. |
| `CorePlaylistSource(client:query:)` | `HMPlaylistSource`; default VOD-only `HotMicStreamQuery`. Preserves supplied filters, user and limit. Nil cursor starts at the query's page (minimum 1); returned cursor follows `pagination.currentPage + 1`, and nil ends at `hasNext == false`. Filters non-VOD and missing-URL summaries before insertion; empty filtered pages continue. Maps directly to URL items, with no by-ID fetch. |
| `HotMicPlayerCoreError` | `unsupportedNamespace(String)`, `notVOD(streamID:)`, `missingVODURL(streamID:)`, `invalidCursor(String)`, `invalidPagination`. `Error`, `LocalizedError`, `Equatable`, `Sendable`. Core transport/authentication errors pass through unchanged. |
| `CoreInteractionSource(client:)` | Main-actor observable `HMInteractionSource`; one per player/user. Prepares next, promotes current without restarting, stops outside both roles. Opt-in: the player's default interaction source is empty. |
| `CoreInteractionSource.connectionState(for:)` | `.idle`, `.starting`, `.connected`, `.reconnecting(attempt:)`, `.disconnected`, `.failed`. Playback continues independently. Startup failures stop the session; leaving and re-entering retries with a new one. Core handles polling reconnects within the existing session. |
| `HMPlayer.skipFailedHotMicItems(using:)` | Deprecated compatibility helper. Prefer native `HMPlayerConfiguration.failedItemPolicy`, default `.skip`, available since player 0.3.1. |

Core uses offset/page-number pagination, not a snapshot of the catalogue. VODs published mid-session can shift page boundaries and be skipped in that browsing session; overlapping duplicates are handled by the player. Restart the feed to refresh the catalogue.

## Engagement and replay

The source advertises chat sending, reactions to messages and poll voting. Core has no stream-level emoji reactions, so those controls stay hidden. Snapshot history and chat batches populate `HMEngagement`; message/poll deletions use the player's moderation APIs, and poll updates use `upsertPoll`. A confirmed send is inserted with the returned server ID at the viewer's current media time. Later echoes reconcile by that ID. Reaction types map to 👍 / 🔥 / 😆 / 😡 / 😢. Core returns a reaction identity, not counts; the adapter updates the known message totals locally and replaces them when Core sends message totals. Polls carry options, response counts, `myAnswer`, creation time and the closed flag; Core supplies no closing timestamp, so closed polls remain visible as results.

Only references in namespace `hotmic` receive sessions. `CorePlaylistSource` retains direct URL playback and adds `hotmic.namespace` / `hotmic.streamID` metadata recording the originating reference; `.hotmicStream` carries the same provenance through resolution. An arbitrary URL or an ID starting with `hotmic:` does not opt in. Timeline access is inert; engagements and timeline caches are weakly held by the source. Each source is scoped to one player and authenticated user.

**Session cost:** current plus next means **at most two sessions per viewer**. Each polls the platform API (roughly a six-second request window); do not share a source between players. Async stops complete before replacement sessions start, including rapid swipes, hiding and teardown. A stopped session is never restarted. Connection loss leaves existing engagement visible while Core reconnects; it does not pause playback.

Replay shows **whatever chat history a Core session returns for a VOD**, positioned at `createdAt - liveDate`, clamped to `[0, duration]`. Core documents `liveDate` as the date the stream went live. Missing origin timestamps map to zero; missing duration uses the item's duration hint (or zero until supplied). A full time-indexed replay history is a backend dependency, outside this package. This mapping assumes the VOD begins at the stream's live origin; backend trimming could require a future offset contract. Live playback, signed URL refresh and moderation UI remain unsupported.

## Failed-item policy

Use the player's native `failedItemPolicy` (default `.skip`; `.stay` is available). `skipFailedHotMicItems(using:)` remains compiling but is deprecated and is no longer installed in the demo. Native skip keeps failed entries in the playlist and excludes them from automatic traversal; it does not remove them. Source pages still filter non-VOD/missing-URL summaries. The adapter's short resolver cache lifetime does not override the player's session-long resolved-item cache; rebuild the playlist/player for changed media or credentials.

## Credentials and demo

Access tokens are HS256 JWTs minted by the partner backend. Never ship the API signing secret in an app, source repository or plist. Obtain short-lived tokens through your authenticated backend; never log credentials or raw authentication responses. Core targets the production API and has no base-URL option.

Open `Sample/HotMicPlayerCoreDemo.xcodeproj` and run `HotMicPlayerCoreDemo` on an iPhone simulator. With no credentials, a visible message explains the fake client fallback. The fake feed uses public MDN MP4 and Apple VOD HLS fixtures, filters live/missing-URL summaries, and supplies two overlapping pages. Swipe or tap Next to page. `HMOverlayLayout` shows scripted chat batches, a poll, reconnect/recovery and message/poll deletions after 30 seconds; double-tap a chat row to react, compose a message and tap a poll option. The fake returns confirmed sends without echoing them, just like Core. Its reaction deletion follows four seconds after reacting. Launch with `--fake` to bypass all credential loading and guarantee no HotMic API calls. Play ID resolves a reference; Non-VOD and Missing URL demonstrate an item error followed by the valid fallback. Internet access is needed for the public videos, but no HotMic API call occurs in fake mode.

For authorized real-API verification, supply `HOTMIC_API_KEY` and `HOTMIC_ACCESS_TOKEN` in the Run environment, or put `HotMicCredentials.json` in the running app's **Documents** directory with those two JSON keys. Both values must be nonempty. Environment values take precedence; an absent/incomplete file falls back to fake mode. The file name is ignored repository-wide and the file is never bundled. Do not put credentials in a shared Xcode scheme. No credentials are included here. A real by-ID request also needs a known VOD stream ID; fake error buttons are hidden with credentials.

The sample imports and links the `HotMicPlayerCore` package product, just as a partner app does; it does not compile adapter source files into the app. Its fake uses `@_spi(Testing) import HotMicPlayerCore` to access the `CoreStreamClient` and `CoreSessionFactory` / `CoreSession` seams and projected binary values. These are experimental Testing SPI, hidden from ordinary partner imports and outside the stable public contract. The authenticated path uses the public `HotMicClient` initializers shown above. `PartnerIntegration.swift` compiles the 15-line README example with an ordinary `import HotMicPlayerCore`. `Sample/generate_project.rb` reproduces the checked-in project using the existing `xcodeproj` Ruby gem. Fake-mode evidence (safe event names and fixture IDs only) is written to app Documents as `demo-evidence.jsonl`; real mode writes no evidence.

## Validation

See [milestone 5b validation](docs/MILESTONE_5B_VALIDATION.md) for simulator evidence, commands, timings and remaining real-API coverage. Unit tests run on iOS because HotMicCore ships only iOS slices. Use the sample scheme's `HotMicPlayerCoreTests` target. Generic device compilation can use `CODE_SIGNING_ALLOWED=NO` without changing signing configuration.
