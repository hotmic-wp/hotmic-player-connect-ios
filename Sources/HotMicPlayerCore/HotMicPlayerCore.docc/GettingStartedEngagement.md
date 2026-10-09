# Getting started: engagement

Add Core sessions and the standard player overlay to a streams integration.

## Wire the source and layout

Link `HotMicPlayerUI` from the player package, then change the streams setup:

```swift
import HotMicPlayerUI

let interactions = CoreInteractionSource(client: client)
let player = HMPlayer(resolver: CoreItemResolver(client: client), interactions: interactions)
player.playlistSource = CorePlaylistSource(client: client)
// In your SwiftUI body:
HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
```

Use one source per player and authenticated user. Keep the lifecycle handlers from
<doc:GettingStartedStreams>. The overlay exposes sending chat, reacting to messages and voting.
Core supplies no stream emoji reactions, so those controls stay hidden. The supported message emoji
are 👍 / 🔥 / 😆 / 😡 / 😢. Set the theme’s `messageReaction` to one of these and its `reactionPalette`
when customizing the UI; the example shows the complete theme initializer.

Read ``CoreInteractionSource/connectionState(for:)`` for engagement status independently of playback.
A prepared next session is promoted without restarting. Session failures never pause media playback.

## Try the public fake

Open `Examples/HotMicExamples.xcodeproj`, scheme `StreamsAndEngagement`.
No credentials means an injected `CoreStreamClient` and `CoreSessionFactory`; neither contacts HotMic.
Public video fixtures still need internet. Add `--fake --verify` to run the repeatable integration flow
and write safe fixture evidence in app Documents (`demo-evidence.jsonl`).

The fake exercises missing duration, sends before timing arrives, chat batches, polls, reaction/vote
updates, reconnects, deletions and late echoes. Without `--verify`, use the overlay normally.
See <doc:ReplayTiming> for the limitations of real Core history.
