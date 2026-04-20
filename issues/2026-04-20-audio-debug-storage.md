## Status

DONE

## Problem

The Go server was writing runtime audio files into `tincan-server/tmp/`.

That included:

- utterance debug captures under `tincan-server/tmp/utterances/`
- synthesized feedback audio under `tincan-server/tmp/generated-audio/`

Because `tmp/` lives inside the repo, routine debugging audio was polluting the working tree and mixing disposable runtime artifacts with source code.

## Solution

Moved server audio storage out of the repository and into app support storage under `~/Library/Application Support/tincan/server-audio/`.

Specifically:

- added a shared helper in `tincan-server/main.go` to resolve and create the runtime audio directory
- changed utterance debug writes to `~/Library/Application Support/tincan/server-audio/utterances/`
- changed synthesized feedback audio writes and reads to `~/Library/Application Support/tincan/server-audio/generated-audio/`
- kept the existing HTTP route shape (`/debug/audio/generated/:name`) so callers do not need to change

## Notes

Existing files already present in `tincan-server/tmp/` are not migrated automatically. New runtime audio is written only to the app support location.
