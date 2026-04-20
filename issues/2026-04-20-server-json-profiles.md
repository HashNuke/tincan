## Status

DONE

## Problem

The spec direction for agent profiles was drifting toward user-managed database records.
That is more machinery than the current backend needs.

For the current stage of the project, agent profiles should live on the server side of the backend and be loaded from a JSON file.
This keeps profile configuration simple while still treating profiles as runtime data rather than hard-coded app logic.

## Solution

Updated `SPEC.md` so that:

- agent profiles are defined on the server side of the backend
- the initial source of truth is a JSON file
- the profile store loads profiles from that server-side JSON file
- profile records still carry backend type, home working directory, model, prompt, and voice settings
- the spec leaves room to move profiles to a database later if needed

## Notes

This keeps the initial implementation small:

- profile configuration stays editable without recompiling the app
- the server owns the profile definitions
- the rest of the system can still treat profiles as structured data records
