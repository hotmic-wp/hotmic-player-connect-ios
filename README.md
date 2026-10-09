# HotMicPlayerCore

HotMic VOD streams and optional engagement for [HotMicPlayer](https://github.com/hotmic-wp/hotmic-player-sdk).
Release candidate **1.0.0-rc.1**. Requires iOS 17+, Swift tools 6.0+ (Swift 5 language mode), and Xcode with the iOS SDK.
HotMicCore 1.0.2 is an iOS binary dependency; build and test for iOS, not macOS.

## Install

Add both packages in Xcode or SwiftPM:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-sdk", from: "1.0.0-rc.1"),
.package(url: "https://github.com/hotmic-wp/hotmic-player-core-ios", from: "1.0.0-rc.1")
```

Link `HotMicPlayer` and `HotMicPlayerCore`. Link the transitive `HotMicCore` product when importing it
to construct a client. Engagement UI additionally links `HotMicPlayerUI` from the player package.
The adapter RC tag must be published by the release manager before these install coordinates resolve.

## Level 1: streams

```swift
import SwiftUI
import HotMicCore
import HotMicPlayer
import HotMicPlayerCore

@MainActor struct StreamsFeed: View {
    @State private var player: HMPlayer
    @Environment(\.scenePhase) private var scenePhase
    init(client: HotMicClient) {
        let player = HMPlayer(resolver: CoreItemResolver(client: client))
        player.playlistSource = CorePlaylistSource(client: client,
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

For by-ID playback, on the main actor set `player.playlistSource = nil`, then
`player.replaceAll([.hotmicStream(streamID)])` and `player.play()`.

`CorePlaylistSource` preserves your query filters and page size, filters live/missing-URL summaries,
and produces direct URL items without by-ID fetches. The player loads further pages and removes overlap
by `hotmic:<id>` identity. Cursors are opaque; nil returned cursor means end. Page-number pagination is
not a catalogue snapshot; new publication can shift page boundaries. Restart the feed to refresh.

The resolver has a 60-second success-only cache (32 entries; zero disables it). The player separately
caches resolved items for its lifetime. Rebuild the player/adapters for changed media or credentials.
Core transport/auth errors propagate; adapter validation errors use `HotMicPlayerCoreError`.
The player’s `failedItemPolicy` defaults to `.skip`; `.stay` allows host retry UI.

## Level 2: streams + engagement

Add `import HotMicPlayerUI`, then use this setup and view in the same lifecycle wrapper:

```swift
let interactions = CoreInteractionSource(client: client)
let player = HMPlayer(resolver: CoreItemResolver(client: client), interactions: interactions)
player.playlistSource = CorePlaylistSource(client: client)
// SwiftUI body:
HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
```

Use one interaction source per player and signed-in user. Chat sending, message reactions
(👍 / 🔥 / 😆 / 😡 / 😢) and voting are supported; stream emoji reactions are unavailable.
Connection failures affect engagement independently of playback. Set `isFeedVisible = false` when
backgrounded or when hiding a mounted feed; restore on visibility. Call `teardown()` on dismissal.

Engagement uses **at most two sessions per viewer**, current plus next. Each polls Core (roughly a
six-second request window). Next waits for a one-second current-item dwell by default; adjust
`nextSessionDelay` (zero opens immediately). Prepared next promotes without restart, and stopping
sessions remain counted until cleanup finishes. Startup transport/429/5xx failures back off up to
30 seconds while current; authentication/permanent failures wait for leave/re-entry.

Core supplies whatever history is in its session snapshot/batches, not a full replay archive.
History maps to `createdAt - liveDate` only inside `[0, duration]`; out-of-window events are dropped.
Unknown origin/duration retains bounded raw history (2,000 messages, 100 polls) until stream timing or
a resolved item’s duration hint permits recovery. Viewer sends keep the playback position while timing
is unknown. Core deletion events suppress messages/polls and late echoes. Closed polls have no closing
timestamp and remain visible as results. Live playback, signed URL refresh and moderator UI are unsupported.

## Credentials

Your **partner backend mints short-lived HS256 viewer JWTs**. Never ship the API signing secret in the app,
repository or plist. Obtain the API key and access token through your authenticated backend:

```swift
let client = HotMicClient(apiKey: apiKey, accessToken: accessToken)
```

Keep credentials out of logs/shared schemes. On sign-out or token replacement, tear down the old player
and create new clients/adapters. Core 1.0.2 targets production and has no configurable base URL.
`hotmic.namespace` / `hotmic.streamID` metadata reaches player analytics; account for stream IDs in your
analytics data handling. Arbitrary URLs or an ID prefix alone never opt into engagement sessions.

## Examples and verification

Open [Examples/HotMicExamples.xcodeproj](Examples/HotMicExamples.xcodeproj). Choose `Streams` (roughly
40 lines) or `StreamsAndEngagement`. These replace the former `Sample/` app; shared support holds fake
clients, credentials and evidence plumbing. Both use ordinary public imports and the actual Core adapters.
`Streams` links no `HotMicPlayerUI` product. No credentials selects fake mode with public MDN MP4/Apple
VOD HLS fixtures (internet needed for videos). `--fake` bypasses all credential loading and guarantees
no HotMic API calls. `--fake --verify` runs an optional fake-only integration script, including paging
and by-ID resolution; engagement adds timing recovery, sends, reactions, voting and moderation.
Safe fixture evidence is written to app Documents as `demo-evidence.jsonl`; real mode writes none.

For **authorized manual real-credential verification**:

1. Select either example scheme and remove `--fake` / `--verify` / `--review-script` from Run arguments.
2. In the local, unshared Run environment, supply nonempty `HOTMIC_API_KEY` and `HOTMIC_ACCESS_TOKEN`
   obtained from your backend. Alternatively create `HotMicCredentials.json` in the installed app’s
   Documents directory with those two JSON keys. The ignored file is never bundled; environment takes
   precedence. Do not copy credentials into this repository or a shared scheme.
3. Run on an iPhone simulator. Confirm **Authenticated Core**, then verify a paged VOD feed, Next/Previous,
   and Play ID with a known authorized VOD ID. Confirm non-VOD/missing-URL entries are filtered/skipped.
4. In `StreamsAndEngagement`, check connected status, history at known media times, send a disposable chat,
   react to a known message, and vote on an authorized open poll. Check server confirmation and seek replay.
   Have an authorized moderator delete only that disposable content and verify the deletion/late-echo behavior.
5. Hide/background the feed, confirm sessions stop using authorized backend telemetry, restore visibility,
   then dismiss/sign out and confirm cleanup. Exercise token expiry/replacement with test credentials.

No real API or credential verification was performed for this release work.

## Documentation, versions and checks

Read the [DocC guides](Sources/HotMicPlayerCore/HotMicPlayerCore.docc/HotMicPlayerCore.md),
[player guides](https://github.com/hotmic-wp/hotmic-player-sdk/tree/1.0.0-rc.1/Sources/HotMicPlayer/HotMicPlayer.docc),
[overlay guides](https://github.com/hotmic-wp/hotmic-player-sdk/tree/1.0.0-rc.1/Sources/HotMicPlayerUI/HotMicPlayerUI.docc),
[API review](docs/API_REVIEW_1.0.md), and [changelog](CHANGELOG.md).

This package follows semver: compatible additions in minor releases, fixes in patches, breaking changes
in majors with deprecations where practical. RCs are prereleases pending review and tagging.
`HotMicPlayerCore.version` reports `1.0.0-rc.1`. Prefer native `failedItemPolicy` over the retained deprecated
`skipFailedHotMicItems(using:)` helper. Testing SPI is outside the stable public contract.

CI runs on macOS for PRs and pushes to `main` only, with a nine-minute limit. It builds both examples
(and the package) for simulator and unsigned generic device, runs strict DocC analysis, then the unit
suite once. Run `bash .github/scripts/validate-release.sh` locally with an available iPhone 17 Pro simulator.
No global installation, credentials or signing configuration changes are needed. The checked-in project
can be regenerated with `ruby Examples/generate_project.rb` if the `xcodeproj` gem is already installed.
