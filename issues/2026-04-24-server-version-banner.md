# Server startup banner must include the bundled binary version

## Status
DONE

## Problem
When `tincan-server` started, its opening log banner only printed the listening
address.

That made it hard to confirm whether the app had launched the newly bundled Go
binary or an older leftover build, especially when investigating stale runtime
behavior across app rebuilds.

## Solution
Injected the shared project version into the Go binary at build time and
included it in the startup banner.

- Added a root `VERSION` file that stores the shared semver core for the
  project.
- Added a `buildVersion` variable in `tincan-server` with a default `dev` value
  for direct local `go build` usage.
- Updated the startup log line to print `tincan-server <version> listening on
  ...`.
- Updated `build-deps.sh` to read `VERSION`, append `+YYYYMMDDHHMM` build
  metadata, and pass the full semver string into `go build` via `-ldflags`.

This makes the bundled server identify its version immediately at startup
without requiring manual version bumps during development builds.
