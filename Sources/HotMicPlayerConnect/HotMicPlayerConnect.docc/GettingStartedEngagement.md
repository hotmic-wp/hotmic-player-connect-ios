# Getting started: engagement

Add Core sessions and the standard player overlay to a streams integration.

## Wire the source and layout

Link `HotMicPlayerUI` from the player package, then change the streams setup:

```swift
import HotMicPlayerUI

let interactions = HotMicInteractionSource(client: client)
let player = HMPlayer(resolver: HotMicItemResolver(client: client), interactions: interactions)
player.playlistSource = HotMicPlaylistSource(client: client)
// In your SwiftUI body:
HMVerticalFeedView(player: player, layout: HMOverlayLayout.self)
```

Use one source per player and authenticated user. Keep the lifecycle handlers from
<doc:GettingStartedStreams>. The overlay exposes sending chat, reacting to messages and voting.
Timed stream emoji reactions stay hidden. The supported message emoji
are 👍 / 🔥 / 😆 / 😡 / 😢. Set the theme’s `messageReaction` to one of these and its `reactionPalette`
when customizing the UI; the example shows the complete theme initializer.

Item fire membership and comment paging use ``HotMicInteractionSource/setReaction(_:isReacted:for:)``
and ``HotMicInteractionSource/comments(for:before:)``. HotMicCore 1.0.2 has neither an item-reaction
API nor a chat-history cursor or comment count, so an authenticated source does not advertise
`.toggleReaction` or `.loadComments`. Publish totals with `updateReactionSummary(_:for:)`,
`updateCommentCount(_:)`, and live rows with `upsertComment(_:)` only when a session actually has them.
Item comments are not media-clock events. VOD replay continues to use the timeline.

Read ``HotMicInteractionSource/connectionState(for:)`` for engagement status independently of playback.
A prepared next session is promoted without restarting. Session failures never pause media playback.

## Try the public fake

Open `Examples/HotMicExamples.xcodeproj`, scheme `StreamsAndEngagement`.
The examples link/import the optional `HotMicPlayerConnectTesting` product. No credentials means an injected
`HotMicStreamClient` and `HotMicSessionFactory` from that product; neither contacts HotMic. Production apps
use the authenticated constructors in `HotMicPlayerConnect` without the testing product.
Public video fixtures still need internet. Add `--fake --verify` to run the repeatable integration flow
and write safe fixture evidence in app Documents (`demo-evidence.jsonl`).

The fake exercises missing duration, sends before timing arrives, chat batches, polls, reaction/vote
updates, reconnects, deletions and late echoes. It also advertises `.toggleReaction` and `.loadComments`:
the fire control shows the count and toggles membership, and Older comments loads the next page.
A live comment arrives beside that list and does not enter the replay timeline. Without `--verify`, use
the overlay and those controls normally.
See <doc:ReplayTiming> for the limitations of real Core history.
