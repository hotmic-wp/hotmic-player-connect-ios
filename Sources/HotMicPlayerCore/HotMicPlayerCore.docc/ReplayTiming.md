# Replay timing

Show the history Core returns, aligned to the VOD recording window.

## Current backend contract

Core supplies a session snapshot and subsequent chat batches and polls, not a complete time-indexed
VOD replay archive. History is positioned at `createdAt - liveDate`, assuming the VOD begins when
the stream went live. Backend trimming would require a future explicit offset contract.
Only offsets in `[0, duration]` appear; pre-origin and post-recording events are dropped, never
clamped onto the endpoints. Core does not supply a poll closing timestamp, so a closed poll remains
visible as results. Missing live origin means history cannot yet be positioned.

## Delayed timing

When duration or live origin is unknown, the adapter retains raw Core values, bounded to the latest
2,000 messages and 100 polls per timeline. History stays invisible until both are usable.
A stream update or a resolved item’s duration hint remaps retained history and rebuilds density.
The item hint is a fallback when Core has not supplied a positive finite duration. Oldest retained
values are evicted when the bound is exceeded; this cannot recover history the backend never sent.

Confirmed viewer sends retain the playback position at send time, including when duration or origin
is unknown. Server echoes reconcile by ID. Once duration is known, source event offsets are constrained
to its window. Deletion updates discard retained raw values and the player suppresses late echoes.

Live playback, signed URL refresh and a full historical replay archive are outside this release.
