## Status

DONE

## Problem

New conversations could be created and run against OpenCode, but there was no return path for agent-side updates back into the Go server and then back to the user.

That meant the system could start work but not surface later updates in any user-facing way.

## Solution

Implemented the first end-to-end update return path:

- added `POST /hooks/opencode` in the Go server
- maps OpenCode hook events back to stored conversations using `backend_conversation_id`
- on `session.idle`, fetches the latest assistant message from OpenCode
- upserts a pending `conversation_update` in the conversations store
- added `GET /updates/pending`
- added `POST /updates/:id/consume`
- updated `/speak` to poll pending updates and play a short notification sound when one arrives

## Notes

This is the first curated return path, not the final one:

- pending updates are stored and consumed through the database
- `/speak` currently uses polling rather than a push channel
- notification playback still uses a canned audio prompt rather than a router-generated spoken summary
