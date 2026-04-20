## Status

DONE

## Problem

The first Go router implementation was rule-based and lived entirely in Go code.

That was useful as a temporary wiring step, but it did not match the intended architecture where router decisions should also run through the agent-adapter boundary.

## Solution

Upgraded the router to use `AgentAdapter`:

- added `config/router_profile.json`
- added `LoadRouterProfile()`
- extended `AgentAdapter` with `RouteUser(...)`
- implemented `OpenCodeServerAdapter.RouteUser(...)` using:
  - OpenCode session creation
  - synchronous `/session/:id/message`
  - JSON-only router prompts
- updated `Router` to delegate routing to the configured adapter instead of local string rules
- updated server startup to validate and wire a dedicated router profile and adapter

## Notes

This is the architectural step that removes the hard-coded Go-only router logic.

The router now uses the same lower-level adapter model as conversation backends, while still remaining a distinct logical component.
