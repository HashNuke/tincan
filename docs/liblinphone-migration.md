# Liblinphone Migration

## Goal

Move the Apple app's realtime communication layer from the current custom WebRTC client plan to Liblinphone, while keeping the higher-level `tincan` application model intact.

The important rule is:

- Liblinphone owns call/media transport
- the Go server owns signaling/media backend behavior needed for Liblinphone interoperability
- `tincan` application concepts remain above that transport layer

These application concepts stay unchanged:

- conversations
- conversation updates
- conversation notes
- router actions
- agent profiles and agent backends
- OpenCode integration
- Swift inference service

## Non-Goals

This migration does not move product-level concepts into SIP or call signaling semantics.
It does not make Liblinphone responsible for router or conversation logic.

## Guiding Principle

Treat Liblinphone as a transport/media stack replacement for the Apple app.
Do not let it become the place where `tincan`'s orchestration model lives.

## High-Level Target Architecture

- macOS/iOS app
  - Liblinphone-based call/media client
  - separate app-layer control/event client if needed

- Go server
  - Liblinphone-compatible call setup/control/media backend
  - existing router, conversations, updates, notes, and agent orchestration

- Swift inference service
  - unchanged responsibility: STT/TTS only

## Migration Phases

### Phase 1: Isolate Existing Custom WebRTC Work

Goal:

- stop deepening the custom app WebRTC path
- keep `/speak` browser page as debug-only
- keep Go server WebRTC work only as a temporary debug transport

### Phase 2: Add a Call Transport Boundary In Go

Goal:

- create an internal transport-neutral call/session layer in the Go server
- make router/orchestration depend on that boundary instead of directly on current WebRTC test wiring

### Phase 3: Add Liblinphone-Compatible Call Server Behavior In Go

Goal:

- implement whatever call setup/control/media protocol Liblinphone requires
- keep it separate from the application-layer orchestration logic

### Phase 4: Replace Apple App Transport Layer With Liblinphone

Goal:

- use Liblinphone for mic/audio/call session behavior
- keep app UI and higher-level user interactions unchanged where possible

### Phase 5: Rewire Immediate Feedback And Updates Through The New Call Transport

Goal:

- make router feedback and update notifications flow through the Liblinphone call path instead of the current browser debug path

## File-By-File Plan

## Go Server

### `tincan-server/main.go`

Current role:

- debug/server entrypoint
- temporary WebRTC offer flow
- `/speak` support
- inference bridging
- hook ingestion

Planned changes:

1. keep as process entrypoint only
2. reduce transport-specific logic over time
3. move temporary WebRTC debug handlers behind clearly marked debug-only sections or files
4. wire new call transport manager into startup once Liblinphone server-side support exists

Long-term direction:

- main startup file should initialize:
  - config
  - DB
  - router
  - conversations
  - call session manager
  - inference supervisor/client

### `tincan-server/speak.html`

Current role:

- browser-only debug harness

Planned changes:

- keep it debug-only
- do not migrate product behavior into it
- continue using it for backend debugging while Liblinphone app work is in progress

### `tincan-server/router_service.go`

Current role:

- user input routing prompt construction
- adapter-backed router execution

Planned changes:

- no transport-specific changes needed
- ensure it remains independent of call transport implementation

### `tincan-server/router/types.go`

Current role:

- shared router input/output types

Planned changes:

- likely unchanged
- may later grow to include more call/session context fields if needed

### `tincan-server/agent_adapters/*.go`

Current role:

- backend execution for router and conversations

Planned changes:

- largely unchanged by Liblinphone migration
- these stay backend/application-layer components

### `tincan-server/conversations/types.go`

Current role:

- conversation model types

Planned changes:

- likely unchanged

### `tincan-server/conversations/store.go`

Current role:

- persistence for conversations, updates, notes

Planned changes:

- likely unchanged
- may gain helper methods for call-session association if needed

### `tincan-server/db/*.go`

Current role:

- database opening and migrations

Planned changes:

- likely unchanged except for any new call-session state tables if needed

### New Go Package: `tincan-server/calls/`

This is the most important Go-side addition for the migration.

Recommended files:

- `calls/types.go`
  - transport-neutral call session state
  - call direction/state enums

- `calls/manager.go`
  - tracks active call sessions
  - maps transport session IDs to application session IDs
  - exposes hooks for incoming audio / outgoing playback / control events

- `calls/events.go`
  - app-layer event messages that can be emitted to the client side

- `calls/linphone_server.go`
  - Liblinphone-facing call setup/control/media integration
  - this file should contain the protocol-specific server behavior needed by the app transport

Goal of this package:

- keep transport-specific call/session behavior isolated from router and conversation orchestration

### New Go Package: `tincan-server/transport/` (Optional)

If the server-side call protocol support grows large, transport glue may need its own package.

Possible files:

- `transport/linphone.go`
- `transport/debug_webrtc.go`

This is optional and only useful if the transport code becomes large enough to justify another boundary.

## Swift Inference Service

### `tincan-inference-macos/Sources/tincan-inference-macos/main.swift`

Current role:

- Unix socket inference server
- STT/TTS actions

Planned changes:

- no transport migration required
- keep this service transport-agnostic
- continue serving Go via Unix socket

This file should not know or care whether the caller is using WebRTC, Linphone, or another client media stack.

## Apple App

### `tincan/MacCallSessionViewModel.swift`

Current role:

- macOS call button logic
- currently being shifted away from old upload-based flow

Planned changes:

1. remove direct dependence on the experimental custom `MacWebRTCClient`
2. replace with a call session object backed by Liblinphone
3. keep the high-level UI state the same where possible:
  - idle
  - connecting
  - connected
  - disconnected
4. continue surfacing app-layer logs/events to SwiftUI

### `tincan/CallSessionViewModel.swift`

Current role:

- iOS call flow

Planned changes:

- same migration idea as macOS
- replace old direct upload/capture assumptions with Liblinphone-backed call state

### `tincan/TincanAppModel.swift`

Current role:

- wires top-level view models

Planned changes:

- introduce a shared call transport abstraction if helpful
- initialize Liblinphone-backed call session objects here or in dedicated app services

### `tincan/ContentView.swift`

Current role:

- shows call UI

Planned changes:

- mostly unchanged visually
- should continue to drive the same product interactions, just through a different transport backend

### `tincan/BackendConnectionConfig.swift`

Current role:

- current backend endpoint constants

Planned changes:

- add or rename configuration for the Go call server as needed
- remove assumptions that the app itself is directly doing custom WebRTC offer/answer signaling if Liblinphone replaces that flow

### `tincan/MacWebRTCClient.swift`

Current role:

- experimental native WebRTC client path

Planned changes:

- remove or archive once Liblinphone path is adopted
- do not continue investing in this file if the migration proceeds

### New Apple App Files

Recommended additions:

- `tincan/LiblinphoneCallClient.swift`
  - wraps Liblinphone setup and call lifecycle

- `tincan/CallTransportState.swift`
  - transport-level state for the app call layer

- `tincan/CallEventBridge.swift`
  - bridges app-layer events from the Go backend into the existing view model/state model if Liblinphone does not carry all app-level events directly

## Suggested First Implementation Order

### Step 1

Add `calls/manager.go` in Go.

Goal:

- create a transport-neutral place where incoming audio and outgoing notifications can be routed independently from current WebRTC debug endpoints

### Step 2

Define the app-layer event path that remains separate from raw call/media transport.

Goal:

- do not lose immediate feedback, updates, and router-driven state while switching transport implementations

### Step 3

Add a thin Liblinphone integration wrapper in the Apple app.

Goal:

- prove call start/end and media session establishment without yet moving all UI flows

### Step 4

Implement the corresponding Go-side signaling/call control behavior required by Liblinphone.

Goal:

- get one real app call session established to the Go backend

### Step 5

Route existing immediate feedback and update notification audio through the new call transport path.

Goal:

- remove dependence on `/speak` for product testing

## Delete/Deprecate Plan

If Liblinphone becomes the real app transport path, the following should eventually be deprecated or removed from product flow:

- `tincan/MacWebRTCClient.swift`
- app-specific custom WebRTC connection attempts

The following remain useful as debug tooling even after migration:

- `tincan-server/speak.html`
- debug audio endpoints in the Go server

## Risks

1. Liblinphone may require more call-control/signaling semantics from Go than initially expected
2. App-layer control events may still need a secondary channel depending on how much product signaling cleanly fits into the call layer
3. It is important not to let transport-specific logic leak into router or conversation code during migration

## Success Criteria

The migration is successful when:

1. the Apple app can start and end a call using Liblinphone
2. mic audio reaches the Go backend
3. Go can send audio back to the app over the call transport
4. router immediate feedback and conversation update notifications still work
5. conversation/routing/notes/backend logic remains independent of the chosen call stack
