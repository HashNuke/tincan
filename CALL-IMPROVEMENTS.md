# Call Improvements

This document collects ideas for making the Tincan call feel less turn-based and more like a live human conversation. The main goal is to reduce dead air, make interruption feel natural, and keep the server in control of what the user hears over the WebRTC audio track.

The current repo shape matters:

- The app captures speech locally with FluidAudio VAD in `AudioTurnPipeline`.
- Approved user speech is sent over the WebRTC data channel as an `utterance` message from `BackendSessionClient`.
- `tincan-server` is currently Go using Pion WebRTC.
- The server already owns the downlink audio track and queues synthesized WAV audio through `sessionAudioWriter`.
- Server audio events flow through `output.CallAudioListener` and `callAudioRenderer`.

## Target Feel

The call should feel like the assistant is present and listening, not like a request/response form with a phone UI. The user should be able to interrupt naturally. Silence after a spoken turn should be rare and intentional. When the system is thinking, the user should hear a subtle processing sound that can be interrupted at once.

The first version should stay simple:

1. Client sends a lightweight speaking-state signal as soon as VAD detects that the user has started speaking.
2. Server immediately stops low-priority playback when that signal arrives.
3. Server plays a loopable processing sound while it is transcribing, routing, dispatching, or waiting for a real spoken response.
4. Real TTS and notifications preempt processing audio.
5. A new router action handles “repeat that” without mutating conversation state.

## Barge-In

When the user starts speaking while server audio is playing, the client should send a data-channel message immediately:

```json
{
  "type": "user_speaking",
  "state": "started",
  "source": "vad",
  "client_time": "2026-04-24T10:15:30.123Z"
}
```

When VAD detects speech end, the client can send:

```json
{
  "type": "user_speaking",
  "state": "ended",
  "source": "vad",
  "client_time": "2026-04-24T10:15:32.900Z"
}
```

The important part is the `started` message. It should be emitted at VAD speech-start time, before diarization, local speech recognition, wake-word filtering, or upload approval finishes. This signal is not permission to route the user’s speech. It is only a turn-taking signal that tells the server to get out of the way.

On the server, `webrtcTransport.handleClientMessage` should accept `user_speaking`. For `started`, it should call a call-audio controller for that session:

- stop current interruptible audio immediately
- clear queued interruptible items
- keep non-interruptible critical audio only if we add that category later
- mark the call state as `userSpeaking=true`

For `ended`, the server can mark `userSpeaking=false`. It should not automatically resume speech that was interrupted. If the interrupted item was processing audio, it can resume later when processing is still active. If it was real TTS, the user can ask to repeat it.

## Server-Owned Processing Audio

The processing sound should be played from `tincan-server`, not the app, because the server is the only component that knows whether it is currently transcribing, routing, waiting on an agent, synthesizing TTS, or playing real speech.

Use this source asset:

```text
/Users/akash/code/apple/tincan/audio/output/processing_click_echo.wav
```

For runtime use, copy it into:

```text
tincan-server/assets/audio/processing_click_echo.wav
```

Then bundle it into the server binary with Go `embed`, similar to:

```go
//go:embed assets/audio/processing_click_echo.wav
var processingClickEchoWAV []byte
```

The processing audio should be looped or re-enqueued by a session playback controller while the session is in a processing state. It should stop when:

- the user starts speaking
- real speech/notification audio is ready
- the request finishes with no spoken response
- the session closes or reconnects

The sound should start when the server receives a completed user utterance or begins work that will take longer than a very short threshold. A small delay, about 150-250 ms, may prevent clicks from playing for fast responses and make the interaction feel less noisy.

## Audio Priority

The current `sessionAudioWriter` is FIFO and cannot stop a WAV mid-playback except by closing the whole writer. For natural turn-taking, we need a small playback controller above it or inside it.

Recommended first-pass categories:

| Priority | Kind | Interruptible | Queue Behavior |
| --- | --- | --- | --- |
| 100 | emergency/system critical | no | plays immediately; rare or unused for now |
| 80 | real TTS response | yes by user barge-in | preempts processing; usually replaces queued processing |
| 70 | notification/update summary | yes by user barge-in | preempts processing; can queue behind current real TTS |
| 50 | clarification question | yes by user barge-in | preempts processing; should be remembered as last replayable audio |
| 20 | processing click/echo loop | yes | never queues behind itself; stops on any real audio |

Simple implementation:

- Add a per-session `CallPlaybackController`.
- Give each playback request an ID, kind, priority, interruptible flag, and WAV bytes.
- Track `currentItem`, a small queue, and a cancellation channel/context.
- Convert WAV to PCMU frames before or during playback, but check cancellation between 20 ms frames.
- On a higher-priority item, cancel the current lower-priority item and clear lower-priority queued items.
- On `user_speaking.started`, cancel the current item if interruptible and drop queued interruptible items.

This controller can replace direct calls to `sessionAudioWriter.Enqueue`. The existing WAV decoding and PCMU frame code in `webrtc_audio.go` can stay useful; it just needs cancellation-aware playback.

## Processing State

The server needs explicit session-level processing state rather than “play processing sound whenever an utterance arrives.” Useful state fields:

- `userSpeaking`
- `processingDepth` or named processing phases
- `currentPlaybackKind`
- `lastReplayableAudio`
- `lastReplayableText`

Processing can be reference-counted:

```text
beginProcessing(sessionID, reason)
endProcessing(sessionID, reason)
```

When processing depth changes from `0` to `1`, schedule the processing loop after a short delay. When it returns to `0`, stop processing playback. This avoids needing every call site to understand the audio loop.

Likely first integration points:

- start around `processUtterance`
- continue through STT and router action handling
- keep active while waiting for immediate feedback TTS generation
- end after the immediate feedback or clarification question has been queued
- for background agent work, use separate notification behavior instead of keeping processing audio alive for minutes

## Repeat Action

Add a router action named `repeat_last_audio`.

This action should replay the previous spoken server audio and should not change conversation state, current conversation handle, clarification history, pending update state, or agent queues.

Router result shape can stay close to the existing schema:

```json
{
  "action": "repeat_last_audio",
  "immediate_feedback": ""
}
```

The implementation should not require `message`, because there is no new agent message. The server should look up `lastReplayableAudio` for the session and play it again. If the raw audio is unavailable, replay `lastReplayableText` through TTS. If neither exists, respond with a short clarification like “I do not have anything to repeat yet.”

Replayable audio should include:

- immediate feedback
- clarification questions
- update summaries
- notifications
- final spoken response snippets

Replayable audio should exclude:

- processing click/echo sounds
- connection tones
- local UI-only sounds
- audio that was never actually queued for the user

## Router Prompt Changes

The router system prompt should list `repeat_last_audio` as an allowed action and include very explicit examples.

Suggested rule text:

```text
- Use repeat_last_audio when the user is asking to hear the last spoken assistant audio again without asking for new reasoning or more detail.
- Do not use repeat_last_audio when the user asks to explain, expand, rephrase, summarize differently, or provide more detail. Those are normal message actions.
- repeat_last_audio must not include message, agent_profile, conversation_handle, conversation_title, or conversation_notes.
```

Examples to add:

```text
- "can you repeat that again" => action=repeat_last_audio
- "say that again" => action=repeat_last_audio
- "come again" => action=repeat_last_audio
- "sorry, what was that" => action=repeat_last_audio
- "oh what? say that again" => action=repeat_last_audio
- "repeat the last thing you said" => action=repeat_last_audio
- "can you explain that again" => action=message, message="explain that again"
- "explain that in more detail" => action=message, message="explain that in more detail"
- "summarize that again but shorter" => action=message, message="summarize that again but shorter"
```

This distinction is important. “Repeat” is an audio playback request. “Explain again” is a semantic request for new agent work.

## Additional Ideas

### Backchannel Acknowledgements

Short acknowledgements like “Got it” or “One sec” can make the call feel alive, but they need restraint. The router already returns `immediate_feedback`; the improvement is to make these consistently short and start processing audio only after that feedback finishes.

Good examples:

- “Got it.”
- “I’ll check.”
- “On it.”
- “Let me look.”

Avoid long acknowledgements because they increase interruption pressure and make the system feel chatty.

### Latency Budget

Track rough timing per turn:

- VAD speech started
- VAD speech ended
- utterance uploaded
- STT finished
- router action selected
- immediate feedback TTS queued
- first audio frame written
- agent work dispatched

A call can feel much better if the first audible response happens within about 500-900 ms after speech end, even if it is only an acknowledgement or processing sound.

### Partial Turn Signals

The client can send `user_speaking.started` before it knows whether the speaker is approved. That improves interruption, but the server should not treat it as command input.

Later, after diarization/wake-word approval, the uploaded utterance remains the source of truth for work. This keeps privacy and speaker filtering intact.

### End-of-Speech Grace

Do not immediately resume processing audio at the exact moment VAD says speech ended. Add a short grace period, around 250-500 ms, so the user can continue a sentence naturally without the assistant clicking between clauses.

### Audible State Palette

Keep the audio palette small:

- call connection/disconnection tones
- subtle processing loop
- real speech
- optional short error tone

Too many tones will make the call feel like a notification system instead of a conversation.

### Interruption Memory

When the user interrupts real TTS, save the interrupted item as the last replayable audio. If the user says “repeat that,” replay from the beginning rather than trying to resume from the interrupted timestamp. Resuming mid-sentence is more complex and less predictable.

### Client UI State

The client can show a tiny state label or waveform change for:

- listening
- you are speaking
- processing
- speaking
- reconnecting

This is secondary to audio behavior, but it helps debug whether the system understood the turn state.

## Suggested Implementation Order

1. Add `user_speaking.started` and `user_speaking.ended` messages from the client VAD path.
2. Teach `tincan-server` to accept those messages and update session call state.
3. Add cancellation-aware server playback so current WebRTC audio can stop between 20 ms frames.
4. Bundle `processing_click_echo.wav` into `tincan-server`.
5. Add the processing loop as a low-priority interruptible playback item.
6. Track `lastReplayableAudio` and `lastReplayableText` for real spoken server output.
7. Add router action `repeat_last_audio`, prompt examples, and router tests.
8. Add focused tests for playback priority, barge-in cancellation, processing-loop cancellation, and repeat-action routing.

This order keeps the first useful user-visible behavior small: the user can interrupt server playback quickly, and silence gets filled only when the server is genuinely busy.
