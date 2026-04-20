## Status

DONE

## Problem

The Go server needs a low-latency way to tell the user that it is still processing queued speech without waiting on a live TTS request.

## Solution

Generated bundled PocketTTS WAV assets under `tincan-server/assets/audio/` for processing/backpressure prompts:

- `hold_on_processing.wav`
- `hold_on_processing_2.wav`
- `hold_on_processing_3.wav`
- `hold_on_processing_4.wav`

## Notes

These files can be bundled directly with the Go server and played immediately when the per-session utterance queue is full or inference is still busy.
