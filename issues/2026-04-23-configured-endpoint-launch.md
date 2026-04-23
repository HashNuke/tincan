# Configured endpoint must suppress bundled server launch

## Status
DONE

## Problem
The macOS app could still launch and reclaim the bundled `tincan-server` even
when the user had already configured a specific host and port to connect to.

That violated the intended connection rule:

- if the user has configured a host and port, the app should only connect to
  that configured endpoint
- the bundled local server should only be started when no explicit endpoint has
  been configured

Because startup and speech-settings flows were checking `connectionMode` instead
of whether an explicit endpoint existed, the app could start or restart the
bundled server unnecessarily.

## Solution
Centralized the decision in `ServerConnectionStore`.

- Added explicit endpoint tracking so the app can distinguish user-configured
  host/port values from the built-in fallback defaults.
- Added `shouldUseBundledServer`, which is only `true` when no explicit endpoint
  configuration exists.
- Updated server URL generation to use the configured endpoint whenever one is
  explicitly set.
- Updated macOS bundled-server startup/shutdown and speech-settings behavior to
  follow `shouldUseBundledServer` instead of relying on connection mode alone.
- Added tests covering both explicit-endpoint override behavior and the default
  bundled-server path.

This makes the configured endpoint authoritative and prevents the app from
launching the bundled server when it should be connecting remotely instead.
