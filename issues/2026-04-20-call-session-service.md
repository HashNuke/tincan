## Status

DONE

## Problem

The project needed a reusable server-side path for handling committed user commands before adding WebRTC transport.

Without that, the future call-session code would either have to route directly through HTTP handlers or duplicate routing and conversation-creation logic.

## Solution

Implemented a first in-process call-session orchestration path:

- added `CallSessionService`
- added `CallSessionController`
- added `POST /call-session/committed-command`
- the new path accepts a committed transcript payload
- it runs a minimal rule-based router for now
- explicit new-conversation intent is required
- `new_conversation` actions are executed through the shared `ConversationService`
- ambiguous commands return a clarifying router response rather than creating a conversation implicitly

## Notes

This is intentionally a small bridge step toward realtime calls:

- the transport is still HTTP for this endpoint
- the orchestration path is now reusable without depending on route-local logic
- future WebRTC handlers can feed committed transcripts into the same `CallSessionService`
- the current router logic is deliberately minimal and can be replaced later by a model-backed router
