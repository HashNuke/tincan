# TODO

## High Priority

- Implement the Go-side Liblinphone-compatible call server behavior on top of the new `calls` package.
- Replace the current debug WebRTC transport path with the real transport used by the Apple app.
- Integrate the Apple app with Liblinphone for real call/media transport.
- Keep the app-layer control/event path separate from the media transport where needed.

## Router

- Enrich `UserInputRouting` context with:
  - known conversation handles
  - current conversation handle
  - pending update handles
  - current conversation notes
- Implement `ConversationUpdateRouting` as a separate routed prompt path.
- Route incoming conversation updates through the router to produce curated:
  - `notification_text`
  - `summary_text`
  - queue decisions

## Conversations

- Finish threading `conversation_notes` through existing-conversation routing.
- Include `conversation_notes` in conversation update routing input.
- Add/verify helpers for reading latest pending updates by conversation handle and profile.

## Calls

- Continue extracting transport-specific logic out of `main.go` into `calls/`.
- Add explicit call/session event types beyond the current first slice if needed.

## App

- Wire the macOS/iOS call UI to the new transport layer.
- Verify immediate feedback and update notifications in the real app path.

## Cleanup

- Continue moving root-level orchestrator files to clearer names/packages where boundaries are stable.
- Review whether router service can fully move into the `router/` package after dependency cleanup.
