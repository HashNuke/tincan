# Bundled server reclaim fails when executable lookup is blocked

## Status
DONE

## Problem
On macOS startup, `MacBundledTincanServerController` tried to reclaim any process
already listening on the bundled server port before launching a fresh
`tincan-server`.

The reclaim logic only treated a listener as bundled when `proc_pidpath(...)`
returned an executable path that exactly matched the current app bundle's
`BundledRuntime/tincan-server` path.

In the sandboxed app, `proc_pidpath(...)` could fail for the already-running
bundled `tincan-server`, so the launcher logged that PID as `unknown
executable`, classified it as non-bundled, and refused to terminate it.

That left port `4490` occupied, prevented the new bundled server from starting,
and then caused downstream failures such as transcription requests hitting a
dead inference socket path.

## Solution
Updated port listener classification to trust the app's tracked
`run/tincan-server.pid` during startup reclaim.

- `reclaimPortListenersIfNeeded(...)` now passes the tracked PID into
  `classifyPortListeners(...)`.
- `classifyPortListeners(...)` now treats a listener as reclaimable when its PID
  matches the tracked bundled server PID, even if executable path lookup returns
  `nil`.
- Added tests covering both the tracked-PID fallback and the safety case where
  an unknown executable is still left alone if it does not match the tracked PID.

This keeps the existing safety boundary for unrelated listeners while allowing
the app to reclaim its own previously launched bundled server across restarts.
