from worker.lautli_worker.streaming import StreamingTranscriber, has_audio_energy


def test_silence_is_filtered_before_asr_to_avoid_whisper_hallucinations():
    assert not has_audio_energy([0.0] * 160_000)
    assert has_audio_energy([0.01] * 160_000)


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


def test_stop_flushes_the_remaining_provisional_segment():
    transcriber = StreamingTranscriber("s", lambda samples: [{"start_ms": 0, "end_ms": 500, "text": "Danke."}])
    transcriber.process(0, [0.1])
    flushed = transcriber.flush()
    assert len(flushed) == 1
    assert flushed[0]["segment"]["stability"] == "final"
    assert transcriber.flush() == []


def test_same_word_can_be_committed_again_later_in_the_meeting():
    transcriber = StreamingTranscriber("s", lambda samples: [{"start_ms": 0, "end_ms": 200, "text": "Ja."}])
    transcriber.process(0, [0.1])
    transcriber.process(0, [0.1])
    later = transcriber.process(3_000, [0.1])
    segments = [event["segment"] for event in later if event["type"] == "segment"]
    assert len(segments) == 1
    assert segments[0]["stability"] == "provisional"
