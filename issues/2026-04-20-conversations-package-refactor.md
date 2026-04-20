## Status

DONE

## Problem

The old conversation store file mixed conversation model types with database and service logic.

That made the storage layer harder to scan and did not reflect the intended separation between conversation types and conversation operations.

## Solution

Moved conversation code into a dedicated `conversations` package:

- added `tincan-server/conversations/types.go`
- added `tincan-server/conversations/service.go`
- moved the `Conversation` type into `types.go`
- moved the SQLite-backed store and conversation operations into `service.go`
- updated the root server and `ConversationService` to import the new package

## Notes

This keeps the structure clearer:

- `conversations/types.go` for conversation data types
- `conversations/service.go` for persistence operations
- the higher-level root `ConversationService` still orchestrates profile resolution, adapter calls, and persistence through the package boundary
