## Status

DONE

## Problem

`agent_profiles.json` still carried inline backend options.

That was outdated and caused repeated backend configuration to be copied into every profile, even though backend settings should be reusable named resources.

## Solution

Refactored the Go server config model to separate profiles from backend definitions:

- added `config/agent_backends.json`
- replaced inline backend options in `agent_profiles.json` with backend-name references only
- added `AgentBackendStore`
- changed `AgentProfile` to reference a backend name instead of carrying backend options inline
- updated startup validation to resolve profile backend references through the new store
- switched the router to use the special backend definition named `__router__`
- renamed the OpenCode backend type to `opencode`
- adopted `connection_type`, `model_variant`, and default `build` agent behavior in the backend options model

## Notes

This resolves the config explosion problem:

- backend options are now defined once
- profiles simply point at backend definitions by name
- the router also uses the same backend-definition mechanism rather than a separate dedicated profile file
