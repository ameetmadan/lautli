# Windows feasibility (epic #23)

Status: **no decision yet.** Nothing in this document has been measured on a Windows laptop. It records what the repository already supports, what was fixed so the worker can run on Windows, the exact measurement procedure for Milestone 1, and the proposed shell and packaging approach to confirm or reject once real numbers exist. Update the tables as measurements arrive.

Scope reminders from the epic: the first Windows beta is transcript-only; audio and transcription stay local; audio is never saved; selected-app capture must never silently fall back to capturing other apps; model quality, capture scope and local-processing guarantees are not changed to make hardware look adequate.

## What is shared and what is not

| Layer | Windows status |
|---|---|
| Worker protocol, streaming, cleanup, vocabulary (`worker/lautli_worker/`) | Reused unchanged. Windows start-up bugs fixed in this change, see below. |
| Device selection | `cuda` → `mps` → `cpu`. `LAUTLI_DEVICE=cpu|cuda|mps` forces a path and never falls back silently. |
| Model download | `download_model.py` is portable (Hugging Face Hub, SHA-256 verified). |
| MCP server | Standard library only; resolves the real, possibly OneDrive-redirected, Documents folder. |
| UI, capture, meeting observation, first-run setup, packaging | Not started. Needs the shell decision below. |
| Meeting notes (Apple FoundationModels) | Out of scope for the beta. |

### Windows problems already fixed

- `scripts/asr_probe.py` imported the POSIX-only `resource` module, and the worker imports `asr_probe`, so **the worker could not start on Windows**. Peak memory now comes from `worker/lautli_worker/platform_support.py` (`GetProcessMemoryInfo` on Windows). The macOS value is unchanged.
- Windows opens stdin/stdout with the ANSI code page and rewrites `\n` to `\r\n`, which corrupts umlauts and adds a carriage return to every protocol line. The worker now forces UTF-8 and `\n` (`configure_stdio`). The MCP server forces `\n` as well.
- Transcripts live in `Documents\lautli`. On Windows the Documents folder is frequently redirected (OneDrive, folder redirection), so the MCP server asks the shell (`SHGetKnownFolderPath`) rather than assuming `%USERPROFILE%\Documents`.
- `pip install torch` from PyPI on Windows installs the **CPU-only** build. A CUDA build needs the PyTorch index URL from <https://pytorch.org/get-started/locally/>. The first-run setup must therefore choose the wheel flavour (see Packaging). `requirements.txt` stays untouched because changing it changes the setup digest on every existing macOS install.

CI now runs the Python tests on `windows-latest` (`python-windows` job), and `windows-feasibility.yml` loads the pinned model on a hosted Windows CPU runner and replays synthetic audio. That workflow shows the worker and model run on Windows. It is not a go/no-go measurement: it uses synthetic noise and a hosted VM, not a minimum-spec laptop.

## Milestone 1 measurement procedure

### 1. Record the hardware

Run on each candidate machine (no host name, user name or paths are recorded):

```powershell
python -m scripts.windows_feasibility --hardware-only
```

It lists OS build, CPU, logical cores, RAM, every display adapter (including Intel/AMD iGPUs that PyTorch cannot use), the CUDA device, the Python version, the pinned package versions, and the device and dtype the worker would select. Use at least:

| Role | Description |
|---|---|
| Requesting user's laptop | The laptop of the person who asked for Windows support in #1. Record its specification before judging it. |
| Typical office laptop, no NVIDIA GPU | For example a recent 4–8 core Intel/AMD CPU, 16 GB RAM, integrated graphics, Windows 11. This is the proposed minimum-spec candidate. |
| NVIDIA laptop (optional) | Shows what the CUDA path buys. |

### 2. Run the worker on CPU and CUDA

Install into a clean virtual environment with `requirements.txt` (CPU) and, for CUDA, the matching PyTorch CUDA wheel. Download the pinned model with `python -m worker.lautli_worker.download_model <dir>`. Run the benchmark once per device:

```powershell
$env:LAUTLI_DEVICE = "cpu"   # then "cuda"
python -m scripts.windows_feasibility --audio call.wav --model <dir> --sources 2 --reference call.txt > report-cpu.json
```

- `call.wav` is a consented 16 kHz recording of a representative call. Keep recordings, reference transcripts and any transcript text out of GitHub. The report contains character counts only.
- `--sources 2` is microphone plus meeting output. Each 5 s hop produces two 10 s windows, exactly as the macOS app does.
- Run it **while Teams or Zoom is in a call** on the same machine, to include the CPU/GPU contention a real meeting causes. Repeat on battery and on mains power.
- `--synthetic 60` exercises the pipeline without audio but is marked `valid_for_decision: false`.

### 3. Pass criterion

The report replays the measured per-window times against the wall clock of a live call, with a single worker:

- `utilization` = processing time ÷ audio time. It must be **below 1.0**, otherwise the backlog grows without bound. At or below **0.8** counts as comfortable headroom.
- `max_lag_s` must stay below **30 s**, the point at which the macOS app stops capture to preserve speech.
- A provisional line appears roughly `10 s + lag` after a phrase starts, so report `mean_lag_s` and `max_lag_s` next to the 10 s window.

Also record `peak_process_memory_gb`, `peak_cuda_memory_gb`, `model_load_s`, `offline_wer` and `offline_real_time_factor` (the WER uses the one-pass offline transcript, because live windows overlap).

If a CPU-only machine fails the criterion, the decision is explicit: narrow supported hardware (for example require an NVIDIA GPU), or investigate an optimised inference backend (CTranslate2/faster-whisper, ONNX Runtime with DirectML, OpenVINO). Do not quietly use a smaller or quantised model, shorter capture scope or a cloud fallback. Any backend change needs a quality comparison against `offline_wer` first.

### 4. Capture checks (needs a Windows 11 machine and a headset)

These are manual checks; record pass/fail and notes.

- [ ] Selected-app capture isolation: with Teams or Zoom selected, music in a browser is **not** transcribed. Capture only the selected app's process tree; if the app is not running, report that. Never fall back to system-wide capture without clear, explicit user consent.
- [ ] Microphone plus meeting output normalise to 16 kHz mono float32 and produce a saved transcript end to end.
- [ ] Headset change mid-call (plug/unplug USB and Bluetooth): capture recovers or reports that it stopped.
- [ ] Speakers instead of headphones: microphone/output duplication appears as documented, since there is no echo cancellation.
- [ ] Managed corporate machine: capture works without administrator rights, and endpoint-protection software does not block the installer, the downloaded runtime or process-loopback capture.
- [ ] Windows 10 vs 11: process-loopback capture is documented by Microsoft for Windows 10 build 20348 and later; confirm the lowest build that actually works and set the minimum accordingly (proposed: Windows 11).

### 5. Results (fill in)

| Machine | CPU | RAM | GPU | Windows build | Device | Utilization | Max lag | Peak RAM | Load time | WER | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| Hosted `windows-latest`, CPU (synthetic) | see workflow summary | | none | | cpu | not decision-grade | | | | | smoke only |
| Requester's laptop | _not measured_ | | | | | | | | | | |
| Office laptop, no NVIDIA | _not measured_ | | | | | | | | | | |
| NVIDIA laptop | _not measured_ | | | | | | | | | | |

## Go / no-go

**Decision: pending hardware measurements.** The expectation, not yet a result, is that the pinned model (about 4 GB) runs comfortably only with a CUDA GPU, and that CPU-only laptops are the open risk because two windows must be processed per 5 s hop. Record the final decision, the supported-hardware list and the observed latency and limitations here and in the README before building the beta UI.

## Proposed Windows shell and packaging (to confirm after feasibility)

These are proposals so the follow-up work can start; none are built.

- **Capture.** Native WASAPI. Selected app: process-loopback capture (`ActivateAudioInterfaceAsync` with `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`, `PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE`, see Microsoft's [ApplicationLoopbackAudio sample](https://learn.microsoft.com/en-us/samples/microsoft/windows-classic-samples/applicationloopbackaudio-sample/)) on the Zoom/Teams process tree. Microphone: shared-mode WASAPI capture of the chosen endpoint. Resample both to 16 kHz mono float32 and send the same `audio_window` messages to the worker.
- **Shell.** A .NET 8 desktop app (tray icon, WinUI 3 or WPF) with a small C# `WorkerClient` mirroring `WorkerClient.swift`: JSON lines over stdin/stdout, bounded buffering with the same 30 s stop, restart on worker failure. C# gives first-class WASAPI/COM interop and accessibility (UI Automation) with the least native code. Alternatives considered: Tauri/Rust (smaller, but more native capture code to own) and Electron (heavy for a background tray app).
- **Setup.** Same model as macOS: download a pinned python-build-standalone Windows runtime, install requirements, download the pinned model, each step with a marker and SHA-256 check, plus a disk-space check (about 7 GB) before starting. Choose the PyTorch wheel by detecting an NVIDIA GPU (CUDA wheel) and otherwise the CPU wheel; record the choice in the setup digest.
- **Install location.** Per-user install (no administrator rights), program files under `%LOCALAPPDATA%\Programs\lautli`, runtime and model under `%LOCALAPPDATA%\lautli`, transcripts in the redirected-aware Documents folder. Avoid MSIX for the first beta: a package directory is read-only and enterprise sideloading policies vary. Use an Inno Setup or WiX installer with a normal uninstall entry that offers to keep or remove the downloaded runtime/model and never touches transcripts.
- **Signing and release.** Authenticode signing (Azure Trusted Signing or an OV/EV certificate) and a Windows job in `release.yml` once an installer exists. Both need an account and credentials.
- **Participant notice, accessibility, localisation.** Reuse the macOS wording (English/German), keep a visible recording indicator, support keyboard and screen-reader use via UI Automation.

## Remaining Milestone 1 and later work

Everything that needs a physical Windows machine, a consented call, a code-signing identity or the project owner's decisions is tracked in the manual follow-up issue linked from the pull request.
