## Status

DONE

## Problem

The temporary `no-summary` plugin no longer matched the project direction.
The router is now the place where immediate feedback and summary-like spoken text should live.

Keeping a standalone summarizer plugin and profile field added dead architecture and unnecessary configuration.

## Solution

Removed the transitional summarizer scaffolding:

- deleted `PluginRegistry.swift`
- removed the `summarizer` field from `AgentProfile`
- removed `summarizer` entries from `agent_profiles.json`
- removed summarizer resolution from `ConversationService`
- simplified `ConversationCreateResponse` by dropping the separate `summary` field
- kept `announcement_text`, which is now built directly from the request message for the current implementation

## Notes

This keeps the server aligned with the newer design:

- no standalone summarizer component
- no extra profile configuration for summarization
- router-owned spoken feedback remains the long-term direction
