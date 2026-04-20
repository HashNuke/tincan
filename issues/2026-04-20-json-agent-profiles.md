## Status

DONE

## Problem

The server had no real runtime source of truth for agent profiles.
Backend selection, working directory selection, and future conversation routing needed a concrete profile representation that was loaded by the server rather than being hard-coded into application logic.

At the same time, this first implementation needed to stay small.
The server should load profiles from a JSON file, but it should not expose a public endpoint for listing them yet.

## Solution

Implemented server-side JSON-backed agent profiles in `tincan-server`:

- added an `AgentProfile` model with the chosen schema
- added an `AgentProfileStore` that loads `agent_profiles.json` from bundled server resources
- validated required fields such as `name`, `working_directory`, and backend `model`
- wired the store into Vapor application configuration
- added a server test that verifies the JSON-backed store loads the bundled profiles correctly

## Notes

This is intentionally a small infrastructure step:

- profiles now exist as real runtime server data
- the public HTTP surface did not expand
- the next step can consume these profiles when creating or routing conversations
