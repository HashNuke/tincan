# Tailscale Plan

## Status

This document is a planning document only.

It describes the desired Tailscale architecture, UX flow, server command structure, config model, and implementation sequence for tincan.

## Goal

Add a smooth phone-pairing flow for the Mac-hosted bundled server using Tailscale and `tsnet`, without forcing the user to type server details on iPhone.

The phone should connect by scanning a QR code from the Mac app.

## Product Goals

1. The Mac app should keep working locally even if Tailscale is unavailable.
2. Phone pairing should be a guided toggle-driven flow, not a manual hostname flow.
3. Tailscale enablement should be persisted in `config.json`.
4. The main bundled server process should be separate from the one-time Tailscale bootstrap process.
5. Runtime fallback should be visible in the Mac UI when Tailscale is configured but not actually active.

## Final UX

### Connect server page on macOS

The Connect server page should be split into two cards.

1. `Run on this computer`
2. `Connect to server`

### Run on this computer card

This card should contain:

- the existing local bundled-server toggle
- the local server endpoint
- a `Connect phone` toggle
- setup/progress state for Tailscale bootstrap
- QR code and server URL once pairing is ready
- runtime fallback warning if Tailscale was enabled in config but is not active at runtime

### Connect to server card

This card should contain the existing manual remote server configuration:

- scheme
- host
- port
- apply button

This remains the advanced/manual path.

## Expected User Workflow

### First-time enable flow

1. User opens macOS Settings > Connect server.
2. User leaves `Run on this computer` enabled.
3. User enables `Connect phone`.
4. The Mac app launches a separate process:

```text
tincan-server setup-tailscale --data-dir <...>
```

5. The Mac app monitors that process live through stdout and stderr.
6. If setup emits a Tailscale login URL, the UI shows:

```text
<spinner> Waiting for you to approve on Tailscale:
<login-link> <open link> <copy link>
```

7. The user approves the node in Tailscale.
8. The setup process reaches the equivalent of:

```text
AuthLoop: state is Running; done
```

9. The setup process fetches the HTTPS-capable node domain from `srv.CertDomains()`.
10. It picks the `.ts.net` domain.
11. It strips a trailing `.` if present.
12. It persists the result to `config.json`.
13. The setup process exits successfully.
14. The Mac app force-restarts the main server process.
15. The main server starts in Tailscale-enabled mode.
16. The Mac UI removes the waiting state and instead shows:
   - QR code
   - `https://<fqdn>`

### Already approved flow

If the device was already approved earlier:

1. User enables `Connect phone`.
2. `setup-tailscale` runs.
3. No login URL is shown.
4. The command quickly resolves the node FQDN and exits successfully.
5. The Mac app restarts the main server.
6. The UI goes directly to QR code plus `https://<fqdn>`.

### Later visits to settings

If `config.json` already contains a Tailscale-enabled state:

1. The `Connect phone` toggle appears enabled.
2. The card should show the saved Tailscale node URL.
3. If the runtime server is currently active with Tailscale, show QR code and the active URL.
4. If the runtime server fell back to local-only mode, show a warning like:

```text
Could not start with Tailscale. Please ensure Tailscale is running.
```

### Disable flow

If the user disables `Connect phone`:

1. Persist `tailscale_enabled = false` to `config.json`.
2. Restart the main server.
3. Stop showing the Tailscale QR and phone-pairing UI.
4. Keep local bundled-server operation unaffected.

## Server Command Model

The server should move from implicit default startup to explicit subcommands.

### Final CLI

```text
tincan-server run
tincan-server setup-tailscale
```

### Why this split

The two commands have different responsibilities.

- `run` is the normal long-lived bundled server process.
- `setup-tailscale` is a short-lived bootstrap process used only for approval and node discovery.

This separation makes the lifecycle much easier to reason about than combining bootstrap and steady-state runtime concerns.

## Recommended File Layout

Preferred structure:

```text
tincan-server/
  main.go
  internal/
    commands/
      run.go
      setup_tailscale.go
    serverapp/
      ... shared server bootstrap/runtime code ...
```

Why:

- a dedicated `commands` package is cleaner long term
- current server bootstrap logic in `main.go` is too large to keep inside a tiny dispatcher
- shared server bootstrap should be extracted into a reusable internal package

Lower-churn alternative if we want fewer moves first:

```text
tincan-server/
  main.go
  run_command.go
  setup_tailscale_command.go
```

Both are valid. The important part is the explicit command split.

## Tailscale Hostname Rules

The Tailscale node hostname should be derived from the machine hostname using:

```text
tincan-<machine-hostname>
```

Normalization rules:

- lowercase everything
- remove apostrophes
- replace runs of non-alphanumeric characters with `-`
- trim leading/trailing `-`

Example:

```text
Akash’s MacBook air
->
tincan-akashs-macbook-air
```

## Config Source of Truth

Tailscale enablement should live in `config.json`.

### New config fields

```json
{
  "tailscale_enabled": true,
  "tailscale_node": "https://tincan-akashs-macbook-air.tail12345.ts.net"
}
```

### Meaning

- `tailscale_enabled`
  - user intent
  - whether phone-connect via Tailscale is enabled
- `tailscale_node`
  - last known canonical HTTPS node URL
  - should be stored as full scheme + host
  - expected scheme is `https`

### Ownership

- `setup-tailscale` writes these fields on successful approval/bootstrap
- `run` refreshes `tailscale_node` whenever it starts successfully with Tailscale and discovers the current node FQDN
- disabling phone-connect writes `tailscale_enabled = false`

### Recommendation on disabling

When the user turns Tailscale off, keep `tailscale_node` unless there is a strong reason to clear it.

Recommended behavior:

- set `tailscale_enabled = false`
- keep `tailscale_node` as last-known value

That preserves useful diagnostic information.

## setup-tailscale Command

### Responsibility

`setup-tailscale` is a bootstrap-only command.

It should:

- initialize or resume the Tailscale node state
- wait for approval if required
- surface setup progress to the Mac app through stdout and stderr
- discover the HTTPS node FQDN from `CertDomains()`
- persist config
- exit

It is not the main bundled server.

### High-level behavior

1. Resolve `dataDir`.
2. Normalize the Tailscale hostname.
3. Create or reuse the tsnet state directory.
4. Start `tsnet.Server`.
5. Call `srv.Up(ctx)`.
6. If approval is needed, Tailscale emits a login URL.
7. Once `Up(ctx)` returns successfully, fetch:

```go
domains := srv.CertDomains()
```

8. Pick the `.ts.net` entry.
9. Trim trailing `.` if present.
10. Construct:

```text
https://<fqdn>
```

11. Persist to `config.json`:

- `tailscale_enabled = true`
- `tailscale_node = "https://<fqdn>"`

12. Emit stable success output.
13. Exit.

### stdout/stderr contract

The Mac app should monitor stdout and stderr directly.

The command may still print raw Tailscale logs, but it should also emit stable app-owned markers so the UI does not depend on brittle vendor log wording.

Recommended markers:

```text
TINCAN_TAILSCALE_STATUS=starting
TINCAN_TAILSCALE_STATUS=needs_login
TINCAN_TAILSCALE_AUTH_URL=https://login.tailscale.com/a/...
TINCAN_TAILSCALE_STATUS=running
TINCAN_TAILSCALE_NODE=https://tincan-....ts.net
TINCAN_TAILSCALE_ERROR=<message>
```

### Approval detection

The command must handle both success shapes:

1. A login URL appears first, then approval completes.
2. Approval already exists and no login URL appears at all.

The UI should not depend on the login URL being present.

## run Command

### Responsibility

`tincan-server run` is the normal bundled server process launched by the Mac app.

It should:

- start the local HTTP server as today
- read `config.json`
- decide whether Tailscale should be attempted
- if enabled, try embedded Tailscale runtime
- if startup succeeds, refresh the stored node URL if needed
- if startup fails, keep serving locally and report fallback state

### Behavior when Tailscale is enabled

If `tailscale_enabled = true` in config:

1. `run` attempts embedded Tailscale startup.
2. If it succeeds:
   - runtime state becomes active
   - `tailscale_node` is refreshed from current `CertDomains()` if needed
3. If it fails:
   - local server still runs
   - runtime state reports that Tailscale was configured but inactive

### Behavior when Tailscale is disabled

If `tailscale_enabled = false` in config:

- behave as if running with `--no-tailscale`
- no Tailscale bootstrap/runtime should be attempted

## Runtime Tailscale Signal

The runtime server needs a clear way to tell the app whether Tailscale is actually active.

### Recommended mechanism

Extend `/healthz`.

The app already calls `/healthz`, so it is the cleanest place to report runtime Tailscale state.

### Proposed health response

Current health response already includes:

- `status`
- `agent_profile_count`

Add a nested Tailscale object:

```json
{
  "status": "ok",
  "agent_profile_count": 3,
  "tailscale": {
    "configured": true,
    "active": false,
    "node": "https://tincan-akashs-macbook-air.tail12345.ts.net",
    "message": "Could not start with Tailscale. Please ensure Tailscale is running."
  }
}
```

### Meaning

- `configured`
  - reflects persisted config intent
- `active`
  - whether the current `run` process actually started Tailscale
- `node`
  - canonical node URL
- `message`
  - runtime user-facing status or failure reason

## Mac App Architecture

The Mac app should manage two different processes.

1. `tincan-server run`
2. `tincan-server setup-tailscale`

They are separate on purpose.

### When enabling Connect phone

1. Launch `tincan-server setup-tailscale`.
2. Pipe stdout and stderr.
3. Watch for:
   - login URL
   - approval completion
   - resolved node URL
   - setup failure
4. Update the UI live.
5. On success:
   - reload config
   - restart `tincan-server run`
   - refresh `/healthz`
   - show QR code and `https://<fqdn>`

### When disabling Connect phone

1. Write `tailscale_enabled = false` to config.
2. Restart `tincan-server run`.
3. Remove the pairing UI state.

### When opening settings later

1. Read persisted config.
2. Read runtime state from `/healthz`.
3. Render based on both:
   - persisted intent
   - actual runtime status

## macOS UI Design

Use the existing `TincanSettingsSectionCard` component from `TincanDesignSystem.swift`.

### Card 1: Run on this computer

Contains:

- local bundled-server toggle
- local endpoint
- `Connect phone` toggle
- if setup is waiting:

```text
<spinner> Waiting for you to approve on Tailscale:
<login-link> <open link> <copy link>
```

- if setup completed and runtime is active:
  - QR code
  - `https://<fqdn>`
- if config says enabled but runtime is inactive:
  - `Could not start with Tailscale. Please ensure Tailscale is running.`

### Card 2: Connect to server

Contains:

- manual scheme/host/port fields
- apply button

This is the existing remote connection path.

## iPhone UX

The iPhone should not need Tailscale-specific setup UI.

### Behavior

1. User opens settings.
2. Taps `Scan QR code`.
3. Scans QR from Mac.
4. App applies:

- `scheme = https`
- `host = <fqdn>`
- `port = 443`

The existing QR payload path is good for this.

## Swift State Ownership Changes

### Current state

The current `connectPhoneEnabled` value is stored in `UserDefaults` via `ServerConnectionStore`.

That does not match the desired architecture.

### Desired state

Tailscale enablement should come from `config.json`, not `UserDefaults`.

### Recommended split

- `ServerConnectionStore`
  - manual local/remote endpoint selection
  - QR payload parsing for scanned phone-connect URLs
- new local server config store
  - reads and writes `config.json`
  - owns:
    - `tailscale_enabled`
    - `tailscale_node`
- setup process monitor
  - owns transient bootstrap state:
    - setup running
    - login URL
    - setup success/failure
- runtime health state
  - owns actual active/fallback Tailscale state

### Reuse candidate

`TincanSpeechSettingsStore.swift` already contains a robust local `config.json` load/save path.

That implementation style should be reused, but Tailscale config should live in a dedicated local config store rather than inside the speech-specific store.

## Go Config Changes

### AppConfigStore changes

Extend `tincan-server/config/app_config.go`:

- `AppConfigStore`
- `AppConfigSnapshot`
- `decodeAppConfig(...)`
- `ApplyPatch(...)`

Add fields:

- `tailscale_enabled`
- `tailscale_node`

### Validation rules

- `tailscale_enabled`
  - boolean
- `tailscale_node`
  - optional string
  - trim whitespace
  - store full URL including scheme
  - expected scheme should be `https`

### Refresh rule

Every time `tincan-server run` starts successfully with Tailscale enabled:

1. call `srv.CertDomains()`
2. choose the `.ts.net` domain
3. trim trailing `.`
4. build `https://<fqdn>`
5. if different from config, rewrite `tailscale_node`

That keeps the stored endpoint synchronized with runtime reality.

## File Touchpoints

### Go server

- `tincan-server/main.go`
- `tincan-server/setup_tailscale.go`
- `tincan-server/tailscale_runtime.go`
- new command files for `run` and `setup-tailscale`
- `tincan-server/config/app_config.go`
- `tincan-server/config/store_test.go`

### Swift app

- `tincan-swift-app/tincan/TincanRootView.swift`
- `tincan-swift-app/tincan/TincanDesignSystem.swift`
- `tincan-swift-app/tincan/MacBundledTincanServerController.swift`
- `tincan-swift-app/tincan/MacTailscaleServerController.swift`
- `tincan-swift-app/tincan/TincanAppModel.swift`
- `tincan-swift-app/tincan/TincanServerSettings.swift`
- `tincan-swift-app/tincan/TincanAPIClient.swift`
- new local config store for `config.json`

## Implementation Sequence

1. Refactor CLI to explicit `run` and `setup-tailscale` subcommands.
2. Add `tailscale_enabled` and `tailscale_node` to Go config.
3. Implement full `setup-tailscale` persistence behavior.
4. Add stable stdout/stderr markers to `setup-tailscale`.
5. Refactor `run` to read config and attempt embedded Tailscale only when enabled.
6. Extend `/healthz` with runtime Tailscale state.
7. Build a dedicated Swift config store for local server/Tailscale settings.
8. Make the Mac app launch and monitor `setup-tailscale` separately.
9. Restart `tincan-server run` after successful setup.
10. Convert macOS settings into the two-card layout.
11. Hook QR + server details + fallback warning into the cards.
12. Remove `UserDefaults` as the source of truth for `Connect phone`.

## Testing Plan

### Go tests

Add or extend tests for:

- command parsing for `run` and `setup-tailscale`
- config read/write for:
  - `tailscale_enabled`
  - `tailscale_node`
- hostname normalization
- `.ts.net` domain selection
- trailing-dot trimming
- `run` rewriting `tailscale_node` when runtime value changes

### Swift tests

Add or extend tests for:

- local config store load/save for Tailscale fields
- QR payload application
- health response decoding for Tailscale runtime state
- setup process monitor state transitions

## Risks and Gotchas

1. A true `commands/` package means shared bootstrap logic must be extracted from `main.go` into reusable code.
2. Current app state is split across `UserDefaults`, config, and runtime state; this must be collapsed cleanly.
3. Setup stdout/stderr monitoring needs proper non-blocking pipe handling.
4. Raw Tailscale logs are not a stable UI API; the app should prefer explicit app-owned output markers.
5. Bootstrap progress and runtime active/fallback state are separate concerns and must stay separate.
6. Avoid noisy config rewrites if the discovered node URL is unchanged.

## Current Repo State vs Desired State

Current repo state is partially aligned but not yet correct.

### Current mismatches

- normal startup is still implicit instead of `tincan-server run`
- `setup-tailscale` exists but does not yet persist Tailscale config
- the embedded Tailscale runtime is already wired into the main server path
- the Mac app currently polls a status file instead of directly monitoring `setup-tailscale` stdout/stderr
- `Connect phone` is still backed by `UserDefaults`
- the macOS Connect server screen is not yet split into two cards

### Desired end state

- `run` and `setup-tailscale` are explicit commands
- config owns Tailscale enablement and node URL
- setup and runtime are separate processes with separate responsibilities
- the Mac app monitors setup process IO directly
- runtime fallback is reported through `/healthz`
- the Mac UI is card-based and reflects both persisted intent and actual runtime state

## Recommendation

Implement this in two broad phases.

### Phase 1

- explicit CLI subcommands
- config schema changes
- setup persistence
- runtime fallback reporting
- health endpoint enrichment

### Phase 2

- Mac app setup-process orchestration
- config-backed phone toggle
- two-card macOS settings UI
- QR + warning polish

## Open Product Decision

When the user disables `Connect phone`, should `tailscale_node` be cleared?

Recommendation:

- do not clear it
- only set `tailscale_enabled = false`

That preserves the last known node value for display and debugging, while still correctly representing user intent.
