# tincan Spec

## Summary

tincan is a multiplatform Apple app for staying "on call" with coding agents throughout the day.
The app should feel like a voice call surface, while the backend handles coding-agent orchestration.

The initial target platforms are iPhone, iPad, and Mac. Apple Watch is out of scope for v1.

## Product Goal

Let the user speak naturally to coding agents in an always-available call-like interface.
The app should:

- capture live audio from the user
- identify whether the speaker is the device owner
- ignore or suppress speech from other people nearby
- forward verified user speech to a backend
- let the backend route the request to the right coding-agent session
- play agent responses back using TTS

## Non-Goals

For the initial version, tincan is not trying to be:

- a generic meeting transcription app
- a group call product
- a fully offline local coding-agent runtime
- a high-security voice biometrics product
- a desktop automation framework by itself

## Core Experience

The default interaction model is an all-day voice session.

The user opens the app, starts a call, and speaks naturally.
The app determines whether the speech is likely from the owner.
If yes, the audio is sent to the backend for canonical transcription and agent routing.
If not, the audio is ignored or held back.
Agent responses are played locally using TTS.

The app should feel conversational, but the backend remains the source of truth for orchestration.

## Architecture Direction

### Responsibility Split

The phone is the call surface and first-pass filter.
The backend is the orchestration brain.

Phone responsibilities:

- microphone capture
- audio session management
- echo cancellation / audio cleanup where available
- voice activity detection
- local speaker diarization and speaker verification
- local playback of agent TTS
- local recovery flows when speaker identity is uncertain

Backend responsibilities:

- canonical speech-to-text
- turn finalization
- agent/session routing
- session lifecycle management
- tool execution and coding-agent interaction
- persistent history and state

### Why This Split

Even if some speech features run on-device, the backend still needs to decide:

- which agent profile should handle the turn
- whether to resume an existing session or create a new one
- which remote coding harness/server should receive the request

That makes the backend the right place for the system of record.

## Audio Identity Model

### Key Distinction

Speaker diarization and speaker identification are related but not identical.

- diarization answers: "who spoke when?" using anonymous speaker tracks
- speaker identification / verification answers: "was this the owner?"

tincan needs both concepts, but owner verification is the product-critical one.

### Owner Enrollment

The app should support owner voice enrollment in setup/settings.

The user records sample speech in the app.
The app creates and stores a local owner voice profile derived from speaker embeddings.
That profile is then used to gate which speech is allowed upstream.

### Just-In-Time Enrollment / Recovery

The app should also support a fallback when:

- the owner has not enrolled yet
- confidence is too low to classify current speech
- the voice profile seems stale or degraded

For v0, this fallback may use a fixed spoken phrase as an audio captcha.
Example phrase: `I like apples`.

This is not treated as strong security.
It is a practical bootstrap and recovery mechanism.

### Audio Gating Flow

The intended first-pass flow is:

1. run local VAD to detect speech
2. segment or track speakers locally
3. compare current speech against the owner profile
4. only send likely-owner audio to the backend
5. if confidence is too low, ask for local confirmation before resuming upstream sends

### Trust Model

The initial trust anchor is possession of the unlocked device, not voice alone.
Voice is used to improve filtering and reduce accidental triggering by others.

## Speech Processing Strategy

### Default Strategy

Canonical STT should run on the backend.

Reasons:

- backend routing is the main product value
- server-side models can evolve faster
- backend can be the single source of truth across multiple coding servers
- continuous on-device STT for all-day usage may be too expensive in battery and thermals

### Local Speech Features

The phone may still run local speech features that improve responsiveness and privacy:

- voice activity detection
- speaker diarization
- owner verification
- local TTS for prompts and recovery flows
- optional local lightweight captions later

### Rejected Default

Full on-device STT as the primary architecture is not the default direction for v1.
It remains an optional future mode for offline/privacy-heavy use cases.

## Agent Identity

Each live coding session should feel like a distinct participant in the call.

Every session should have:

- a profile-scoped display label for that session
- a stable TTS voice for that session
- a backing agent profile that determines its persona and home working directory

### Profile With Home Directory

An agent profile represents a named agent persona plus its execution home.
It tells the backend both who the agent is and where that family of chats should run.

Each profile should define at least:

- a stable profile key
- a human-facing agent name
- a home working directory
- the backend/harness configuration for sessions started in that directory
- the default TTS voice for chats in that profile

Examples:

- `emma` -> home directory `/some/path`
- `atlas` -> home directory `~/sources/opencode`

Once the backend chooses a profile, it also chooses the working directory context for the chat.

### Chat Numbering

Chats inside a profile may be assigned simple profile-scoped display numbers:

- `emma#1`
- `emma#2`
- `atlas#3`

The fully qualified display label should remain profile-scoped to avoid collisions across agents.

These numbers are convenience labels, not durable identifiers.
They do not need to increase monotonically and they do not define session identity.

The backend may assign whichever number is currently available for that profile, excluding numbers already in use by active conversations.
Archived or expired conversations may release their display numbers back into the available pool.

### Internal IDs

Every session still needs an immutable internal identifier.

Examples:

- UUID
- backend session ID
- opaque database/storage ID

The display label such as `emma#2` must not be treated as the primary key.
It is only a human-facing handle that can be reassigned later after a conversation expires or is archived.

### Voice

The voice should remain stable for the duration of a session.
Profile-level default voices are preferred over random session voices.

Why:

- users can build a consistent association between an agent and how its chats sound
- session identity stays understandable during long usage
- the numeric suffix is enough to distinguish multiple parallel chats for the same agent

## Pluggable Coding Agents

tincan should not be hard-wired to one coding agent provider.
It should support pluggable agent backends through profiles and adapters.

### Agent Profile

An agent profile is a reusable template for an agent persona plus its execution home.
Agent profiles are defined on the server side of the backend.
For now, the source of truth should be a JSON file managed by the server.

This means profiles should be treated as data records loaded at runtime, not compile-time configuration.

It defines:

- stable profile key
- agent name
- home working directory
- backend/harness type
- backend-specific options
- model or model family
- endpoint configuration
- default system prompt/preset
- default TTS voice
- supported capabilities

Examples:

- `emma` -> OpenCode Server profile rooted at `/some/path`
- `atlas` -> Codex profile rooted at `~/sources/opencode`

The important rule is that backend choice comes from the agent profile.
Switching a profile from OpenCode Server to Codex or another coding agent should be a profile configuration change, not a rewrite of the main tincan flow.

### Profile Persistence

For v1, agent profiles should come from a JSON file on the server side of the backend.

Each stored profile record should include at least:

- stable profile key
- display name
- home working directory
- backend type
- backend-specific options blob or structured fields
- default model selection
- default system prompt or preset
- default TTS voice
- archived/active state
- optional metadata such as created-at and updated-at timestamps

The system may later move these records into a database, but the initial assumption is a server-owned JSON file that tincan reads on startup and reloads when appropriate.

### Agent Adapter

Each provider/harness integration should conform to a common adapter surface.

The adapter should be selected from the profile's backend type and backend-specific options.
That means OpenCode Server, Codex, or any future coding agent backend can plug into the same conversation flow.

Representative operations:

- start session
- resume session
- send turn
- interrupt session
- stream events
- fetch metadata/status

For the immediate OpenCode Server path, tincan should still keep this behind a small internal adapter boundary.
That lets v1 ship with OpenCode first while preserving the ability to swap or add other coding-agent backends later through profile options.

### Agent Session

A live agent session is an instance of a profile.
It binds together:

- profile
- profile home working directory
- immutable session ID
- profile-scoped chat number
- display label
- conversation history
- backend routing information
- current voice/persona state

The key distinction is:

- the profile decides the agent identity and home working directory context
- the session number identifies one chat within that agent profile

## Backend Modules

The backend should be separated into small modules.
The goal is to keep the main tincan flow simple while isolating backend-specific behavior behind narrow interfaces.

### Desired Module Boundaries

The backend should be split into the following responsibilities:

- `AgentProfileStore`
  - loads agent profiles from the server-side JSON file
  - resolves profile key to home working directory, default model, backend type, and backend-specific settings
  - supports list, fetch, and later reload/update operations for profiles

- `ConversationStore`
  - stores tincan conversation records
  - maps a tincan conversation to the backing OpenCode session ID
  - tracks lifecycle state such as `starting`, `running`, `completed`, `failed`, or `archived`

- `Router`
  - decides whether to continue a current conversation, target an existing session, or create a new one
  - returns a constrained routing action only

- `AgentSessionService`
  - orchestrates conversation startup and turn delivery
  - asks the adapter to create or resume a backing session
  - updates the conversation store as session state changes

- `AgentAdapter`
  - common interface for creating sessions, sending turns, fetching status, and stopping sessions
  - selected from the profile's backend type

- `OpenCodeServerManager`
  - OpenCode-specific helper that ensures an OpenCode server exists for a given profile home directory
  - manages process startup, attachment details, and health checks
  - treats the profile home directory as the OpenCode project root

- `OpenCodeClient`
  - OpenCode-specific API client
  - creates sessions
  - sends messages
  - fetches session status
  - later may consume event streams

- `ConversationMonitor`
  - watches active OpenCode sessions
  - updates tincan when a backing session becomes idle, completed, aborted, or failed
  - can start with polling before later moving to SSE

### What Stays Out Of Scope

To keep the first increment tight, v1 should not try to solve all of these at once:

- a fully generic multi-provider orchestration layer
- a plugin framework for third-party agent backends
- a broad event bus across the whole app
- deep client UI syncing for every intermediate agent event

The only required abstraction is the narrow adapter boundary around agent-session operations.
OpenCode-specific helpers are acceptable as the first implementation, as long as the rest of the backend talks to them through the adapter selected by the agent profile.

### First Increment

The first useful increment is OpenCode Server support through that adapter boundary:

1. resolve the target agent profile
2. ensure an OpenCode server is available for that profile's home working directory
3. create a backing OpenCode session for that project if needed
4. send the transcript as a message to that session
5. track that session until it becomes completed, idle, aborted, or failed
6. update the tincan conversation state accordingly

This is the smallest end-to-end improvement over `opencode run`.
It introduces persistent conversations and lifecycle tracking without requiring a large redesign, while still keeping room for Codex or other backends later.

### Polling Before Streaming

The initial `ConversationMonitor` should use status polling.
It is simpler to implement and enough to detect when a conversation has ended.

Server-sent events from OpenCode can be added later after the core conversation lifecycle is working reliably.

## Routing

Routing should be backend-driven and candidate-based.
The backend should not depend on strict transcript normalization before routing.

### Why

Speech transcripts are messy.
Users may say things like `Emma twelve`, `talk to Atlas`, or `start a new Emma chat`, and ASR may render these inconsistently.

Trying to fully normalize all spoken variants into exact structured references is not the v1 strategy.
Instead, the backend should give a small routing model the raw transcript plus the live routing table and ask it to choose from a constrained action set.

### Routing Inputs

The router should receive:

- the raw transcript for the current turn
- the currently focused session, if any
- the list of active agent profiles
- the list of active sessions
- each session's display handle, such as `emma#12`
- each session's backing profile
- a short summary of each active session
- optional profile aliases or pronunciation hints

### Routing Outputs

The router should only be allowed to return one of a small set of actions:

- `route_to_session(session_id)`
- `route_to_profile(profile_id)`
- `create_new_session(profile_id)`
- `continue_current_session`
- `ask_clarifying_question`

The router should also return:

- confidence
- brief reason

If confidence is below a configured threshold, the backend should ask a clarifying question instead of guessing.

### Routing Policy

The intended v1 flow is:

1. transcribe the utterance
2. gather active profiles, active sessions, current focus, and short session summaries
3. call a small routing model with the raw transcript and those candidates
4. accept only one action from the constrained routing schema
5. execute the selected routing action deterministically in the backend

This means the model helps interpret noisy speech, but it does not get broad autonomy.
It only chooses among known destinations and a very small set of allowed actions.

### Non-Goals For V1 Routing

v1 routing should not:

- rely on a large hand-built transcript normalization layer
- use embeddings as the sole routing mechanism
- use a general-purpose autonomous agent to decide routing
- let the routing model directly operate tools or mutate sessions without backend validation

Embeddings may still be useful later for candidate ranking or topic matching, but they are not the primary routing authority in v1.

### Example Routing Cases

- `tell Emma twelve to keep working on the Vapor auth bug`
  - likely result: `route_to_session(session_id for emma#12)`

- `ask Atlas about the audio pipeline`
  - likely result: `route_to_profile(atlas)` or `route_to_session` if there is one obvious active Atlas session

- `start a fresh Emma chat for the UI`
  - likely result: `create_new_session(emma)`

- `keep going on that bug`
  - likely result: `continue_current_session` if there is a clear current focus, otherwise `ask_clarifying_question`

## TTS

The client should support local TTS at minimum for:

- agent replies
- enrollment prompts
- identity recovery prompts
- uncertain-command confirmations

The app may later support multiple TTS engines, but v1 only needs enough local TTS to sustain the call illusion and handle voice verification flows without backend round trips.

## Example End-to-End Flows

### Normal Verified Turn

1. user speaks while the call is active
2. phone detects speech and verifies it is likely the owner
3. phone streams the audio to the backend
4. backend transcribes and routes the request
5. selected agent session responds
6. phone speaks the reply using the session's assigned voice

### Unknown or Low-Confidence Speaker

1. speech is detected
2. phone cannot confidently verify the speaker as the owner
3. phone does not immediately forward the audio upstream
4. phone asks for local confirmation using the fixed spoken phrase
5. if confirmed, phone refreshes/creates the owner profile and resumes sending likely-owner speech

### New Agent Session

1. backend decides a new session is needed
2. backend selects the target profile, which also selects the home working directory
3. backend allocates an available display number within that profile
4. app assigns the matching display handle, such as `emma#4`
5. session keeps the same label and voice until it ends

## Privacy and Safety Expectations

The app should bias toward not sending speech upstream when owner confidence is low.

Initial expectations:

- non-owner nearby speech should be filtered locally where possible
- only likely-owner audio should be streamed by default
- identity challenges should run locally
- voice enrollment data should be treated as sensitive app data

## Open Questions

These are not yet fully resolved:

- should v1 be half-duplex or full-duplex during active agent speech
- how aggressively should uncertain speech be dropped versus buffered
- how should the app expose manual override when verification is repeatedly wrong
- what is the right threshold and UX for re-enrollment
- how much local STT, if any, should exist for instant captions or confirmations

## Initial v1 Summary

The current v1 direction is:

- call-like app on iPhone, iPad, and Mac
- embedded Swift backend hosted by the Mac app
- pluggable coding-agent profiles
- OpenCode-driven execution through `opencode run`
- OpenCode plugin hooks forwarding session events back to the tincan backend
- stable profile-scoped session identities like `emma#4`
- backend candidate-based routing using a small routing model over raw transcripts
- no speaker identification in the first shipping cut
- transcript-in, CLI-run-out as the first end-to-end verification path

## V1 Reset

The first buildable version is intentionally narrower than the broader long-term spec above.

For v1:

- the phone client does not perform speaker identification
- the backend does not receive multiple-speaker filtering signals
- the immediate goal is to prove the orchestration loop from call transcript to coding-agent execution

The concrete v1 execution flow is:

1. the phone client captures or simulates a transcript
2. the client sends that transcript to the Mac app's embedded Swift backend
3. the backend selects an agent profile
4. the backend shells out to `opencode run`
5. an embedded OpenCode plugin forwards hook events back to the same Swift backend
6. the backend returns the final result to the client

This v1 is therefore centered on:

- `agent profiles`
- `opencode run`
- `opencode` plugin hooks
- Mac-side Swift orchestration

Audio capture, STT, and call UX still matter, but they sit on top of this loop rather than replacing it.
