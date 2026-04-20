## Status

PARTIAL

## Problem

Conversation creation needed a modular way to produce spoken intro text without committing early to a real summarization model.

The server needed a tiny internal plugin path for summarization so profiles could select an implementation, while the first implementation stayed extremely simple.

## Solution

Implemented an internal summarizer plugin registry with a built-in `no-summary` plugin:

- added a `Summarizer` protocol and `PluginRegistry`
- added `NoSummarySummarizer`, which returns the original input text unchanged
- extended agent profiles with a `summarizer` field
- configured bundled profiles to use `no-summary`
- `POST /conversations` now resolves the profile's summarizer plugin
- conversation creation returns both `summary` and `announcement_text` so the app can speak the intro immediately

## Notes

This was intentionally minimal:

- there is no dynamic plugin loader
- there is no user scripting surface
- only the `Summarizer` plugin type was introduced
- the current plugin simply passed through the original prompt text

## Follow-up

This approach was later superseded.
The project direction moved summary-like behavior into the router itself, so the standalone `no-summary` plugin is no longer needed.
