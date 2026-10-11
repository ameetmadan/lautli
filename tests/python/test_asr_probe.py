import numpy as np
import soundfile as sf

from scripts import asr_probe


def test_load_audio_reads_wav_as_mono_float_samples(tmp_path):
    wav_path = tmp_path / "meeting.wav"
    stereo = np.column_stack((np.ones(16000, dtype=np.float32), np.zeros(16000, dtype=np.float32)))
    sf.write(wav_path, stereo, 16000)

    load_audio = getattr(asr_probe, "load_audio", None)
    assert callable(load_audio), "load_audio is not implemented"
    samples, sample_rate = load_audio(wav_path)

    assert sample_rate == 16000
    assert samples.dtype == np.float32
    assert samples.shape == (16000,)
    assert np.allclose(samples, 0.5, atol=1e-3)


def test_timestamped_chunks_become_transcript_segments():
    segment_records = getattr(asr_probe, "segment_records", None)
    assert callable(segment_records), "segment_records is not implemented"

    assert segment_records(
        {"chunks": [{"timestamp": (1.25, 2.5), "text": " Hallo zusammen. "}]}
    ) == [{"start_ms": 1250, "end_ms": 2500, "text": "Hallo zusammen."}]
