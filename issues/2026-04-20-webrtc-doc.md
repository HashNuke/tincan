## Status

DONE

## Problem

The project had reached a point where app-to-server communication was no longer well-described by simple request-response HTTP.

The server needs to receive user audio, run routing, trigger backend actions, and later push asynchronous conversation updates and TTS playback back to the app.

## Solution

Added `docs/webrtc.md` documenting:

- why the app-to-`tincan-server` connection should become bidirectional
- the recommended split of WebRTC for app-server and HTTP plus hooks for agent backends
- the two main directions of the real-time loop: user to backend and backend to user
- the role of the router in both directions
- the incremental path from the current HTTP development flow toward a session-oriented WebRTC flow

## Notes

This keeps the architecture clear:

- `tincan-server` is the real-time orchestrator for the call session
- agent backends remain simpler HTTP plus hook integrations
- the app receives unsolicited conversation updates and TTS playback over the same real-time session
