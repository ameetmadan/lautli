from worker.meeting_worker.streaming import StreamingTranscriber


def test_segment_becomes_final_only_when_repeated_in_overlapping_windows():
    transcriber = StreamingTranscriber("session", lambda samples: [{"start_ms": 1000, "end_ms": 1800, "text": " Grüezi mitenand. "}])
    first = transcriber.process(0, [0.0] * 10)
    second = transcriber.process(1000, [0.0] * 10)
    assert [event["segment"]["stability"] for event in first if event["type"] == "segment"] == ["provisional"]
    assert [event["segment"]["stability"] for event in second if event["type"] == "segment"] == ["final"]


def test_final_segment_is_never_committed_twice():
    transcriber = StreamingTranscriber("s", lambda samples: [{"start_ms": 0, "end_ms": 500, "text": "Ja."}])
    transcriber.process(0, [0.0])
    transcriber.process(0, [0.0])
    events = transcriber.process(0, [0.0])
    finals = [e for e in events if e.get("segment", {}).get("stability") == "final"]
    assert len(finals) == 0
