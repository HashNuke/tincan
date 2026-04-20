## Status

DONE

## Problem

The Go server could transcribe uploaded speech, but there was no router step between the transcript and server actions.

That meant transcripts were not yet being interpreted into the structured actions described in the router spec, and explicit new-conversation commands were not flowing through the intended decision point.

## Solution

Implemented the first Go router pass:

- added `router.go`
- added a `Router` service with `RouteUserTranscript`
- added structured router results including:
  - `action`
  - `message`
  - `agent`
  - `conversation_title`
  - `immediate_feedback`
  - `raw_transcript`
- the first router implementation is rule-based
- explicit new-conversation phrases now route to `new_conversation`
- ambiguous inputs return `ask_clarifying_question`
- empty inputs return `ignore`
- `handleUtteranceUpload` now routes transcripts before taking action
- `new_conversation` router results are executed through `ConversationService`

## Notes

This is intentionally the first pass.
It establishes the correct architectural shape:

- transcript
- router
- structured action
- service execution

The router is still intentionally narrow and can be expanded later for existing conversation messaging, update readouts, and context switching.
