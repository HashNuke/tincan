# WebRTC Transport Migration

Status: DONE

## Problem

The app was still tied to Linphone naming and packaging even though the actual call flow was already local microphone capture plus server-side speech routing. That left us with three concrete problems:

1. The macOS app started a Linphone core that was not part of the real audio path.
2. The project depended on a broken remote `stasel/WebRTC` Swift package layout for macOS.
3. The client/server transport still used HTTP upload plus SSE instead of a single WebRTC session transport.

## Solution

The app and server were migrated to a pure WebRTC transport path:

1. Vendored the `stasel/WebRTC` M147 binary locally as `webrtc-multiplatform` and patched the macOS header layout so Xcode can import the framework on both iOS and macOS.
2. Replaced the app's Linphone dependency with a WebRTC-backed `BackendSessionClient` that:
   - performs HTTP offer/answer signaling against `/webrtc/session`
   - opens a WebRTC data channel named `tincan`
   - sends utterance payloads over the data channel
   - receives playback/notify events back over the same channel
3. Removed Linphone usage from the Swift app and deleted the app-side Linphone wrapper.
4. Added a server-side WebRTC transport built on `pion/webrtc` that:
   - creates and tracks WebRTC sessions
   - binds the data channel to the existing call/session manager event sink
   - routes utterance payloads through the existing transcription and router pipeline
   - sends utterance results and playback notifications back through the data channel
5. Removed stale server-side Linphone route implementation and updated transport docs.

## Verification

The following checks passed after the migration:

- `go build ./...` in `tincan-server`
- `xcodebuild -scheme "tincan" -project "tincan.xcodeproj" -destination "platform=macOS" build`
- `xcodebuild -scheme "tincan" -project "tincan.xcodeproj" -destination "platform=iOS Simulator,name=iPhone 17" build`

## Notes

There are still a few non-blocking compiler warnings in existing app code, but the WebRTC transport migration itself now builds successfully on both target platforms and no longer depends on Linphone in the app.
