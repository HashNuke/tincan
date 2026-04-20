## Status

DONE

## Problem

The project needed a concrete migration plan for replacing the current custom app-side WebRTC direction with Liblinphone while keeping the rest of the `tincan` architecture intact.

## Solution

Added `docs/liblinphone-migration.md` documenting:

- what stays unchanged in the application model
- what moves into Liblinphone and Go-side call transport support
- the file-by-file changes needed across the Go server, Swift inference service, and Apple app
- the recommended migration phases and success criteria

## Notes

The plan keeps Liblinphone strictly in the transport/media layer and avoids moving router, conversation, or agent concepts into call signaling semantics.
