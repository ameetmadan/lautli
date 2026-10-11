# Swiss German Meeting Notes

A local-first macOS prototype for automatic Zoom and Teams meeting detection, live Swiss German transcription, and later Standard German meeting notes. Audio and inference stay on the Mac. The current build has meeting detection, ScreenCaptureKit capture, a local Whisper worker, and a live transcript view; notes, exports, pause/resume, and manual app selection are still in progress.

## Requirements

- macOS 15 or newer and Xcode Command Line Tools.
- Python 3.13 on Apple Silicon with an MPS-capable PyTorch build.
- About 3 GB of free space for the pinned Apache-2.0 Flix Swiss German checkpoint, plus Python and build dependencies.

The checkpoint is `Flix-AI/flix-swissgerman-full` at revision `a9c347a904af5d31b28c537ac732e0618aed6136`. Do not substitute the CC-BY-NC Swiss German Turbo conversion for work meetings.

## Setup and launch

From the repository root:

```sh
python3.13 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -c 'from huggingface_hub import snapshot_download; snapshot_download("Flix-AI/flix-swissgerman-full", revision="a9c347a904af5d31b28c537ac732e0618aed6136", local_dir=".models/flix-swissgerman-full")'
scripts/build_mac_app.sh
open "dist/Meeting Notes.app"
```

The first model load can take a while. The menu bar shows model loading before it enables automatic meeting capture. macOS asks for microphone and Screen Recording access; allow both. For automatic Zoom/Teams detection, also choose **Allow meeting detection…** in the menu and enable Accessibility access in System Settings. The app waits for meeting controls and app audio before starting.

The menu-bar indicator is visible while capture runs. Finalized transcript lines appear in the menu. Closing the menu does not stop capture; use the menu's stop/quit action to end the process.

## Test with YouTube audio

Open a Swiss German SRF video in Safari, Chrome, Firefox, Edge, Brave, or Arc and start playback. Open the Meeting Notes menu and choose **Test with a Swiss German video…**, then select that browser. This captures that browser's output audio only (not your microphone) and streams it through the same local Whisper worker. Select **Stop YouTube test** when finished. The browser test transcript is shown in the menu and is not saved as a recording.

## Development checks

```sh
swift test --package-path macos
.venv/bin/python -m pytest -q
```

The `scripts/asr_probe.py` command benchmarks a local WAV without uploading it:

```sh
.venv/bin/python scripts/asr_probe.py path/to/16khz-audio.wav
```

## Current validation limits

The model was exercised on synthetic Standard German on an M1 Pro/16 GB host, not on Swiss German meeting audio or the target M5/24 GB Mac. No real Zoom or Teams call has been used to verify the system-audio format, permissions, meeting detector labels, transcript quality, or sustained real-time performance. Review the transcript before relying on it; this prototype does not yet produce or save Standard German notes.
