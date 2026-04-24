Status: DONE

# tsnet pairing flow

## Problem

The app's connection settings are currently modeled as a generic scheme, host, and port editor.

That works for raw local or manually configured remote servers, but it is not a smooth fit for a `tsnet`-backed server:

- ATS still disfavors plain `http` endpoints, so `tsnet` should be used to provide a tailnet-reachable HTTPS endpoint instead of teaching users to enter insecure WebRTC URLs.
- `tsnet` startup can require authentication, device approval, HTTPS enablement, or service approval before the endpoint is actually usable.
- A long `.ts.net` hostname is awkward to type and makes the current settings UI feel too low-level for the common case.

## Solution

Added embedded `tsnet` support to `tincan-server` so the app only has to launch the bundled server and read Tailscale status from it.

The implemented fix includes:

- normalizing the Tailscale hostname as `tincan-<machine-hostname>` for stable `.ts.net` names
- running `tincan-server` with embedded `tsnet` support and a `--no-tailscale` fallback flag
- adding a `tincan-server setup-tailscale` command for explicit Tailscale bootstrap flows
- parsing the Tailscale approval URL from tsnet user logs and surfacing it through a status file the Mac app can read
- showing Mac settings UI for the approval link with `Open link` and `Copy link` actions plus a waiting spinner while approval is pending
- showing the final Tailscale HTTPS endpoint and QR code once the server is ready
- letting the iPhone settings screen scan a QR code and apply the server connection automatically
- keeping the existing manual host and port editor as a fallback path

## Result

Users can now pair the phone by scanning a QR code instead of typing server details, while the Mac app guides Tailscale approval directly from Settings and upgrades the tsnet helper to HTTPS once approval completes.
