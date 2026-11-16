import getpass
import json
import platform

import numpy as np
import pytest

from scripts import windows_feasibility as feasibility


def test_comfortable_machine_keeps_pace_with_no_lag_growth():
    result = feasibility.simulate_backlog([[1.0, 1.0]] * 100)
    assert result["keeps_pace"] and result["comfortable"]
    assert result["utilization"] == 0.4
    assert result["max_lag_s"] == 2.0


def test_machine_slower_than_real_time_grows_backlog_and_fails():
    # Two sources at 3.5 s per window need 7 s of every 5 s hop.
    result = feasibility.simulate_backlog([[3.5, 3.5]] * 100)
    assert not result["keeps_pace"]
    assert result["utilization"] == 1.4
    assert result["final_lag_s"] > feasibility.MAX_BACKLOG_SECONDS


def test_full_utilization_is_not_enough_headroom():
    result = feasibility.simulate_backlog([[2.5, 2.5]] * 50)
    assert not result["keeps_pace"]  # utilization == 1: any hiccup builds an unbounded queue


def test_tight_but_stable_machine_is_not_flagged_comfortable():
    result = feasibility.simulate_backlog([[2.2, 2.2]] * 100)
    assert result["keeps_pace"] and not result["comfortable"]


def test_simulation_requires_data():
    with pytest.raises(ValueError):
        feasibility.simulate_backlog([])


def test_benchmark_drives_the_real_streaming_transcriber_per_source():
    seen = []

    def recognize(samples):
        seen.append(len(samples))
        return [{"start_ms": 0, "end_ms": 500, "text": "Grüezi mitenand"}]

    ticks = iter(range(10_000))
    samples = np.zeros(25 * 16_000, dtype=np.float32)
    report = feasibility.benchmark(samples, recognize, sources=2, clock=lambda: next(ticks) * 0.5)
    # 25 s of audio: windows at 0, 5, 10, 15 s; two sources each.
    assert seen == [160_000] * 8
    assert report["pace"]["windows"] == 8
    assert report["sources"] == 2
    assert report["window_seconds"]["mean"] == 0.5
    assert report["transcript_characters"] > 0
    assert "Grüezi" not in json.dumps(report)


def test_benchmark_rejects_audio_shorter_than_one_window():
    with pytest.raises(ValueError, match="at least"):
        feasibility.benchmark(np.zeros(16_000, dtype=np.float32), lambda _: [])


def test_synthetic_audio_is_deterministic_float32_with_energy():
    first, second = feasibility.synthetic_audio(3), feasibility.synthetic_audio(3)
    assert first.dtype == np.float32 and len(first) == 48_000
    assert np.array_equal(first, second) and float(np.abs(first).max()) > 0.01


def test_hardware_report_contains_no_personal_identifiers():
    report = feasibility.hardware_report()
    serialized = json.dumps(report)
    for private in (platform.node(), getpass.getuser()):
        assert len(private) < 4 or private not in serialized
    assert report["selected_device"] in {"cuda", "mps", "cpu"}
    assert {"torch", "transformers", "numpy"} <= set(report["packages"])
    assert report["cpu"]["logical_cores"]
