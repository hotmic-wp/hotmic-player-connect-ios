# Session cost and lifecycle

Budget up to two Core sessions per viewer when engagement is enabled.

## Current plus next

Streams alone fetch catalogue pages and by-ID summaries; they open no engagement sessions.
With ``HotMicInteractionSource``, current opens immediately and next opens after current has remained
active for `nextSessionDelay` seconds (default 1). This dwell debounce avoids speculative sessions
during fast swiping; it is elapsed lifecycle time, not accumulated playback. Zero opts into immediate next.
Each Core session polls the API on roughly a six-second request window.

A prepared next session survives promotion. Leaving both roles stops it. Stopping sessions continue
to occupy the two slots until asynchronous cleanup finishes; replacements wait for a freed slot.
Timeline access never starts networking. Timelines and engagements are held weakly by the source.

## Visibility and teardown

Hosts must set `player.isFeedVisible = false` on backgrounding and when hiding a mounted feed, then
restore it on foreground/visibility. This closes current/next sessions and prevents background polling.
Call `player.teardown()` on final dismissal. Do not share a source between players or signed-in users.

Startup transport, 429 and 5xx failures retry with a fresh session while current, at 1/2/4… seconds,
capped at 30. A failed speculative next retries on promotion. Authentication and permanent failures
wait for leave/re-entry (replace the client for new credentials). Polling reconnects within an active
session keep existing engagement visible and do not interrupt media playback.
