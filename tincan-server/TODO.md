# TODO

Focus: server-side APIs and supporting changes needed for the UI in `../DESIGN.md`.

Reference:

- `api/api-gaps.md`

## Phase 1: Read APIs

## Phase 1.5: Data Model Fixes

- Define how “new/unread text update” is represented.
  - Current model only has global pending/consumed updates.
  - Decide whether that is enough or whether device/session-specific viewed state is needed.

## Phase 3: Transcript Strategy

- If we later want a true thread timeline:
  - either persist timeline entries in tincan-server, or
  - add adapter read support to fetch thread history from the backend.

- If needed, add `GET /api/v1/conversations/{id}/timeline`.

## Phase 4: Settings Write APIs

- When `tincan-server` is launched from the Swift app, pass a writable directory inside the app's Application Support directory via `--data-dir`.

- Add persistence and validation around config writes as needed for the Mac editing flows.
