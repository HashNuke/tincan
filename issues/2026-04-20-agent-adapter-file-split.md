## Status

DONE

## Problem

The Go agent adapter code had grown into one file and mixed several concerns:

- shared adapter interface and result types
- adapter registry
- OpenCode implementation
- Codex placeholder implementation

That made the package harder to scan and extend.

## Solution

Split the adapter code into separate files in the same Go package:

- `agent_adapter_types.go` for the shared interface and result types
- `agent_adapter.go` for the adapter registry
- `agent_adapter_opencode.go` for the OpenCode implementation
- `agent_adapter_codex.go` for the Codex placeholder implementation

## Notes

In Go, files that share the same package must remain in the same directory, so this cleanup uses multiple files in `tincan-server/` rather than a nested package directory.
