#!/usr/bin/env python3
from __future__ import annotations

import argparse
import array
import asyncio
import base64
import contextlib
import io
import json
import queue as thread_queue
import sys
import tempfile
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib import error as urlerror
from urllib import request as urlrequest

import av
import sounddevice as sd
from aiortc import RTCPeerConnection, RTCSessionDescription
from aiortc.mediastreams import MediaStreamError


DEFAULT_SERVER_URL = "http://127.0.0.1:55055"
TINCAN_CHANNEL_LABEL = "tincan"
SEND_SAMPLE_RATE = 16_000
PLAY_SAMPLE_RATE = 48_000
HEARTBEAT_INTERVAL_SECONDS = 5.0


@dataclass(frozen=True)
class DecodedAudio:
    pcm_s16: bytes
    sample_rate: int
    channels: int
    duration_seconds: float


class HarnessError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Send prerecorded audio to tincan either through the app's WebRTC transport "
            "or into a loopback output device such as BlackHole."
        )
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    send_parser = subparsers.add_parser(
        "send",
        help="Connect to tincan-server over WebRTC and send audio as utterances",
    )
    send_parser.add_argument("audio", nargs="+", type=Path, help="Audio file(s) to send")
    send_parser.add_argument(
        "--server",
        default=DEFAULT_SERVER_URL,
        help=f"tincan server base URL (default: {DEFAULT_SERVER_URL})",
    )
    send_parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="Number of times to send each provided audio file",
    )
    send_parser.add_argument(
        "--between",
        type=float,
        default=0.25,
        help="Seconds to wait between utterances",
    )
    send_parser.add_argument(
        "--response-timeout",
        type=float,
        default=60.0,
        help="Seconds to wait for each utterance_result",
    )
    send_parser.add_argument(
        "--keep-open",
        action="store_true",
        help="Keep the WebRTC session open after sending the last utterance",
    )
    send_parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print connection state changes and non-result data channel traffic",
    )
    send_parser.add_argument(
        "--device",
        help="Output device index or a case-insensitive substring of the output device name",
    )
    send_parser.add_argument(
        "--sample-rate",
        type=int,
        default=PLAY_SAMPLE_RATE,
        help=f"Playback output sample rate (default: {PLAY_SAMPLE_RATE})",
    )
    send_parser.add_argument(
        "--stereo",
        action="store_true",
        help="Preserve stereo instead of downmixing to mono for received audio playback",
    )
    send_parser.add_argument(
        "--volume",
        type=float,
        default=1.0,
        help="Linear gain multiplier for received audio playback (default: 1.0)",
    )

    interactive_parser = subparsers.add_parser(
        "interactive",
        help="Keep a WebRTC session open and drive it with SAY/FILE commands from stdin",
    )
    interactive_parser.add_argument(
        "--server",
        default=DEFAULT_SERVER_URL,
        help=f"tincan server base URL (default: {DEFAULT_SERVER_URL})",
    )
    interactive_parser.add_argument(
        "--response-timeout",
        type=float,
        default=60.0,
        help="Seconds to wait for each utterance_result",
    )
    interactive_parser.add_argument(
        "--device",
        help="Output device index or a case-insensitive substring of the output device name",
    )
    interactive_parser.add_argument(
        "--sample-rate",
        type=int,
        default=PLAY_SAMPLE_RATE,
        help=f"Playback output sample rate (default: {PLAY_SAMPLE_RATE})",
    )
    interactive_parser.add_argument(
        "--stereo",
        action="store_true",
        help="Preserve stereo instead of downmixing to mono for received audio playback",
    )
    interactive_parser.add_argument(
        "--volume",
        type=float,
        default=1.0,
        help="Linear gain multiplier for received audio playback (default: 1.0)",
    )
    interactive_parser.add_argument(
        "--voice",
        help="Optional macOS say voice name for SAY commands",
    )
    interactive_parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print connection state changes and raw non-result data channel traffic",
    )

    play_parser = subparsers.add_parser(
        "play",
        help="Play audio into a selected output device such as BlackHole",
    )
    play_parser.add_argument("audio", nargs="+", type=Path, help="Audio file(s) to play")
    play_parser.add_argument(
        "--device",
        help="Output device index or a case-insensitive substring of the output device name",
    )
    play_parser.add_argument(
        "--sample-rate",
        type=int,
        default=PLAY_SAMPLE_RATE,
        help=f"Output sample rate (default: {PLAY_SAMPLE_RATE})",
    )
    play_parser.add_argument(
        "--repeat",
        type=int,
        default=1,
        help="Number of times to play each provided audio file",
    )
    play_parser.add_argument(
        "--gap",
        type=float,
        default=0.25,
        help="Seconds to wait between playbacks",
    )
    play_parser.add_argument(
        "--stereo",
        action="store_true",
        help="Preserve stereo instead of downmixing to mono",
    )
    play_parser.add_argument(
        "--volume",
        type=float,
        default=1.0,
        help="Linear gain multiplier for playback (default: 1.0)",
    )

    subparsers.add_parser(
        "devices",
        help="List available audio devices so you can pick a loopback output",
    )

    return parser.parse_args()


def ensure_existing_file(path: Path) -> Path:
    resolved = path.expanduser().resolve()
    if not resolved.is_file():
        raise HarnessError(f"audio file not found: {path}")
    return resolved


def decode_audio(path: Path, sample_rate: int, channels: int) -> DecodedAudio:
    return decode_audio_input(
        lambda: av.open(str(path)),
        source_label=str(path),
        sample_rate=sample_rate,
        channels=channels,
    )


def decode_audio_input(
    open_container: Callable[[], Any],
    source_label: str,
    sample_rate: int,
    channels: int,
) -> DecodedAudio:
    if channels not in (1, 2):
        raise HarnessError(f"unsupported channel count: {channels}")

    layout = "mono" if channels == 1 else "stereo"
    pcm_chunks: list[bytes] = []
    total_samples = 0

    try:
        container = open_container()
    except Exception as exc:  # pragma: no cover - PyAV error types vary by codec
        raise HarnessError(f"failed to open audio source {source_label}: {exc}") from exc

    try:
        stream = next((candidate for candidate in container.streams if candidate.type == "audio"), None)
        if stream is None:
            raise HarnessError(f"no audio stream found in {source_label}")

        resampler = av.AudioResampler(format="s16", layout=layout, rate=sample_rate)

        for frame in container.decode(stream):
            total_samples += collect_resampled_pcm(resampler.resample(frame), pcm_chunks)

        total_samples += collect_resampled_pcm(resampler.resample(None), pcm_chunks)
    finally:
        container.close()

    pcm_s16 = b"".join(pcm_chunks)
    if not pcm_s16:
        raise HarnessError(f"decoded audio was empty: {source_label}")

    duration_seconds = total_samples / sample_rate if total_samples else 0.0
    return DecodedAudio(
        pcm_s16=pcm_s16,
        sample_rate=sample_rate,
        channels=channels,
        duration_seconds=duration_seconds,
    )


def collect_resampled_pcm(result: Any, chunks: list[bytes]) -> int:
    if result is None:
        return 0

    frames = result if isinstance(result, list) else [result]
    total_samples = 0
    for frame in frames:
        chunks.append(bytes(frame.planes[0]))
        total_samples += frame.samples
    return total_samples


def pcm_to_wav_bytes(pcm_s16: bytes, sample_rate: int, channels: int) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(2)
        wav_file.setframerate(sample_rate)
        wav_file.writeframes(pcm_s16)
    return buffer.getvalue()


def scale_pcm_volume(pcm_s16: bytes, volume: float) -> bytes:
    if volume == 1.0:
        return pcm_s16
    if volume < 0:
        raise HarnessError("volume must be >= 0")

    samples = array.array("h")
    samples.frombytes(pcm_s16)
    for index, sample in enumerate(samples):
        scaled = int(round(sample * volume))
        samples[index] = max(-32_768, min(32_767, scaled))
    return samples.tobytes()


def list_audio_devices() -> None:
    default_input, default_output = sd.default.device
    for index, device in enumerate(sd.query_devices()):
        default_marker = []
        if index == default_input:
            default_marker.append("default-in")
        if index == default_output:
            default_marker.append("default-out")
        marker = f" [{' '.join(default_marker)}]" if default_marker else ""
        print(
            f"{index:>2}: {device['name']}{marker}\n"
            f"    in={device['max_input_channels']} out={device['max_output_channels']} "
            f"default_sr={device['default_samplerate']:.0f}"
        )


def resolve_output_device(spec: str | None) -> int | None:
    if spec is None:
        return None

    devices = list(sd.query_devices())
    if spec.isdigit():
        index = int(spec)
        if not 0 <= index < len(devices):
            raise HarnessError(f"device index out of range: {index}")
        if devices[index]["max_output_channels"] <= 0:
            raise HarnessError(f"device {index} is not an output device: {devices[index]['name']}")
        return index

    needle = spec.casefold()
    matches = [
        (index, device)
        for index, device in enumerate(devices)
        if device["max_output_channels"] > 0 and needle in device["name"].casefold()
    ]
    if not matches:
        raise HarnessError(f"no output device matched {spec!r}")
    if len(matches) > 1:
        matched_names = ", ".join(f"{index}:{device['name']}" for index, device in matches)
        raise HarnessError(f"multiple output devices matched {spec!r}: {matched_names}")
    return matches[0][0]


def device_label(index: int | None) -> str:
    if index is None:
        return "system default output"
    return f"{index}: {sd.query_devices(index)['name']}"


def text_value(value: Any) -> str:
    if value is None:
        return ""
    return str(value)


def playback_layout(channels: int) -> str:
    if channels == 1:
        return "mono"
    if channels == 2:
        return "stereo"
    raise HarnessError(f"unsupported playback channel count: {channels}")


def collect_resampled_pcm_bytes(
    resampler: av.AudioResampler,
    frame: av.AudioFrame | None,
) -> list[bytes]:
    chunks: list[bytes] = []
    collect_resampled_pcm(resampler.resample(frame), chunks)
    return chunks


class RemoteAudioPlayer:
    def __init__(
        self,
        *,
        output_device: int | None,
        sample_rate: int,
        channels: int,
        volume: float,
    ) -> None:
        self.output_device = output_device
        self.sample_rate = sample_rate
        self.channels = channels
        self.volume = volume
        self.layout = playback_layout(channels)
        self._queue: thread_queue.Queue[bytes] = thread_queue.Queue(maxsize=128)
        self._pending = bytearray()
        self._stream: sd.RawOutputStream | None = None

    def start(self) -> None:
        if self._stream is not None:
            return
        self._stream = sd.RawOutputStream(
            samplerate=self.sample_rate,
            channels=self.channels,
            dtype="int16",
            device=self.output_device,
            callback=self._callback,
        )
        self._stream.start()

    def stop(self) -> None:
        stream = self._stream
        self._stream = None
        self._pending.clear()
        self._drain_queue()
        if stream is None:
            return
        with contextlib.suppress(Exception):
            stream.stop()
        with contextlib.suppress(Exception):
            stream.close()

    def enqueue_pcm(self, pcm_s16: bytes) -> None:
        if not pcm_s16:
            return
        self.start()
        scaled_pcm = scale_pcm_volume(pcm_s16, self.volume)
        try:
            self._queue.put_nowait(scaled_pcm)
        except thread_queue.Full:
            with contextlib.suppress(thread_queue.Empty):
                self._queue.get_nowait()
            with contextlib.suppress(thread_queue.Full):
                self._queue.put_nowait(scaled_pcm)

    def _drain_queue(self) -> None:
        while True:
            with contextlib.suppress(thread_queue.Empty):
                self._queue.get_nowait()
                continue
            return

    def _callback(self, outdata: Any, frames: int, time_info: Any, status: Any) -> None:
        del time_info
        if status:
            print(f"[playback] output status: {status}", file=sys.stderr)

        bytes_needed = frames * self.channels * 2
        output_view = memoryview(outdata).cast("B")
        written = 0

        while written < bytes_needed:
            if not self._pending:
                try:
                    self._pending.extend(self._queue.get_nowait())
                except thread_queue.Empty:
                    break

            chunk_size = min(bytes_needed - written, len(self._pending))
            output_view[written : written + chunk_size] = self._pending[:chunk_size]
            del self._pending[:chunk_size]
            written += chunk_size

        if written < bytes_needed:
            output_view[written:bytes_needed] = b"\x00" * (bytes_needed - written)


def http_json(method: str, url: str, payload: dict[str, Any] | None = None, timeout: float = 15.0) -> dict[str, Any]:
    headers = {"content-type": "application/json"} if payload is not None else {}
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    request = urlrequest.Request(url, data=body, headers=headers, method=method)

    try:
        with urlrequest.urlopen(request, timeout=timeout) as response:
            raw_body = response.read()
    except urlerror.HTTPError as exc:
        response_body = exc.read().decode("utf-8", errors="replace").strip()
        message = response_body or exc.reason
        raise HarnessError(f"{method} {url} failed with HTTP {exc.code}: {message}") from exc
    except OSError as exc:
        raise HarnessError(f"{method} {url} failed: {exc}") from exc

    if not raw_body:
        return {}

    try:
        return json.loads(raw_body)
    except json.JSONDecodeError as exc:
        preview = raw_body.decode("utf-8", errors="replace").strip()
        raise HarnessError(f"{method} {url} returned invalid JSON: {preview}") from exc


def http_delete(url: str, timeout: float = 5.0) -> None:
    request = urlrequest.Request(url, method="DELETE")
    try:
        with urlrequest.urlopen(request, timeout=timeout):
            return
    except urlerror.HTTPError as exc:
        if exc.code == 404:
            return
        response_body = exc.read().decode("utf-8", errors="replace").strip()
        message = response_body or exc.reason
        raise HarnessError(f"DELETE {url} failed with HTTP {exc.code}: {message}") from exc
    except OSError as exc:
        raise HarnessError(f"DELETE {url} failed: {exc}") from exc


async def wait_for_ice_complete(peer_connection: RTCPeerConnection, timeout: float) -> None:
    deadline = asyncio.get_running_loop().time() + timeout
    while peer_connection.iceGatheringState != "complete":
        if asyncio.get_running_loop().time() >= deadline:
            raise HarnessError(f"timed out after {timeout:.1f}s waiting for ICE gathering")
        await asyncio.sleep(0.05)


class TincanWebRTCClient:
    def __init__(
        self,
        server_url: str,
        *,
        verbose: bool = False,
        remote_audio_player: RemoteAudioPlayer | None = None,
    ) -> None:
        self.server_url = server_url.rstrip("/")
        self.verbose = verbose
        self.remote_audio_player = remote_audio_player
        self.peer_connection = RTCPeerConnection()
        self.data_channel = self.peer_connection.createDataChannel(TINCAN_CHANNEL_LABEL)
        self.data_channel_open = asyncio.Event()
        self.event_queue: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.pending_results: dict[str, asyncio.Future[dict[str, Any]]] = {}
        self.remote_audio_tasks: set[asyncio.Task[None]] = set()
        self.session_id: str | None = None
        self.heartbeat_task: asyncio.Task[None] | None = None
        self._attach_peer_events()
        self._attach_data_channel(self.data_channel)

    async def connect(self) -> None:
        try:
            self.peer_connection.addTransceiver("audio", direction="recvonly")
            offer = await self.peer_connection.createOffer()
            await self.peer_connection.setLocalDescription(offer)
            await wait_for_ice_complete(self.peer_connection, timeout=5.0)

            local_description = self.peer_connection.localDescription
            if local_description is None or not local_description.sdp.strip():
                raise HarnessError("local SDP offer was missing after ICE gathering")

            response = http_json(
                "POST",
                f"{self.server_url}/webrtc/session",
                {"offer_sdp": local_description.sdp},
            )

            session_id = response.get("session_id")
            answer_sdp = response.get("answer_sdp")
            if not session_id or not answer_sdp:
                raise HarnessError(f"session registration returned incomplete JSON: {response}")

            self.session_id = str(session_id)
            await self.peer_connection.setRemoteDescription(
                RTCSessionDescription(sdp=str(answer_sdp), type="answer")
            )
            await asyncio.wait_for(self.data_channel_open.wait(), timeout=10.0)
            self.heartbeat_task = asyncio.create_task(self._heartbeat_loop())
        except Exception:
            await self.close()
            raise

    async def send_utterance(self, wav_bytes: bytes, response_timeout: float) -> dict[str, Any]:
        if self.data_channel.readyState != "open":
            raise HarnessError(f"data channel is not open: {self.data_channel.readyState}")

        request_id = uuid.uuid4().hex
        future: asyncio.Future[dict[str, Any]] = asyncio.get_running_loop().create_future()
        self.pending_results[request_id] = future

        payload = {
            "type": "utterance",
            "request_id": request_id,
            "content_type": "audio/wav",
            "audio_base64": base64.b64encode(wav_bytes).decode("ascii"),
        }
        self.data_channel.send(json.dumps(payload))

        try:
            return await asyncio.wait_for(future, timeout=response_timeout)
        finally:
            self.pending_results.pop(request_id, None)

    async def close(self) -> None:
        session_url = None
        if self.session_id:
            session_url = f"{self.server_url}/webrtc/session/{self.session_id}"

        self._fail_pending(HarnessError("session closed"))
        self.session_id = None

        if session_url is not None:
            with contextlib.suppress(HarnessError):
                http_delete(session_url)

        if self.heartbeat_task is not None:
            self.heartbeat_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self.heartbeat_task
            self.heartbeat_task = None

        for task in list(self.remote_audio_tasks):
            task.cancel()
        for task in list(self.remote_audio_tasks):
            with contextlib.suppress(asyncio.CancelledError):
                await task
        self.remote_audio_tasks.clear()

        await self.peer_connection.close()

    def _attach_peer_events(self) -> None:
        @self.peer_connection.on("connectionstatechange")
        def on_connectionstatechange() -> None:
            state = self.peer_connection.connectionState
            if self.verbose:
                print(f"[webrtc] connection state -> {state}", file=sys.stderr)
            if state in {"closed", "failed"}:
                self._fail_pending(HarnessError(f"peer connection closed in state {state}"))

        @self.peer_connection.on("track")
        def on_track(track: Any) -> None:
            kind = getattr(track, "kind", "unknown")
            if self.verbose:
                print(f"[webrtc] remote track received: {kind}", file=sys.stderr)

            if kind != "audio" or self.remote_audio_player is None:
                return

            task = asyncio.create_task(self._consume_remote_audio_track(track))
            self.remote_audio_tasks.add(task)

            def on_done(done_task: asyncio.Task[None]) -> None:
                self.remote_audio_tasks.discard(done_task)

            task.add_done_callback(on_done)

    def _attach_data_channel(self, channel: Any) -> None:
        @channel.on("open")
        def on_open() -> None:
            if self.verbose:
                print(f"[webrtc] data channel {channel.label} opened", file=sys.stderr)
            self.data_channel_open.set()

        @channel.on("close")
        def on_close() -> None:
            if self.verbose:
                print(f"[webrtc] data channel {channel.label} closed", file=sys.stderr)
            self._fail_pending(HarnessError("data channel closed"))

        @channel.on("message")
        def on_message(message: Any) -> None:
            self._handle_data_channel_message(message)

    def _handle_data_channel_message(self, message: Any) -> None:
        if isinstance(message, bytes):
            text = message.decode("utf-8", errors="replace")
        else:
            text = str(message)

        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            if self.verbose:
                print(f"[webrtc] ignored non-JSON message: {text}", file=sys.stderr)
            return

        message_type = payload.get("type")
        if message_type == "utterance_result":
            request_id = payload.get("request_id")
            if not request_id:
                return
            future = self.pending_results.get(str(request_id))
            if future is None or future.done():
                return
            error_message = payload.get("error")
            if error_message:
                future.set_exception(HarnessError(str(error_message)))
            else:
                future.set_result(payload)
            return

        if self.verbose:
            print(f"[webrtc] event {message_type}: {json.dumps(payload, ensure_ascii=False)}", file=sys.stderr)
        self.event_queue.put_nowait(payload)

    def _fail_pending(self, exc: Exception) -> None:
        for future in self.pending_results.values():
            if not future.done():
                future.set_exception(exc)

    async def _heartbeat_loop(self) -> None:
        try:
            while True:
                await asyncio.sleep(HEARTBEAT_INTERVAL_SECONDS)
                if self.data_channel.readyState != "open":
                    continue
                self.data_channel.send(json.dumps({"type": "ping"}))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            if self.verbose:
                print(f"[webrtc] heartbeat loop failed: {exc}", file=sys.stderr)

    async def _consume_remote_audio_track(self, track: Any) -> None:
        if self.remote_audio_player is None:
            return

        resampler = av.AudioResampler(
            format="s16",
            layout=self.remote_audio_player.layout,
            rate=self.remote_audio_player.sample_rate,
        )

        try:
            while True:
                frame = await track.recv()
                for chunk in collect_resampled_pcm_bytes(resampler, frame):
                    self.remote_audio_player.enqueue_pcm(chunk)
        except MediaStreamError:
            if self.verbose:
                print("[webrtc] remote audio track ended", file=sys.stderr)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            print(f"[webrtc] remote audio track failed: {exc}", file=sys.stderr)
        finally:
            for chunk in collect_resampled_pcm_bytes(resampler, None):
                self.remote_audio_player.enqueue_pcm(chunk)


async def run_send(args: argparse.Namespace) -> int:
    audio_paths = build_audio_sequence(args.audio, args.repeat)
    output_device = resolve_output_device(args.device)
    remote_audio_player = RemoteAudioPlayer(
        output_device=output_device,
        sample_rate=args.sample_rate,
        channels=2 if args.stereo else 1,
        volume=args.volume,
    )
    client = TincanWebRTCClient(
        args.server,
        verbose=args.verbose,
        remote_audio_player=remote_audio_player,
    )
    await client.connect()

    print(f"Connected to {args.server} with session {client.session_id}")
    print(f"Playback output: {device_label(output_device)}")

    try:
        for index, audio_path in enumerate(audio_paths, start=1):
            decoded = decode_audio(audio_path, sample_rate=SEND_SAMPLE_RATE, channels=1)
            wav_bytes = pcm_to_wav_bytes(decoded.pcm_s16, decoded.sample_rate, decoded.channels)

            print(
                f"[{index}/{len(audio_paths)}] sending {audio_path} "
                f"({decoded.duration_seconds:.2f}s, {len(wav_bytes)} bytes wav)"
            )
            response = await client.send_utterance(
                wav_bytes=wav_bytes,
                response_timeout=args.response_timeout,
            )

            transcript = text_value(response.get("text")).strip()
            print(f"Transcript: {transcript or '(empty)'}")

            if index < len(audio_paths):
                await asyncio.sleep(args.between)

        if args.keep_open:
            print("Session left open. Press Ctrl+C to close it.")
            while True:
                await asyncio.sleep(3600)
    finally:
        await client.close()
        remote_audio_player.stop()

    return 0


def play_decoded_audio(decoded: DecodedAudio, output_device: int | None, volume: float) -> None:
    pcm_s16 = scale_pcm_volume(decoded.pcm_s16, volume)
    chunk_size_bytes = 4096 * decoded.channels * 2

    with sd.RawOutputStream(
        samplerate=decoded.sample_rate,
        channels=decoded.channels,
        dtype="int16",
        device=output_device,
    ) as output_stream:
        for offset in range(0, len(pcm_s16), chunk_size_bytes):
            output_stream.write(pcm_s16[offset : offset + chunk_size_bytes])


async def run_play(args: argparse.Namespace) -> int:
    audio_paths = build_audio_sequence(args.audio, args.repeat)
    output_device = resolve_output_device(args.device)
    output_label = device_label(output_device)
    channel_count = 2 if args.stereo else 1

    print(f"Playing into {output_label}")
    print("Point the tincan app's input device at the same loopback device if you want the Swift app to consume it.")

    for index, audio_path in enumerate(audio_paths, start=1):
        decoded = decode_audio(audio_path, sample_rate=args.sample_rate, channels=channel_count)

        print(
            f"[{index}/{len(audio_paths)}] playing {audio_path} "
            f"({decoded.duration_seconds:.2f}s, {decoded.sample_rate} Hz, {decoded.channels} ch)"
        )

        play_decoded_audio(
            DecodedAudio(
                pcm_s16=scale_pcm_volume(decoded.pcm_s16, args.volume),
                sample_rate=decoded.sample_rate,
                channels=decoded.channels,
                duration_seconds=decoded.duration_seconds,
            ),
            output_device=output_device,
            volume=1.0,
        )

        if index < len(audio_paths):
            await asyncio.sleep(args.gap)

    return 0


def interactive_prompt() -> str | None:
    try:
        return input("tincan> ")
    except EOFError:
        return None


def parse_interactive_command(line: str) -> tuple[str, str | None]:
    stripped = line.strip()
    if not stripped:
        return "empty", None

    command, separator, remainder = stripped.partition(" ")
    normalized = command.casefold()
    payload = remainder.strip() if separator else ""

    if normalized in {"exit", "quit"}:
        return "exit", None
    if normalized in {"help", "?"}:
        return "help", None
    if normalized == "say":
        return "say", payload
    if normalized == "file":
        return "file", payload
    return "say", stripped


async def synthesize_say_audio(text: str, destination_dir: Path, voice: str | None) -> Path:
    if not text.strip():
        raise HarnessError("SAY requires non-empty text")

    output_path = destination_dir / f"{uuid.uuid4().hex}.aiff"
    command = ["say", "-o", str(output_path)]
    if voice:
        command.extend(["-v", voice])
    command.append(text)

    try:
        process = await asyncio.create_subprocess_exec(
            *command,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
        )
    except FileNotFoundError as exc:
        raise HarnessError("macOS 'say' command was not found") from exc

    _, stderr = await process.communicate()
    if process.returncode != 0:
        message = stderr.decode("utf-8", errors="replace").strip()
        raise HarnessError(message or f"'say' failed with exit code {process.returncode}")

    return ensure_existing_file(output_path)


async def consume_server_events(
    client: TincanWebRTCClient,
) -> None:
    while True:
        payload = await client.event_queue.get()
        try:
            message_type = text_value(payload.get("type")).strip() or "unknown"

            if message_type == "play_audio":
                text = text_value(payload.get("text")).strip()
                print(f"[event] play_audio: {text or '(empty)'}")
                continue

            if message_type == "notify":
                text = text_value(payload.get("text")).strip()
                summary_text = text_value(payload.get("summary_text")).strip()
                print(f"[event] notify: {summary_text or text or '(empty)'}")
                continue

            print(f"[event] {message_type}: {json.dumps(payload, ensure_ascii=False)}")
        finally:
            client.event_queue.task_done()


async def send_audio_path(
    client: TincanWebRTCClient,
    audio_path: Path,
    response_timeout: float,
) -> None:
    decoded = decode_audio(audio_path, sample_rate=SEND_SAMPLE_RATE, channels=1)
    wav_bytes = pcm_to_wav_bytes(decoded.pcm_s16, decoded.sample_rate, decoded.channels)

    print(
        f"Sending {audio_path} "
        f"({decoded.duration_seconds:.2f}s, {len(wav_bytes)} bytes wav)"
    )
    response = await client.send_utterance(wav_bytes=wav_bytes, response_timeout=response_timeout)

    transcript = text_value(response.get("text")).strip()
    print(f"Transcript: {transcript or '(empty)'}")


async def run_interactive(args: argparse.Namespace) -> int:
    output_device = resolve_output_device(args.device)
    remote_audio_player = RemoteAudioPlayer(
        output_device=output_device,
        sample_rate=args.sample_rate,
        channels=2 if args.stereo else 1,
        volume=args.volume,
    )
    client = TincanWebRTCClient(
        args.server,
        verbose=args.verbose,
        remote_audio_player=remote_audio_player,
    )

    event_task: asyncio.Task[None] | None = None

    await client.connect()
    print(f"Connected to {args.server} with session {client.session_id}")
    print(f"Playback output: {device_label(output_device)}")
    print("Commands: SAY <text>, FILE <path>, HELP, EXIT")
    print("Bare text is treated as SAY.")

    try:
        event_task = asyncio.create_task(consume_server_events(client))

        with tempfile.TemporaryDirectory(prefix="tincan-audio-harness-") as temp_dir:
            temp_dir_path = Path(temp_dir)

            while True:
                line = await asyncio.to_thread(interactive_prompt)
                if line is None:
                    print("EOF received. Closing session.")
                    break

                command, payload = parse_interactive_command(line)
                if command == "empty":
                    continue
                if command == "help":
                    print("Commands: SAY <text>, FILE <path>, HELP, EXIT")
                    print("Bare text is treated as SAY.")
                    continue
                if command == "exit":
                    break

                try:
                    if command == "say":
                        audio_path = await synthesize_say_audio(payload or "", temp_dir_path, args.voice)
                    elif command == "file":
                        if not payload:
                            raise HarnessError("FILE requires a path")
                        audio_path = ensure_existing_file(Path(payload))
                    else:
                        raise HarnessError(f"unsupported interactive command: {command}")

                    await send_audio_path(
                        client=client,
                        audio_path=audio_path,
                        response_timeout=args.response_timeout,
                    )
                except HarnessError as exc:
                    print(f"error: {exc}", file=sys.stderr)
    finally:
        if event_task is not None:
            event_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await event_task
        await client.close()
        remote_audio_player.stop()

    return 0


def build_audio_sequence(audio_args: list[Path], repeat: int) -> list[Path]:
    if repeat < 1:
        raise HarnessError("--repeat must be >= 1")

    sequence: list[Path] = []
    for _ in range(repeat):
        for path in audio_args:
            sequence.append(ensure_existing_file(path))
    return sequence


async def async_main() -> int:
    args = parse_args()
    if args.command == "devices":
        list_audio_devices()
        return 0
    if args.command == "send":
        return await run_send(args)
    if args.command == "interactive":
        return await run_interactive(args)
    if args.command == "play":
        return await run_play(args)
    raise HarnessError(f"unsupported command: {args.command}")


def main() -> int:
    try:
        return asyncio.run(async_main())
    except KeyboardInterrupt:
        print("Interrupted.", file=sys.stderr)
        return 130
    except HarnessError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
