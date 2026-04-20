## Status

DONE

## Problem

The Go server had the new foundational pieces for profiles, persistence, and backend adapters, but there was not yet an actual conversation creation flow using them together.

Without that, the new storage and boundary layer was only structural and not yet exercised by a real endpoint.

## Solution

Implemented the first explicit new-conversation flow in the Go server:

- added `POST /conversations`
- resolves the requested agent profile from `AgentProfileStore`
- looks up the backend adapter for that profile
- allocates the next conversation number using `ConversationStore`
- starts the backend conversation through the adapter
- persists the conversation row in SQLite
- returns the created conversation metadata in the HTTP response

## Notes

The first adapter-backed implementation is intentionally simple:

- `OpenCodeServerAdapter` currently returns a generated backend conversation ID scaffold
- the important part of this step is that profile resolution, numbering, adapter routing, and persistence are now connected together in one real flow
