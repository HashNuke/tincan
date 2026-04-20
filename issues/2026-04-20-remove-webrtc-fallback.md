## Status

DONE

## Problem

The temporary `calls/webrtc_debug.go` transport was still present even though the project had already committed to the Liblinphone migration path.

Keeping the fallback around made the transport story noisier and suggested a fallback route that the product no longer intends to use.

## Solution

Removed the unused WebRTC debug fallback transport:

- deleted `tincan-server/calls/webrtc_debug.go`
- simplified `tincan-server/calls/linphone_server.go`
- left the `LinphoneServer` boundary in place, but without registering the old `/webrtc/offer` fallback route

## Notes

This keeps the transport direction clear:

- the server still has a Liblinphone-facing transport boundary
- the old debug WebRTC implementation is no longer part of the active code path
