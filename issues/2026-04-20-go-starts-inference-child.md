## Status

DONE

## Problem

Running the Go server and the Swift inference service as separate manual processes made local development clumsy.

The Go server needed a simple way to ensure the local inference service was available before handling STT or TTS requests.

## Solution

Added a small inference supervisor to `tincan-server`:

- the Go server now checks whether the Unix socket is already ready
- if not, it starts `tincan-inference-macos` as a child process using `swift run`
- it waits for the socket at `~/Library/Application Support/tincan/run/inference.sock` to become ready before serving requests
- it forwards the child process stdout and stderr to the current terminal
- it shuts the child process down when the Go server exits

## Notes

This keeps local startup simple:

- start the Go server
- let it bring up the Swift inference service automatically if needed
- reuse an already-running inference service when the socket is available
