# Audio pipeline start state not reset on launch failure

## Status
DONE

## Problem
`AudioTurnPipeline.start()` marked `isRunning = true` before successfully starting
`AVAudioEngine`. If `startAudioEngine(...)` threw an error (for example when no
audio input channels are available), the pipeline remained in a running state even
though capture was not active.

This caused downstream behavior issues such as:
- `start()` becoming a no-op on subsequent calls because `isRunning` stayed `true`.
- Recovery/observer/stream/task teardown not running after failed startup.
- Inconsistent internal state where a partially initialized pipeline appeared active.

## Solution
Updated `AudioTurnPipeline.start()` to wrap the startup call in `do/catch` and,
- remove observers,
- stop the audio engine,
- finish/cancel the audio stream and processing task,
- reset `isRunning` to `false`,
- then rethrow the original error.

This restores a clean startup state when launch fails and allows a user retry.
