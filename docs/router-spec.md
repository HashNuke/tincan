# Router Spec

## Goal

The router turns committed user speech and backend conversation updates into structured actions that the server can execute.

The router now owns both:

- command routing from user speech
- short spoken summary text for immediate feedback and meaningful conversation updates

There is no separate summarizer component.

## Scope

The router is responsible for:

- deciding whether a committed command should create a new conversation or send a message to an existing one
- selecting the target agent profile or conversation handle
- deciding whether the user wants to switch to another agent or hear an update
- selecting which pending conversation update should be read out
- generating short spoken text for immediate feedback and queued updates

The router is not responsible for:

- live audio endpointing
- transcription itself
- direct database writes
- direct backend mutation

## Voice Command Boundary

The router only runs after the voice layer has committed a buffered command.

The intended v1 interaction model is:

1. a wake or command phrase activates command capture
2. the app buffers the spoken command
3. an explicit commit phrase sends the buffered command to the router
4. an explicit cancel phrase discards the buffered command

This keeps the router focused on intent and target selection rather than on deciding when the user has finished speaking.

## Explicit New Conversation Rule

New conversations must be explicitly requested by the user.

Examples:

- `start a new Emma conversation to fix the Vapor auth bug`
- `new chat with Atlas for the audio pipeline`
- `create a new Emma session for the server work`

If the user does not explicitly ask for a new conversation, the router must not create one implicitly.

If no existing target is clear, the router should ask a clarifying question instead of guessing.

## Existing Conversation Messages

If the user refers to an existing conversation, the router should return a message action targeting that conversation.

Examples:

- `tell Emma twelve to keep going on the auth bug`
- `send this to Emma one`
- `ask Atlas three to continue`

The server can then resolve the user-facing handle like `emma#12` to the stored conversation record and from there to the backend session ID.

## Conversation Updates

The backend should normalize meaningful backend state changes into one coarse event type:

- `conversation_update`

This event should carry details, but the system should not expose many fine-grained backend state event types as first-class concepts in v1.

Example payload:

```json
{
  "type": "conversation_update",
  "conversation_handle": "emma#12",
  "agent_profile": "emma",
  "raw_status": "idle",
  "is_terminal": true,
  "summary": "finished checking the Vapor auth bug",
  "timestamp": "2026-04-20T10:25:00Z"
}
```

## Pending Update Buffer

The server should keep a pending update buffer for conversation updates that may need to be announced to the user.

Rules:

- each conversation can have a latest pending update
- newer updates replace older pending updates for the same conversation
- repeated updates should be coalesced rather than spoken one-by-one
- short update pings can be buffered briefly before TTS playback

Typical short announcements:

- `Emma#12 has something.`
- `Atlas#15 got news.`

If the user later says something like:

- `yes emma#12`
- `yes atlas`

the router should interpret that as a request to read the latest pending update for that conversation or for the latest pending conversation under that profile.

If there is no pending update for the requested target, the router should ask a clarifying question or report that there is nothing new.

## Router Inputs

For user commands, the router should receive:

- committed transcript
- active agent profiles
- active conversations
- conversation handles such as `emma#12`
- current focused conversation, if any
- pending conversation updates
- latest pending update per conversation
- latest pending update per agent profile

For backend-originated conversation updates, the router should receive:

- normalized `conversation_update`
- current pending update state
- target conversation metadata

## Router Output Shape

The router should return a normalized object with a small fixed schema.

Example for new conversation:

```json
{
  "action": "new_conversation",
  "message": "fix the Vapor auth bug",
  "agent": "emma",
  "conversation_handle": null,
  "immediateFeedback": "Hello, I'm Emma 12. I am working on fixing the Vapor auth bug.",
  "rawTranscript": "start a new Emma conversation to fix the Vapor auth bug"
}
```

Example for existing conversation message:

```json
{
  "action": "message",
  "message": "keep going on the auth bug",
  "agent": null,
  "conversation_handle": "emma#12",
  "immediateFeedback": "Sending that to Emma 12.",
  "rawTranscript": "tell Emma twelve to keep going on the auth bug"
}
```

Example for reading a buffered update:

```json
{
  "action": "read_conversation_update",
  "message": null,
  "agent": null,
  "conversation_handle": "atlas#15",
  "immediateFeedback": null,
  "rawTranscript": "yes atlas"
}
```

Recommended action values:

- `new_conversation`
- `message`
- `read_conversation_update`
- `ask_clarifying_question`
- `ignore`

## Immediate Feedback And Update Text

The router owns the short spoken text used for:

- new conversation announcements
- acknowledgement of message routing
- short queued update announcements
- fuller readouts when the user asks to hear a conversation update

Examples:

- `Hello, I'm Emma 12. I am working on fixing the Vapor auth bug.`
- `Sending that to Emma 12.`
- `Emma#12 has something.`
- `Atlas#15 got news.`
- `Emma#12 finished fixing the Vapor auth issue.`

## JSONL Router Log

Committed router actions should be written to a JSONL file.

This file is an append-only log of routed voice commands.
It is not a copy of full OpenCode conversation history.

The goal is to keep:

- the original spoken transcript
- the router decision
- the resolved conversation or profile target
- the immediate spoken feedback produced for the user

Each line should contain one committed command.

Example entries:

```json
{"type":"new_conversation","timestamp":"2026-04-20T10:15:00Z","agent_profile":"emma","raw_transcript":"start a new Emma conversation to fix the Vapor auth bug","message":"fix the Vapor auth bug","immediate_feedback":"Hello, I'm Emma 1. I am working on fixing the Vapor auth bug."}
{"type":"message","timestamp":"2026-04-20T10:16:10Z","conversation_handle":"emma#1","conversation_id":"local-conversation-id","backend_conversation_id":"opencode-session-id","raw_transcript":"tell Emma one to keep going on the auth bug","message":"keep going on the auth bug","immediate_feedback":"Sending that to Emma 1."}
{"type":"read_conversation_update","timestamp":"2026-04-20T10:18:00Z","conversation_handle":"atlas#15","raw_transcript":"yes atlas","immediate_feedback":"Atlas#15 finished checking the audio pipeline."}
```

Suggested fields:

- `type`
- `timestamp`
- `agent_profile`
- `conversation_handle`
- `conversation_id`
- `backend_conversation_id`
- `raw_transcript`
- `message`
- `immediate_feedback`

Only committed commands should be written to this log.
Do not log partial live transcript fragments.

## Execution Flow

### User To Backend

The intended flow is:

1. voice layer captures a command after wake phrase activation
2. explicit commit phrase sends the buffered transcript to the router
3. router returns a structured action
4. server responds quickly with the router's immediate feedback
5. server executes the requested action deterministically

For `new_conversation`:

1. allocate the lowest available conversation number for the chosen profile
2. create the backend session
3. persist the local conversation record
4. send the message to the backend session
5. queue or play the router's immediate feedback through TTS

For `message`:

1. resolve the conversation handle to the stored conversation record
2. read the stored backend conversation ID
3. send the message to that backend session
4. queue or play the router's immediate feedback through TTS

### Backend To User

The return path is:

1. agent backend sends a hook or callback to the server
2. server turns meaningful changes into `conversation_update`
3. router decides whether the update is meaningful enough for user-facing announcement text
4. server queues the resulting update announcement for TTS playback
5. user may later ask to hear the latest update for a specific conversation or profile

## Clarification Policy

If the router cannot confidently determine whether the user intended a new conversation, an existing conversation message, or an update readout, it should return `ask_clarifying_question`.

It should not create a new conversation implicitly.

Examples:

- `talk to Emma about the auth bug`
  - ambiguous if there are multiple Emma conversations
- `continue working on the server bug`
  - ambiguous if there is no current focus
- `yes atlas`
  - ambiguous if Atlas has no pending update or multiple equally plausible update targets without a clear latest one

## Plugin Direction

The router itself runs models and may be backed by a model provider through the same lower-level agent execution path used for normal conversation agents.

For example:

- conversation agents may use `opencode-server`
- router inference may use `codex`

This means the lower-level agent execution abstraction can be reused in different roles, while the router remains a distinct logical component.

## Non-Goals

This router spec does not require:

- full speech endpointing based on VAD alone
- storing full OpenCode message history in tincan
- implicit conversation creation
- a separate standalone summarizer component
- a dynamic public plugin system
