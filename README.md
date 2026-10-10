# HotMicPlayerConnect

HotMic VOD streams and optional engagement for [HotMicPlayer](https://github.com/hotmic-wp/hotmic-player-ios).
Release candidate **1.0.0-rc.2**. Requires iOS 17+, Swift tools 6.0+ (Swift 5 language mode), and Xcode with the iOS SDK.
HotMicCore 1.0.2 is an iOS binary dependency; build and test for iOS, not macOS.

## Install

Add both packages in Xcode or Swift Package Manager. Pin each package to its release candidate:

```swift
.package(url: "https://github.com/hotmic-wp/hotmic-player-ios", exact: "1.1.0-alpha.1"),
.package(url: "https://github.com/hotmic-wp/hotmic-player-connect-ios", exact: "1.0.0-rc.2")
```

The player repository is public. Link `HotMicPlayer` and `HotMicPlayerConnect`. Link the transitive `HotMicCore` product when importing it
to construct a client. Engagement UI additionally links `HotMicPlayerUI` from the player package.

## Level 1: streams

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

For by-ID playback, on the main actor set `player.playlistSource = nil`, then
`player.replaceAll([.hotmicStream(streamID)])` and `player.play()`.

`HotMicPlaylistSource` preserves your query filters and page size, filters live/missing-URL summaries,
and produces direct URL items without by-ID fetches. The player loads further pages and removes overlap
by `hotmic:<id>` identity. Cursors are opaque; nil returned cursor means end. Page-number pagination is
not a catalogue snapshot; new publication can shift page boundaries. Restart the feed to refresh.

The resolver has a 60-second success-only cache (32 entries; zero disables it). The player separately
caches resolved items for its lifetime. Rebuild the player/adapters for changed media or credentials.
Core transport/auth errors propagate; adapter validation errors use `HotMicPlayerConnectError`.
The player’s `failedItemPolicy` defaults to `.skip`; `.stay` allows host retry UI.

## Level 2: streams + engagement

Add `import HotMicPlayerUI`, then use this setup and view in the same lifecycle wrapper:

```swift
let interactions = HotMicInteractionSource(client: client)
let player = HMPlayer(resolver: HotMicItemResolver(client: client), interactions: interactions)
player.playlistSource = HotMicPlaylistSource(client: client)
// SwiftUI body:
HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
```

Use one interaction source per player and signed-in user. Chat sending, message reactions
(👍 / 🔥 / 😆 / 😡 / 😢) and voting are supported. Timed stream emoji reactions are unavailable.
Item fire membership and comment paging are optional: HotMicCore 1.0.2 does not provide them, so an
authenticated source omits `.toggleReaction` and `.loadComments`. A testing session can supply both.
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
40 lines) or `StreamsAndEngagement`. Shared support holds fake clients, credentials and verification
helpers. Both use ordinary public imports and the actual Connect adapters. Examples also link/import
`HotMicPlayerConnectTesting` for fake clients; production apps need only `HotMicPlayerConnect`.
`Streams` links no `HotMicPlayerUI` product. No credentials selects fake mode with public MDN MP4/Apple
VOD HLS fixtures (internet needed for videos). `--fake` bypasses all credential loading and guarantees
no HotMic API calls. `--fake --verify` runs an optional fake-only integration script, including paging
and by-ID resolution; engagement adds timing recovery, sends, reactions, voting, moderation, fire
membership, older comments and a live comment. Item comments do not change the VOD timeline.
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

## Documentation, versions and checks

Read the [DocC guides](Sources/HotMicPlayerConnect/HotMicPlayerConnect.docc/HotMicPlayerConnect.md),
[player guides](https://github.com/hotmic-wp/hotmic-player-ios/tree/1.1.0-alpha.1/Sources/HotMicPlayer/HotMicPlayer.docc),
[overlay guides](https://github.com/hotmic-wp/hotmic-player-ios/tree/1.1.0-alpha.1/Sources/HotMicPlayerUI/HotMicPlayerUI.docc),
[API review](docs/API_REVIEW_1.0.md), and [changelog](CHANGELOG.md).

This package follows semver: compatible additions in minor releases, fixes in patches, breaking changes
in majors with deprecations where practical. RCs are prereleases for integration evaluation before
the stable release.
`HotMicPlayerConnect.version` reports `1.0.0-rc.2`. The interim `skipFailedHotMicItems(using:)` helper
was removed in 1.0; use native `HMPlayerConfiguration.failedItemPolicy`. Injectable clients, projected
fixture values and accelerated retry controls live in the optional `HotMicPlayerConnectTesting` product,
separate from the runtime API.

CI runs on macOS for PRs and pushes to `main` only, with a nine-minute limit. It builds both examples
(and the package) for simulator and unsigned generic device, runs strict DocC analysis, then the unit
suite once. The public player dependency resolves without a GitHub token or credential helper.
`PARTNER_DOCS_DENYLIST` may optionally supply newline-separated private terms to the content check.
Run `bash .github/scripts/validate-release.sh` locally with an available iOS simulator. Selection prefers
an installed iPhone model and falls back to another available iPhone; `SIMULATOR_UDID` can select an
existing device explicitly. `BUILD_ONLY=1` defers the suite for a local example smoke run.
No global installation, credentials or signing configuration changes are needed. The checked-in project
can be regenerated with `ruby Examples/generate_project.rb` if the `xcodeproj` gem is already installed.
