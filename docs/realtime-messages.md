# Realtime Messages

## Goal

This document defines the message contract for the bidirectional app-to-`tincan-server` real-time session.

The transport is expected to be a WebRTC data channel plus audio streams, but this document is transport-agnostic about the message payloads themselves.

The goal is to make the app-server session concrete without requiring the rest of the system to use WebRTC.

## Message Directions

There are two main directions:

- app -> server
- server -> app

The audio track carries microphone or TTS audio.
The data channel carries structured events and control messages.

## Envelope

Each data channel message should use a small envelope.

Suggested shape:

```json
{
  "type": "router.immediate_feedback",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:00Z",
  "payload": {}
}
```

Suggested common fields:

- `type`
- `session_id`
- `timestamp`
- `payload`

## App To Server Messages

### `voice.command_committed`

Sent when the app has finished buffering a spoken command and wants the server to run the router.

Example:

```json
{
  "type": "voice.command_committed",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:00Z",
  "payload": {
    "raw_transcript": "start a new Emma conversation to fix the Vapor auth bug"
  }
}
```

### `voice.command_cancelled`

Sent when the app cancels the currently buffered command.

Example:

```json
{
  "type": "voice.command_cancelled",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:05Z",
  "payload": {}
}
```

### `tts.playback_finished`

Sent when the client finishes playing a queued TTS item.

Example:

```json
{
  "type": "tts.playback_finished",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:08Z",
  "payload": {
    "announcement_id": "announcement-123"
  }
}
```

### `tts.playback_interrupted`

Sent when the client interrupts or drops a queued TTS item.

Example:

```json
{
  "type": "tts.playback_interrupted",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:09Z",
  "payload": {
    "announcement_id": "announcement-123"
  }
}
```

## Server To App Messages

### `router.immediate_feedback`

Sent immediately after the router processes a committed user command.

Example:

```json
{
  "type": "router.immediate_feedback",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:01Z",
  "payload": {
    "text": "Hello, I'm Emma 12. I am working on fixing the Vapor auth bug."
  }
}
```

### `conversation.created`

Sent when the server successfully creates and persists a new conversation.

Example:

```json
{
  "type": "conversation.created",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:01Z",
  "payload": {
    "conversation_id": "local-conversation-id",
    "conversation_handle": "emma#12",
    "agent_profile": "emma",
    "backend_conversation_id": "opencode-session-id"
  }
}
```

### `conversation.update_queued`

Sent when the server decides a meaningful backend update should be available to the user.

This is the coarse user-facing update event.

Example:

```json
{
  "type": "conversation.update_queued",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:03:00Z",
  "payload": {
    "conversation_id": "local-conversation-id",
    "conversation_handle": "emma#12",
    "agent_profile": "emma",
    "is_terminal": false,
    "text": "Emma#12 has something."
  }
}
```

### `conversation.update_consumed`

Sent when a pending update has been spoken or otherwise consumed.

Example:

```json
{
  "type": "conversation.update_consumed",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:04:00Z",
  "payload": {
    "conversation_handle": "emma#12"
  }
}
```

### `tts.play`

Sent when the server wants the app to play a piece of spoken text or a referenced TTS asset.

Example:

```json
{
  "type": "tts.play",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:01Z",
  "payload": {
    "announcement_id": "announcement-123",
    "text": "Hello, I'm Emma 12. I am working on fixing the Vapor auth bug.",
    "priority": "normal"
  }
}
```

### `tts.stop`

Sent when the server wants current playback interrupted.

Example:

```json
{
  "type": "tts.stop",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:02Z",
  "payload": {
    "reason": "user_command"
  }
}
```

### `router.clarification_requested`

Sent when the router cannot confidently pick the next action.

Example:

```json
{
  "type": "router.clarification_requested",
  "session_id": "call-session-id",
  "timestamp": "2026-04-20T11:00:03Z",
  "payload": {
    "text": "Which Emma conversation did you mean?"
  }
}
```

## Relationship To Router Actions

Typical mapping:

- router returns `new_conversation`
  - server emits `router.immediate_feedback`
  - server emits `conversation.created`
  - server may emit `tts.play`

- router returns `message`
  - server emits `router.immediate_feedback`
  - server may emit `tts.play`

- backend hook becomes a meaningful `conversation_update`
  - server emits `conversation.update_queued`
  - server may emit `tts.play` immediately or later

- router returns `ask_clarifying_question`
  - server emits `router.clarification_requested`
  - server may emit `tts.play`

## Queueing Semantics

Announcements may be buffered before playback.

Useful fields for queued announcement payloads:

- `announcement_id`
- `conversation_handle`
- `priority`
- `text`
- `is_terminal`

Suggested behavior:

- terminal conversation updates should have higher priority
- repeated update pings for the same conversation should be coalesced
- the latest queued update for a conversation should replace older pending update announcements

## Minimal V1 Message Set

The smallest practical initial message set is:

- app -> server:
  - `voice.command_committed`
  - `voice.command_cancelled`

- server -> app:
  - `router.immediate_feedback`
  - `conversation.created`
  - `conversation.update_queued`
  - `tts.play`
  - `tts.stop`
  - `router.clarification_requested`

This is enough to support:

- committed command routing
- new conversation creation
- existing conversation messaging
- queued update announcements
- TTS playback coordination

## Non-Goals

This document does not define:

- the exact binary format for audio tracks
- exact retry or reconnection behavior
- WebRTC ICE or SDP details
- message compression or framing beyond basic JSON envelopes
