import base64
import io
import json

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
