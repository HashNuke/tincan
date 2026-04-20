## Status

DONE

## Problem

The router was already returning `immediate_feedback`, but that text was not yet being turned into audio and played back to the user.

That meant the system could decide what to say, but not actually speak it back in the `/speak` test flow.

## Solution

Implemented the first immediate-feedback audio path:

- added TTS synthesis support to the Go inference client over the Unix socket
- when a router result includes `immediate_feedback`, the Go server now requests PocketTTS audio from `tincan-inference-macos`
- the generated WAV is written to `tincan-server/tmp/generated-audio/`
- the Go server serves generated feedback files through `GET /debug/audio/generated/:name`
- `/speak` now auto-plays `feedback_audio_url` when it is returned in the utterance response

## Notes

This is a practical bridge step:

- it does not yet use WebRTC downlink audio for feedback
- it does give the browser test page a working automatic audio response path
- the same router feedback text can later move to a direct WebRTC audio path without changing the router contract
