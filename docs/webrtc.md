# WebRTC

## Goal

The app-server connection should become bidirectional and session-oriented.

The current request-response HTTP model is not sufficient once the server needs to:

- receive continuous user audio
- return immediate router feedback quickly
- push asynchronous conversation updates to the user
- queue and play TTS responses without the user explicitly polling for them

For that reason, the primary app-to-`tincan-server` transport should move toward WebRTC.

## High-Level Transport Split

Recommended split:

- app <-> `tincan-server`: WebRTC
- `tincan-server` <-> agent backends: HTTP plus backend-specific hooks

This keeps real-time interactive behavior on the app-server path while preserving simple backend integrations for OpenCode and other agent systems.

## Why WebRTC

The server is no longer only responding to direct client requests.
It must also push unsolicited events back to the app when agent conversations produce meaningful updates.

Needed bidirectional behavior includes:

- upstream microphone audio from the app to the server
- downstream immediate feedback after router decisions
- downstream queued conversation updates for TTS playback
- interruption or cancellation control while audio is being played

This fits a real-time session better than one-off HTTP requests.

## Session Model

The app should establish a long-lived real-time session with `tincan-server`.

That session should carry:

- upstream audio from the user
- downstream TTS audio or TTS playback events
- control messages about router actions and conversation updates

Conceptually, the server becomes the session orchestrator for the user's ongoing call.

## Suggested Channel Responsibilities

### Audio Uplink

The app streams microphone audio to the server.

The server then:

1. transcribes the audio
2. waits for a committed command boundary
3. runs the router on the committed transcript

### Data Channel

The data channel can carry control and state messages such as:

- transcript committed
- router immediate feedback
- conversation created
- conversation update queued
- play TTS
- stop TTS
- cancel current buffer

### Audio Downlink

The server can return synthesized TTS audio over the real-time session, or instruct the client to fetch/play synthesized audio.

The important point is that the server must be able to initiate the user-facing response without the client first making a separate HTTP request for it.

## Direction One: User To Backend

Primary path:

1. app streams audio to `tincan-server`
2. server transcribes
3. server runs the router
4. server returns immediate feedback
5. server executes the requested action through the selected `AgentAdapter`

Examples:

- create a new OpenCode-backed conversation
- send a new message to an existing conversation
- switch to another conversation update

## Direction Two: Backend To User

Return path:

1. agent backend sends conversation updates to `tincan-server` through hooks
2. server normalizes them into `conversation_update`
3. router decides whether they should be turned into user-facing spoken text
4. meaningful updates are queued for announcement
5. server pushes those announcements back to the app over the real-time session

Typical short update text:

- `Emma#12 has something.`
- `Atlas#15 got news.`

If the user asks to hear more, the router can then choose a fuller readout for the pending update.

## Agent Backend Integration

Agent backends do not need to use WebRTC.

The expected split remains:

- `tincan-server` talks to agent backends via HTTP APIs
- agent backends notify `tincan-server` through hooks

Examples:

- OpenCode session creation via HTTP
- OpenCode session updates via hooks

## Router Role In The Real-Time Flow

The router sits in both directions of the real-time loop.

### On user input

The router decides:

- create new conversation or not
- target existing conversation or not
- whether the user wants to switch to another agent or hear a buffered update
- what immediate spoken feedback should be returned

### On backend update input

The router decides:

- whether a backend change is meaningful enough to announce
- what short spoken text should be queued for the user
- what fuller spoken text to use if the user asks to hear more

## Incremental Adoption

This does not require replacing every HTTP path immediately.

Practical incremental path:

1. keep current HTTP endpoints for backend development and testing
2. define the session-oriented message model now
3. move app-server control and event flow to WebRTC
4. later move audio uplink and downlink fully onto that same session

## Non-Goals

This document does not define:

- exact SDP negotiation details
- exact codec choices
- full iOS audio session behavior
- detailed interruption policy while TTS is playing

It only establishes that the app-server connection should be treated as a bidirectional real-time session rather than only a collection of one-off HTTP requests.
