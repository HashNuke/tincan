## Status

DONE

## Problem

The app-side Liblinphone integration needed a dependency setup that could use a locally built Linphone SDK first and avoid forcing a remote package resolution for all platforms.

Because the app supports multiple Apple platforms, adding a single remote `linphone-sdk-swift-ios` package in the app target caused platform-friction and made local-build workflows difficult.

## Solution

Updated `linphone-multiplatform/Package.swift` to route dependency resolution through a local shim helper:

- Added a small resolver that prefers a sibling local package path (`../linphone-sdk-swift-ios`, `../linphone-sdk-swift-macos`) when present.
- Fell back to the upstream remote Linphone Swift package URLs when local paths are unavailable.
- Kept the target selection platform-aware so iOS and macOS resolve to their matching `linphonesw` product.

This lets you continue using locally built SDK artifacts when available while preserving compatibility with remote builds.
