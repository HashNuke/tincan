## Status
DONE

## Problem
The macOS call flow required explicit speaker identification and an enrolled owner voice profile before audio could be sent. That blocked normal hands-free use and did not fit the router-driven interaction model. The app needed to listen for the router name as a wake word, then isolate and upload only the audio from the speaker who said that wake word.

## Solution
Replaced the explicit speaker-identification gate with wake-word speaker gating in the macOS client.

- The wake word is resolved from the configured router profile name, with `Atlas` as the fallback.
- Each captured speech turn is diarized and grouped per speaker.
- Each grouped speaker clip is transcribed locally.
- If exactly one diarized speaker says the wake word, only that speaker's grouped audio is uploaded.
- If no speaker says the wake word, the turn is dropped.
- If multiple speakers say the wake word, the turn is blocked and the UI reports the ambiguity.
- The call UI now shows passive wake-word status instead of explicit identification controls.

## Notes
Verification covered compilation and the new wake-word helper tests. The broader test suite still has unrelated existing failures in `ownerProfileStorePersistsRoundTrip` and the UI test runner's macOS authentication startup.
