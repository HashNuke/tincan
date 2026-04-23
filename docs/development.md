# Development

Developer-facing notes for building, packaging, and testing tincan live here.

## Bundled Runtime

Use `build-deps.sh` to stage the macOS runtime that `tincan-swift-app` ships with. It downloads the pinned STT/TTS models and Kitten G2P assets if they are missing, then builds `tincan-inference-macos` and `tincan-server`.

Versioning:

* `VERSION` at the repo root contains the shared semver core for the project.
* `build-deps.sh` appends `+YYYYMMDDHHMM` build metadata for bundled runtime builds and injects the full version into the Go binaries.

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
* Existing model directories are validated before reuse; incomplete staged assets are repaired or redownloaded.
* Kitten TTS `voices.npz` assets are converted to the `voices.safetensors` file expected by the bundled inference binary.
* `--force-model-downloads` redownloads the pinned models and Kitten G2P assets.
* The app should pass a writable `--data-dir` to `tincan-server`; no writable server data is bundled in `BundledRuntime`.

## Call Shell

Use `scripts/tincan_call_shell.py` for prerecorded speech tests and interactive WebRTC call sessions without talking into the microphone yourself.

Direct WebRTC send to `tincan-server`:

```bash
uv run python scripts/tincan_call_shell.py send
uv run python scripts/tincan_call_shell.py send /absolute/path/to/sample.wav
uv run python scripts/tincan_call_shell.py send sample.m4a --server http://127.0.0.1:4490 --repeat 3
```

Interactive WebRTC shell:

```bash
uv run python scripts/tincan_call_shell.py interactive
uv run python scripts/tincan_call_shell.py interactive --device "MacBook Pro Speakers"
```

Interactive commands:

```text
DEFAULT
SAY Atlas, ask Emma to run the date command and tell me what day is today
FILE /absolute/path/to/sample.wav
HELP
EXIT
```

Loopback playback into a virtual device such as BlackHole:

```bash
uv run python scripts/tincan_call_shell.py devices
uv run python scripts/tincan_call_shell.py play --device "BlackHole 2ch"
uv run python scripts/tincan_call_shell.py play sample.wav --device "BlackHole 2ch"
```

Notes:

* `send` and `play` default to `samples/ask-emma-hn-headline.wav`, which says "Atlas, ask Emma to get the top item on Hacker News".
* `send` matches the current app transport: it sends `audio/wav` utterances over the `tincan` WebRTC data channel.
* `send` and `interactive` negotiate the server's WebRTC audio downlink and play the remote audio track directly; URL-based audio payloads are no longer used.
* `interactive` keeps one WebRTC session open, sends the same sample with `DEFAULT`, treats bare text as `SAY`, and uses macOS `say` only for `SAY <text>`.
* `play` is for end-to-end app testing. Point the Swift app's input device at the same loopback device so the app treats the playback as microphone input.
