## Status

DONE

## Problem

The server needed a real persistence layer for conversations so that backend conversation IDs from OpenCode could be saved and reused later.

The previous plan to poll OpenCode session status was also not the right shape for this project.
Instead, the backend needed a way for OpenCode to push session lifecycle updates back into Vapor when a conversation changes state or stops.

## Solution

Implemented the first persistence and hook callback slice:

- added Fluent and `FluentSQLiteDriver` to `tincan-server`
- configured SQLite in Vapor with in-memory databases for tests and a file-backed database for normal runs
- added a `Conversation` model and `CreateConversation` migration
- auto-migrate now runs during server startup
- added a Vapor route at `POST /hooks/opencode`
- the hook route looks up conversations by `backend_conversation_id`
- `session.status`, `session.idle`, and `session.error` events now update stored conversation state
- added a repo-local OpenCode plugin file at `opencode-plugins/tincan-conversation-hooks.js`

## Notes

Important behavior:

- conversations are now persisted in SQLite using Fluent
- the OpenCode session ID is treated as the backend conversation identifier
- the callback route marks conversations idle or failed when OpenCode emits the corresponding events
- this avoids polling and matches the desired hook-driven architecture better

Operational note:

- local `.opencode/plugins` hooks are project-scoped to the config directory used by the running OpenCode server
- if `opencode serve` is started from the home directory, project-local hooks from other working directories will not be picked up automatically
- for multi-project agent profiles, a global plugin install is the safer default unless OpenCode is started from each project root
