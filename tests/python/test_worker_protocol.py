import base64
import json

import pytest

from worker.meeting_worker.protocol import ProtocolError, parse_message, encode_message


def test_audio_window_accepts_valid_local_float32_payload():
    samples = base64.b64encode(bytes(16_000 * 4)).decode("ascii")
    message = parse_message(json.dumps({
        "type": "audio_window", "session_id": "session-1", "start_ms": 0,
        "sample_rate_hz": 16_000, "samples_base64": samples,
    }))
    assert message.sample_count == 16_000


@pytest.mark.parametrize("value", ["{", "{}", json.dumps({"type": "stop", "session_id": ""})])
def test_rejects_malformed_messages(value):
    with pytest.raises(ProtocolError):
        parse_message(value)


def test_rejects_oversized_or_invalid_audio():
    with pytest.raises(ProtocolError):
        parse_message(" " * (4 * 1024 * 1024 + 1))
    with pytest.raises(ProtocolError):
        parse_message(json.dumps({
            "type": "audio_window", "session_id": "s", "start_ms": 0,
            "sample_rate_hz": 8000, "samples_base64": base64.b64encode(b"\0\0").decode(),
        }))


def test_encodes_one_newline_delimited_response():
    encoded = encode_message({"type": "status", "state": "ready", "message": "Local"})
    assert encoded.endswith("\n")
    assert json.loads(encoded) == {"type": "status", "state": "ready", "message": "Local"}
