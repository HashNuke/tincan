## Status

DONE

## Problem

The architecture discussion had shifted toward making Go the main backend while reducing the Swift server to an inference-only service.

That direction needed to be written down clearly so the project could avoid a messy split where WebRTC lived in Go but orchestration remained in Swift.

## Solution

Added `docs/golang-server.md` documenting:

- Go as the main backend for realtime sessions, routing, conversations, and agent orchestration
- Swift as a narrow inference server for Parakeet STT and PocketTTS
- the app-to-Go, Go-to-Swift, and Go-to-agent-backend communication paths
- the desired service responsibilities and migration direction

## Notes

This keeps the architecture cleaner:

- Go becomes the realtime and orchestration hub
- Swift stays focused on model execution
- the boundary between services is narrower and easier to evolve
