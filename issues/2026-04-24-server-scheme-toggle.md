Status: DONE

# Server scheme toggle

## Problem

The iPhone settings screen only exposed `Host` and `Port` while the connection model always forced the scheme to `http`.

This caused two problems:

- Entering a full URL like `http://wheeljack.tail445590.ts.net` into the host field produced an invalid server URL because the app expected only a hostname.
- Users had no way to select `https` for remote servers, which made the connection settings incomplete and confusing.

## Solution

Added a persisted server scheme setting to the app connection model and exposed it in the settings UI as a `Scheme` segmented toggle above the host field.

The fix includes:

- storing `http` or `https` separately from the host and port
- using the selected scheme when building the base URL
- using `ws` or `wss` automatically for live updates based on the selected scheme
- showing the full configured endpoint with scheme in the current connection label
- covering scheme persistence and legacy URL migration with unit tests

## Result

Users can now configure remote servers as either HTTP or HTTPS without trying to cram a URL scheme into the host field.
