## Status

DONE

## Problem

The shared config model types such as `AgentProfile` and `AgentBackendDefinition` were still living in the runtime loader file.

That made the config model harder to reuse and blurred the line between data types and file-loading logic.

## Solution

Moved the shared config model types into `tincan-server/config/types.go`:

- `AgentProfile`
- `AgentBackendDefinition`
- `AgentBackendOptions`

Updated the Go server code to import those types from the `config` package where needed, while keeping the loader logic in `agent_config.go`.

## Notes

This is the first real package extraction step for the Go server.
It keeps the config model independent from the loader implementation and makes later package cleanup easier.
