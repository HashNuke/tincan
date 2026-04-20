## Status

DONE

## Problem

The first Go `OpenCodeServerAdapter` implementation was only a stub.

That meant conversations could be persisted through the new storage and adapter boundary, but they were not yet creating real OpenCode sessions or sending the first prompt to the backend.

## Solution

Completed the first real OpenCode adapter integration:

- extended `AgentAdapter.StartConversation` to accept a conversation title and message
- updated `ConversationService` to pass a placeholder title for now
- implemented `OpenCodeServerAdapter.StartConversation` to:
  - create an OpenCode session through `/session`
  - send the initial prompt through `/session/:id/prompt_async`
  - return the real OpenCode session ID as `backend_conversation_id`
- kept title generation simple for now so router-owned title generation can be added later

## Notes

This keeps the architecture moving in the intended direction:

- router will eventually own conversation titles
- adapter only consumes the title and message it is given
- conversation persistence in Go now connects to a real OpenCode session instead of a generated placeholder ID
