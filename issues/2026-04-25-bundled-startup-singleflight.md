## Status

DONE

## Problem

The macOS app had multiple code paths that could call `MacBundledTincanServerController.startIfNeeded(...)` around the same time.

- app startup called `ensureMacServerStarted()`
- local speech settings secret sync also called `startIfNeeded(...)`
- other app-level flows could request startup while an earlier startup was still in flight

`TincanAppModel.ensureMacServerStarted()` already had its own task guard, but that protection only applied to that one call site. Other callers could still enter the controller directly and trigger overlapping launch attempts. The startup log showed repeated `mac launcher initialized` and repeated bundled server launches in short bursts.

## Solution

Centralized startup single-flight behavior inside `MacBundledTincanServerController`.

- added controller-owned startup task tracking
- changed `startIfNeeded(...)` to join an in-flight startup when the requested Tailscale mode matches
- made callers with a different requested mode wait for the in-flight startup to finish before starting a new launch path
- updated `restart(...)` to wait for any in-flight startup before stopping and relaunching
- moved the previous launch body into a private `performStartIfNeeded(...)` helper so recursive internal transitions do not re-enter the single-flight wrapper

## Notes

This fix does not change the existing reclaim behavior for stale pid files or port listeners. It specifically prevents repeated overlapping startup attempts from separate call sites in the macOS app.
