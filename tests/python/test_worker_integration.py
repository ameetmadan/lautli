import base64
import io
import json
import uuid

import pytest

from worker.lautli_worker.main import serve


def _audio(start_ms, session_id="s"):
    return {
        "type": "audio_window", "session_id": session_id, "start_ms": start_ms,
        "sample_rate_hz": 16000,
        "samples_base64": base64.b64encode(bytes(16 * 4)).decode(),
    }


def test_fake_worker_emits_ready_provisional_final_and_clean_stop():
    input_lines = [
        json.dumps(_audio(0)), json.dumps(_audio(1000)),
        json.dumps({"type": "stop", "session_id": "s"}),
    ]
    source = io.StringIO("\n".join(input_lines) + "\n")
    destination = io.StringIO()
    result = serve(source, destination, lambda _: [{"start_ms": 0, "end_ms": 100, "text": "Hoi."}])
    messages = [json.loads(line) for line in destination.getvalue().splitlines()]
    segments = [item["segment"]["stability"] for item in messages if item["type"] == "segment"]
    assert result == 0
    assert messages[0]["state"] == "ready"
    assert segments == ["provisional", "final"]
    assert messages[-1]["message"] == "Transcription stopped"


def test_fake_worker_rejects_malformed_input_and_exits_cleanly():
    source = io.StringIO("not-json\n")
    destination = io.StringIO()
    assert serve(source, destination, lambda _: []) == 2
    assert json.loads(destination.getvalue().splitlines()[-1])["state"] == "failed"


def test_fake_worker_accepts_stop_without_audio():
    source = io.StringIO(json.dumps({"type": "stop", "session_id": "s"}) + "\n")
    destination = io.StringIO()
    assert serve(source, destination, lambda _: []) == 0
    messages = [json.loads(line) for line in destination.getvalue().splitlines()]
    assert messages[-1] == {"type": "status", "state": "ready", "message": "Transcription stopped"}


def _file_audio(start_ms, session_id="file", sample_count=16_000):
    return {
        **_audio(start_ms, session_id), "mode": "file",
        "samples_base64": base64.b64encode(bytes(sample_count * 4)).decode(),
    }


def _serve_messages(messages, recognize):
    source = io.StringIO("".join(json.dumps(message) + "\n" for message in messages))
    destination = io.StringIO()
    result = serve(source, destination, recognize)
    return result, [json.loads(line) for line in destination.getvalue().splitlines()]


def test_file_windows_are_final_and_acknowledged_after_segments_with_recording_timestamps():
    result, messages = _serve_messages([
        _file_audio(0), _file_audio(1000), {"type": "stop", "session_id": "file"},
    ], lambda _: [{"start_ms": 100, "end_ms": 900, "text": " Grüezi. "}])
    assert result == 0
    relevant = [message for message in messages if message["type"] != "status"]
    assert [message["type"] for message in relevant] == [
        "segment", "window_complete", "segment", "window_complete",
    ]
    first, second = relevant[0]["segment"], relevant[2]["segment"]
    assert (first["start_ms"], first["end_ms"]) == (100, 900)
    assert (second["start_ms"], second["end_ms"]) == (1100, 1900)
    assert first["text"] == "Grüezi."
    assert first["stability"] == second["stability"] == "final"
    assert uuid.UUID(first["id"]) != uuid.UUID(second["id"])
    assert relevant[1] == {"type": "window_complete", "session_id": "file",
                           "start_ms": 0, "sample_count": 16_000}
    assert messages[-1]["message"] == "Transcription stopped"


def test_file_final_partial_window_commits_without_waiting_for_overlap_or_stop():
    lengths = []

    def recognize(samples):
        lengths.append(len(samples))
        return [{"start_ms": 100, "end_ms": 500, "text": "Ende."}]

    result, messages = _serve_messages([_file_audio(20_000, sample_count=3200)], recognize)
    assert result == 0
    assert lengths == [3200]
    segment = next(message["segment"] for message in messages if message["type"] == "segment")
    assert segment["stability"] == "final"
    assert (segment["start_ms"], segment["end_ms"]) == (20_100, 20_200)
    assert messages[-1] == {"type": "window_complete", "session_id": "file",
                            "start_ms": 20_000, "sample_count": 3200}


def test_silent_file_window_still_acknowledges_progress():
    result, messages = _serve_messages([_file_audio(0)], lambda _: [])
    assert result == 0
    assert not any(message["type"] == "segment" for message in messages)
    assert messages[-1]["type"] == "window_complete"


def test_file_stop_resets_session_before_live_or_another_file():
    result, messages = _serve_messages([
        _file_audio(50_000, "first"), {"type": "stop", "session_id": "first"},
        _audio(0, "meeting"), {"type": "stop", "session_id": "meeting"},
        _file_audio(0, "second"), {"type": "stop", "session_id": "second"},
    ], lambda _: [{"start_ms": 0, "end_ms": 100, "text": "Ja."}])
    assert result == 0
    finals = [message for message in messages
              if message.get("segment", {}).get("stability") == "final"]
    assert [message["session_id"] for message in finals] == ["first", "meeting", "second"]
    assert [message["segment"]["start_ms"] for message in finals] == [50_000, 0, 0]


@pytest.mark.parametrize("first, second", [(_file_audio(0), _audio(1000, "file")),
                                          (_audio(0, "file"), _file_audio(1000))])
def test_session_cannot_mix_live_and_file_windows(first, second):
    result, messages = _serve_messages([first, second], lambda _: [])
    assert result == 2
    assert messages[-1] == {"type": "status", "state": "failed", "message": "Session mode mismatch"}


def test_file_inference_failure_is_sanitized_and_never_acknowledged():
    def recognize(_):
        raise RuntimeError("private transcript from /private/recording.wav")

    result, messages = _serve_messages([_file_audio(0)], recognize)
    assert result == 1
    assert not any(message["type"] == "window_complete" for message in messages)
    assert messages[-1] == {"type": "status", "state": "failed", "message": "Local transcription failed"}
    assert "private" not in json.dumps(messages)
