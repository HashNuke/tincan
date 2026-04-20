## Status

DONE

## Problem

The Go server still tracked active realtime sessions through ad hoc maps inside `main.go`.

That worked for the temporary WebRTC debug path, but it was the wrong shape for the planned Liblinphone migration because transport/session concerns were not isolated behind a reusable call-session layer.

## Solution

Implemented the first `calls` package slice:

- added `tincan-server/calls/types.go`
- added `tincan-server/calls/manager.go`
- introduced a transport-neutral `Manager`
- moved active session tracking and backend-conversation-to-session linking into that manager
- changed the current Go WebRTC debug path to use the `calls` manager for:
  - session registration
  - push-to-talk state
  - event sink registration
  - backend conversation linkage
  - event pushing

## Notes

This is the first migration slice, not the full Liblinphone integration.

The current WebRTC debug path still exists, but it now uses a transport-neutral call/session manager rather than raw maps in `main.go`.
