# Golang Server

## Goal

The main backend should move to a Go server.

The Go server becomes the primary backend for realtime sessions, routing, conversations, and agent orchestration.
The existing Swift server should be reduced to a narrow inference service responsible only for model execution.

This keeps the architecture simpler than splitting realtime transport into Go while leaving orchestration in Swift.

## High-Level Architecture

Recommended split:

- app <-> Go server: WebRTC
- Go server <-> Swift inference server: internal HTTP
- Go server <-> OpenCode and other agent backends: HTTP plus hooks

The Go server is the main backend.
The Swift server becomes a model-serving microservice.

## Why This Split

This architecture is preferred because:

- Go is a better fit for server-side WebRTC and long-lived realtime session handling
- it avoids splitting orchestration logic across two languages
- Swift remains where it has the strongest value: model inference and Apple-friendly runtime integration
- the system boundary becomes cleaner and easier to reason about

## Go Server Responsibilities

The Go server should own:

- WebRTC peer endpoint handling
- realtime session lifecycle
- app call session state
- routing user commands
- conversation creation and continuation
- conversation persistence
- agent profile loading and selection
- OpenCode integration
- hook handling from agent backends
- queued update announcements
- JSONL router/action logging
- communication with the Swift inference server

In other words, the Go server becomes the orchestration and realtime hub.

## Swift Server Responsibilities

The Swift server should be reduced to a minimal inference service.

It should own:

- speech-to-text using Parakeet
- text-to-speech using PocketTTS
- health checks for those model services

It should not own:

- conversations
- routing
- agent orchestration
- WebRTC
- realtime session state

## Swift Inference API

The Swift inference server should expose a very small API surface.

Suggested endpoints:

- `POST /transcribe`
- `POST /speak`
- `GET /health`

### `POST /transcribe`

Input:

- audio payload

Output:

- transcript text

### `POST /speak`

Input:

- text to synthesize

Output:

- synthesized audio

### `GET /health`

Output:

- model readiness
- cache or runtime health details

## Go Server Realtime Flow

The intended realtime path is:

1. app connects to Go server over WebRTC
2. app sends microphone audio to Go server
3. Go server forwards audio to the Swift inference server for transcription
4. Go server buffers and commits commands
5. Go server runs the router
6. Go server executes the chosen action
7. Go server sends immediate feedback and update announcements back to the app
8. when audio must be played, Go server obtains TTS audio from the Swift inference server and sends it to the client over WebRTC

## Agent Backend Flow

The Go server should talk directly to OpenCode and other agent backends.

Typical path:

1. router returns `new_conversation`, `message`, or another action
2. Go server resolves the target conversation or agent profile
3. Go server creates or continues the backend session
4. backend hooks later send updates back to the Go server
5. Go server normalizes those updates and decides whether to queue a user-facing announcement

## Conversation Updates

The Go server should keep the coarse event model already discussed:

- `conversation_update`

The Go server is responsible for:

- tracking pending updates per conversation
- selecting which updates should be announced
- deciding when the user is requesting to hear a buffered update

## Persistence

The Go server should become the source of truth for:

- conversations
- conversation numbers
- backend conversation IDs
- agent profiles if those later move out of JSON
- pending updates

SQLite remains acceptable as the initial persistence layer.

## Router Ownership

The router should live in the Go server.

It owns:

- command routing
- create versus existing conversation decisions
- switch intent detection
- update selection for readout
- short spoken feedback generation

There is no separate standalone summarizer component.

## Suggested Internal Components In Go

The Go server will likely need components similar to:

- `RealtimeSessionManager`
- `Router`
- `ConversationStore`
- `AgentProfileStore`
- `AgentAdapter`
- `OpenCodeAdapter`
- `AnnouncementQueue`
- `InferenceClient` for talking to Swift

These names are illustrative, not mandatory.

## Migration Direction

Recommended migration path:

1. stop expanding orchestration features in the Swift server
2. keep the Swift server stable as an inference-only service
3. design and implement the Go server as the new main backend
4. move routing and conversation orchestration into Go
5. have Go call the Swift server for transcription and speech synthesis

## Non-Goals

This document does not define:

- the exact Go framework to use
- exact Pion wiring details
- exact database library choice in Go
- the exact transport between app and Go beyond the high-level decision to use WebRTC

It only defines the service boundary and responsibility split.
