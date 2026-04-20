## Status

DONE

## Problem

The adapter-backed router path was still constructing the full router prompt inside the OpenCode adapter.

That mixed prompt/context assembly with backend execution logic, which made the adapter too responsible for router behavior.

## Solution

Refactored the router flow so prompt construction lives in `router_service.go`:

- router service now builds the user router prompt
- the prompt contains:
  - static router instruction context
  - dynamic context including defined agent profiles
  - the user transcript block
- adapters now receive a compiled router prompt and only execute it against the backend
- renamed the adapter method to `RunRouterPrompt`

## Notes

This keeps the boundary cleaner:

- router service decides what context the model should see
- adapter code only knows how to execute the request on the backend
- this is the right direction for eventually moving more router logic into the `router` package itself
