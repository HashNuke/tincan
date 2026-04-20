## Status

DONE

## Problem

The `/speak` page could capture microphone input and upload utterances, but it did not have a convenient way to listen to output from the server side.

That made it harder to use the page as a true local call test harness.

## Solution

Added basic output support to `/speak`:

- added a `Play Server Audio` button to play a bundled server audio asset
- added a remote audio element on the page for future WebRTC downlink audio
- added a Go route at `GET /debug/audio/processing` that serves a bundled WAV asset

## Notes

This is a small testing aid.
It does not yet mean the Go server is sending real WebRTC audio downlink, but it gives the page a concrete output path and a ready place for remote audio when that path is added later.
