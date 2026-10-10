# ``HotMicPlayerConnectTesting``

Inject fake transports into the real Connect adapters for offline previews and tests.

## Overview

Link this optional product alongside `HotMicPlayerConnect` and import both modules. Production integrations
using `HotMicClient` do not need the testing product. These fixture protocols and values are separate
from the small runtime API. All session operations run on the main actor; stream clients and raw
value projections are Sendable. A factory must create fresh single-use sessions, subscribe events before
startup, and await cleanup in an idempotent stop implementation.

```swift
import HotMicPlayerConnect
import HotMicPlayerConnectTesting

// fakeClient conforms to HotMicStreamClient; fakeSessions conforms to HotMicSessionFactory.
let resolver = HotMicItemResolver(client: fakeClient)
let playlist = HotMicPlaylistSource(client: fakeClient)
// Construct the interaction source on the main actor.
let interactions = HotMicInteractionSource(factory: fakeSessions)
```

The package’s two examples contain complete fake implementations. The adapter remains responsible for
pagination filtering, replay timing, moderation and bounded session lifecycle. Testing constructors
accept the same cache/query/dwell settings as the runtime, plus `retryBaseDelay` for accelerated tests.

`itemEngagement` defaults to none, matching HotMicCore 1.0.2. Opt into `.toggleReaction` and
`.loadComments` only when the session implements `setItemReaction(_:isReacted:)` and `comments(before:)`.
Returned comment pages stay off the VOD timeline. Snapshot `itemReactions` and `commentCount`, plus
`itemReaction` and `liveComment` events, are what the adapter publishes on `HMEngagement`.

## Topics

### Stream fixtures
- ``HotMicStreamClient``
- ``HotMicFixtureStreamSummary``
- ``HotMicFixtureStreamPage``

### Session fixtures
- ``HotMicSessionFactory``
- ``HotMicSession``
- ``HotMicSessionSnapshot``
- ``HotMicSessionEvent``
- ``HotMicChat``
- ``HotMicMessageReaction``
- ``HotMicItemReaction``
- ``HotMicCommentPage``
- ``HotMicFixturePoll``
