# TINCAN-EXEC

## Goal

Replace Tincan's OpenCode HTTP orchestration with managed CLI execution:

- `tincan-server` owns conversation state
- `tincan-exec` launches backend CLIs
- OpenCode hooks publish updates back to Tincan only when the run is managed

This keeps the wrapper thin and pushes state changes into `tincan-server`.

## Investigation

### `tava pipe`

Relevant files:

- `~/code/tava/commands/pipe.go`
- `~/code/tava/commands/pipe_env_helpers.go`

Key properties:

- it is a thin process wrapper
- it forwards stdin/stdout/stderr
- it mirrors child exit code
- it uses environment variables as the managed-run contract
- it does not own conversation state parsing

That is the main design lesson worth copying.

### OpenCode CLI

Relevant source:

- `~/sources/opencode/packages/opencode/src/cli/cmd/run.ts`
- `~/sources/opencode/packages/plugin/src/index.ts`

Key findings:

- `opencode run` is the right orchestration primitive for v1
- it supports `--session` for continuing an existing session
- it supports `--format json` for structured output
- prompt input is plain text from argv/stdin, not structured JSON input
- the CLI internally talks to the OpenCode server/SDK, but Tincan does not need to orchestrate that layer directly
- the CLI exits when the session reaches idle

### OpenCode hooks

The OpenCode plugin event stream gives enough data for Tincan:

- `message.part.updated`
- `session.status`
- `session.idle`
- `session.error`

For text parts, the plugin receives:

- `sessionID`
- `messageID`
- `part.id`
- `part.text`
- `part.time.end`

That means Tincan can create local conversation updates directly from hook payloads and does not need to fetch the latest assistant message over OpenCode HTTP.

## Final Design

### Managed env contract

Only these env vars are passed to managed agent runs:

- `TINCAN_SERVER`
- `TINCAN_CONVERSATION_ID`

Rules:

- `TINCAN_SERVER` is the managed-run indicator
- if `TINCAN_SERVER` is missing, the OpenCode plugin does nothing
- `TINCAN_CONVERSATION_ID` is the local Tincan conversation ID

Dropped from the design:

- `TINCAN_RUN_ID`
- `TINCAN_WORK_DIR`
- transport session env

### Process model

- one managed child process per conversation
- follow-up user messages are queued in Tincan
- when a child finishes, Tincan drains all currently pending inputs into one batch
- the next child is launched with `opencode run --session <backend_session_id>`

This avoids overlapping `opencode run --session ...` processes for the same session and prevents duplicate hook streams from multiple plugin instances.

### Prompt batching

Follow-up batching is plain stdin text, not JSON input.

Single pending input:

- send the raw user text

Multiple pending inputs:

- send one synthetic prompt
- include numbered user messages in arrival order
- explicitly say they are queued follow-ups for the same conversation

### Conversation identity

The local Tincan conversation ID is the primary key immediately.

Flow:

1. create local conversation first
2. leave `backend_conversation_id` empty
3. launch managed `opencode run`
4. bind the backend session ID later from the first OpenCode hook that includes `session_id`

This removes the old requirement that backend session IDs exist before a conversation can be persisted.

## Implemented Changes

### Wrapper

Added:

- `tincan-server/cmd/tincan-exec/main.go`

Behavior:

- launches child command
- inherits stdin/stdout/stderr
- forwards signals
- exits with child exit code

### Scheduler

Added:

- `tincan-server/managed_run_scheduler.go`

Responsibilities:

- enforce one active child per conversation
- drain pending conversation inputs into a dispatch batch
- build the managed backend command
- launch `tincan-exec`
- inject `TINCAN_SERVER` and `TINCAN_CONVERSATION_ID`
- mark dispatch completion/failure from hooks
- launch the next queued batch only after the prior child exits

### Conversation queue

Added:

- `conversation_inputs` table
- `ConversationInput` model
- queue lifecycle store methods

Status flow:

- conversation starts as `starting`
- active child makes it `busy`
- `session.idle` moves it to `running`
- `session.error` or abnormal exit moves it to `failed`

### OpenCode adapter

Reworked:

- `tincan-server/agent_adapters/opencode.go`

Behavior now:

- validates OpenCode as command-only
- does not support `base_url` in agent backend config
- builds `opencode run --format json --dir ...`
- uses `--title` for new conversations when available
- uses `--session` for follow-ups
- passes prompt text via stdin
- runs router/update prompts through one-shot `opencode run --format json`
- parses completed text output from CLI JSON lines

Note:

- the earlier plan mentioned `--pure`, but the current OpenCode CLI does not expose that flag
- router/update prompts therefore use regular `opencode run` with a synthetic combined prompt

### OpenCode plugin

Reworked:

- `agent-plugins/opencode/tincan-opencode.js`

Behavior now:

- no-op unless `TINCAN_SERVER` and `TINCAN_CONVERSATION_ID` are set
- posts to `${TINCAN_SERVER}/hooks/opencode`
- includes `conversation_id` on every payload
- emits completed assistant text parts from `message.part.updated`
- emits `session.status`, `session.idle`, and `session.error`

### Hook handling

Reworked:

- `tincan-server/controllers/hook_controller.go`

Behavior now:

- resolves hooks by local `conversation_id`
- binds `backend_conversation_id` from the first hook carrying `session_id`
- creates local conversation updates directly from text-part hooks
- does not fetch assistant messages back from OpenCode HTTP
- treats idle/error as scheduler lifecycle signals, not as message-fetch triggers

### Conversation routing and live state

Reworked:

- `tincan-server/conversation_service.go`
- `tincan-server/controllers/user_input_controller.go`
- `tincan-server/calls/manager.go`
- `tincan-server/live_updates.go`

Behavior now:

- current call context is keyed by local conversation ID
- new conversations are linked to the call immediately
- follow-up messages are enqueued first
- if a conversation is already busy, the immediate feedback changes to queued feedback

### Packaging

Updated:

- `build-deps.sh`

Behavior now:

- stages `tincan-exec` into `tincan-swift-app/BundledRuntime`

## Current Backend Command Shape

New conversation:

```bash
tincan-exec opencode run --format json --dir <workdir> --title <title> ...
```

Follow-up batch:

```bash
tincan-exec opencode run --format json --dir <workdir> --session <backend_session_id> ...
```

Managed env:

```bash
TINCAN_SERVER=http://127.0.0.1:<port>
TINCAN_CONVERSATION_ID=<local-conversation-id>
```

## Updated Hook Payload Shape

Text part:

```json
{
  "conversation_id": "conv-123",
  "event_type": "message.part.updated",
  "session_id": "sess-abc",
  "message_id": "msg-1",
  "part_id": "part-1",
  "text": "Finished the refactor."
}
```

Idle:

```json
{
  "conversation_id": "conv-123",
  "event_type": "session.idle",
  "session_id": "sess-abc",
  "status_type": "idle"
}
```

Error:

```json
{
  "conversation_id": "conv-123",
  "event_type": "session.error",
  "session_id": "sess-abc",
  "error_name": "SomeError",
  "error_message": "details"
}
```

## Remaining Follow-Ups

- add Codex command-mode orchestration on top of the same scheduler abstraction
- add recovery behavior for `running` dispatch rows after an unexpected server crash
- add broader scheduler-specific tests around queue batching and abnormal child exits
