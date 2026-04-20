## Status

DONE

## Problem

The Go server still wired the current debug WebRTC transport directly in `main.go`.

That made it harder to transition toward a Liblinphone-facing transport layer because there was no named server-side boundary representing the future app transport.

## Solution

Added a `LinphoneServer` boundary in the `calls` package:

- added `tincan-server/calls/linphone_server.go`
- `main.go` now initializes a `LinphoneServer`
- `main.go` now registers call transport routes through that boundary instead of directly through the debug WebRTC implementation

## Notes

The current implementation still uses the existing debug WebRTC offer route under the hood.
This is a migration boundary step, not the final SIP/Liblinphone protocol implementation.

The important improvement is that the transport-facing server layer now has a named place to evolve independently from the rest of the application logic.
