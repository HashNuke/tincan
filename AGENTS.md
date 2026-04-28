# tincan app

The goal of this app is to be an app where I can talk to it on call (like how whatsapp calls, Messenger calls, etc happen on phone or desktop). And it should help with orchestrating my coding agent.

This is a multiplatform app. So it'll work on both ipad and iphone and mac. We'll add Apple Watch features later.

Primary functionality
* I should be able to start on call on the app.
* The app sends the audio to the server/endpoint it runs (on the backend)
* The backend uses a speech-to-text model (nvidia parakeet) via mlx-audio-swift library to understand what I'm saying.
* And then execute it with one of the coding agents running. It could be sending a message to an existing session, or creating a new session.
* Since we stay on call all day, I want you to use speaker diarization to identify what audio I speak vs what others speak (so that you can ignore stuff others say). FluidAudio library provides speaker diarization.

## Code

The main app is the xcode project for tincan that is the universal macos/ios/watch app. This is the UI, written in SwiftUI.

The `tincan-server` subdir has the orchestration server. This backend server is written in Go and includes support for Tailscale connectivity.

## Reference

* FluidAudio source code is available in ~/sources/FluidAudio
* OpenCode source code is available in ~/sources/opencode
* OpenCode server docs - https://opencode.ai/docs/server.md
* `opencode run` docs - https://opencode.ai/docs/cli/

When git committing, always commit with a very detailed commit description. Include the list of changes and the purpose of the changes in the commit.

NEVER run UI automation tests in xcode unless I explicitly ask for it to be run.

When you need to build and run the app from CLI, prefer the repo-local `bin/build-and-run` script. Use `bin/build-and-run mac`, `bin/build-and-run ios`, or `bin/build-and-run all` instead of rebuilding that workflow manually.
