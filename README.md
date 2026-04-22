# tincan

TODO

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

## License

Copyright 2026 Akash Manohar John

* `tincan-swift-app`, `tincan-server` and all tincan components are licensed under FSL-1.1-ALv2 (See LICENSE.md).
* `webrtc-multiplatform` contents are licensed under [WebRTC license](https://webrtc.org/support/license).
