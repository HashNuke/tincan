## Status

DONE

## Problem

Even after introducing the `calls` manager, the current debug WebRTC offer/answer and peer lifecycle code still lived directly in `main.go`.

That kept transport-specific debug plumbing mixed into the server entrypoint.

## Solution

Moved the current debug WebRTC signaling and peer handling into the `calls` package:

- added `tincan-server/calls/webrtc_debug.go`
- added `WebRTCDebugServer`
- moved the current `/webrtc/offer` handling, peer creation, RTP logging, and data-channel event-sink wiring into that package
- updated `main.go` to initialize and use the debug transport through the `calls` package instead of carrying the implementation inline

## Notes

This keeps the debug WebRTC path available while making the server entrypoint cleaner and moving another transport-specific piece behind the call/session boundary.
