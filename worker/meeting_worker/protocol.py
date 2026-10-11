import base64
import binascii
import json
from dataclasses import dataclass
from typing import Any

MAX_MESSAGE_BYTES = 4 * 1024 * 1024
MAX_AUDIO_SECONDS = 30
SAMPLE_RATE_HZ = 16_000


class ProtocolError(ValueError):
    pass


@dataclass(frozen=True)
class AudioWindow:
    session_id: str
    start_ms: int
    sample_rate_hz: int
    samples: bytes

    @property
    def sample_count(self) -> int:
        return len(self.samples) // 4


@dataclass(frozen=True)
class Stop:
    session_id: str


def parse_message(line: str) -> AudioWindow | Stop:
    if len(line.encode("utf-8")) > MAX_MESSAGE_BYTES:
        raise ProtocolError("Message exceeds the size limit")
    try:
        value = json.loads(line)
    except (json.JSONDecodeError, UnicodeEncodeError) as error:
        raise ProtocolError("Message must be valid JSON") from error
    if not isinstance(value, dict):
        raise ProtocolError("Message must be a JSON object")
    kind = value.get("type")
    session_id = value.get("session_id")
    if not isinstance(session_id, str) or not session_id or len(session_id) > 128:
        raise ProtocolError("session_id must be a non-empty string of at most 128 characters")
    if kind == "stop":
        return Stop(session_id)
    if kind != "audio_window":
        raise ProtocolError("Unsupported message type")
    start_ms = value.get("start_ms")
    sample_rate = value.get("sample_rate_hz")
    payload = value.get("samples_base64")
    if isinstance(start_ms, bool) or not isinstance(start_ms, int) or start_ms < 0:
        raise ProtocolError("start_ms must be a non-negative integer")
    if sample_rate != SAMPLE_RATE_HZ:
        raise ProtocolError("Audio must be 16 kHz mono float32 PCM")
    if not isinstance(payload, str):
        raise ProtocolError("samples_base64 must be a base64 string")
    try:
        samples = base64.b64decode(payload, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ProtocolError("samples_base64 is invalid") from error
    if not samples or len(samples) % 4 or len(samples) > SAMPLE_RATE_HZ * MAX_AUDIO_SECONDS * 4:
        raise ProtocolError("Audio window must contain 1 to 30 seconds of float32 samples")
    return AudioWindow(session_id, start_ms, sample_rate, samples)


def encode_message(value: dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n"
