## Status

DONE

## Problem

The project needed a concrete written definition for how voice commands should become router actions, especially around when a new conversation may be created versus when a message should be sent to an existing conversation.

There also needed to be a clear rule for command commitment in a hands-free voice flow and for how committed commands should be logged without duplicating full OpenCode history.

## Solution

Added `docs/router-spec.md` documenting:

- the explicit wake or command phrase model
- the requirement that new conversations must be explicitly requested
- the router output schema for `new_conversation`, `message`, `read_conversation_update`, `ask_clarifying_question`, and `ignore`
- the normalized `conversation_update` model and pending update buffer behavior
- the fact that the router owns short spoken feedback and update summary text
- the JSONL append-only router log for committed voice commands
- the execution flow between voice capture, router output, backend execution, backend hooks, and TTS feedback

## Notes

The documented model keeps v1 predictable:

- no implicit conversation creation
- no reliance on VAD alone for commit boundaries
- no duplication of full backend conversation history
- no standalone summarizer component outside the router
- committed commands remain inspectable through lightweight JSONL records
