# Tincan UI Design Direction

## Goal

Move the app from a utility-style prototype to a voice-first interface that feels like an always-on call surface for coordinating coding agents.

The HTML reference in `/Users/akash/Downloads/tincan_agents_ui.html` is a good direction for the visual language and the main screen types. We should treat it as a product reference, not a literal spec. The phone chrome, notch, and other mockup artifacts are not part of the app design.

## Decision Summary

- Keep the reference's dark, high-contrast visual style.
- Keep the reference's active call dashboard and transcript detail patterns.
- Adapt the reference's list screen into a conversation-first home screen backed by server threads rather than a plain agent roster.
- Treat the active-call dashboard as the in-call state of the home screen, not as a completely separate product surface.
- Add a fourth surface for settings, because the current app has important operational controls that do not belong inline on the main call screen.
- Use the same overall design language on iPhone and Mac. On Mac, adapt it to wider layouts instead of pretending the app is still inside a phone frame.
- Keep voice as the primary interaction model. Text entry can exist, but it should be secondary.

## What We Should Reuse From The Reference

### 1. Visual language

The reference gets several things right:

- Dark background with a single "live" accent color.
- Rounded cards for primary content blocks.
- Monospace metadata for technical details like handles, paths, timers, and badges.
- Compact pill/chip treatment for agent identity and session state.
- A UI that looks operational rather than consumer-social.

This fits tincan well because the product is half call app, half agent operations console.

### 2. Active call dashboard

The first reference screen should become the main in-call state of the home screen.

What to keep:

- Call status at the top.
- Compact call controls near the top rather than giant controls dominating the whole screen.
- A list of current/recent agent sessions in the middle.
- A high-priority update card that can pull the user into a transcript.
- A lightweight live waveform or listening indicator near the bottom.

Implementation note:

- The waveform / audiogram is feasible for tincan because tincan owns the audio path for its own VoIP call.
- We should derive that UI from our own captured and rendered VoIP audio, not from any assumed access to the system Phone / FaceTime call stack.

Why it fits:

- tincan is supposed to stay on call for long periods.
- The user needs to monitor multiple agent conversations while still feeling "on the line."
- The update card is a good representation of server-side `notify` events.
- This pattern also works well as a top section layered above the home conversation list when a call is active.

### 3. Transcript view

The second reference screen is the right model for focused conversation review.

What to keep:

- Header with conversation handle and inline call controls pinned at the top.
- Agent chip plus working directory/session metadata.
- A scrollable detail area below the header.
- Rich update cards for patches, diffs, attachments, or notable results.

Why it fits:

- The user sometimes needs to inspect what an agent said or sent.
- Notifications should deep-link here.
- One of the reference designs already shows the right pattern: call controls on top, transcript content below.
- This is the right place for longer-form output that would clutter the main call screen.

### 4. List screen pattern

The third reference screen is still useful, but the structure should be repurposed.

What to keep:

- Branded header.
- Card-based list treatment.
- Compact metadata and status badges on each row.

Why it fits:

- The app needs a strong list-based home surface.
- The card pattern works well for conversation threads like `emma#16` and `atlas#7`.
- The same pattern can still be reused inside Settings for agent profiles.

## What We Should Change For Tincan

### 1. Add settings as a first-class surface

The reference is missing settings, but tincan already has configuration and operational controls that must live somewhere stable.

Settings should have three main sections:

- Server
  - On Mac, default to "run local server on this Mac"
  - When local server is selected on Mac, show a QR code for the phone to scan
  - Also support manual host + port entry
  - On phone, support connecting by host + port entry or QR scan
- Agent backends
  - Editable on Mac
  - Read-only on phone
- Agent profiles
  - Editable on Mac
  - Read-only on phone

Operational status that does not need to be directly editable, such as speaker identity state, permissions state, and recent diagnostics, should still be visible somewhere in the UI, but it does not need to define the primary settings taxonomy.

Recommendation:

- On the home screen, make the call action the primary top-right button.
- Keep Settings accessible from the home screen toolbar as a secondary action.
- Keep Settings accessible from the active call dashboard too.
- Present settings as a sheet on iPhone.
- Use a sheet or inspector-style panel on Mac, but keep the internal design identical at first.
- On Mac, make the local-server option the default server mode.

### 2. Make speaker identification visible

Speaker diarization / owner identification is core to the product, not a hidden technical detail.

The active call screen should show one compact status chip or banner for:

- Listening to owner
- Waiting for speaker verification
- Ignoring non-owner speech
- Speaker identity unavailable / needs setup

The current Mac-specific speaker identity state should not stay buried in a separate card forever. It should become part of the universal call UI.

### 3. Treat text input as secondary

The transcript reference includes a bottom text composer. We should not carry that into the current app design.

For tincan:

- Voice remains primary.
- We do not support chat input yet.
- The transcript screen should stay read-only for now.

Recommendation:

- Do not show a chat input or send button on the transcript screen.
- Revisit text input only when the product actually supports it.

### 4. Put agent configuration in Settings, but with platform-specific capabilities

The reference's "add agent" affordance should not remain as a loose button on the main list surface. Agent configuration belongs under Settings.

Current direction:

- Agent backends are editable on Mac and read-only on phone.
- Agent profiles are editable on Mac and read-only on phone.

Current reality:

- Agent profiles live on the server under `<data-dir>/config/agent_profiles.json`.
- Checked-in sample runtime config lives under `tincan-server/testdata/data-dir/config/`.
- Backends are also server-defined today.
- The app does not yet have client-facing APIs for editing them.

Recommendation:

- The settings IA should reserve space for these sections now.
- On phone, present those sections as browse-only.
- On Mac, implement editing only after the app can manage the underlying server-backed data safely.
- Do not ship fake edit affordances before that support exists.

### 5. Adapt the Mac layout instead of copying the phone composition exactly

The same design language should work on Mac, but we should use the extra width.

Good Mac adaptations:

- Wider transcript column.
- Two-column dashboard when useful.
- Larger paddings and more breathing room.

What not to do:

- Do not preserve fake phone spacing, notch padding, or narrow content widths.

## Proposed App Information Architecture

### Surface 1: Home / Conversations

Default when idle. Also available while on call.

Content:

- Brand/header
- Primary call button in the top-right
- Server-backed conversation list
- Each conversation handle as its own thread, for example `emma#16` or `atlas#7`
- Per-thread metadata such as latest preview, pending update state, and recency
- Lightweight global status line
- Settings entry point

Use this when the user wants to:

- Start a call
- Resume or inspect an existing thread
- Pick what to focus on before entering transcript detail
- See which conversations need attention first

Home screen behavior:

- The list should come from the server, not from static local mock state.
- Each conversation row represents a distinct thread.
- Tapping a row opens that thread's transcript screen.
- If there are no conversations yet, show an empty state with the call button as the primary CTA.
- When a call becomes active, the home screen should switch into an in-call variant instead of navigating somewhere unrelated.
- In the in-call variant, call controls appear at the top of the home screen.
- The conversation currently active in the call should be visually highlighted and can occupy more space than the other rows.
- That featured current conversation should feel closer to the first reference design's emphasized session card.
- When a conversation receives a new text update from the agent, its row/card should gain a stronger highlighted state so it stands out in the list.

### Surface 2: Active Call Dashboard

Primary in-call state of the home screen.

Content:

- Call state and elapsed time
- Compact controls: mute, speaker/output, end call, sessions
- Speaker identity / diarization state
- Featured current conversation card
- Conversation list with handle, preview, and activity/update badge
- Pending update card
- Waveform or listening indicator

Use this when the user wants to:

- Stay on the call
- Monitor multiple sessions
- Jump into an update only when necessary

Active call dashboard behavior:

- This should feel like the home conversation list with a live call header added on top.
- The currently active conversation in the call should be promoted into the featured card treatment.
- Other conversations remain visible below it as a list.
- Conversations that receive new text updates from agents should get a more attention-grabbing highlighted state until the user views them.
- Any waveform / audiogram shown here should be driven only by tincan's own VoIP media pipeline.

### Surface 3: Conversation Transcript

Focused detail screen for a single session.

Content:

- Conversation handle
- Agent metadata and working directory
- Pinned top bar with inline call controls
- Conversation updates timeline fetched from the server
- Rich transcript / update / artifact cards

Use this when the user wants to:

- Read what happened
- Inspect a pending update in detail
- Follow a specific agent conversation closely

Transcript screen behavior:

- Tapping a conversation on the home screen opens this screen.
- The body content should be driven by a conversation-updates API, not by only the last live event held in memory.
- The timeline should render updates in a transcript-like way, because that is how the user reads the thread.
- When the screen opens, it should scroll to the most recent message/update.
- Call controls stay visible at the top while the user scrolls the transcript/update content below.

### Surface 4: Settings

Operational configuration and diagnostics.

Content:

- Server
- Agent backends
- Agent profiles
- Secondary status/details such as diagnostics, permissions, and identity state

Use this when the user wants to:

- Fix setup problems
- Change server connection details
- Inspect or manage agent backends and profiles
- Inspect low-level app state

### Settings behavior by platform

#### On Mac

- Default server mode is "run server on this Mac"
- Show the connection target as both text and QR code
- Allow editing agent backends
- Allow editing agent profiles

#### On iPhone

- Default behavior is to connect to a server
- Let the user connect by:
  - entering host + port manually
  - scanning a QR code from the Mac app
- Show agent backends in read-only form
- Show agent profiles in read-only form

## Mapping The Current App Into This Structure

### Current iPhone UI

Today the iPhone UI puts nearly everything in one scrolling form:

- Backend URL
- Call status
- Last transcript
- Start/end call buttons
- Activity log

This should be split across:

- Active call dashboard
- Transcript detail
- Settings

### Current Mac UI

Today the Mac UI has separate cards for:

- Call status and controls
- Speaker identity
- Last transcript

This is closer to the target, but it still lacks:

- Real navigation structure
- Conversation-first home screen
- Session list
- Transcript detail screen
- Settings surface

### Current diagnostics placement

Logs are useful, but they should not dominate the main UI.

Recommendation:

- Keep detailed logs and troubleshooting info in a secondary area inside Settings.
- Keep only small, high-value status summaries in the main screens.

## Data And API Gaps We Need To Close

The reference UI assumes richer app state than the app currently has.

### Data the app already has

- Call active/idle state
- Last transcript text
- Server `notify` and `play_audio` events
- On Mac, speaker identity status

### Data the app does not yet have in a usable UI shape

- Configured agent backend list
- Configured agent profile list
- Active/recent conversation list
- Pending update counts per conversation or agent
- Which conversation is the current active call context
- Whether a conversation has a new text update that should visually stand out in the list
- Conversation update history for a conversation
- Rich conversation artifacts for transcript rendering
- Shared settings model across iPhone and Mac
- QR payload generation/scanning flow for server connection
- Mac local-server lifecycle and status in UI

### Backend work likely required

Add app-facing endpoints for:

- Agent backends list
- Agent profiles list
- Agent backend/profile mutation on Mac if we want in-app editing
- Conversation/session summaries
- Conversation update history / transcript detail
- Pending updates list / unread state
- Server health / discoverability info for QR-based connect

Minimum API shape for the first usable version:

- one endpoint to list conversations for the home screen
- one endpoint to fetch updates for a single conversation thread
- conversation-list data should indicate current call context and whether each thread has an unread/new text update
- continued SSE/live notification support so open transcript screens can merge live events into the fetched history

The server already has the underlying data for much of this in:

- `<data-dir>/config/agent_profiles.json`
- `conversations`
- `conversation_updates`

But the app client currently only talks to:

- session registration
- utterance upload
- SSE events

That is not enough to power the reference-style UI.

## Client Architecture Changes Required

### 1. Shared settings model

Create one shared app settings store for both iPhone and Mac.

It should own:

- Server connection mode
- Host + port
- Local server status on Mac
- QR-shareable connection payload
- Read-only or editable backend/profile settings state depending on platform

This replaces the current split where iPhone exposes a URL field inline and Mac uses a static connection path.

### 2. Shared UI domain models

We should introduce models shaped for UI rather than reusing transport responses directly.

Suggested models:

- `AgentSummary`
  - name
  - workingDirectory
  - activityState
  - conversationCount
- `ConversationSummary`
  - handle
  - agentName
  - previewText
  - status
  - hasPendingUpdate
  - hasUnreadTextUpdate
  - isCurrentCallConversation
  - updatedAt
- `ConversationTimelineItem`
  - conversation update
  - agent message
  - notification
  - artifact/diff
  - timestamp
- `SettingsState`
  - server
  - agentBackends
  - agentProfiles
  - diagnostics
  - editCapabilities

### 3. Shared navigation/state container

The current app is split by platform at `ContentView` and uses separate view models.

For the redesign, the app needs a shared navigation model that can answer:

- Which top-level surface is active
- Which conversation is selected
- Whether settings is open
- Whether the app is idle or on-call

The platform-specific logic should stay mostly in capabilities and call plumbing, not in the visual structure.

## Implementation Plan

### Phase 1: Lock the product structure

- Create shared design tokens and reusable UI primitives.
- Create the four main surfaces with placeholder/mock data.
- Move backend URL and logs out of the main call screen and into Settings.
- Define the Server settings flow around:
  - local Mac server
  - host + port entry
  - QR code generation/scanning

### Phase 2: Unify app state

- Add shared settings storage.
- Add shared navigation state.
- Expose speaker identity state in the universal UI model.
- Add platform-aware settings capabilities for editable-on-Mac and read-only-on-phone sections.

### Phase 3: Add real operational data

- Add server endpoints for backends, profiles, conversations, and transcript/history data.
- Build a client-side store that merges initial fetches with live SSE updates.
- Populate the dashboard, home conversation list, and transcript with real data.
- Wire QR connection payloads and Mac local-server status into the Server settings section.
- Make the transcript screen fetch conversation updates on open and merge them with live updates while the call is active.

### Phase 4: Add secondary features

- Manual text reply in transcript view
- Agent backend/profile edit flows on Mac if backed by server APIs
- Rich diff/artifact cards

## Recommended First UI Build Order

If we start implementing the redesign, the build order should be:

1. Shared theme and reusable cards/chips
2. New root navigation shell
3. Active call dashboard
4. Home conversation list
5. Settings
6. Transcript detail
7. Data/API wiring

That order gives us a visible structural improvement quickly, while keeping the backend-dependent work isolated.

## Explicit Decisions For Now

- Use the reference's visual system.
- Use the reference's active-call and transcript patterns directly.
- Replace the roster-style home concept with a conversation list from the server.
- Treat each conversation handle, such as `emma#16` or `atlas#7`, as its own thread.
- Put the call action in the home screen's top-right as the primary action.
- Add settings as a fourth screen/sheet.
- Keep voice-first interaction central.
- Server settings are organized around local Mac hosting, host + port entry, and QR handoff to phone.
- Agent backends and agent profiles live under Settings.
- Agent backend/profile editing is Mac-only; phone is read-only.
- Do not ship fake edit controls before there is real backend support.
- Do not keep backend URL fields and raw logs on the main screen.
- Use the same design direction for iPhone and Mac, with width-aware layout adjustments on Mac.
