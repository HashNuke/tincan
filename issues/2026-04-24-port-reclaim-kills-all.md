# Port reclaim must terminate any existing listener

## Status
DONE

## Problem
Startup reclaim was still trying to decide whether the process already listening
on port `4490` looked like the app's bundled `tincan-server`.

In practice that was fragile:

- executable lookup could fail and show `unknown executable`
- the tracked PID file could be missing
- an older `tincan-server` binary could still own the port and block startup

That meant the app sometimes never even attempted to send `SIGTERM` or
`SIGKILL`, because it rejected the existing listener before reaching the
termination path.

## Solution
Changed startup reclaim to terminate every process that is already listening on
the configured server port before launching a fresh `tincan-server`.

- `reclaimPortListenersIfNeeded()` no longer classifies listeners as bundled vs
  non-bundled.
- It now logs all listener PIDs on the port and attempts to terminate each one.
- This makes port ownership authoritative: if something is occupying the server
  port, the app reclaims it before launch.

No extra macOS entitlement was required for this change. The app is not using
the App Sandbox, and same-user signal delivery was not the blocker here.
