## Status

DONE

## Problem

The `/speak` page was polling every few seconds for pending updates, even though the browser already had an active WebRTC session to the Go server.

Polling was only a temporary bridge and was not the intended long-term model.

## Solution

Replaced the polling path with WebRTC data-channel push:

- the browser now creates an `events` data channel on the WebRTC peer connection
- the Go server stores that data channel per session when it arrives
- immediate feedback audio events are pushed over the live data channel
- conversation update notifications are also pushed over the live data channel
- `/speak` now plays pushed audio URLs immediately instead of polling `/updates/pending`

## Notes

This is a better fit for the current architecture:

- updates are pushed over the existing realtime session
- the browser no longer has to poll for notification availability
- audio payload delivery still uses server-generated URLs, but notification timing is now push-based over WebRTC
