## Status

DONE

## Problem

The adapter implementations had already been split into separate files, but they were still living in the root package.

Now that shared config and router types have their own packages, the adapters no longer needed to stay in the root directory.

## Solution

Moved the adapter code into a real `agent_adapters` package:

- added `tincan-server/agent_adapters/types.go`
- added `tincan-server/agent_adapters/registry.go`
- added `tincan-server/agent_adapters/opencode.go`
- added `tincan-server/agent_adapters/codex.go`
- updated root server, router, and conversation service code to import the package explicitly

## Notes

This is the first proper adapter package boundary in the Go server.
It was only made cleanly possible after moving shared config and router types out of the root package.
