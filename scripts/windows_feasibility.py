"""Record hardware/dependency facts and measure whether this machine keeps pace with live transcription.

The report is meant to be pasted into WINDOWS.md or a GitHub issue, so it holds no
personal data: no host or user name, no paths, and only transcript lengths, never transcript text.
Run it on the machine being evaluated, with consented audio that stays local:

    python -m scripts.windows_feasibility --audio call.wav --model <model dir> --sources 2 --reference call.txt

The benchmark replays the app's live windowing (10 s windows every 5 s per source, see WorkerClient.swift)
through the real worker pipeline and a single worker, as the app uses. Microphone plus meeting output are
two sources, so each hop produces two windows.
"""
import argparse
import contextlib
import importlib.metadata
import json
import os
import platform
import statistics
import subprocess
import sys
import time
from collections.abc import Callable
from pathlib import Path

import numpy as np

from worker.lautli_worker.platform_support import peak_memory_bytes, total_memory_bytes

SAMPLE_RATE_HZ = 16_000
WINDOW_SECONDS = 10
HOP_SECONDS = 5
# The macOS app stops capture when this much audio is waiting for the worker (WorkerClient.swift).
MAX_BACKLOG_SECONDS = 30
# Above this share of the available time the machine has no headroom for a slower moment.
COMFORTABLE_UTILIZATION = 0.8
PACKAGES = ("torch", "transformers", "accelerate", "huggingface_hub", "numpy", "soundfile")


def _run(command: list[str]) -> str:
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=20, check=False)
    except (OSError, subprocess.SubprocessError):
        return ""
    return completed.stdout.strip()


def cpu_name() -> str:
    if sys.platform == "win32":
        try:
            import winreg

            with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"HARDWARE\DESCRIPTION\System\CentralProcessor\0") as key:
                return str(winreg.QueryValueEx(key, "ProcessorNameString")[0]).strip()
        except OSError:
            return platform.processor()
    if sys.platform == "darwin":
        return _run(["sysctl", "-n", "machdep.cpu.brand_string"]) or platform.processor()
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8", errors="replace").splitlines():
            if line.lower().startswith("model name"):
                return line.partition(":")[2].strip()
    except OSError:
        pass
    return platform.processor()


def display_adapters() -> list[str]:
    """Names of every GPU Windows knows about, including Intel/AMD integrated ones PyTorch cannot use."""
    if sys.platform != "win32":
        return []
    output = _run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                   "(Get-CimInstance Win32_VideoController).Name"])
    return [line.strip() for line in output.splitlines() if line.strip()]


def package_versions() -> dict[str, str | None]:
    versions: dict[str, str | None] = {}
    for name in PACKAGES:
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = None
    return versions


def hardware_report() -> dict:
    """Facts needed to compare machines. Deliberately excludes host name, user name and file paths."""
    import torch

    from worker.lautli_worker.device import pick_device

    total = total_memory_bytes()
    device, dtype = pick_device()
    cuda = None
    if torch.cuda.is_available():
        properties = torch.cuda.get_device_properties(0)
        cuda = {
            "name": properties.name, "memory_gb": round(properties.total_memory / 1024**3, 1),
            "compute_capability": f"{properties.major}.{properties.minor}", "driver_cuda_runtime": torch.version.cuda,
        }
    return {
        "os": {
            "system": platform.system(), "release": platform.release(), "build": platform.version(),
            "edition": platform.win32_edition() if sys.platform == "win32" else None,
            "machine": platform.machine(),
        },
        "cpu": {"name": cpu_name(), "logical_cores": os.cpu_count()},
        "ram_gb": round(total / 1024**3, 1) if total else None,
        "display_adapters": display_adapters(),
        "cuda_device": cuda,
        "python": platform.python_version(),
        "packages": package_versions(),
        "selected_device": device,
        "selected_dtype": str(dtype).removeprefix("torch."),
    }


def simulate_backlog(hop_durations: list[list[float]], hop_seconds: float = HOP_SECONDS,
                     window_seconds: float = WINDOW_SECONDS) -> dict:
    """Replay measured per-window processing times against the wall clock a live call produces.

    `hop_durations[k]` holds the seconds spent on each source's window k. Window k is complete (and can be
    sent) at `k * hop_seconds + window_seconds`. A single worker handles windows first-come-first-served.
    `lag` is how long a finished window waited past its own completion; utilization above 1 means the
    backlog grows without bound.
    """
    if not hop_durations:
        raise ValueError("no windows were processed")
    lags, worker_free_at, busy = [], 0.0, 0.0
    for index, durations in enumerate(hop_durations):
        available = index * hop_seconds + window_seconds
        for duration in durations:
            start = max(available, worker_free_at)
            worker_free_at = start + duration
            busy += duration
            lags.append(worker_free_at - available)
    span = len(hop_durations) * hop_seconds
    utilization = busy / span
    return {
        "windows": len(lags), "utilization": round(utilization, 3),
        "max_lag_s": round(max(lags), 2), "final_lag_s": round(lags[-1], 2),
        "mean_lag_s": round(statistics.fmean(lags), 2),
        "keeps_pace": utilization < 1 and max(lags) < MAX_BACKLOG_SECONDS,
        "comfortable": utilization <= COMFORTABLE_UTILIZATION and max(lags) < MAX_BACKLOG_SECONDS,
    }


def benchmark(samples: np.ndarray, recognize: Callable[[list[float]], list[dict]], sources: int = 2,
              clock: Callable[[], float] = time.perf_counter) -> dict:
    """Run every live window of `samples` through `recognize` for `sources` simultaneous streams."""
    from worker.lautli_worker.streaming import StreamingTranscriber

    window, hop = WINDOW_SECONDS * SAMPLE_RATE_HZ, HOP_SECONDS * SAMPLE_RATE_HZ
    if len(samples) < window:
        raise ValueError(f"need at least {WINDOW_SECONDS} seconds of audio")
    names = ["meetingOutput", "microphone"][:sources] if sources <= 2 else [f"source{i}" for i in range(sources)]
    transcribers = [StreamingTranscriber(f"bench-{name}", recognize) for name in names]
    hop_durations: list[list[float]] = []
    characters = 0
    for offset in range(0, len(samples) - window + 1, hop):
        chunk = samples[offset:offset + window].tolist()
        durations = []
        for transcriber, name in zip(transcribers, names):
            started = clock()
            events = transcriber.process(int(offset * 1000 / SAMPLE_RATE_HZ), chunk, name)
            durations.append(clock() - started)
            characters += sum(len(event["segment"]["text"]) for event in events if event["type"] == "segment")
        hop_durations.append(durations)
    for transcriber in transcribers:
        characters += sum(len(event["segment"]["text"]) for event in transcriber.flush())
    all_durations = [duration for durations in hop_durations for duration in durations]
    ordered = sorted(all_durations)
    return {
        "audio_seconds": round(len(samples) / SAMPLE_RATE_HZ, 1), "sources": len(names),
        "window_seconds": {
            "mean": round(statistics.fmean(all_durations), 2),
            "p95": round(ordered[min(len(ordered) - 1, int(len(ordered) * 0.95))], 2), "max": round(ordered[-1], 2),
        },
        "pace": simulate_backlog(hop_durations),
        "transcript_characters": characters,
    }


def synthetic_audio(seconds: int) -> np.ndarray:
    """Speech-shaped noise. Exercises the pipeline but is NOT valid evidence for a go/no-go decision."""
    rng = np.random.default_rng(0)
    count = seconds * SAMPLE_RATE_HZ
    envelope = 0.5 + 0.5 * np.sin(2 * np.pi * 3 * np.arange(count) / SAMPLE_RATE_HZ)
    return (0.1 * envelope * rng.standard_normal(count)).astype(np.float32)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--audio", type=Path, help="16 kHz consented recording; stays on this machine")
    source.add_argument("--synthetic", type=int, metavar="SECONDS", help="pipeline smoke test only")
    parser.add_argument("--model", type=Path, default=Path(".models/flix-swissgerman-full"))
    parser.add_argument("--sources", type=int, default=2, choices=range(1, 5), help="2 = microphone + meeting output")
    parser.add_argument("--reference", type=Path, help="reference transcript to compute word error rate")
    parser.add_argument("--hardware-only", action="store_true", help="print the hardware report and exit")
    args = parser.parse_args()
    if not args.hardware_only and not (args.audio or args.synthetic):
        parser.error("one of --audio, --synthetic or --hardware-only is required")

    report: dict = {"hardware": hardware_report()}
    if args.hardware_only:
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0

    from scripts.asr_probe import load_audio
    from scripts.evaluate_wer import wer
    from worker.lautli_worker.main import load_recognizer

    samples = synthetic_audio(args.synthetic) if args.synthetic else load_audio(args.audio)[0]
    os.environ["WHISPER_MODEL_PATH"] = str(args.model)
    started = time.perf_counter()
    with contextlib.redirect_stdout(sys.stderr):  # the loader prints a protocol status line
        recognize = load_recognizer()
    report["model_load_s"] = round(time.perf_counter() - started, 1)
    recognized_text: list[str] = []

    def recording(window: list[float]) -> list[dict]:
        segments = recognize(window)
        recognized_text.extend(segment["text"] for segment in segments)
        return segments

    report["benchmark"] = benchmark(samples, recording, args.sources)
    report["benchmark"]["valid_for_decision"] = args.synthetic is None
    report["peak_process_memory_gb"] = round(peak_memory_bytes() / 1024**3, 2)
    import torch

    if torch.cuda.is_available():
        report["peak_cuda_memory_gb"] = round(torch.cuda.max_memory_allocated() / 1024**3, 2)
    if args.reference:
        # Live windows overlap by 5 s, so only the one-pass offline transcript is a fair quality number.
        from scripts.asr_probe import transcribe

        offline = transcribe(args.audio, args.model)
        report["offline_wer"] = round(wer(args.reference.read_text(encoding="utf-8"), offline["text"]), 3)
        report["offline_real_time_factor"] = offline["real_time_factor"]
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
