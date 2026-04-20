## Status

DONE

## Problem

The WebRTC direction was documented at a high level, but the project still needed a concrete message contract for the bidirectional app-server session.

Without that, it would be unclear which control and event payloads should move over the real-time connection and how those messages relate to router actions, conversation creation, update buffering, and TTS playback.

## Solution

Added `docs/realtime-messages.md` documenting:

- a common JSON envelope for realtime data channel messages
- app-to-server messages for committed commands, cancellations, and TTS playback state
- server-to-app messages for immediate router feedback, conversation creation, queued updates, clarification prompts, and TTS control
- queueing semantics for pending announcements
- the minimal v1 message set needed for the first real-time session implementation

## Notes

This keeps the real-time session concrete without overcommitting to transport details:

- the app-server contract is now explicit
- audio transport details remain separate from control message design
- the message model lines up with the router and WebRTC docs already written
