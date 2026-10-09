# HotMicPlayerCore

Optional HotMic streams adapter for [HotMicPlayer](https://github.com/hotmic-wp/hotmic-player-sdk). iOS 17+, Swift 5 language mode with Swift tools 6.0+. The player stays dependency-free; this separate package adds the HotMicCore binary dependency. VOD only. No sessions, chat, polls or reactions.

## Install

Add these packages in Xcode (or use the equivalent SwiftPM dependencies), and link `HotMicPlayer` and `HotMicPlayerCore` to your app target:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", from: "0.3.0"),
.package(url: "https://github.com/hotmic-wp/hotmic-player-core-ios", branch: "main")
```

The adapter is not tagged yet; use `main` after this milestone merges, or the reviewed commit for a reproducible integration. It transitively requires HotMicCore `from: "1.0.2"`. Import `HotMicCore` when constructing the shared authenticated client.

## Integration in 15 lines

```swift
import SwiftUI
import HotMicCore
import HotMicPlayer
import HotMicPlayerCore
@MainActor struct Feed: View {
    @State private var player: HMPlayer
    init(client: HotMicClient) {
        let player = HMPlayer(resolver: CoreItemResolver(client: client))
        player.playlistSource = CorePlaylistSource(client: client)
        _player = State(initialValue: player)
    }
    var body: some View {
        HMVerticalFeedView(player: player).task { await player.start() }
    }
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
| `HMPlayer.skipFailedHotMicItems(using:)` | Main-actor observer returning `Task<Void, Never>`. Removes only references rejected with this adapter's terminal non-VOD/missing-URL error; handles upcoming, final and only entries. Retain and cancel the task on dismissal. |

Core uses offset/page-number pagination, not a snapshot of the catalogue. VODs published mid-session can shift page boundaries and be skipped in that browsing session; overlapping duplicates are handled by the player. Restart the feed to refresh the catalogue.

There is no Core implementation of `HMInteractionSource` in this milestone. The player's default demo interaction source remains its default; supplying real interactions is future work. Signed URL refresh and live playback are unsupported. The adapter's short cache lifetime does not override the player's session-long resolved-item cache; rebuild the playlist/player for changed media or credentials.

## Interim failed-item policy

HotMicPlayer 0.3.0 reports resolver errors but does not skip failed entries. For by-ID playlists, install this host-side helper **before** edits or playback:

```swift
let resolver = CoreItemResolver(client: client)
let player = HMPlayer(resolver: resolver)
let skipTask = player.skipFailedHotMicItems(using: resolver)
player.replaceAll([.hotmicStream(streamID), .hotmicStream(fallbackID)])
// On permanent dismissal:
skipTask.cancel()
player.teardown()
```

Source pages already filter unplayable summaries. By-ID references throw a typed error; the player emits `.error(item:kind:)` with `.resolution(description)`. The helper first matches the player's `.resolution` error kind, then consults the **same resolver passed to the player** and switches on its typed `HotMicPlayerCoreError.notVOD` or `.missingVODURL` outcome for that reference ID. It does not inspect or match error message text. The resolver keeps at most 256 recent terminal outcomes and clears an old outcome when a new resolution starts. It removes the matching unchanged item with `remove(ids:)`; this selects the next survivor or becomes idle. It never treats transport/authentication errors as terminal and does not depend on the player's private retry count. Other event subscribers still see the item error. Install one helper per player. The player will gain a native failed-item policy in its next release; this helper will then be deprecated.

## Credentials and demo

Access tokens are HS256 JWTs minted by the partner backend. Never ship the API signing secret in an app, source repository or plist. Obtain short-lived tokens through your authenticated backend; never log credentials or raw authentication responses. Core targets the production API and has no base-URL option.

Open `Sample/HotMicPlayerCoreDemo.xcodeproj` and run `HotMicPlayerCoreDemo` on an iPhone simulator. With no credentials, a visible message explains the fake client fallback. The fake feed uses public MDN MP4 and Apple VOD HLS fixtures, filters live/missing-URL summaries, and supplies two overlapping pages. Swipe or tap Next to page. Play ID resolves a reference; Non-VOD and Missing URL demonstrate an item error followed by the valid fallback. Internet access is needed for the public videos, but no HotMic API call occurs in fake mode.

For authorized real-API verification, supply `HOTMIC_API_KEY` and `HOTMIC_ACCESS_TOKEN` in the Run environment, or put `HotMicCredentials.json` in the running app's **Documents** directory with those two JSON keys. Both values must be nonempty. Environment values take precedence; an absent/incomplete file falls back to fake mode. The file name is ignored repository-wide and the file is never bundled. Do not put credentials in a shared Xcode scheme. No credentials are included here. A real by-ID request also needs a known VOD stream ID; fake error buttons are hidden with credentials.

The sample imports and links the `HotMicPlayerCore` package product, just as a partner app does; it does not compile adapter source files into the app. Its fake uses `@_spi(Testing) import HotMicPlayerCore` to access the two-fetch `CoreStreamClient` seam, projected summary/page initializers and adapter fake-client initializers. These are experimental Testing SPI, hidden from ordinary partner imports and outside the stable public contract. The authenticated path uses the public `HotMicClient` initializers shown above. `PartnerIntegration.swift` compiles the 15-line README example with an ordinary `import HotMicPlayerCore`. `Sample/generate_project.rb` reproduces the checked-in project using the existing `xcodeproj` Ruby gem. Fake-mode evidence (safe event names and fixture IDs only) is written to app Documents as `demo-evidence.jsonl`; real mode writes no evidence.

## Validation

See [milestone validation](docs/MILESTONE_4_VALIDATION.md) for simulator evidence, commands, timings and remaining real-API coverage. Unit tests run on iOS because HotMicCore ships only iOS slices. Use the sample scheme's `HotMicPlayerCoreTests` target. Generic device compilation can use `CODE_SIGNING_ALLOWED=NO` without changing signing configuration.
