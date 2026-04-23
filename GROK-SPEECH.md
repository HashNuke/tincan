# Grok / Speech Services Plan

## Goal

Make STT and TTS internally pluggable while keeping the existing config key names:

- `stt_model`
- `tts_model`

Those keys will stop meaning "always a local model directory name" and instead become provider-qualified selectors in the form `<provider>/<model>`.

Examples:

- `stt_model: "macos/parakeet-tdt-0.6b-v3-coreml"`
- `tts_model: "macos/kitten-tts-mini-0.8"`
- `tts_model: "grok/grok-tts-v1"`

I would keep the stored format canonical as `provider/model`.

## Proposed Config Shape

```json
{
  "router_profile": "emma",
  "stt_model": "macos/parakeet-tdt-0.6b-v3-coreml",
  "tts_model": "grok/grok-tts-v1",
  "services": {
    "grok": {
      "base_url": "https://api.x.ai/v1",
      "tts": {
        "language": "en",
        "voice_id": "Eve",
        "output_format": {
          "codec": "wav",
          "sample_rate": 44100
        }
      }
    }
  }
}
```

Notes:

- Keep `stt_model` and `tts_model` for compatibility and clarity.
- Add a top-level `services` object for non-secret provider configuration.
- Do not put API keys in `config.json`.
- Store secrets in macOS Keychain with:
  - keychain service: `com.tincanbot`
  - account names:
    - `GROK_API_KEY`
    - `GEMINI_API_KEY`

## Important Design Decisions

- The selector format is always `<provider>/<model>`.
- The selector prefix chooses the provider: `macos`, `grok`, `gemini`.
- The selector suffix is provider-defined and interpreted in context.
  - For `macos`, it maps to the folder name inside the models directory.
  - For `grok`, values like `grok/grok-tts-v1` can be mapped internally by the server according to whether they came from `stt_model` or `tts_model`.
- The Mac app writes secrets to Keychain directly.
- `tincan-server` reads secrets from Keychain directly.
- The server API should expose only non-secret config plus secret presence/status, never the secret value.

## File-By-File Changes

### Backend config and model selection

`tincan-server/config/app_config.go`

- Keep `router_profile`, `stt_model`, and `tts_model`.
- Add parsing and persistence for a typed `services` block.
- Parse provider-qualified values out of `stt_model` and `tts_model`.
- Parse them using a single `<provider>/<model>` parser, then validate them with STT-vs-TTS context.
- Preserve unknown keys in `config.json` exactly like the current store does.
- Add getters for:
  - parsed STT selector
  - parsed TTS selector
  - named service config from `services`
- Add update methods so the future settings API can write non-secret config without editing files directly.

`tincan-server/config/types.go`

- Add typed structs for the new `services` block if you want to keep provider config types centralized.
- Suggested types:
  - `SpeechSelector`
  - `ServiceConfig`
  - `GrokServiceConfig`
  - `GrokTTSConfig`
  - `OutputFormat`

`tincan-server/config/store_test.go`

- Add coverage for:
  - default config creation
  - loading `services`
  - preserving `services` when `router_profile` changes
  - parsing provider-qualified `stt_model` / `tts_model`
  - backward compatibility with plain local model names

`tincan-server/testdata/data-dir/config/config.json`

- Update the sample runtime config to include the new `services` block.
- Keep the sample using `macos:` selectors unless you specifically want the checked-in example to demonstrate Grok.

### Backend runtime plumbing

`tincan-server/main.go`

- Introduce internal interfaces for:
  - speech-to-text
  - text-to-speech
- Replace the direct assumption that both STT and TTS always use the local Unix socket inference process.
- Resolve the provider for `stt_model` and `tts_model` independently.
- Only use `tincan-inference-macos` for selectors with the `macos` prefix.
- Route Grok TTS through an HTTP client instead of the local socket.
- Keep the current local inference launch logic for `macos`.
- Mixed mode must work:
  - `stt_model = macos/...`
  - `tts_model = grok/...`

`tincan-server/controllers_support.go`

- Send spoken notifications through the abstract TTS service, not directly through `inferenceClient`.

`tincan-server/inference_launch_test.go`

- Update tests so `configuredInferenceModels()` only uses the `macos` selections.
- If a side is non-`macos`, launch should fall back to a bundled default for that side until the local inference binary becomes optionally loadable.

`tincan-server/speech_services.go` or `tincan-server/speech/`

- New file or package for provider routing.
- Recommended responsibilities:
  - parse `<provider>/<model>` selectors
  - choose provider implementations
  - expose `SpeechToTextService` and `TextToSpeechService`
  - hold provider-specific and field-specific validation rules

`tincan-server/speech_services_test.go`

- New tests for:
  - provider routing
  - mixed local/remote mode
  - missing keychain credentials
  - invalid service config
  - unsupported provider selection

### Grok credential access

`tincan-server/go.mod`

- Add `github.com/keybase/go-keychain`.

`tincan-server/service_credentials_darwin.go`

- New darwin-only wrapper around `go-keychain`.
- Read generic password items using:
  - service: `com.tincanbot`
  - account: `GROK_API_KEY` or `GEMINI_API_KEY`
- Return explicit errors for:
  - key not found
  - keychain access denied
  - malformed value

`tincan-server/service_credentials_stub.go`

- New non-darwin stub so tests and non-mac builds fail cleanly instead of accidentally compiling macOS-only code paths.

### Grok TTS implementation

`tincan-server/grok_tts.go`

- New HTTP client for `POST /v1/tts`.
- Use `services.grok.base_url` with a default of `https://api.x.ai/v1`.
- Pull the API key from Keychain at request time or from a refreshable provider so the app can update Keychain without needing a server restart.
- Map config to xAI request fields:
  - selector suffix plus field context to internal Grok request behavior
  - for `tts_model = "grok/grok-tts-v1"`, map that internal selector to the correct Grok TTS request shape
  - `services.grok.tts.language`
  - `services.grok.tts.output_format`
- Translate HTTP failures into useful server-side errors.

`tincan-server/main.go`

- For the first cut, request Grok output as WAV, not MP3.
- Current server playback path expects WAV and converts WAV to PCMU for WebRTC.
- If you keep the playground’s MP3 output, you will need an extra decode/transcode step before `QueueSessionAudio()`.

`tincan-server/webrtc_audio.go`

- No change if Grok returns WAV.
- Only needs work if you want to accept MP3 or another compressed format from remote TTS providers.

### Optional local inference cleanup

`tincan-inference-macos/Sources/tincan-inference-macos/InferenceRuntimeConfiguration.swift`

- Optional improvement: make STT and TTS model loading independently optional.
- Today the binary wants both `--stt-model` and `--tts-model`.
- In mixed mode that means local inference may still load an unused local model.

`tincan-inference-macos/Sources/tincan-inference-macos/InferenceSocketServer.swift`

- Optional improvement: only initialize the services that are actually requested by config.
- Not required for the first Grok TTS integration, but useful for memory and startup time.

### App-facing settings APIs

`tincan-server/api/routes.go`

- Add `GET /api/v1/app-config`.
- Add `PATCH /api/v1/app-config` for non-secret settings:
  - `router_profile`
  - `stt_model`
  - `tts_model`
  - `services`
- Add a read-only secret status surface, either:
  - inside `GET /api/v1/app-config`, or
  - via `GET /api/v1/service-credentials/status`
- Return only booleans like `has_api_key`, never raw credentials.

`tincan-server/api/routes_test.go`

- Add tests for:
  - reading app config
  - patching app config
  - persisting `services`
  - secret presence/status response shape

### macOS app settings

`tincan-swift-app/tincan/TincanAPIClient.swift`

- Add DTOs and requests for the new app-config endpoints.
- Add models for:
  - `stt_model`
  - `tts_model`
  - `services`
  - credential presence/status

`tincan-swift-app/tincan/TincanAppModel.swift`

- Add a dedicated settings store for speech/service config instead of overloading `ServerConnectionStore`.
- Inject it into the macOS settings screen.

`tincan-swift-app/tincan/TincanRootView.swift`

- Add a macOS-only “Services” section in Settings.
- Show:
  - `stt_model`
  - `tts_model`
  - provider base URLs
  - provider-specific non-secret options
  - whether an API key is present
- Do not show this section on iOS.

`tincan-swift-app/tincan/MacKeychainService.swift`

- New macOS-only wrapper over `Security`.
- Write/update/delete generic password items under `com.tincanbot`.
- Support at least:
  - `GROK_API_KEY`
  - `GEMINI_API_KEY`
- The app can also use this wrapper to show simple “stored / missing” status without exposing the secret in UI.

`tincan-swift-app/tincan/TincanSpeechSettingsStore.swift`

- New store responsible for:
  - loading app-config from the server
  - saving app-config back to the server
  - writing API keys to Keychain locally
  - exposing validation errors and save state to SwiftUI

`tincan-swift-app/tincan/tincan.entitlements`

- Probably no change for the first pass.
- Revisit only if sandboxing or keychain access groups become necessary later.

## Things You’re Missing Right Now

- Grok TTS does not actually expose a `model` field in the request you pasted.
  - It exposes `voice_id`, `language`, and `output_format`.
  - So values like `grok/grok-tts-v1` need to be treated as internal provider selectors, not blindly forwarded as API fields.

- Grok STT and Gemini STT are not spec’d here yet.
  - We can build the internal abstraction now.
  - We cannot implement those remote STT providers cleanly until we have their request/response contracts.

- The current playback path expects WAV.
  - xAI’s example uses MP3.
  - If you want the fastest first implementation, switch Grok TTS to WAV in server requests.

- The current local inference binary still wants both a local STT model and a local TTS model at launch.
  - Mixed mode works, but it may still load an unused local model unless we make local inference loading optional.

- Secrets should not go through the server API.
  - The Mac app should write Keychain directly.
  - The server should only read Keychain and expose secret presence, not secret contents.

## Recommended Build Order

1. Add typed parsing for provider-qualified `stt_model` / `tts_model` and the `services` block.
2. Add speech service interfaces and keep the existing `macos` implementation behind them.
3. Add Keychain lookup on the server.
4. Add Grok TTS using WAV output.
5. Add app-config read/write APIs.
6. Add the macOS-only Settings UI and local Keychain write path.
7. After that, add more providers one by one.

## Difficulty

- Internal pluggable architecture only: medium.
- Grok TTS only, with Keychain and config support: medium.
- Full settings round-trip in the macOS app: medium.
- Grok/Gemini STT after that: medium to high, because the API contracts and audio format expectations are still missing.
