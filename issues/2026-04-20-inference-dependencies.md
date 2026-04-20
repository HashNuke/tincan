## Status

DONE

## Problem

The new `tincan-inference-macos` package needed to match the model runtime dependencies already used by the previous Swift server so that Parakeet STT and PocketTTS integration could be moved over cleanly.

## Solution

Added the same core inference dependencies to `tincan-inference-macos`:

- `FluidAudio` from `0.13.6`
- `onnxruntime-swift-package-manager` from `1.24.2`

The executable target now links:

- `FluidAudio`
- `onnxruntime`

## Notes

These versions were chosen to match the versions actually resolved in `tincan-server-old`.
The new inference package builds successfully with those dependencies.
