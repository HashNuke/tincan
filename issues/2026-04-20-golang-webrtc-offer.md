## Status

DONE

## Problem

The new Go-based `tincan-server` needed a minimal realtime entrypoint that the app's call button could connect to.

For the first slice, the server only needed to establish a WebRTC peer connection and answer an SDP offer. It did not need to process incoming audio yet.

## Solution

Implemented the first Go WebRTC signaling path using Pion:

- kept the Go server listening on `0.0.0.0:8004`
- added `GET /speak` as a browser-based local test page for fast iteration
- added `POST /webrtc/offer`
- added session-scoped push-to-talk control endpoints
- the endpoint accepts an SDP offer and returns an SDP answer plus a server-generated session ID
- incoming audio tracks are accepted and drained, but ignored for now
- peer connections are kept in memory until they disconnect or fail
- retained `GET /healthz` for a simple health check

## Notes

This is intentionally the smallest useful slice:

- the `/speak` page avoids rebuilding the mac app for every signaling tweak
- the `/speak` page now sends explicit push-to-talk start and stop control signals tied to the negotiated session ID
- app signaling can begin against the Go server
- media is not processed yet
- inference is not wired yet
- the server is acting as a WebRTC peer endpoint rather than just a signaling relay
