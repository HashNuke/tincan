# Server mode settings looked like tabs instead of a single local-or-remote choice

## Status
DONE

## Problem
In macOS settings, the server connection UI presented `Run on this Mac` and
`Connect remote` as side-by-side chips.

That made the control read like tab navigation instead of a single binary choice
between using the bundled local server and connecting to a remote server.

The desired behavior is:

- `Run on this computer` should be the default path on Mac
- it should be represented as a toggle, not a tab-like chip group
- when local mode is enabled, the remote connection editor should collapse
- when local mode is disabled, the remote connection editor should expand

On phone, only the remote connection UI should be shown.

## Solution
Updated the server settings section in `TincanRootView`.

- Replaced the macOS chip-style local/remote selector with a `Run on this
  computer` switch.
- Kept the local QR code and current connection details visible only when that
  switch is enabled.
- Added a `Connect to remote server` section below it.
- Collapsed the remote editor on Mac while local mode is enabled, and expanded
  it when local mode is disabled.
- Left the iPhone/iOS path remote-only, so only the remote server block is
  shown there.

This makes the settings read as one clear choice instead of two tab-like views.
