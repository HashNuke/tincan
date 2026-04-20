## Status

DONE

## Problem

The `/speak` page could establish a WebRTC connection and push-to-talk control flow, but there was no working end-to-end path from a held utterance to actual speech-to-text output.

The project needed a simple local test loop that would:

- capture one utterance on the browser test page
- send it to the Go server
- forward it to `tincan-inference-macos`
- print the returned transcript in the Go server console

## Solution

Implemented the first end-to-end `/speak` STT loop:

- `/speak` now records a local WAV utterance while `Z` is held
- on key release, the browser uploads that WAV to the Go server
- the Go server sends the audio to `tincan-inference-macos` over the Unix socket protocol
- `tincan-inference-macos` now uses FluidAudio `AsrManager` with Parakeet-backed models for STT
- the returned transcript is printed in the Go server console and returned to the page

## Notes

This path is intentionally simple:

- the browser page is still a fast local test harness
- WebRTC audio is still present, but the first real STT path is based on an uploaded WAV utterance on key release
- the Go server now has a working Unix-socket inference client for STT
