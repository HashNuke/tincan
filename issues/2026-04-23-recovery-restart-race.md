# Audio recovery task restarts capture after shutdown

## Status
DONE

## Problem
`AudioTurnPipeline.scheduleEngineRecovery(...)` launched an untracked async task.
If a hardware-change or tap-timeout recovery was queued and the user stopped the
call before that task finished, the recovery path could still continue and call
`startAudioEngine(...)` after shutdown.

This could restart microphone capture after `stop()` had already torn the
pipeline down.

## Solution
Tracked the pending recovery task and cancel it during shutdown/deinit.

- Added `engineRecoveryTask` so recovery work can be cancelled explicitly.
- Cancel the task and clear it in `stop()`.
- Re-check `isRunning` and task cancellation inside `recoverAudioEngine(...)`
  before stopping/restarting the engine.
- Clear recovery state with `defer` so stale recovery flags do not linger.

This keeps shutdown authoritative and prevents delayed recovery work from
bringing capture back up.
