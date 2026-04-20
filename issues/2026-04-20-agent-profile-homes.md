## Status

DONE

## Problem

`SPEC.md` described agent profiles too much like project identities and changed session naming to project-scoped labels such as `tincan/4`.

That did not match the intended product model.
The intended model is that an agent profile can still be a named agent such as `emma` or `atlas`, while also carrying the home working directory where that agent should run.
Conversation numbering should then be scoped to the profile, producing labels such as `emma#1`, `emma#2`, and `atlas#3`.
These labels are display handles only, not durable internal IDs.

## Solution

Updated `SPEC.md` so that:

- an agent profile is defined as an agent persona plus its home working directory
- profile selection also selects the execution directory context
- conversation labels are assigned from currently available profile-scoped numbers
- user-facing labels use the `profile#N` form, such as `emma#4`
- archived or expired conversations can release those display numbers for reuse
- routing uses a backend candidate-based small model over raw transcripts instead of a large transcript-normalization layer
- coding-agent backend selection is driven by agent profile options, so OpenCode Server, Codex, and future backends plug in through the same `AgentAdapter` boundary
- examples and v1 summary language now match the profile-scoped naming model

## Notes

This keeps the profile abstraction flexible:

- the profile can represent a specific agent identity
- the same profile still anchors execution to a specific filesystem workspace
- multiple conversations can coexist under that profile without losing the agent identity
- the visible `profile#N` label remains a lightweight call-style handle rather than a storage key
- v1 routing remains constrained to a tiny backend-validated action schema rather than open-ended agent autonomy
- the first implementation can still be OpenCode-specific internally, as long as the main tincan flow talks through a profile-selected adapter
