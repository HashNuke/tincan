## Status

DONE

## Problem

The project direction changed so that `tincan-server` should become a Go-based server, while the previous Swift/Vapor backend was moved aside to `tincan-server-old`.

The repository needed a fresh Go server module in `tincan-server` so the new backend work could start from a clean base.

## Solution

Initialized a Go project in `tincan-server`:

- created a Go module with `go mod init tincan-server`
- added a minimal `main.go`
- added a small `/healthz` endpoint
- default server port is `8080`

## Notes

This is only the project bootstrap.
It gives the new Go backend a clean entrypoint without carrying over the old Swift server structure.
