# TODO

Focus: server-side APIs and supporting changes needed for the UI in `../DESIGN.md`.

Reference:

- `api/api-gaps.md`

## Phase 1: Read APIs

- Add `GET /api/v1/conversations`
  - Return server-backed conversation summaries for the home screen.
  - Include handle, profile/backend identity, working directory, status, updated time, preview text, and pending/unread update state.

- Add `GET /api/v1/conversations/{handle}`
  - Return a single conversation summary plus notes.

- Add `GET /api/v1/conversations/{handle}/updates`
  - Return update history for one conversation thread.
  - Good enough for an updates-based transcript screen.

- Add `GET /api/v1/calls/{session_id}/state`
  - Return current active conversation handle, linked backend conversation IDs, and push-to-talk state.

- Add `GET /api/v1/agent-profiles`
  - Populate Settings > Agent profiles.

- Add `GET /api/v1/agent-backends`
  - Populate Settings > Agent backends.

## Phase 1.5: Data Model Fixes

- Decide how to produce `preview_text` for conversation list rows.
  - Derive from latest pending update, latest backend message, or persist a summary field.

- Start maintaining `conversations.last_message_at` if we want a reliable “last updated” signal in the UI.

- Define how “new/unread text update” is represented.
  - Current model only has global pending/consumed updates.
  - Decide whether that is enough or whether device/session-specific viewed state is needed.

## Phase 2: Live UI Sync

- Extend SSE/live events beyond `play_audio` and `notify`.
  - Add session state events if needed.
  - Add conversation context change events.
  - Add conversation update created events for list highlighting.

- Decide whether to keep using `/linphone/session/{id}/events` for all UI live events or add a new `/api/v1/.../events` route.

## Phase 3: Transcript Strategy

- Decide whether the transcript screen is:
  - update history only, or
  - a true thread timeline with user and assistant messages.

- If transcript means update history only:
  - the `/conversations/{handle}/updates` endpoint may be enough.

- If transcript means a true thread timeline:
  - either persist timeline entries in tincan-server, or
  - add adapter read support to fetch thread history from the backend.

- If needed, add `GET /api/v1/conversations/{handle}/timeline`.

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
