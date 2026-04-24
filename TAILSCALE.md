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

Required fields:

```json
{
  "server_url": "https://remote-tincan-server.example.com",
  "tailscale_enabled": true,
  "tailscale_node_url": "https://tincan-akashs-macbook-air.tailnet-name.ts.net"
}
```

Field meanings:

- `server_url`: server this app instance should connect to on startup. This is used by iOS and by the Mac `Connect to remote server` card. It is not the URL where the Mac-hosted bundled server advertises itself.
- `tailscale_enabled`: user intent for Mac-hosted phone connectivity
- `tailscale_node_url`: last known Tailscale HTTPS URL where this Mac-hosted bundled server is reachable

Validation:

- `server_url` must be a full `http` or `https` URL
- `tailscale_node_url` must be a full `https` URL
- `tailscale_node_url` should not include an explicit port
- trim whitespace before storing

When disabling `Connect phone`:

- set `tailscale_enabled = false`
- keep `tailscale_node_url` as the last known value
- restart `tincan-server run`

No legacy or fallback config implementations should be kept as parallel behavior.

## setup-tailscale Behavior

`tincan-server setup-tailscale` must:

1. resolve the data directory
2. derive the Tailscale hostname
3. create or reuse the tsnet state directory
4. start the tsnet setup server on port `80`
5. call `srv.Up(ctx)`
6. surface login URLs through stdout/stderr
7. wait until the node is approved or already approved
8. fetch `srv.CertDomains()`
9. pick the domain containing `.ts.net`
10. strip a trailing `.` before using it
11. construct `https://<fqdn>`
12. persist:
    - `tailscale_enabled = true`
    - `tailscale_node_url = "https://<fqdn>"`
13. emit stable machine-readable output
14. exit successfully

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
4. if `--tailscale` is passed, attempt embedded tsnet runtime on port `443`
5. if Tailscale runtime starts successfully:
   - serve the tincan API over Tailscale HTTPS
   - fetch `srv.CertDomains()`
   - pick the `.ts.net` domain
   - strip a trailing `.`
   - refresh `tailscale_node_url` in `config.json` if it changed
6. if Tailscale runtime fails:
   - return startup failure to the Mac app
   - the Mac app restarts `tincan-server run` without `--tailscale`
   - the fallback run still reads config and exposes that Tailscale is configured but inactive

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
    "configured": true,
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

For the Mac `Run on this computer` card, the QR payload comes from `tailscale_node_url`.

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
- `tailscale_enabled`
- `tailscale_node_url`

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

### Phase 1: Go Server CLI and Config

#### `tincan-server/main.go`

- [ ] Replace the current implicit default startup with a command dispatcher.
- [ ] Support exactly these subcommands:
  - `run`
  - `setup-tailscale`
- [ ] Return a usage error for missing or unknown subcommands.
- [ ] Move the current long-lived server startup body into a `runTincanServerCommand(ctx, args)` function in `run_command.go`.
- [ ] Keep `setup-tailscale` dispatch pointed at `runSetupTailscaleCommand(ctx, args)`.
- [ ] Remove top-level parsing of long-lived server flags from `main()`.

#### `tincan-server/run_command.go`

- [ ] Create this file.
- [ ] Move current server flags into `runTincanServerCommand`:
  - `--data-dir`
  - `--log-file`
  - `--port`
  - `--tailscale`
- [ ] Do not include `--tailscale-status-file`; status-file reporting is not part of the final design.
- [ ] Start the local HTTP server exactly as today.
- [ ] Read `config.json` through `AppConfigStore`.
- [ ] Attempt embedded Tailscale runtime only when `--tailscale` is present.
- [ ] Return startup failure if `--tailscale` is present and Tailscale startup fails; the Mac app owns the fallback restart without `--tailscale`.
- [ ] Store runtime Tailscale state on the server struct for `/healthz`.
- [ ] Refresh `tailscale_node_url` when Tailscale runtime starts and discovers a different `.ts.net` URL.
- [ ] Add or update command dispatch tests next to this change:
  - missing subcommand
  - unknown subcommand
  - `run`
  - `setup-tailscale`
  - `run --tailscale`

#### `tincan-server/config/app_config.go`

- [ ] Add fields to `AppConfigStore`:
  - `serverURL string`
  - `tailscaleEnabled bool`
  - `tailscaleNodeURL string`
- [ ] Add fields to `AppConfigSnapshot`:
  - `ServerURL string json:"server_url,omitempty"`
  - `TailscaleEnabled bool json:"tailscale_enabled,omitempty"`
  - `TailscaleNodeURL string json:"tailscale_node_url,omitempty"`
- [ ] Update `decodeAppConfig` to parse the three fields.
- [ ] Add `ServerURL() (string, bool)`.
- [ ] Add `TailscaleEnabled() bool`.
- [ ] Add `TailscaleNodeURL() (string, bool)`.
- [ ] Add `SetServerURL(value string) error`.
- [ ] Add `SetTailscaleEnabled(value bool) error`.
- [ ] Add `SetTailscaleNodeURL(value string) error`.
- [ ] Add `SetTailscaleBootstrapResult(nodeURL string) error` that writes:
  - `tailscale_enabled = true`
  - `tailscale_node_url = nodeURL`
- [ ] Add `SetTailscaleDisabled() error` that writes:
  - `tailscale_enabled = false`
  - preserves `tailscale_node_url`
- [ ] Extend `ApplyPatch` for:
  - `server_url`
  - `tailscale_enabled`
  - `tailscale_node_url`
- [ ] Validate `server_url` as a full `http` or `https` URL with a host.
- [ ] Validate `tailscale_node_url` as a full `https` URL with a host and no explicit port.
- [ ] Trim whitespace before storing URL fields.
- [ ] Preserve unrelated keys when writing.
- [ ] Add or update config tests next to this change:
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

- [ ] Add a test that missing optional fields load as empty/false.
- [ ] Add a test that `server_url` loads from `config/config.json`.
- [ ] Add a test that `SetServerURL("https://example.ts.net")` writes `server_url`.
- [ ] Add a test that invalid `server_url` values are rejected:
  - empty host
  - unsupported scheme
  - relative string
- [ ] Add a test that `tailscale_enabled` loads from `config/config.json`.
- [ ] Add a test that `SetTailscaleBootstrapResult("https://tincan-host.tail.ts.net")` writes both Tailscale fields.
- [ ] Add a test that `SetTailscaleDisabled()` sets `tailscale_enabled = false` without deleting `tailscale_node_url`.
- [ ] Add a test that `tailscale_node_url` rejects non-HTTPS URLs.
- [ ] Add a test that `tailscale_node_url` rejects explicit ports.
- [ ] Add a test that patching unknown fields still fails.

### Phase 2: Go Tailscale Setup and Runtime

#### `tincan-server/tailscale_runtime.go`

- [ ] Remove status-file reporter types and JSON status-file writing.
- [ ] Keep hostname normalization in this file and reuse it from setup/runtime.
- [ ] Add `selectTailscaleNodeURL(domains ...[]string) (string, error)`.
- [ ] Make `selectTailscaleNodeURL`:
  - trim whitespace
  - strip trailing `.`
  - select a host containing `.ts.net`
  - return `https://<host>`
  - error when no usable domain exists
- [ ] Add a runtime state type used by `/healthz`, for example:
  - `Configured bool`
  - `Active bool`
  - `NodeURL string`
  - `Message string`
- [ ] Start tsnet runtime on `:443` only.
- [ ] Use `srv.ListenTLS("tcp", ":443")`.
- [ ] On successful runtime startup, mark runtime state active.
- [ ] On startup/listen failure, mark runtime state inactive with message:
  - `Could not start with Tailscale. Please ensure Tailscale is running.`
- [ ] When `--tailscale` startup fails, return an error so the Mac app can restart without `--tailscale`.
- [ ] Add or update Tailscale helper tests next to this change:
  - `TestNormalizeTailscaleHostname`
  - `TestSelectTailscaleNodeURLSelectsTSNetDomain`
  - `TestSelectTailscaleNodeURLStripsTrailingDot`
  - `TestSelectTailscaleNodeURLIgnoresNonTSNetDomains`
  - `TestSelectTailscaleNodeURLErrorsWithoutTSNetDomain`

#### `tincan-server/setup_tailscale.go`

- [ ] Keep this command separate from the main server runtime.
- [ ] Parse `--data-dir`.
- [ ] Remove `--tailscale-status-file`.
- [ ] Emit `TINCAN_TAILSCALE_STATUS=starting` before tsnet startup.
- [ ] Start the tsnet setup server on port `80`; do not use `443` in `setup-tailscale`.
- [ ] Use `tsnet.Server.UserLogf` to detect `https://login.tailscale.com/a/...`.
- [ ] When a login URL is detected, emit:
  - `TINCAN_TAILSCALE_STATUS=needs_login`
  - `TINCAN_TAILSCALE_AUTH_URL=<url>`
- [ ] After `srv.Up(ctx)` succeeds, call `srv.CertDomains()`.
- [ ] Resolve the canonical node URL through `selectTailscaleNodeURL`.
- [ ] Persist the setup result through `AppConfigStore.SetTailscaleBootstrapResult(nodeURL)`.
- [ ] Emit `TINCAN_TAILSCALE_STATUS=running`.
- [ ] Emit `TINCAN_TAILSCALE_NODE=<nodeURL>`.
- [ ] Exit successfully after emitting the node URL.
- [ ] On failure, emit `TINCAN_TAILSCALE_ERROR=<message>` before returning the error.
- [ ] Add marker-formatting tests next to this change if marker formatting is factored into helpers.

#### `tincan-server/tailscale_runtime_test.go`

- [ ] Create or extend this test file.
- [ ] Test hostname normalization:
  - `Akash’s MacBook air` becomes `tincan-akashs-macbook-air`
  - punctuation runs collapse into one hyphen
  - empty input becomes `tincan-mac`
- [ ] Test domain selection:
  - selects `foo.ts.net`
  - strips trailing `.`
  - ignores non-`.ts.net` domains
  - errors when no `.ts.net` domain exists
- [ ] Test marker formatting helpers if marker output is factored into helper functions.

#### `tincan-server/main.go`

- [ ] Add Tailscale runtime state to the server struct.
- [ ] Update `handleHealth` to include:
  - `tailscale.configured`
  - `tailscale.active`
  - `tailscale.node_url`
  - `tailscale.message`
- [ ] Ensure health remains `200 OK` when Tailscale fails but local server is running.
- [ ] Add health response tests next to this change:
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
  - `tailscaleEnabled: Bool`
  - `tailscaleNodeURL: URL?`
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
- [ ] Test saving `tailscale_enabled`.
- [ ] Test saving `tailscale_node_url`.
- [ ] Test bootstrap result writes `tailscale_enabled = true` and `tailscale_node_url`.
- [ ] Test disabling keeps `tailscale_node_url`.
- [ ] Test unrelated config keys are preserved.
- [ ] Test invalid `server_url` is rejected.
- [ ] Test invalid `tailscale_node_url` is rejected.

#### `tincan-swift-app/tincan/TincanServerSettings.swift`

- [ ] Replace separate persisted scheme/host/port as the primary model with one `serverURL`.
- [ ] Remove `connectPhoneEnabled` from this store.
- [ ] Remove `server_connect_phone_enabled` UserDefaults usage.
- [ ] Keep `connectionRevision` so workspace/call models refresh when the URL changes.
- [ ] Keep `serverBaseURL`, `liveUpdatesURL`, and `liveUpdatesOriginHeaderValue` computed from `serverURL`.
- [ ] Add a draft URL string used by settings UI.
- [ ] Add `applyServerURLDraft()` that validates URL syntax but does not save until health succeeds.
- [ ] Add health-check retry behavior:
  - request `/healthz`
  - retry every 5 seconds
  - stop after 60 seconds
  - save only after success
- [ ] Expose Apply/checking state for the UI.
- [ ] Make QR scan apply direct URL payloads only.
- [ ] Add server connection tests next to this change:
  - direct URL parsing
  - invalid URL rejection
  - health-success-before-save
  - health-timeout-does-not-save
  - HTTPS-to-WSS live updates URL
  - connection revision increment after successful save

#### `tincan-swift-app/tincanTests/ServerConnectionStoreTests.swift`

- [ ] Replace scheme/host/port persistence tests with `server_url` tests.
- [ ] Test valid direct URL parsing.
- [ ] Test invalid direct URL parsing.
- [ ] Test save-after-health-success.
- [ ] Test no-save-after-health-timeout.
- [ ] Test websocket URL derives `wss` from HTTPS.
- [ ] Test connection revision increments after successful save.

#### `tincan-swift-app/tincan/TincanAPIClient.swift`

- [ ] Extend `HealthResponse` with nested `TailscaleHealth`.
- [ ] Decode:
  - `configured`
  - `active`
  - `node_url`
  - `message`
- [ ] Require the final health response to include `tailscale`.
- [ ] Add health decoding tests next to this change:
  - `tailscale.configured = false`
  - active Tailscale state
  - inactive fallback message

### Phase 4: Swift Tailscale Setup Monitor and Server Launch

#### `tincan-swift-app/tincan/MacTailscaleServerController.swift`

- [ ] Rewrite this from status-file polling to setup-process monitoring.
- [ ] Add setup state:
  - idle
  - starting
  - needs login with auth URL
  - running/completed with node URL
  - failed with message
- [ ] Launch `tincan-server setup-tailscale --data-dir <AppPaths.appSupportDirectory.path>`.
- [ ] Capture stdout and stderr with pipes.
- [ ] Parse stable markers:
  - `TINCAN_TAILSCALE_STATUS=starting`
  - `TINCAN_TAILSCALE_STATUS=needs_login`
  - `TINCAN_TAILSCALE_AUTH_URL=...`
  - `TINCAN_TAILSCALE_STATUS=running`
  - `TINCAN_TAILSCALE_NODE=...`
  - `TINCAN_TAILSCALE_ERROR=...`
- [ ] Expose `authURL`.
- [ ] Expose `nodeURL`.
- [ ] Expose `progressMessage`.
- [ ] Expose `availabilityMessage`.
- [ ] Stop any existing setup process before launching a new one.
- [ ] On successful node URL, ask `TincanLocalServerConfigStore` to reload.
- [ ] Add marker parser tests next to this change:
  - auth URL marker parsing
  - node URL marker parsing
  - error marker parsing
  - transition from starting to needs-login
  - transition from running plus node URL to completed/ready

#### `tincan-swift-app/tincanTests/MacTailscaleServerControllerTests.swift`

- [ ] Create or extend this test file for pure marker parsing.
- [ ] Test auth URL marker parsing.
- [ ] Test node URL marker parsing.
- [ ] Test error marker parsing.
- [ ] Test status transition from starting to needs-login.
- [ ] Test status transition from running to completed when node URL arrives.

#### `tincan-swift-app/tincan/MacBundledTincanServerController.swift`

- [ ] Launch `tincan-server run`, not bare `tincan-server`.
- [ ] Remove `--tailscale-status-file`.
- [ ] Keep `--data-dir`.
- [ ] Keep `--port`.
- [ ] Pass `--tailscale` only when local config says Tailscale is enabled.
- [ ] If launching with `--tailscale` fails, restart with the same base arguments without `--tailscale`.
- [ ] Update tests or helper assertions that inspect process arguments.
- [ ] Keep local server readiness check against loopback `/healthz`.
- [ ] Add bundled server argument tests next to this change:
  - includes `run`
  - includes `--tailscale` when enabled
  - omits `--tailscale` when disabled
  - omits `--tailscale-status-file`

#### `tincan-swift-app/tincan/TincanAppModel.swift`

- [ ] Add `localServerConfig = TincanLocalServerConfigStore()`.
- [ ] Pass the local config store into `ServerConnectionStore`.
- [ ] Pass the local config store into `MacTailscaleServerController`.
- [ ] Replace `serverSettings.$connectPhoneEnabled` subscription with local config Tailscale state.
- [ ] When `Connect phone` is enabled:
  - launch setup process
  - wait for successful node URL
  - restart bundled server
  - refresh `/healthz`
- [ ] When `Connect phone` is disabled:
  - write `tailscale_enabled = false`
  - restart bundled server without `--tailscale`
  - clear transient setup state
- [ ] On app startup, start bundled server according to `tailscale_enabled` from config.

#### `tincan-swift-app/tincan/AppPaths.swift`

- [ ] Remove `tincanServerTailscaleStatusURL` after status-file polling is removed.
- [ ] Keep `generatedAppConfigURL` as the config store path.

### Phase 5: Swift Settings UI

#### `tincan-swift-app/tincan/TincanRootView.swift`

- [ ] Split macOS Connect server UI into two `TincanSettingsSectionCard` cards:
  - `Run on this computer`
  - `Connect to remote server`
- [ ] In `Run on this computer`, keep the bundled server toggle.
- [ ] In `Run on this computer`, add `Connect phone` bound to `localServerConfig.tailscaleEnabled`.
- [ ] On enabling `Connect phone`, call the setup flow from `TincanAppModel`.
- [ ] While setup is starting, show a spinner.
- [ ] If auth URL exists, show:
  - waiting text
  - approval URL
  - `Open link`
  - `Copy link`
- [ ] After node URL exists, show:
  - QR code encoding direct node URL
  - text value of node URL
- [ ] Show runtime fallback warning from decoded `/healthz` Tailscale state.
- [ ] In `Connect to remote server`, replace scheme picker, host field, and port field with one URL field.
- [ ] Disable the Apply button while health retry is running.
- [ ] Show spinner/progress state while applying URL.
- [ ] On iOS, keep the QR scanner button.
- [ ] On iOS, make scanner payload populate the direct URL draft and run the health retry before saving.
- [ ] Remove UI paths that generate `tincan://connect?...` payloads.

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
  - `tailscale_enabled: true`
  - `tailscale_node_url: https://...ts.net`
- [ ] Confirm main server restarts after setup.
- [ ] Confirm `/healthz` reports:
  - `tailscale.configured = true`
  - `tailscale.active = true`
  - `tailscale.node_url = https://...ts.net`
- [ ] Scan the QR code on iPhone.
- [ ] Confirm iPhone saves `server_url` only after health succeeds.

## Current Implementation Gaps

These are the known gaps between the current code and this plan:

- normal server startup is still implicit instead of `tincan-server run`
- `Connect phone` is still stored in `UserDefaults`
- `setup-tailscale` is not launched as a separate Mac setup process
- setup/runtime state is currently based on a status file
- `config.json` does not yet contain `server_url`, `tailscale_enabled`, or `tailscale_node_url`
- `/healthz` does not report Tailscale runtime state
- setup currently reports/assumes port `443`; master notes require setup on port `80`
- QR payload currently uses `tincan://connect?...`; required payload is the direct server URL
- manual server settings still use separate scheme/host/port fields
- Apply does not yet retry health checks for up to 60 seconds before saving
- Tailscale domain selection does not yet require `.ts.net` or strip trailing `.`
- Mac settings are visually grouped but not yet two dedicated cards
