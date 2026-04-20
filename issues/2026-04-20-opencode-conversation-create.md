## Status

DONE

## Problem

The server could store conversations and receive OpenCode hook callbacks, but it still had no real path for creating a conversation through OpenCode and persisting the returned backend session ID.

Without that step, the hook receiver had nothing to map incoming session events onto.

## Solution

Implemented the first end-to-end OpenCode conversation creation flow:

- added a small `OpenCodeClient` for `opencode-server`
- added `POST /conversations`
- the route loads the selected agent profile from the JSON-backed profile store
- it allocates the lowest available `conversation_number` for that profile
- it creates an OpenCode session using the profile's `working_directory`
- it persists the returned OpenCode session ID into `backend_conversation_id`
- it sends the initial prompt through `prompt_async`
- it marks the local conversation as `running` once the async prompt is accepted

## Notes

Current lifecycle model:

- conversations are only created when tincan makes an outbound OpenCode session call
- the returned OpenCode session ID is the durable mapping key
- follow-up status changes are expected to arrive through the registered OpenCode hook plugin
- no polling is required for the normal status path

This keeps the integration narrow:

- creation happens through `POST /conversations`
- state updates happen through `POST /hooks/opencode`
