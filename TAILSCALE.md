# Tailscale Implementation Plan

> **Source of truth:** `TAILSCALE-CHAT.md` is the master product record. This file is the implementation plan derived from it. If this file conflicts with `TAILSCALE-CHAT.md`, fix this file.

## Goal

Add Tailscale-backed phone pairing for the Mac-hosted tincan server so the phone can connect by scanning a QR code instead of typing server details.

The Mac app owns the guided setup flow. The server owns tsnet setup/runtime and persisted connection state.

## Required User Experience

### macOS Connect Server Screen

The Connect server screen must be organized into two cards:

1. `Run on this computer`
2. `Connect to remote server`

Use the existing `TincanSettingsSectionCard` visual component.

### Run on this computer Card

This card contains:

- local bundled-server toggle
- local server endpoint
- `Connect phone` toggle
- Tailscale setup progress
- Tailscale approval URL, when approval is required
- `Open link` and `Copy link` buttons for the approval URL
- QR code once the Tailscale node URL is known
- server URL next to the QR code
- fallback warning if Tailscale is enabled in config but runtime is not active

When the user enables `Connect phone`, the Mac app must launch:

```text
tincan-server setup-tailscale --data-dir <app-support-data-dir>
```

The Mac app must monitor that setup process through stdout and stderr.

If setup emits a Tailscale approval URL, show:

```text
<spinner> Waiting for you to approve on Tailscale:
<login-link> <open link> <copy link>
```

When setup completes successfully:

- remove the approval/waiting UI
- show the QR code
- show the Tailscale server URL
- restart the main bundled server process

If the device was already approved, setup may complete without ever showing a login URL. The UI must handle this and go straight to QR code plus server URL.

### Connect to remote server Card

This card is for connecting this app instance to a server.

Replace separate scheme/host/port fields with one `server_url` input.

Examples:

```text
http://127.0.0.1:4490
https://tincan-akashs-macbook-air.tailnet-name.ts.net
```

When the user applies the URL:

1. call the server health endpoint
2. retry every 5 seconds for up to 60 seconds
3. keep the Apply button disabled and spinning while checking
4. save `server_url` only after the health check succeeds

This retry behavior is required because the Tailscale HTTPS endpoint may take time to fetch its certificate.

### iPhone Connect Server Screen

The phone Connect server screen must provide a `Scan QR code` option.

Scanning the Mac QR code applies the scanned URL as `server_url`.

After scanning or manually entering a URL, the phone must perform the same health-check retry behavior before saving:

- retry every 5 seconds
- stop after 60 seconds
- save `server_url` only after success

## Server Command Model

The server command model must be explicit:

```text
tincan-server run
tincan-server setup-tailscale
```

`tincan-server run` is the normal long-lived server.

`tincan-server setup-tailscale` is a separate bootstrap process used by the Mac app when the user enables `Connect phone`.

No default implicit startup path should remain once the CLI split is implemented.

## tsnet References

Use these Tailscale docs as the implementation reference:

- `https://tailscale.com/docs/features/tsnet#include-tsnet-in-your-program`
- `https://tailscale.com/docs/features/tsnet/how-to/create-basic-tsnet-app`

The runtime server should follow the documented `tsnet.Server` listener pattern:

1. create `tsnet.Server` with the derived hostname and persistent state directory
2. create a listener with `srv.Listen("tcp", addr)`
3. obtain `srv.LocalClient()`
4. when `addr == ":443"`, wrap the listener with `tls.NewListener` using `LocalClient.GetCertificate`
5. serve the existing tincan HTTP handler with `http.Serve`

Do not use `ListenTLS` for the planned implementation. The intended implementation follows the docs above.

## Tailscale Hostname

The tsnet hostname must be derived from the machine hostname:

```text
tincan-<machine-hostname>
```

Normalization rules:

- lowercase everything
- remove straight and curly apostrophes
- replace runs of non-alphanumeric characters with `-`
- trim leading/trailing `-`
- if the normalized machine name is empty, use `mac`

Example:

```text
Akash’s MacBook air
->
tincan-akashs-macbook-air
```

## Config Model

Use `config.json` as the source of truth. Do not use `UserDefaults` as the source of truth for these values.

The app passes `--data-dir <AppPaths.appSupportDirectory.path>` to `tincan-server`. The config file path for both the Swift app and Go server is:

```text
<data-dir>/config/config.json
```

In Swift, this is exposed as `AppPaths.generatedAppConfigURL`.

Required fields:

```json
{
  "server_url": "https://remote-tincan-server.example.com",
  "tailscale": {
    "enabled": true,
    "node_url": "https://tincan-akashs-macbook-air.tailnet-name.ts.net"
  }
}
```

Field meanings:

- `server_url`: server this app instance should connect to on startup. This is used by iOS and by the Mac `Connect to remote server` card. It is not the URL where the Mac-hosted bundled server advertises itself.
- `tailscale.enabled`: user intent for Mac-hosted phone connectivity
- `tailscale.node_url`: last known Tailscale HTTPS URL where this Mac-hosted bundled server is reachable

Validation:

- `server_url` must be a full `http` or `https` URL
- `tailscale.node_url` must be a full `https` URL
- `tailscale.node_url` should not include an explicit port
- trim whitespace before storing

When disabling `Connect phone`:

- set `tailscale.enabled = false`
- keep `tailscale.node_url` as the last known value
- restart `tincan-server run`

No legacy or fallback config implementations should be kept as parallel behavior.

## setup-tailscale Behavior

`tincan-server setup-tailscale` must:

1. resolve the data directory
2. derive the Tailscale hostname
3. create or reuse the tsnet state directory
4. start a tsnet listener on port `80` using the documented `srv.Listen("tcp", ":80")` pattern
5. surface login URLs through stdout/stderr
6. wait until the node is approved or already approved
7. fetch `srv.CertDomains()`
8. pick the domain containing `.ts.net`
9. strip a trailing `.` before using it
10. construct `https://<fqdn>`
11. persist:
    - `tailscale.enabled = true`
    - `tailscale.node_url = "https://<fqdn>"`
12. emit stable machine-readable output
13. exit successfully

The command must handle both approval flows:

- first-time setup emits a login URL, then approval completes
- already-approved setup emits no login URL and completes directly

### setup-tailscale Output Contract

The Mac app may show raw log text for diagnostics, but UI logic should use stable app-owned markers from stdout/stderr.

Required markers:

```text
TINCAN_TAILSCALE_STATUS=starting
TINCAN_TAILSCALE_STATUS=needs_login
TINCAN_TAILSCALE_AUTH_URL=https://login.tailscale.com/a/...
TINCAN_TAILSCALE_STATUS=running
TINCAN_TAILSCALE_NODE=https://tincan-....ts.net
TINCAN_TAILSCALE_ERROR=<message>
```

The setup command should still allow Tailscale's own logs to appear, because those logs are useful for troubleshooting.

## run Behavior

`tincan-server run` must:

1. start the local HTTP server as today
2. read `config.json`
3. run local-only unless `--tailscale` is passed
4. if `--tailscale` is passed, attempt embedded tsnet runtime on port `443` using the documented `srv.Listen("tcp", ":443")` plus `tls.NewListener(..., GetCertificate: lc.GetCertificate)` pattern
5. if Tailscale runtime starts successfully:
   - serve the tincan API over Tailscale HTTPS
   - fetch `srv.CertDomains()`
   - pick the `.ts.net` domain
   - strip a trailing `.`
   - refresh `tailscale.node_url` in `config.json` if it changed
6. if Tailscale runtime fails:
   - fail this `tincan-server run --tailscale` process
   - do not silently continue as local-only inside the server process
   - return a non-zero startup failure to the Mac app
   - the Mac app may then start a new `tincan-server run` process without `--tailscale`
   - the second local-only run still reads config and exposes that Tailscale is configured but inactive

There is no `--no-tailscale` flag. Tailscale is opt-in through `--tailscale`.

## Runtime Tailscale Signal

The Mac app needs to distinguish:

- Tailscale enabled in config
- Tailscale active in the current server process because it was started with `--tailscale`
- Tailscale configured but inactive because the Mac app fell back to a local-only `run`

Expose this through `/healthz`, because the app already uses that endpoint.

Health response shape:

```json
{
  "status": "ok",
  "agent_profile_count": 3,
  "tailscale": {
    "enabled": true,
    "active": false,
    "node_url": "https://tincan-akashs-macbook-air.tailnet-name.ts.net",
    "message": "Could not start with Tailscale. Please ensure Tailscale is running."
  }
}
```

This is the runtime indicator the Mac settings UI should use for fallback warnings.

## QR Payload

The QR code shown on Mac should encode the server URL directly:

```text
https://tincan-akashs-macbook-air.tailnet-name.ts.net
```

The scanned QR payload must be saved as `server_url` only after the health-check retry succeeds.

For the Mac `Run on this computer` card, the QR payload comes from `tailscale.node_url`.

## Swift Ownership

### Remove From `ServerConnectionStore`

`ServerConnectionStore` should no longer own:

- `connectPhoneEnabled`
- separate persisted scheme/host/port as the primary model

### Keep In `ServerConnectionStore`

`ServerConnectionStore` can own:

- current effective server URL
- health-check state
- QR/manual URL application
- connection revision notifications

### Add Local Config Store

Add a dedicated Swift local config store for `config.json`.

It owns:

- `server_url`
- `tailscale.enabled`
- `tailscale.node_url`

Follow the load/save style used by `TincanSpeechSettingsStore.swift`, but keep this store separate from speech settings.

### Add Setup Process Monitor

Add a Mac-only setup process monitor responsible for:

- launching `tincan-server setup-tailscale`
- reading stdout and stderr without blocking
- parsing stable markers
- storing transient setup state:
  - setup running
  - approval URL
  - setup error
  - completed node URL

Do not model setup progress by polling a status file.

### Add Runtime Health State

Runtime Tailscale active/fallback state should come from `/healthz`, not from a status file.

The Mac settings UI renders from:

- persisted config intent
- transient setup process state
- runtime health state

## Detailed Implementation Checklist

Work through this in order. Each checkbox is intended to be a small, reviewable change.

Progress note, 2026-04-24:

- `setup-tailscale` now waits for the node URL before persisting success, and the Mac app launches that setup command when `Connect phone` is enabled.
- The Mac setup UI now consumes stdout/stderr markers directly instead of polling the removed status file.
- The Connect server settings screen is now split into the planned cards and uses one direct `server_url` input for remote connections.
- QR payloads are direct HTTPS node URLs. On iOS, scanned payloads are staged into the URL draft and saved only after health retry succeeds.
- `connectPhoneEnabled` is now backed by `config/config.json` under `tailscale.enabled`; a dedicated local config store is still deferred, so `ServerConnectionStore` is temporarily doing this persistence work.
- Enabling `Connect phone` now uses transient setup intent. The toggle is only persisted to `tailscale.enabled` after `setup-tailscale` exits successfully and has written the bootstrap result.
- The Mac app writes `setup-tailscale` stdout/stderr to `logs/tincan-server-setup-tailscale.log`, hides the duplicate `Tailscale: starting` row during setup, and shows only the spinner progress message for starting/running states.
- Before launching setup, the Mac app reclaims port `80` only from an existing matching `tincan-server setup-tailscale` process for the bundled executable.
- Empty `server_url` now means the remote server card is disabled/unconfigured; the remote URL draft stays empty instead of showing the Mac's local share host.
- The `Run on this computer` toggle now sits on the card title row, and the redundant `Bundled server` label has been removed.
- The local address row is no longer shown in the settings card; local mode now displays a short status sentence instead.

### Phase 1: Go Server CLI and Config

#### `tincan-server/main.go`

- [x] Replace the current implicit default startup with a command dispatcher.
- [x] Support exactly these subcommands:
  - `run`
  - `setup-tailscale`
- [x] Return a usage error for missing or unknown subcommands.
- [x] Move the current long-lived server startup body into a `runTincanServerCommand(ctx, args)` function in `run_command.go`.
- [x] Keep `setup-tailscale` dispatch pointed at `runSetupTailscaleCommand(ctx, args)`.
- [x] Remove top-level parsing of long-lived server flags from `main()`.

#### `tincan-server/run_command.go`

- [x] Create this file.
- [x] Move current server flags into `runTincanServerCommand`:
  - `--data-dir`
  - `--log-file`
  - `--port`
  - `--tailscale`
- [x] Do not include `--tailscale-status-file`; status-file reporting is not part of the final design.
- [x] Start the local HTTP server exactly as today.
- [x] Read `config.json` through `AppConfigStore`.
- [x] Attempt embedded Tailscale runtime only when `--tailscale` is present.
- [x] If `--tailscale` is present and Tailscale startup/listen fails, exit this server process with an error; do not continue local-only inside the same process.
- [x] Let the Mac app own the fallback restart by launching a fresh `tincan-server run` process without `--tailscale`.
- [x] Store runtime Tailscale state on the server struct for `/healthz`.
- [x] Refresh `tailscale.node_url` when Tailscale runtime starts and discovers a different `.ts.net` URL.
- [x] Add or update command dispatch tests next to this change:
  - missing subcommand
  - unknown subcommand
  - `run`
  - `setup-tailscale`
  - `run --tailscale` argument dispatch
- [ ] Add startup integration coverage for `run --tailscale` returning an error when Tailscale startup/listen fails.

#### `tincan-server/config/app_config.go`

- [x] Add fields to `AppConfigStore`:
  - `serverURL string`
  - `tailscale AppConfigTailscale`
- [x] Add `AppConfigTailscale` with fields:
  - `Enabled bool json:"enabled,omitempty"`
  - `NodeURL string json:"node_url,omitempty"`
- [x] Add fields to `AppConfigSnapshot`:
  - `ServerURL string` with JSON key `server_url`
  - `Tailscale AppConfigTailscale` with JSON key `tailscale`
- [x] Update `decodeAppConfig` to parse `server_url` and the nested `tailscale` object.
- [x] Add `ServerURL() (string, bool)`.
- [x] Add `TailscaleEnabled() bool`.
- [x] Add `TailscaleNodeURL() (string, bool)`.
- [x] Add `SetServerURL(value string) error`.
- [x] Add `SetTailscaleEnabled(value bool) error`.
- [x] Add `SetTailscaleNodeURL(value string) error`.
- [x] Add `SetTailscaleBootstrapResult(nodeURL string) error` that writes:
  - `tailscale.enabled = true`
  - `tailscale.node_url = nodeURL`
- [x] Add `SetTailscaleDisabled() error` that writes:
  - `tailscale.enabled = false`
  - preserves `tailscale.node_url`
- [x] Extend `ApplyPatch` for:
  - `server_url`
  - `tailscale`
- [x] Validate `server_url` as a full `http` or `https` URL with a host.
- [x] Validate `tailscale.node_url` as a full `https` URL with a host and no explicit port.
- [x] Trim whitespace before storing URL fields.
- [x] Preserve unrelated keys when writing.
- [x] Add or update config tests next to this change:
  - `TestAppConfigStoreLoadsServerURL`
  - `TestAppConfigStoreSetServerURLWritesConfig`
  - `TestAppConfigStoreRejectsInvalidServerURL`
  - `TestAppConfigStoreLoadsTailscaleFields`
  - `TestAppConfigStoreSetTailscaleBootstrapResult`
  - `TestAppConfigStoreSetTailscaleDisabledKeepsNodeURL`
  - `TestAppConfigStoreRejectsInvalidTailscaleNodeURL`
  - `TestAppConfigStoreApplyPatchUpdatesTailscaleFields`
  - `TestAppConfigStoreApplyPatchRejectsUnknownTailscaleRelatedFields`

#### `tincan-server/config/store_test.go`

- [x] Add a test that missing optional fields load as empty/false.
- [x] Add a test that `server_url` loads from `config/config.json`.
- [x] Add a test that `SetServerURL("https://example.ts.net")` writes `server_url`.
- [x] Add a test that invalid `server_url` values are rejected:
  - empty host
  - unsupported scheme
  - relative string
- [x] Add a test that `tailscale.enabled` loads from `config/config.json`.
- [x] Add a test that `SetTailscaleBootstrapResult("https://tincan-host.tail.ts.net")` writes both Tailscale fields.
- [x] Add a test that `SetTailscaleDisabled()` sets `tailscale.enabled = false` without deleting `tailscale.node_url`.
- [x] Add a test that `tailscale.node_url` rejects non-HTTPS URLs.
- [x] Add a test that `tailscale.node_url` rejects explicit ports.
- [x] Add a test that patching unknown fields still fails.

### Phase 2: Go Tailscale Setup and Runtime

#### `tincan-server/tailscale_runtime.go`

- [x] Remove status-file reporter types and JSON status-file writing.
- [x] Keep hostname normalization in this file and reuse it from setup/runtime.
- [x] Add `selectTailscaleNodeURL(domains ...[]string) (string, error)`.
- [x] Make `selectTailscaleNodeURL`:
  - trim whitespace
  - strip trailing `.`
  - select a host containing `.ts.net`
  - return `https://<host>`
  - error when no usable domain exists
- [x] Add a runtime state type used by `/healthz`, for example:
  - `Configured bool`
  - `Active bool`
  - `NodeURL string`
  - `Message string`
- [x] Start tsnet runtime on `:443` only.
- [x] Use the documented listener pattern:
  - `ln, err := srv.Listen("tcp", ":443")`
  - `lc, err := srv.LocalClient()`
  - wrap with `tls.NewListener(ln, &tls.Config{GetCertificate: lc.GetCertificate})`
  - serve the existing tincan mux over the wrapped listener
- [x] On successful runtime startup, mark runtime state active.
- [x] On startup/listen failure, mark runtime state inactive with message:
  - `Could not start with Tailscale. Please ensure Tailscale is running.`
- [x] When `--tailscale` startup/listen fails, return an error and let the process exit non-zero.
- [x] Add or update Tailscale helper tests next to this change:
  - `TestNormalizeTailscaleHostname`
  - `TestSelectTailscaleNodeURLSelectsTSNetDomain`
  - `TestSelectTailscaleNodeURLStripsTrailingDot`
  - `TestSelectTailscaleNodeURLIgnoresNonTSNetDomains`
  - `TestSelectTailscaleNodeURLErrorsWithoutTSNetDomain`

#### `tincan-server/setup_tailscale.go`

- [x] Keep this command separate from the main server runtime.
- [x] Parse `--data-dir`.
- [x] Remove `--tailscale-status-file`.
- [x] Emit `TINCAN_TAILSCALE_STATUS=starting` before tsnet startup.
- [x] Start the tsnet setup listener with `srv.Listen("tcp", ":80")`; do not use `443` in `setup-tailscale`.
- [x] Use `tsnet.Server.UserLogf` to detect `https://login.tailscale.com/a/...`.
- [x] When a login URL is detected, emit:
  - `TINCAN_TAILSCALE_STATUS=needs_login`
  - `TINCAN_TAILSCALE_AUTH_URL=<url>`
- [x] After the setup listener is running and the node is approved, call `srv.CertDomains()`.
- [x] Resolve the canonical node URL through `selectTailscaleNodeURL`.
- [x] Persist the setup result through `AppConfigStore.SetTailscaleBootstrapResult(nodeURL)`.
- [x] Emit `TINCAN_TAILSCALE_STATUS=running`.
- [x] Emit `TINCAN_TAILSCALE_NODE=<nodeURL>`.
- [x] Exit successfully after emitting the node URL.
- [x] On failure, emit `TINCAN_TAILSCALE_ERROR=<message>` before returning the error.
- [ ] Add marker-formatting tests next to this change if marker formatting is factored into helpers.

#### `tincan-server/tailscale_runtime_test.go`

- [x] Create or extend this test file.
- [x] Test hostname normalization:
  - `Akash’s MacBook air` becomes `tincan-akashs-macbook-air`
  - punctuation runs collapse into one hyphen
  - empty input becomes `tincan-mac`
- [x] Test domain selection:
  - selects `foo.ts.net`
  - strips trailing `.`
  - ignores non-`.ts.net` domains
  - errors when no `.ts.net` domain exists
- [ ] Test marker formatting helpers if marker output is factored into helper functions.

#### `tincan-server/main.go`

- [x] Add Tailscale runtime state to the server struct.
- [x] Update `handleHealth` to include:
  - `tailscale.enabled`
  - `tailscale.active`
  - `tailscale.node_url`
  - `tailscale.message`
- [x] Ensure health remains `200 OK` when Tailscale fails but local server is running.
- [x] Add health response tests next to this change:
  - disabled Tailscale
  - active Tailscale
  - configured-but-inactive fallback

### Phase 3: Swift Config and Connection Model

#### `tincan-swift-app/tincan/TincanLocalServerConfigStore.swift`

- [ ] Create this file.
- [ ] Load from `AppPaths.generatedAppConfigURL`.
- [ ] Preserve unrelated JSON keys when saving.
- [ ] Expose published state:
  - `serverURL: URL?`
  - `tailscaleEnabled: Bool` mapped to `tailscale.enabled`
  - `tailscaleNodeURL: URL?` mapped to `tailscale.node_url`
- [ ] Add `reload()`.
- [ ] Add `setServerURL(_ url: URL) throws`.
- [ ] Add `setTailscaleEnabled(_ enabled: Bool) throws`.
- [ ] Add `setTailscaleNodeURL(_ url: URL) throws`.
- [ ] Add `setTailscaleBootstrapResult(_ url: URL) throws`.
- [ ] Validate `serverURL` as `http` or `https` with host.
- [ ] Validate `tailscaleNodeURL` as `https` with host and no explicit port.
- [ ] Add config store tests next to this change:
  - `loadsEmptyConfig`
  - `loadsServerURL`
  - `savesServerURL`
  - `savesTailscaleEnabled`
  - `savesTailscaleNodeURL`
  - `bootstrapResultEnablesTailscaleAndStoresNodeURL`
  - `disablingTailscaleKeepsNodeURL`
  - `preservesUnrelatedConfigKeys`
  - `rejectsInvalidServerURL`
  - `rejectsInvalidTailscaleNodeURL`

#### `tincan-swift-app/tincanTests/TincanLocalServerConfigStoreTests.swift`

- [ ] Create this test file.
- [ ] Test loading empty config.
- [ ] Test loading existing `server_url`.
- [ ] Test saving `server_url`.
- [ ] Test saving `tailscale.enabled`.
- [ ] Test saving `tailscale.node_url`.
- [ ] Test bootstrap result writes `tailscale.enabled = true` and `tailscale.node_url`.
- [ ] Test disabling keeps `tailscale.node_url`.
- [ ] Test unrelated config keys are preserved.
- [ ] Test invalid `server_url` is rejected.
- [ ] Test invalid `tailscale.node_url` is rejected.

#### `tincan-swift-app/tincan/TincanServerSettings.swift`

- [x] Replace separate persisted scheme/host/port as the primary model with one `serverURL`.
- [ ] Remove `connectPhoneEnabled` from this store.
- [x] Remove `server_connect_phone_enabled` UserDefaults usage.
- [ ] Keep `connectionRevision` so workspace/call models refresh when the URL changes.
- [ ] Keep `serverBaseURL`, `liveUpdatesURL`, and `liveUpdatesOriginHeaderValue` computed from `serverURL`.
- [x] Add a draft URL string used by settings UI.
- [x] Add `applyServerURLDraft()` that validates URL syntax but does not save until health succeeds.
- [ ] Implement health retry through injected dependencies:
  - `healthChecker: (URL) async throws -> HealthResponse`
  - `retryPolicy` containing max duration, interval, and max attempts
  - production policy: 5 second interval, 60 second maximum duration
  - unit-test policy: one attempt, zero delay
- [x] Add health-check retry behavior:
  - request `/healthz`
  - retry every 5 seconds
  - stop after 60 seconds
  - save only after success
- [x] Expose Apply/checking state for the UI.
- [x] Make QR scan apply direct URL payloads only.
- [ ] Add server connection tests next to this change:
  - direct URL parsing
  - invalid URL rejection
  - health-success-before-save
  - health-timeout-does-not-save
  - HTTPS-to-WSS live updates URL
  - connection revision increment after successful save

#### `tincan-swift-app/tincanTests/ServerConnectionStoreTests.swift`

- [ ] Replace scheme/host/port persistence tests with `server_url` tests.
- [x] Test valid direct URL parsing.
- [ ] Test invalid direct URL parsing.
- [ ] Test save-after-health-success using an injected fake health checker; do not make a real network call.
- [ ] Test no-save-after-health-timeout using a one-attempt retry policy with a failing fake health checker.
- [x] Test websocket URL derives `wss` from HTTPS.
- [ ] Test connection revision increments after successful save.

#### `tincan-swift-app/tincan/TincanAPIClient.swift`

- [ ] Extend `HealthResponse` with nested `TailscaleHealth`.
- [ ] Decode:
  - `tailscale.enabled`
  - `tailscale.active`
  - `tailscale.node_url`
  - `tailscale.message`
- [ ] Require the final health response to include the nested `tailscale` object.
- [ ] Add health decoding tests next to this change:
  - `tailscale.enabled = false`
  - active Tailscale state
  - inactive fallback message

### Phase 4: Swift Tailscale Setup Monitor and Server Launch

#### `tincan-swift-app/tincan/MacTailscaleServerController.swift`

- [x] Rewrite this from status-file polling to setup-process monitoring.
- [x] Add setup state:
  - idle
  - starting
  - needs login with auth URL
  - running/completed with node URL
  - failed with message
- [x] Launch `tincan-server setup-tailscale --data-dir <AppPaths.appSupportDirectory.path>`.
- [x] Capture stdout and stderr with pipes.
- [x] Parse stable markers:
  - `TINCAN_TAILSCALE_STATUS=starting`
  - `TINCAN_TAILSCALE_STATUS=needs_login`
  - `TINCAN_TAILSCALE_AUTH_URL=...`
  - `TINCAN_TAILSCALE_STATUS=running`
  - `TINCAN_TAILSCALE_NODE=...`
  - `TINCAN_TAILSCALE_ERROR=...`
- [x] Expose `authURL`.
- [x] Expose `nodeURL`.
- [x] Expose `progressMessage`.
- [x] Expose `availabilityMessage`.
- [x] Stop any existing setup process before launching a new one.
- [x] Write setup stdout/stderr to `AppPaths.tincanServerSetupTailscaleLogURL`.
- [x] Before setup launch, reclaim port `80` from an existing matching `tincan-server setup-tailscale` process.
- [ ] On successful node URL, ask `TincanLocalServerConfigStore` to reload.
- [x] Add marker parser tests next to this change:
  - auth URL marker parsing
  - node URL marker parsing
  - error marker parsing
  - starting status progress text
  - setup command arguments
  - setup port reclaim target matching

#### `tincan-swift-app/tincanTests/MacTailscaleServerControllerTests.swift`

- [x] Create or extend this test file for pure marker parsing.
- [x] Test auth URL marker parsing.
- [x] Test node URL marker parsing.
- [x] Test error marker parsing.
- [x] Test starting status uses the single progress message and suppresses the summary row.
- [x] Test setup command arguments use `setup-tailscale --data-dir <dir>` with no extra port override.
- [x] Test port reclaim only targets the same bundled executable running `setup-tailscale`.

#### `tincan-swift-app/tincan/MacBundledTincanServerController.swift`

- [x] Launch `tincan-server run`, not bare `tincan-server`.
- [x] Remove `--tailscale-status-file`.
- [x] Keep `--data-dir`.
- [x] Keep `--port`.
- [x] Pass `--tailscale` only when local config says Tailscale is enabled.
- [x] If launching with `--tailscale` fails or exits before readiness, restart with the same base arguments without `--tailscale`.
- [x] Treat that second launch as a new process; do not expect server-side fallback behavior.
- [x] Update tests or helper assertions that inspect process arguments.
- [x] Keep local server readiness check against loopback `/healthz`.
- [x] Add bundled server argument tests next to this change:
  - includes `run`
  - includes `--tailscale` when enabled
  - omits `--tailscale` when disabled
  - omits `--tailscale-status-file`

#### `tincan-swift-app/tincan/TincanAppModel.swift`

- [ ] Add `localServerConfig = TincanLocalServerConfigStore()`.
- [ ] Pass the local config store into `ServerConnectionStore`.
- [ ] Pass the local config store into `MacTailscaleServerController`.
- [x] Replace `serverSettings.$connectPhoneEnabled` subscription with config-backed Tailscale state.
- [x] Add transient `connectPhoneSetupRequested` state so the UI toggle can be on during setup without persisting `tailscale.enabled`.
- [x] When `Connect phone` is enabled:
  - launch setup process
  - wait for successful node URL
  - persist `tailscale.enabled` only after successful setup
  - restart bundled server
  - refresh `/healthz`
- [x] When `Connect phone` is disabled:
  - write `tailscale.enabled = false`
  - restart bundled server without `--tailscale`
  - clear transient setup state
- [x] On app startup, start bundled server according to `tailscale.enabled` from config.

#### `tincan-swift-app/tincan/AppPaths.swift`

- [ ] Remove `tincanServerTailscaleStatusURL` after status-file polling is removed.
- [ ] Keep `generatedAppConfigURL` as the config store path.
- [x] Add `tincanServerSetupTailscaleLogURL`.

### Phase 5: Swift Settings UI

#### `tincan-swift-app/tincan/TincanRootView.swift`

- [x] Split macOS Connect server UI into two `TincanSettingsSectionCard` cards:
  - `Run on this computer`
  - `Connect to remote server`
- [x] In `Run on this computer`, keep the bundled server toggle.
- [x] In `Run on this computer`, add `Connect phone` bound to config-backed `tailscale.enabled`.
- [x] On enabling `Connect phone`, call the setup flow from `TincanAppModel`.
- [x] While setup is starting, show only the spinner/progress row and suppress the duplicate `Tailscale: starting` summary row.
- [x] If auth URL exists, show:
  - waiting text
  - approval URL
  - `Open link`
  - `Copy link`
- [x] After node URL exists, show:
  - QR code encoding direct node URL
  - text value of node URL
- [ ] Show runtime fallback warning from decoded `/healthz` Tailscale state.
- [x] In `Connect to remote server`, replace scheme picker, host field, and port field with one URL field.
- [x] Disable the Apply button while health retry is running.
- [x] Show spinner/progress state while applying URL.
- [x] On iOS, keep the QR scanner button.
- [x] On iOS, make scanner payload populate the direct URL draft and run the health retry before saving.
- [x] Remove UI paths that generate `tincan://connect?...` payloads.

#### `tincan-swift-app/tincan/TincanDesignSystem.swift`

- [ ] Reuse `TincanSettingsSectionCard`; only modify this file if spacing or layout primitives are missing.
- [ ] Do not add nested cards.

#### `tincan-swift-app/tincanTests` view-model tests

- [ ] Add tests for any extracted formatting helpers:
  - setup waiting text
  - fallback warning text
  - direct QR payload string
- [ ] Leave Xcode UI automation coverage to the pending/deferred UI automation task list below.

### Phase 6: Remove Prototype Artifacts

#### `tincan-server/tailscale_runtime.go`

- [ ] Confirm no status-file writing remains.
- [ ] Confirm no status-file JSON structs remain unless used for health response.

#### `tincan-swift-app/tincan/MacTailscaleServerController.swift`

- [ ] Confirm no status-file polling remains.

#### `tincan-swift-app/tincan/TincanServerSettings.swift`

- [ ] Confirm no `connectPhoneEnabled` remains.
- [ ] Confirm no `server_connect_phone_enabled` key remains.
- [ ] Confirm scheme/host/port are not the primary persisted connection model.

#### `tincan-swift-app/tincan/AppPaths.swift`

- [ ] Confirm `tincanServerTailscaleStatusURL` is removed.

#### `tshello/`

- [ ] Leave this playground unchanged unless it blocks builds or tests.
- [ ] Do not make app runtime depend on `tshello`.

### Phase 7: Pending Xcode UI Automation Tests

- [ ] Pending/deferred: Add UI automation coverage for macOS Connect server two-card layout.
- [ ] Pending/deferred: Add UI automation coverage for Tailscale approval URL display.
- [ ] Pending/deferred: Add UI automation coverage for QR scanner/apply flow on iOS.
- [ ] Pending/deferred: Do not run Xcode UI automation tests for this implementation pass unless explicitly requested.

### Phase 8: Verification Checklist

#### Go

- [ ] Run:

```bash
cd tincan-server
go test ./...
```

- [ ] Confirm `tincan-server run --data-dir <dir> --port 4490` starts local server without Tailscale.
- [ ] Confirm `tincan-server run --data-dir <dir> --port 4490 --tailscale` attempts Tailscale runtime on port `443`.
- [ ] Confirm `tincan-server setup-tailscale --data-dir <dir>` emits stable markers.

#### Swift/macOS

- [ ] Run:

```bash
bin/build-and-run mac
```

- [ ] Confirm the app launches the bundled server with `run`.
- [ ] Confirm the settings screen shows two cards.
- [ ] Confirm enabling `Connect phone` launches setup, not the main server with status-file polling.

#### Manual Tailscale

- [ ] Enable `Connect phone`.
- [ ] Confirm approval URL appears if Tailscale requires login.
- [ ] Use `Open link` and approve the node.
- [ ] Confirm the setup UI transitions to QR code plus URL.
- [ ] Confirm `config.json` contains:
  - `tailscale.enabled: true`
  - `tailscale.node_url: https://...ts.net`
- [ ] Confirm main server restarts after setup.
- [ ] Confirm `/healthz` reports:
  - `tailscale.enabled = true`
  - `tailscale.active = true`
  - `tailscale.node_url = https://...ts.net`
- [ ] Scan the QR code on iPhone.
- [ ] Confirm iPhone saves `server_url` only after health succeeds.

## Current Implementation Gaps

These are the known gaps between the current code and this plan:

- A dedicated `TincanLocalServerConfigStore` has not been split out yet; `ServerConnectionStore` is temporarily handling local config persistence for `server_url` and `tailscale`.
- Runtime fallback warning UI still needs to consume decoded nested `/healthz.tailscale` state.
- Some Swift config and health behavior still needs deeper unit coverage around injected health retries and config-store boundaries.
