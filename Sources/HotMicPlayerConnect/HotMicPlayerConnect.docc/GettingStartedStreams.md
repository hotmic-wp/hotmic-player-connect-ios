# Getting started: streams

Integrate a paged HotMic VOD feed using the player and Connect adapter.

## Install

Add both packages and link the `HotMicPlayer` and `HotMicPlayerConnect` products.
Link `HotMicCore` too when importing it to create your authenticated client.
Pin each package to its release candidate.

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", exact: "1.0.0-rc.1"),
.package(url: "https://github.com/hotmic-wp/hotmic-player-connect-ios", exact: "1.0.0-rc.2")
```

## Build a feed

```swift
import SwiftUI
import HotMicCore
import HotMicPlayer
import HotMicPlayerConnect

@MainActor struct StreamsFeed: View {
    @State private var player: HMPlayer
    @Environment(\.scenePhase) private var scenePhase
    init(client: HotMicClient) {
        let player = HMPlayer(resolver: HotMicItemResolver(client: client))
        player.playlistSource = HotMicPlaylistSource(client: client,
            query: HotMicStreamQuery(includesLive: false, includesScheduled: false,
                                    includesVOD: true, page: 1, limit: 20))
        _player = State(initialValue: player)
    }
    var body: some View {
        HMVerticalFeedView(player: player)
            .task { await player.start() }
            .onAppear { player.isFeedVisible = true }
            .onChange(of: scenePhase) { _, phase in player.isFeedVisible = phase == .active }
            .onDisappear { player.teardown() }
    }
}
```

For navigation that hides a mounted feed, also set `isFeedVisible = false` while hidden.
For by-ID playback set `player.playlistSource = nil`, then
`player.replaceAll([.hotmicStream(streamID)])` and `player.play()` on the main actor.

## Pagination and failures

The source preserves query filters, user and page size; nil cursor starts at the query’s page (minimum 1).
Treat cursors as opaque. A nil returned cursor ends the feed. Live streams and missing VOD URLs are
filtered; an entirely filtered page can still continue. Summaries produce direct URL items without
extra by-ID fetches. The player removes overlapping IDs. Page-number pagination is not a catalogue
snapshot: publication during browsing can shift boundaries; restart the feed to refresh.

The resolver caches successful results for 60 seconds, up to 32 entries by default. Zero capacity
disables that cache. The player separately retains resolved items for its lifetime; rebuild for changed
credentials or media URLs. Cancellation propagates. Core authentication and transport errors pass through;
unsupported namespace, non-VOD, missing URL and malformed pagination use ``HotMicPlayerConnectError``.
The player’s native `HMPlayerConfiguration.failedItemPolicy` defaults to `.skip`; use `.stay` to show retries.

Open `Examples/HotMicExamples.xcodeproj`, scheme `Streams`, for a roughly 40-line entry point with
an injected fake client by default. Shared support holds credentials, fixtures and optional verification.
The example imports the optional `HotMicPlayerConnectTesting` product for its fake client; production
apps do not need this product. Only public API is imported. `--fake` bypasses credential loading entirely.
