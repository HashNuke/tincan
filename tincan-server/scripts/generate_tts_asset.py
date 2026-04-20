#!/usr/bin/env python3

import argparse
import json
import socket
import struct
import sys
import uuid
from pathlib import Path


def send_message(sock: socket.socket, header: dict, body: bytes) -> None:
    header_bytes = json.dumps(header).encode("utf-8")
    sock.sendall(struct.pack(">I", len(header_bytes)))
    sock.sendall(header_bytes)
    if body:
        sock.sendall(body)


def recv_exact(sock: socket.socket, byte_count: int) -> bytes:
    chunks = []
    remaining = byte_count
    while remaining > 0:
        chunk = sock.recv(remaining)
        if not chunk:
            raise RuntimeError("socket closed while reading response")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def recv_message(sock: socket.socket) -> tuple[dict, bytes]:
    header_len_bytes = recv_exact(sock, 4)
    header_len = struct.unpack(">I", header_len_bytes)[0]
    header = json.loads(recv_exact(sock, header_len).decode("utf-8"))
    body = recv_exact(sock, header.get("body_length", 0)) if header.get("body_length", 0) else b""
    return header, body


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a bundled PocketTTS WAV asset via tincan-inference-macos")
    parser.add_argument("text", help="Text to synthesize")
    parser.add_argument("output", help="Path to output wav file")
    parser.add_argument("--voice", default="alba", help="PocketTTS voice")
    parser.add_argument(
        "--socket",
        default=str(Path.home() / "Library/Application Support/tincan/run/inference.sock"),
        help="Unix socket path for tincan-inference-macos",
    )
    args = parser.parse_args()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    body = json.dumps({"text": args.text, "voice": args.voice}).encode("utf-8")
    header = {
        "kind": "request",
        "request_id": str(uuid.uuid4()),
        "action": "tts",
        "model": "pockettts",
        "content_type": "application/json",
        "body_length": len(body),
        "voice": args.voice,
        "text_format": "plain",
    }

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(args.socket)
        send_message(sock, header, body)
        response_header, response_body = recv_message(sock)

    if response_header.get("kind") == "error":
        print(f"TTS request failed: {response_header.get('message', 'unknown error')}", file=sys.stderr)
        return 1

    if response_header.get("kind") != "result" or response_header.get("action") != "tts":
        print(f"Unexpected response: {response_header}", file=sys.stderr)
        return 1

    output_path.write_bytes(response_body)
    print(f"Wrote {len(response_body)} bytes to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
