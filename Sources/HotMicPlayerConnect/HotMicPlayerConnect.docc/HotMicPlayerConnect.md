# ``HotMicPlayerConnect``

Play HotMic VOD streams and optionally add session-backed chat, message reactions and polls.

## Overview

This add-on connects HotMicCore to the independent HotMicPlayer package. Choose streams alone,
or add engagement and HotMicPlayerUI’s `HMOverlayLayout`. Requires iOS 17+, Swift tools 6.0+
and HotMicPlayer 1.1.0-alpha.1 or a later compatible 1.x release. A `from:` requirement on a prerelease floats across later prereleases; pin exact player and Connect versions until 1.1.0 ships. This package uses Swift 5 language mode.

The [player documentation](https://github.com/hotmic-wp/hotmic-player-ios/tree/1.1.0-alpha.1/Sources/HotMicPlayer/HotMicPlayer.docc)
covers playback, playlists, errors, caching, analytics and custom layouts.

## Topics

### Integration guides
- <doc:GettingStartedStreams>
- <doc:GettingStartedEngagement>
- <doc:AuthenticationAndTokens>
- <doc:SessionCostAndLifecycle>
- <doc:ReplayTiming>
- <doc:Moderation>

### Streams
- ``HotMicItemResolver``
- ``HotMicPlaylistSource``
- ``HotMicPlayerConnectError``

### Engagement
- ``HotMicInteractionSource``
