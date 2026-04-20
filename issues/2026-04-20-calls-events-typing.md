## Status

DONE

## Problem

The first `calls` package migration introduced a transport-neutral manager, but the app-layer events being pushed through it were still ad hoc maps built directly in `main.go`.

That kept the event model too loose for a transport boundary that is supposed to survive migration from the current WebRTC debug path to Liblinphone.

## Solution

Added typed app-layer call events to the `calls` package:

- `PlayAudioEvent`
- `NotifyEvent`
- helper constructors for both

Updated the current Go server to use those typed events when pushing:

- router immediate feedback audio
- conversation update notifications

## Notes

This is still a small slice, but it is important cleanup for the transport-neutral call layer.
It reduces map-shaped event payloads in the server entrypoint and makes later call transport changes easier.
