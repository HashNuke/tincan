# MLX Metallib Bundle

Status: DONE

## Problem

`build-deps.sh` built `tincan-inference-macos` with `swift build` and only copied the executable into `tincan-swift-app/BundledRuntime`.

`mlx-swift` requires its compiled Metal shader library at runtime. Its README explicitly notes that command-line SwiftPM cannot build the Metal shaders and that the final build must use Xcode or `xcodebuild`.

Because the bundled runtime only contained the bare executable, TTS model loading failed at runtime with:

```text
MLX error: Failed to load the default metallib. library not found ...
```

## Solution

Updated `build-deps.sh` so `tincan-inference-macos` is built with `xcodebuild` instead of command-line SwiftPM.

The script now uses a dedicated derived-data directory under `tincan-inference-macos/.build/xcode-derived-data`, then stages:

- the built `tincan-inference-macos` executable
- the generated MLX Metal shader library from `mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib`

The Metal library is copied into the bundled runtime as `mlx.metallib` next to the executable, which matches MLX's first runtime lookup path for command-line tools.

## Result

`./build-deps.sh --skip-model-downloads --runtime-dir /tmp/tincan-bundled-runtime-test` now succeeds and the staged runtime contains:

- `tincan-inference-macos`
- `mlx.metallib`

This fixes the missing-metallib packaging issue for the macOS bundled inference runtime.
