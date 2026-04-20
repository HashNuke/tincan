## Status

DONE

## Problem

The conversation creation and OpenCode hook logic was embedded directly inside `routes.swift`.

That made the HTTP routes work, but it was the wrong shape for the next WebRTC and call-session work because the same orchestration logic would need to be reused outside of plain HTTP route closures.

## Solution

Refactored the server conversation flow into reusable components:

- added `ConversationService` to own conversation creation and OpenCode hook handling
- added `ConversationController` as a Vapor `RouteCollection`
- moved `POST /conversations` onto the controller backed by the shared service
- moved `POST /hooks/opencode` onto the controller backed by the shared service
- registered the shared service in application storage during startup

## Notes

This keeps the next step cleaner:

- HTTP routes still work the same way
- the shared conversation orchestration now has a single implementation point
- future WebRTC call-session code can call the same `ConversationService` directly instead of duplicating route logic
