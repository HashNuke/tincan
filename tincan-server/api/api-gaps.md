# Tincan Server API Gaps

## Purpose

This document maps the current Go server API surface to the UI we want to build in `DESIGN.md`, and identifies the missing APIs we need to add.

The main conclusion is simple:

- The server already has most of the data we need internally.
- The server does **not** yet expose that data as app-facing HTTP APIs.
- For the transcript screen, the server may also need to persist or fetch more history than it does today.

## Current HTTP API Surface

The server currently exposes these routes:

- `GET /healthz`
  - Basic health response.
- `POST /linphone/session`
  - Register a new call session and return `session_id`.
- `DELETE /linphone/session/{id}`
  - Remove a call session.
- `GET /linphone/session/{id}/events`
  - SSE stream for live call events.
- `POST /session/{id}/utterance`
  - Upload captured speech audio for STT and routing.
- `POST /session/{id}/push-to-talk/start`
  - Enable push-to-talk for a call session.
- `POST /session/{id}/push-to-talk/stop`
  - Disable push-to-talk for a call session.
- `POST /hooks/opencode`
  - Internal hook endpoint for backend agent updates.
- `GET /debug/audio/generated/{name}`
  - Debug/generated audio fetch.
- `GET /speak`
  - Debug/demo page.

For the UI, the important thing is that the current API surface is almost entirely call-transport oriented. It is not yet a read API for conversations, transcript history, profiles, or backends.

## Data Already Available Internally

The server already has these internal data sources:

- Agent profiles
  - Loaded from `config/agent_profiles.json`
- Agent backends
  - Loaded from `config/agent_backends.json`
- Conversations table
  - `display_handle`
  - `agent_profile_name`
  - `agent_backend`
  - `working_directory`
  - `status`
  - `created_at`
  - `updated_at`
  - `last_message_at`
  - `ended_at`
- Conversation updates table
  - `summary_text`
  - `detail_text`
  - `notification_text`
  - `status`
  - `updated_at`
  - `consumed_at`
- Conversation notes table
- In-memory call/session state
  - current conversation handle per active session
  - current backend conversation ID per active session
  - push-to-talk state
  - clarification history

## Important Limitations In The Current Internal Model

There are a few gaps between "data exists" and "UI can use it":

- There is no public HTTP API to read conversation summaries.
- There is no public HTTP API to read conversation updates or notes.
- There is no public HTTP API to read agent profiles or backends.
- There is no public HTTP API to read active call state for a session.
- The SSE stream currently carries only `play_audio` and `notify` style events.
- `Conversation.LastMessageAt` exists in the model but does not appear to be updated anywhere yet.
- The transcript screen wants a thread-like history, but the server currently persists only pending update summaries, not a full user/assistant timeline.

That last point is the biggest transcript-related gap.

## UI Requirements By Screen

### 1. Home / Conversations

The home screen needs a server-backed conversation list.

Minimum fields needed per row:

- conversation handle
- agent/profile identity
- working directory
- last updated time
- status
- preview text
- whether there is a pending/unread text update

When a call is active, the UI also needs to know:

- which conversation is the current active call context

### 2. Active Call Home State

The in-call home state needs:

- active call session state
- current conversation handle
- linked conversation handles for the session
- push-to-talk state
- continued live events for notifications/audio

### 3. Conversation Transcript

The transcript screen needs:

- a way to fetch history for a single conversation thread
- enough data to render a timeline of updates/messages/artifacts
- a way to know whether opening the thread should clear the "new update" highlight

### 4. Settings

The settings UI needs read APIs for:

- agent backends
- agent profiles

On Mac, if we want in-app editing later, we will also need write APIs for:

- create/update/delete backend
- create/update/delete profile

## Missing APIs

## Phase 1: Read APIs Needed To Build The UI

### `GET /api/v1/conversations`

Purpose:

- Drive the home conversation list.

Suggested response shape:

```json
{
  "conversations": [
    {
      "id": "uuid",
      "handle": "emma#16",
      "agent_profile_name": "emma",
      "agent_backend": "opencode-1",
      "working_directory": "/Users/akash/code/apple/tincan",
      "status": "running",
      "updated_at": "2026-04-21T07:11:00Z",
      "last_message_at": "2026-04-21T07:11:00Z",
      "preview_text": "Finished the patch and left one follow-up.",
      "has_pending_update": true
    }
  ]
}
```

Notes:

- `preview_text` is not currently stored directly in a durable conversation summary record.
- We will need to derive it from the latest pending update, latest message history, or a newly persisted summary field.

### `GET /api/v1/conversations/{handle}`

Purpose:

- Fetch one conversation summary for focused UI state.

Suggested response shape:

```json
{
  "conversation": {
    "id": "uuid",
    "handle": "emma#16",
    "agent_profile_name": "emma",
    "agent_backend": "opencode-1",
    "working_directory": "/Users/akash/code/apple/tincan",
    "status": "running",
    "updated_at": "2026-04-21T07:11:00Z",
    "last_message_at": "2026-04-21T07:11:00Z",
    "notes_text": "Home screen redesign thread"
  }
}
```

### `GET /api/v1/conversations/{handle}/updates`

Purpose:

- Drive the transcript screen.

Suggested response shape:

```json
{
  "conversation": {
    "handle": "emma#16"
  },
  "updates": [
    {
      "id": "uuid",
      "kind": "conversation_update",
      "summary_text": "Finished the patch.",
      "detail_text": "Updated the home screen so the active thread stays featured.",
      "notification_text": "I have an update.",
      "status": "pending",
      "updated_at": "2026-04-21T07:11:00Z",
      "consumed_at": null
    }
  ]
}
```

Important:

- This is enough for an update-history screen.
- It is **not** enough for a rich transcript if we want user messages and assistant messages as a full thread.

### `GET /api/v1/calls/{session_id}/state`

Purpose:

- Support the in-call home state.
- Tell the app which conversation is currently active for the call.

Suggested response shape:

```json
{
  "session_id": "transport-session-id",
  "push_to_talk": false,
  "current_conversation_handle": "emma#16",
  "current_backend_conversation_id": "backend-id",
  "linked_backend_conversation_ids": [
    "backend-id",
    "backend-id-2"
  ]
}
```

Notes:

- The server already knows this data in `calls.Manager`.
- It just is not exposed yet.

### `GET /api/v1/agent-profiles`

Purpose:

- Populate the Settings > Agent profiles screen.

Suggested response shape:

```json
{
  "profiles": [
    {
      "name": "emma",
      "working_directory": "/Users/akash/code/apple/tincan",
      "agent_backend": "opencode-1"
    }
  ]
}
```

### `GET /api/v1/agent-backends`

Purpose:

- Populate the Settings > Agent backends screen.

Suggested response shape:

```json
{
  "backends": [
    {
      "name": "opencode-1",
      "type": "opencode",
      "options": {
        "base_url": "http://...",
        "model": "...",
        "agent": "build"
      }
    }
  ]
}
```

## Phase 2: Better Live/UI Sync APIs

### Extend SSE event payloads

The existing SSE stream is useful for audio playback and notification summaries, but the UI will likely need more structured live events.

Suggested additions:

- `session_state`
  - current conversation handle
  - push-to-talk state
- `conversation_context_changed`
  - when a voice command switches the active thread
- `conversation_update_created`
  - when a thread gets a new update that should highlight in the list

This could either extend:

- `GET /linphone/session/{id}/events`

or live under a new namespaced route such as:

- `GET /api/v1/calls/{session_id}/events`

### `POST /api/v1/conversations/{handle}/mark-viewed`

Purpose:

- Clear the list highlight when the user opens a thread.

Open question:

- Do we want this to globally consume the update for everyone, or only mark it viewed for this device/session?

Today the server has only a global `pending -> consumed` model for updates.

## Phase 3: APIs Needed For A Real Transcript

The current `conversation_updates` table does not represent a full thread transcript.

If the transcript screen should show more than summarized update cards, we need one of these approaches:

### Option A: Persist full timeline entries in tincan

Add a new server-side timeline/message table and store:

- user utterance text
- assistant message text
- update cards
- timestamps
- optional artifact metadata

Then expose:

- `GET /api/v1/conversations/{handle}/timeline`

### Option B: Fetch thread history from the backend adapter

Add read methods to the adapter layer.

For example:

```go
type Adapter interface {
    // existing methods...
    FetchConversationTimeline(conversation conversations.Conversation, backend config.AgentBackendDefinition) ([]TimelineItem, error)
}
```

Then expose:

- `GET /api/v1/conversations/{handle}/timeline`

This is likely necessary for OpenCode-backed threads because the transcript UI wants actual thread history, not just pending update summaries.

## Phase 4: Mac Editing APIs For Settings

If the Mac app should edit profiles/backends, we will need write APIs.

Examples:

- `POST /api/v1/agent-profiles`
- `PATCH /api/v1/agent-profiles/{name}`
- `DELETE /api/v1/agent-profiles/{name}`
- `POST /api/v1/agent-backends`
- `PATCH /api/v1/agent-backends/{name}`
- `DELETE /api/v1/agent-backends/{name}`

Important implementation note:

- The current config stores are built from embedded JSON via `go:embed`.
- That means the current implementation is effectively read-only at runtime.
- Before we add write APIs, we need to move these configs to writable storage and define validation/update rules.
- The cleanest approach is to add a `--data-dir` flag to `tincan-server`.
- When the server is launched from the Swift app, the app should pass a writable directory inside its Application Support folder.
- If `--data-dir` is not passed, the server should default to `~/.tincan`.
- The server should create that directory if it does not exist.
- The server should create/open the SQLite DB inside that directory if it does not exist.
- The server should also store `agent_profiles.json` and `agent_backends.json` there.
- If either JSON file is missing, the server should create an empty file there.
- Embedded defaults should not be used as a runtime fallback for config files.

## Optional API Improvements

### Enrich `GET /healthz`

The current health endpoint is enough for a basic alive check, but Settings may benefit from richer server info:

- server version
- available feature flags
- counts of profiles/backends/conversations

This is optional, not a blocker.

## Recommended Implementation Order

1. Add `GET /api/v1/conversations`
2. Add `GET /api/v1/conversations/{handle}`
3. Add `GET /api/v1/conversations/{handle}/updates`
4. Add `GET /api/v1/calls/{session_id}/state`
5. Add `GET /api/v1/agent-profiles`
6. Add `GET /api/v1/agent-backends`
7. Decide whether transcript means:
   - update history only
   - or a true full message timeline
8. If true timeline is required, add adapter read support or server-side timeline persistence
9. After config storage is made writable, add Mac-only edit APIs for profiles/backends

## Bottom Line

To build the UI we designed, the server needs a new app-facing read API layer under a stable namespace such as `/api/v1`.

The two biggest gaps are:

- no conversation list/read endpoints
- no true transcript/timeline endpoint

Settings read APIs are straightforward.
Transcript fidelity is the part that needs an actual server-side design decision.
