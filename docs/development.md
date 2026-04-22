# Development

Developer-facing notes for building, packaging, and testing tincan live here.

## Bundled Runtime

Use `build-deps.sh` to stage the macOS runtime that `tincan-swift-app` ships with. It downloads the pinned STT/TTS models and Kitten G2P assets if they are missing, then builds `tincan-inference-macos` and `tincan-server`.

Requirements:

* `swift`
* `go`
* `uvx`

Commands:

```bash
./build-deps.sh
./build-deps.sh --skip-model-downloads
./build-deps.sh --force-model-downloads
./build-deps.sh --runtime-dir /absolute/path/to/BundledRuntime
```

Default output:

```text
tincan-swift-app/BundledRuntime/
  tincan-server
  tincan-inference-macos
  models/
    parakeet-tdt-0.6b-v3-coreml/
    kitten-tts-mini-0.8/
    _dependencies/
      kitten-tts-g2p/
```

Notes:

* `--skip-model-downloads` only rebuilds the binaries and restages the runtime tree.
* `--force-model-downloads` redownloads the pinned models and Kitten G2P assets.
* The app should pass a writable `--data-dir` to `tincan-server`; no writable server data is bundled in `BundledRuntime`.

## Audio Harness

Use `scripts/tincan_audio_harness.py` for prerecorded speech tests without talking into the microphone yourself.

Direct WebRTC send to `tincan-server`:

```bash
uv run python scripts/tincan_audio_harness.py send /absolute/path/to/sample.wav
uv run python scripts/tincan_audio_harness.py send sample.m4a --server http://127.0.0.1:55055 --repeat 3
```

Loopback playback into a virtual device such as BlackHole:

```bash
uv run python scripts/tincan_audio_harness.py devices
uv run python scripts/tincan_audio_harness.py play sample.wav --device "BlackHole 2ch"
```

Notes:

* `send` matches the current app transport: it sends `audio/wav` utterances over the `tincan` WebRTC data channel.
* `play` is for end-to-end app testing. Point the Swift app's input device at the same loopback device so the app treats the playback as microphone input.
