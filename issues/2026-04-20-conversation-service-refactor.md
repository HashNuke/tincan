## Status

DONE

## Problem

The first Go conversation creation flow had been exposed through a temporary `POST /conversations` route.

That route was useful as a development seam, but it was not the intended long-term interaction surface. The important part was the underlying orchestration logic, not the HTTP endpoint itself.

## Solution

Refactored the Go conversation creation flow into a reusable `ConversationService`:

- added `conversation_service.go`
- moved the profile resolution, adapter dispatch, conversation number allocation, and persistence logic into `ConversationService.CreateConversation`
- removed the temporary `POST /conversations` route from `main.go`
- wired the new service into Go server startup so future router/call-session code can call it directly

## Notes

This keeps the Go server architecture cleaner:

- conversation creation is now an internal service operation
- future voice/router flows can call the same logic without depending on an HTTP seam
- the storage and adapter boundaries remain intact
