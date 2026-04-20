## Status

DONE

## Problem

The new `tincan-inference-macos` service needed a local-only transport that the Go server could use without opening a TCP port.

It also needed a standard request/response protocol that could carry both STT and TTS requests on the same persistent connection, while allowing binary payloads for audio.

## Solution

Implemented the first Unix domain socket protocol scaffold in `tincan-inference-macos`:

- added a Unix socket server listening at `~/Library/Application Support/tincan/run/inference.sock`
- added a framed request/response protocol using:
  - 4-byte big-endian header length
  - JSON header
  - raw binary body
- added a standard envelope carrying:
  - `kind`
  - `request_id`
  - `action`
  - `model`
  - `content_type`
  - `body_length`
  - optional metadata such as sample rate, channel count, and voice
- added support for two actions:
  - `stt`
  - `tts`

## Notes

The current handlers are protocol-complete but inference-light:

- `stt` and `tts` requests are parsed through the new framed socket protocol
- the server returns structured responses on the same socket connection
- actual model execution is still stubbed and can now be wired in behind the protocol

This gives the Go server a stable local integration point without exposing a TCP port.
