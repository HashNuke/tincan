## Status

DONE

## Problem

The router needed a place to retain conversation-specific instructions over time.

Using only the latest user message was not enough context for future routing and update summarization, but notes also should not be mixed into the main conversation row or updated by agent output.

## Solution

Added a dedicated `conversation_notes` table and the first persistence path for it:

- added `ConversationNote` to the `conversations` package
- added an explicit migration for `conversation_notes`
- added store methods to get and upsert notes by `conversation_id`
- extended `UserRouterResult` with `updated_conversation_notes`
- updated the user router prompt schema to include the notes field
- when a new conversation is created, the Go server now persists returned notes if the router includes them

## Notes

This is the first step, not the full notes-aware routing loop yet.

Current state:

- notes are persisted through a separate table
- user routing can return updated notes
- notes are not yet fully threaded into existing-conversation routing or conversation-update routing contexts
