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

- a stable spoken/display name for that session
- a stable TTS voice for that session
- a backing agent profile that determines how it behaves

### Naming

Agent profiles have stable base names, such as:

- `atlas`
- `aida`

Live sessions derive human-facing names from the profile plus a counter, such as:

- `atlas#41`
- `aida#12`

The numeric suffix may be recycled daily for human-facing labels.
These names are display identifiers, not primary keys.

### Internal IDs

Every session still needs an immutable internal identifier.

Examples:

- UUID
- backend session ID
- date-scoped session key such as `2026-04-19/atlas/41`

The internal ID must not depend on the recycled display counter.

### Voice

The voice should remain stable for the duration of a session.
Profile-level default voices are preferred over random session voices.

Why:

- users can learn that "Atlas sounds like Atlas"
- session identity stays understandable during long usage
- the suffix already provides enough novelty

## Pluggable Coding Agents

tincan should not be hard-wired to one coding agent provider.
It should support pluggable agent backends through profiles and adapters.

### Agent Profile

An agent profile is a reusable template that defines:

- base name
- backend/harness type
- model or model family
- endpoint configuration
- default system prompt/preset
- default TTS voice
- supported capabilities

Examples:

- `atlas` -> Codex + GPT-5.4
- `aida` -> GLM 5.1 + another coding harness

### Agent Adapter

Each provider/harness integration should conform to a common adapter surface.

Representative operations:

- start session
- resume session
- send turn
- interrupt session
- stream events
- fetch metadata/status

### Agent Session

A live agent session is an instance of a profile.
It binds together:

- profile
- immutable session ID
- display label
- conversation history
- backend routing information
- current voice/persona state

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
2. backend allocates a new internal session ID
3. app assigns the matching display handle, such as `atlas#41`
4. session keeps the same name and voice until it ends

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
- should agent routing be purely backend-driven, or can the user address a profile by name in speech
- how much local STT, if any, should exist for instant captions or confirmations

## Initial v1 Summary

The current v1 direction is:

- call-like app on iPhone, iPad, and Mac
- local VAD + speaker filtering on device
- owner voice enrollment plus fixed-phrase fallback
- backend as canonical STT and orchestration layer
- pluggable coding-agent profiles
- stable session identities like `atlas#41`
- local TTS playback with profile/session voice identity
