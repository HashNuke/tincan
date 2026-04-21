# TODO

Focus: server-side APIs and supporting changes needed for the UI in `../DESIGN.md`.

Reference:

- `api/api-gaps.md`

## Phase 1: Read APIs

- Add `GET /api/v1/conversations`
  - Return server-backed conversation summaries for the home screen.
  - Include conversation ID, handle, profile/backend identity, working directory, status, updated time, preview text, and pending/unread update state.
  - Support cursor pagination so the app can auto-load more conversations while scrolling instead of using a fixed `limit=10`.

- Add `GET /api/v1/conversations/{id}/messages`
  - Return agent update history for one conversation thread.
  - Good enough for the phase 1 transcript screen.

- Add `GET /api/v1/agent-profiles`
  - Populate Settings > Agent profiles.

- Add `GET /api/v1/agent-backends`
  - Populate Settings > Agent backends.

- Add an app WebSocket endpoint under `/api/v1/live`
  - Keep it separate from the Linphone SSE path.
  - Send an initial snapshot on connect, then incremental UI/text events.

## Phase 1.5: Data Model Fixes

- Decide how to produce `preview_text` for conversation list rows.
  - Derive from latest message row or persist a summary field on the conversation row.

- Start maintaining `conversations.last_message_at` if we want a reliable “last updated” signal in the UI.

- Replace `conversation_updates` with append-only `messages`.
  - Persist every agent update as its own message row.
  - Use that table as the transcript source for phase 1.

- Define how “new/unread text update” is represented.
  - Current model only has global pending/consumed updates.
  - Decide whether that is enough or whether device/session-specific viewed state is needed.

## Phase 2: Live UI Sync

- Use WebSocket for app-facing live updates.
  - Do not reintroduce the old `/linphone/session/{id}/events` transport.
  - Keep transport-layer events and app UI/text events as separate paths.

- Send a socket snapshot immediately after connect.
  - Include current active conversation ID if there is one.
  - This removes the need for a separate required phase 1 call-state endpoint.

- Add incremental socket events for:
  - new conversation message created
  - conversation context changed
  - conversation summary metadata changed

## Phase 3: Transcript Strategy

- Phase 1 transcript is agent update history only.
  - `GET /api/v1/conversations/{id}/messages` plus append-only `messages` storage is enough.

- If we later want a true thread timeline:
  - either persist timeline entries in tincan-server, or
  - add adapter read support to fetch thread history from the backend.

- If needed, add `GET /api/v1/conversations/{id}/timeline`.

## Phase 4: Settings Write APIs

- Do not add profile/backend write APIs until config storage is made writable.

- Replace the current `go:embed` read-only config loading model with writable storage.
  - Preferred approach: add a server `--data-dir` flag.
  - When `tincan-server` is launched from the Swift app, pass a writable directory inside the app's Application Support directory.
  - If `--data-dir` is not passed, default to `~/.tincan`.
  - Create the data directory if it does not exist.
  - Store writable `agent_profiles.json`, `agent_backends.json`, and the SQLite DB there.
  - Create/open the SQLite DB there if it does not exist yet.
  - If `agent_profiles.json` or `agent_backends.json` are missing, create empty JSON files there.
  - Do not use embedded defaults as a runtime fallback for config files.

- After that, add Mac-only editing support APIs:
  - `POST /api/v1/agent-profiles`
  - `PATCH /api/v1/agent-profiles/{name}`
  - `DELETE /api/v1/agent-profiles/{name}`
  - `POST /api/v1/agent-backends`
  - `PATCH /api/v1/agent-backends/{name}`
  - `DELETE /api/v1/agent-backends/{name}`

## Nice To Have

- Enrich `GET /healthz` with more server info if Settings needs it.
- Add endpoint docs/examples once the new routes exist.
