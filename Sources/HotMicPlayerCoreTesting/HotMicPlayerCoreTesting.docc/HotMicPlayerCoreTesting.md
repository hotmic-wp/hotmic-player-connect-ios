# ``HotMicPlayerCoreTesting``

Inject fake transports into the real Core adapters for offline previews and tests.

## Overview

Link this optional product alongside `HotMicPlayerCore` and import both modules. Production integrations
using `HotMicClient` do not need the testing product. These fixture protocols and values are separate
from the small runtime API. All session operations run on the main actor; stream clients and raw
value projections are Sendable. A factory must create fresh single-use sessions, subscribe events before
startup, and await cleanup in an idempotent stop implementation.

```swift
import HotMicPlayerCore
import HotMicPlayerCoreTesting

// fakeClient conforms to CoreStreamClient; fakeSessions conforms to CoreSessionFactory.
let resolver = CoreItemResolver(client: fakeClient)
let playlist = CorePlaylistSource(client: fakeClient)
// Construct the interaction source on the main actor.
let interactions = CoreInteractionSource(factory: fakeSessions)
```

The package’s two examples contain complete fake implementations. The adapter remains responsible for
pagination filtering, replay timing, moderation and bounded session lifecycle. Testing constructors
accept the same cache/query/dwell settings as the runtime, plus `retryBaseDelay` for accelerated tests.

## Topics

### Stream fixtures
- ``CoreStreamClient``
- ``CoreStreamSummary``
- ``CoreStreamPage``

### Session fixtures
- ``CoreSessionFactory``
- ``CoreSession``
- ``CoreSessionSnapshot``
- ``CoreSessionEvent``
- ``CoreChat``
- ``CoreMessageReaction``
- ``CorePoll``
