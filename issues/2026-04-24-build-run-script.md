## Status

DONE

## Problem

There was no single repo-local command to build and immediately run the app from the command line.

For macOS, that meant manually building with `xcodebuild` and then locating and opening the generated `.app` bundle. For iOS, it meant manually finding a connected phone, building for that destination, installing the app, and launching it on-device.

## Solution

Added a root script at `bin/build-and-run`.

- `bin/build-and-run mac` builds the `tincan` scheme for macOS and launches the built app on the current Mac
- `bin/build-and-run ios` looks for a connected physical iPhone with developer services available, builds for that device, installs the app with `devicectl`, and launches it on the phone
- `bin/build-and-run all` runs the macOS flow first and then attempts the iPhone flow using the same physical-device detection rules
- if no suitable physical iPhone is available, the `ios` mode prints a message and exits without attempting an iPhone build

## Notes

The script uses `xcodebuild` for build output resolution and `xcrun devicectl` for iPhone install/launch so the workflow stays entirely in CLI.

The repo guidance in `AGENTS.md` now tells future changes to prefer `bin/build-and-run mac`, `bin/build-and-run ios`, or `bin/build-and-run all` when building and launching from the command line.

After the first run, the iPhone path needed a follow-up fix because the temporary-device-list cleanup used `trap ... RETURN`, which failed under the script's zsh execution. The cleanup now uses explicit `rm -f` calls so the iPhone flow can continue normally.
