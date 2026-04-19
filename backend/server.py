from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
import time
import uuid
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
import uvicorn


PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 8004

app = FastAPI(title="tincan local backend", version="0.1.0")


@lru_cache(maxsize=1)
def fluidaudio_package_path() -> Path:
    override = os.environ.get("TINCAN_FLUIDAUDIO_PACKAGE_PATH")
    if override:
        path = Path(override).expanduser().resolve()
        if (path / "Package.swift").exists():
            return path

    derived_data_root = Path.home() / "Library" / "Developer" / "Xcode" / "DerivedData"
    candidates = list(derived_data_root.rglob("SourcePackages/checkouts/FluidAudio/Package.swift"))
    if not candidates:
        raise RuntimeError(
            "Could not find a FluidAudio checkout. Resolve package dependencies in Xcode first."
        )

    newest = max(candidates, key=lambda candidate: candidate.stat().st_mtime)
    return newest.parent


def transcribe_wav(audio_path: Path) -> str:
    package_path = fluidaudio_package_path()
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as json_file:
        json_path = Path(json_file.name)

    command = [
        "xcrun",
        "swift",
        "run",
        "--package-path",
        str(package_path),
        "fluidaudiocli",
        "transcribe",
        str(audio_path),
        "--output-json",
        str(json_path),
    ]

    started_at = time.monotonic()
    completed = subprocess.run(
        command,
        cwd=package_path,
        capture_output=True,
        text=True,
        check=False,
    )
    elapsed = time.monotonic() - started_at

    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        raise RuntimeError(
            f"FluidAudio transcription failed after {elapsed:.2f}s\nstdout:\n{stdout}\nstderr:\n{stderr}"
        )

    try:
        output = json.loads(json_path.read_text())
    finally:
        json_path.unlink(missing_ok=True)

    transcript = str(output.get("text", "")).strip()
    print(f"[tincan-backend] transcript ({elapsed:.2f}s): {transcript}", flush=True)
    return transcript


@app.get("/health")
def health() -> dict[str, str]:
    return {
        "status": "ok",
        "fluidaudio_package_path": str(fluidaudio_package_path()),
    }


@app.post("/infer")
async def infer(request: Request) -> dict[str, str]:
    payload = await request.body()
    if not payload:
        raise HTTPException(status_code=400, detail="Expected a WAV request body")

    request_id = str(uuid.uuid4())
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as wav_file:
        wav_path = Path(wav_file.name)
        wav_file.write(payload)

    try:
        transcript = transcribe_wav(wav_path)
    except Exception as error:  # pragma: no cover - surfaced to the app and console
        print(f"[tincan-backend] inference failed: {error}", flush=True)
        raise HTTPException(status_code=500, detail=str(error)) from error
    finally:
        wav_path.unlink(missing_ok=True)

    return {
        "requestId": request_id,
        "transcript": transcript,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the tincan local STT server.")
    parser.add_argument("--host", default=DEFAULT_HOST)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    print(
        f"[tincan-backend] starting on {args.host}:{args.port} using {fluidaudio_package_path()}",
        flush=True,
    )
    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
