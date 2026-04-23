# Mic Delay and Flashing Indicator

**Status:** DONE

## Problem
When clicking the call button in the Mac app, there was a 3-second delay before the microphone audio was visible in the audiogram. During this time, there was silence. Additionally, the macOS microphone indicator in the menu bar would flash multiple times before the mic finally worked.

## Cause
1. **Call Startup Blocked on Processing Prep:** `MacCallSessionViewModel.startCall()` awaited wake-word speaker-gating setup (`identityManager.prepare()`) before it even started the microphone pipeline. That meant the audiogram stayed flat while diarization models initialized.
2. **Audio Engine Started Too Late:** `AudioTurnPipeline.start()` then awaited `turnDetector.prepare()` before starting `AVAudioEngine`. The VAD model load added more delay before the tap could deliver live input levels.
3. **Flashing Mic Indicator:** `AVAudioEngine` was redundantly re-instantiated multiple times in `AudioTurnPipeline.swift` (inside startup, recovery, and stop paths). Each fresh engine allocation tore down and rebuilt the audio graph, causing the macOS menu bar microphone indicator to flash.

## Solution
1. **Overlap Wake-Word Prep With Mic Bring-Up:** `MacCallSessionViewModel.startCall()` now starts wake-word preparation and microphone startup in parallel, so the meter can react immediately instead of waiting for diarization setup to finish.
2. **Start `AVAudioEngine` Before VAD Warmup Finishes:** `AudioTurnPipeline.start()` now brings up the engine first and only then awaits `turnDetector.prepare()`. The tap can emit live input levels right away, and early audio is buffered in `AsyncStream` until VAD processing is ready.
3. **Persistent `AVAudioEngine`:** Removed the redundant `audioEngine = AVAudioEngine()` re-assignments from the startup, recovery, and stop paths. The pipeline now keeps one engine instance alive across restarts and only stops/resets it, which avoids hardware thrash and stabilizes the mic indicator.
4. **User-Facing State Waits for Processing Warmup:** The Mac call UI no longer enters a separate `Starting mic` phase, and the initial `Microphone capture started` log is emitted only after VAD warmup completes. The mic still starts immediately, but the user-visible state no longer implies the full processing pipeline is ready before it actually is.
