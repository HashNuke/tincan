## Status

DONE

## Problem

The Go server's `main.go` had grown large because the entire `/speak` browser test page was embedded directly as a raw string constant.

That made the server entrypoint harder to scan and maintain.

## Solution

Extracted the `/speak` page from `main.go`:

- added `tincan-server/speak.html`
- added `tincan-server/speak_page.go`
- embedded the HTML asset using Go's `embed` support
- kept the runtime behavior the same while removing the large inline page from `main.go`

## Notes

This is a structural cleanup only.
The `/speak` route still serves the same test page, but the Go server code is now easier to navigate.
