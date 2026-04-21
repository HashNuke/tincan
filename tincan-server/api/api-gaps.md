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
- `POST /webrtc/session`
  - Submit a WebRTC offer and return `session_id` plus the answer SDP.
- `DELETE /webrtc/session/{id}`
  - Remove a WebRTC call session.
- WebRTC data channel messages
  - Carry utterance uploads and server playback notifications after signaling completes.
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

Important scope decision:

- We should not repurpose the Linphone SSE route for the native app UI.
- The app should use a separate live update path for text/UI events.
- That path should be a WebSocket, not SSE.

## Data Already Available Internally

The server already has these internal data sources:

- Agent profiles
  - Loaded from `<data-dir>/config/agent_profiles.json`
- Agent backends
  - Loaded from `<data-dir>/config/agent_backends.json`
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
- Conversation updates table today
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

Planned storage change:

- Rename `conversation_updates` to `messages`.
- Persist every conversation update as its own message row.
- Phase 1 transcript means "agent update history", and the `messages` table is enough for that.

## Important Limitations In The Current Internal Model

There are a few gaps between "data exists" and "UI can use it":

- There is no public HTTP API to read conversation summaries.
- There is no public HTTP API to read conversation messages or notes.
- There is no public HTTP API to read agent profiles or backends.
- There is no app-specific live WebSocket for text/UI state changes.
- The existing SSE stream carries only Linphone/browser call events such as `play_audio` and `notify`.
- `Conversation.LastMessageAt` exists in the model but does not appear to be updated anywhere yet.
- The transcript screen wants an update history, but the current `conversation_updates` model is a pending/consumed queue, not an append-only history.

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

List behavior:

- Do not hard-cap the UI to 10 threads.
- The server should support incremental loading so the app can auto-load more rows while scrolling.
- The SwiftUI implementation should still render lazily even if the user eventually browses all conversations.

### 2. Active Call Home State

The in-call home state needs:

- a live feed for current conversation changes
- a live feed for new text/update messages
- an initial snapshot when the WebSocket connects so the app can recover after reconnect/backgrounding

### 3. Conversation Transcript

The transcript screen needs:

- a way to fetch message history for a single conversation by conversation ID
- enough data to render a timeline of agent updates
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
- Return the newest conversations first.
- Support incremental loading while the user scrolls.

Suggested response shape:

```json
{
  "next_cursor": "opaque-cursor",
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
- We will need to derive it from the latest message row or persist it on the conversation row.
- Use cursor pagination or equivalent. The UI should not request "all conversations" in one response just because the design shows an infinitely scrollable list.

Suggested query parameters:

- `cursor`
- `page_size`

### `GET /api/v1/conversations/{id}/messages`

Purpose:

- Drive the transcript screen.
- Use conversation ID, not handle, because handles are user-facing references and IDs are already returned by `/conversations`.

Suggested response shape:

```json
{
  "conversation": {
    "id": "uuid",
    "handle": "emma#16",
    "agent_profile_name": "emma",
    "agent_backend": "opencode-1",
    "working_directory": "/Users/akash/code/apple/tincan",
    "status": "running"
  },
  "next_cursor": "opaque-cursor",
  "messages": [
    {
      "id": "uuid",
      "kind": "agent_update",
      "summary_text": "Finished the patch.",
      "detail_text": "Updated the home screen so the active thread stays featured.",
      "notification_text": "I have an update.",
      "created_at": "2026-04-21T07:11:00Z"
    }
  ]
}
```

Important:

- This is enough for the phase 1 transcript.
- The table behind this endpoint should become `messages`, not `conversation_updates`.
- Each agent update should be persisted as its own message row rather than overwriting one pending record.

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

### `GET /api/v1/live` (WebSocket)

Purpose:

- Deliver app-facing live text/UI updates.
- Stay separate from the Linphone SSE transport path.

Recommended behavior:

- The first WebSocket message after connect should be an initial snapshot.
- That avoids a separate required `GET /api/v1/calls/{session_id}/state` endpoint in phase 1.
- Reconnect behavior should be: reconnect socket, receive snapshot, then continue receiving deltas.

Suggested event types:

- `snapshot`
  - current active conversation ID, if any
  - whether a call is active, if needed by the UI
- `conversation_message_created`
  - when a thread gets a new text/update message
- `conversation_context_changed`
  - when voice routing switches the active thread
- `conversation_updated`
  - if summary metadata like preview text or timestamps change

### `POST /api/v1/conversations/{id}/mark-viewed`

Purpose:

- Clear the list highlight when the user opens a thread.

Open question:

- Do we want this to globally consume the update for everyone, or only mark it viewed for this device/session?

Today the server has only a global `pending -> consumed` model for updates.
That should be revisited once the transcript source becomes append-only `messages`.

## Phase 3: APIs Needed For A Real Transcript

Phase 1 transcript is only agent update history, and the planned `messages` table is enough for that.

If we later want a real user/assistant transcript, phase 1 is not enough.

If the transcript screen should show more than summarized update cards, we need one of these approaches:

### Option A: Persist full timeline entries in tincan

Add a new server-side timeline/message table and store:

- user utterance text
- assistant message text
- update cards
- timestamps
- optional artifact metadata

Then expose:

- `GET /api/v1/conversations/{id}/timeline`

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

- `GET /api/v1/conversations/{id}/timeline`

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

- The current config stores load writable JSON files from `<data-dir>/config`.
- `tincan-server` accepts a `--data-dir` flag for that runtime data.
- When the server is launched from the Swift app, the app should pass a writable directory inside its Application Support folder.
- If `--data-dir` is not passed, the server should default to `~/.tincan`.
- The server should create that directory if it does not exist.
- The server should create/open the SQLite DB inside that directory if it does not exist.
- The server should also store `agent_profiles.json` and `agent_backends.json` there.
- If either JSON file is missing, the server should create an empty file there.
- Checked-in sample runtime data now lives under `tincan-server/testdata/data-dir/config`.
- Before we add write APIs, we still need validation/update rules for the Mac editing flows.

## Optional API Improvements

### Enrich `GET /healthz`

The current health endpoint is enough for a basic alive check, but Settings may benefit from richer server info:

- server version
- available feature flags
- counts of profiles/backends/conversations

This is optional, not a blocker.

## Recommended Implementation Order

1. Add `GET /api/v1/conversations` with cursor pagination
2. Replace `conversation_updates` with append-only `messages`
3. Add `GET /api/v1/conversations/{id}/messages`
4. Add app WebSocket live updates under `/api/v1/live`
5. Add `GET /api/v1/agent-profiles`
6. Add `GET /api/v1/agent-backends`
7. If a real user/assistant transcript is required later, add timeline support on top of phase 1 messages
8. After config storage is made writable, add Mac-only edit APIs for profiles/backends

## Bottom Line

To build the UI we designed, the server needs a new app-facing read API layer under a stable namespace such as `/api/v1`.

The two biggest gaps are:

- no conversation list/read endpoints
- no app-specific live WebSocket
- no append-only message history for transcript rendering

Settings read APIs are straightforward.
Phase 1 transcript is now well-defined.
The later decision is only whether we ever need a full user/assistant timeline.
