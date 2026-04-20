## Status

DONE

## Problem

The Go server validates every configured agent profile against a registered adapter at startup.

Because `agent_profiles.json` includes a `codex` profile but only `opencode-server` was registered in `DefaultAgentAdapters()`, the server failed to start with:

`no agent adapter registered for backend "codex"`

## Solution

Added a placeholder `CodexAdapter`:

- registered `codex` in `DefaultAgentAdapters()`
- added basic profile validation for Codex profiles
- made `StartConversation` return a clear `not implemented yet` error for now

## Notes

This keeps startup validation strict while still allowing the server to boot with mixed profile backends.

The Codex backend is still not implemented, but the server no longer fails during initialization just because the profile exists.
