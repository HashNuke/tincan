# Healthz Startup Polling

Status: DONE

## Problem

On macOS startup, the bundled server readiness loop polled `http://127.0.0.1:4490/healthz` every 250ms while waiting for `tincan-server` to become healthy. When the server process was not listening yet, each attempt produced noisy `NSURLErrorDomain Code=-1004` and Network.framework connection-refused logs.

## Solution

Slowed the bundled server health readiness retry interval to 2 seconds. This keeps startup readiness detection simple while reducing repeated failed connection attempts during normal server boot.
