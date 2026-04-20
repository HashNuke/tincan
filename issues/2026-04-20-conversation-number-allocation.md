## Status

DONE

## Problem

Conversations needed a profile-scoped numeric handle such as `emma#1`, but the server had no persisted conversation number or allocation rule.

The numbering also needed to be reusable in a controlled way.
For each agent profile, the server should assign the lowest positive integer that is not currently reserved by a running or bad-state conversation.

## Solution

Implemented persisted conversation numbers and a profile-scoped allocator:

- added `conversation_number` to the `Conversation` model
- added a Fluent migration to backfill the new column into the SQLite schema
- added `Conversation.nextAvailableNumber(for:on:)`
- the allocator finds the lowest positive integer not reserved for the target profile
- reserved states currently include `starting`, `running`, `busy`, `retry`, `failed`, and `aborted`
- reusable states currently include `idle`, `completed`, and `archived`

## Notes

This keeps the display handle policy simple:

- conversation numbers are scoped per `agent_profile_name`
- active or problematic conversations keep their number reserved
- ended or archived conversations can release their number for reuse
- the display handle can now be derived from `agent_profile_name` plus `conversation_number`
