# Stale bundled server survives app bundle path changes

## Status
DONE

## Problem
`build-deps.sh` stages the runtime in `tincan-swift-app/BundledRuntime`, and the
Xcode target copies that directory into the app bundle resources during each
macOS build.

The persistent launch failure was not caused by the runtime being omitted from
the app bundle. It was caused by startup reclaim logic dropping the tracked
`tincan-server` PID too early when the already-running process came from a
different app bundle path, such as an older DerivedData build.

That meant a previously launched bundled server could keep listening on port
`4490`, while the next app launch treated it as non-bundled and refused to
reclaim it. If `proc_pidpath(...)` also failed, the logs showed the listener as
an `unknown executable`, which made the failure look like an unrelated process
or stale binary mystery.

## Solution
Kept the tracked bundled server PID eligible for startup port reclaim even when
its executable path no longer matches the current bundle path.

- `startIfNeeded()` now preserves the tracked PID result from
  `reclaimTrackedBundledServerIfNeeded(...)` and passes it into port-listener
  classification.
- `reclaimTrackedBundledServerIfNeeded(...)` now returns the tracked PID when
  the process is still running but belongs to an older bundle path, instead of
  clearing the PID file before listener classification runs.
- This allows the existing tracked-PID fallback in `classifyPortListeners(...)`
  to reclaim the old bundled listener on the next launch.

This keeps the runtime bundled as an app resource while fixing the case where an
older bundled server binary from a previous app build continued owning the port.
