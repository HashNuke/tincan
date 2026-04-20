## Status

DONE

## Problem

The new Go server needed a real foundation for conversation orchestration before adding richer routing behavior.

That meant introducing:

- agent profiles as runtime data
- a persistent conversation store
- an agent backend boundary instead of hard-coding backend behavior directly into call flow logic

## Solution

Implemented the first storage and boundary layer in `tincan-server`:

- added an embedded JSON-backed `AgentProfileStore`
- added a SQLite-backed `ConversationStore`
- created the initial `conversations` schema
- added an `AgentAdapter` interface
- added a first `OpenCodeServerAdapter` profile validator scaffold
- wired profiles, conversation store, and adapters into Go server startup

## Notes

This does not yet move conversation execution onto the new store or adapter boundary.
It establishes the pieces needed for the next incremental step:

- resolving profiles from config
- persisting conversations in Go
- routing backend-specific behavior through a stable interface
