# Live Meeting Transcription Implementation Plan

> **For agentic workers:** Use this plan task-by-task. Keep the menu app responsive, the audio buffer bounded, and the inference local.

**Goal:** Build a macOS prototype that detects native Zoom/Teams meetings, live-transcribes Swiss German locally, and produces evidence-linked Standard German notes when the meeting ends.

**Architecture:** A Swift menu-bar app owns meeting detection, ScreenCaptureKit audio capture, visible controls, and a bounded buffer. A local Python worker performs overlapping-window Whisper transcription and, after stop, local note generation. Both communicate over newline-delimited JSON; no cloud inference or audio files.

**Tech Stack:** SwiftUI/AppKit, ScreenCaptureKit, Accessibility API, Swift Package Manager, Python, Hugging Face Transformers with Apple MPS (or MLX only if the selected commercially usable checkpoint is supported), mlx-lm for notes.

**Spec:** `docs/superpowers/specs/2026-10-11-local-meeting-transcription-design.md`

## Global Constraints

- Support macOS native Zoom and Teams clients only.
- Keep all inference and meeting content on device.
- Do not write audio to disk; cap the in-memory ring buffer at 30 seconds.
- Keep capture state visible and expose pause, skip, and stop controls.
- Persist transcript, notes, timestamps, and model revisions only.
- If detection is uncertain or permission is missing, require manual start and show why.
- Never silently switch to cloud inference or discard transcript segments.

## Review Focus

- Opening Zoom or Teams without a call must not start capture; test app launch and idle meeting window.
- Quiet lobby, local mute, and temporary silence must not end a real meeting; test each state.
- Screen/audio or microphone permission denial must leave capture stopped with an actionable status.
- Transcription slower than real time must cap memory and show lag; feed audio faster than a fake worker can consume it.
- Worker crash after committed segments must preserve transcript and export; terminate a fake worker mid-session.

---

## File Structure

- `macos/Package.swift`: Swift package and app target dependencies.
- `macos/Sources/MeetingNotesApp/App.swift`: menu-bar entry point and visible capture state.
- `macos/Sources/MeetingNotesApp/MeetingDetector.swift`: Zoom/Teams process and accessibility state observations; detector state machine.
- `macos/Sources/MeetingNotesApp/AudioCapture.swift`: ScreenCaptureKit stream, audio format conversion, and bounded ring buffer.
- `macos/Sources/MeetingNotesApp/WorkerClient.swift`: newline-delimited JSON process client and worker lifecycle.
- `macos/Sources/MeetingNotesApp/SessionStore.swift`: local transcript/note JSON and Markdown export; no audio storage.
- `worker/pyproject.toml`: pinned Python dependencies and local worker entry point.
- `worker/meeting_worker/protocol.py`: strict message parsing and validation.
- `worker/meeting_worker/transcription.py`: model adapter, sliding windows, stable-prefix commitment, timestamps.
- `worker/meeting_worker/notes.py`: section-wise notes extraction and evidence validation.
- `tests/swift/MeetingDetectorTests.swift`: meeting detector state transition tests with fake observations.
- `tests/swift/AudioBufferTests.swift`: ring-buffer bounds and timestamp continuity tests.
- `tests/python/test_protocol.py`: protocol validation, malformed input, and bounded-window tests.
- `tests/python/test_notes.py`: evidence references and unknown owner/date behavior.
- `README.md`: install, model download, permissions, launch, and test procedure.

## Task 1: Prove the local model path on this Mac

Before building the UI, establish that the Apache-2.0 `Flix-AI/flix-swissgerman-full` Whisper checkpoint loads locally through Transformers on Apple MPS and transcribes a short WAV, with no network call after model download. Pin the Hugging Face revision in run metadata. Compare a short Swiss German sample with a human transcript and record processing time and peak memory. A preconverted MLX Turbo fine-tune is available, but it is CC-BY-NC-4.0; do not use it for work meetings. If Transformers/MPS cannot keep up, investigate converting the Apache-2.0 checkpoint to MLX before considering any other model.

**Acceptance:** one command emits timestamped Standard German segments for a 60-second sample; processing takes no more than 60 seconds on the user's M5; model files are local, revision-pinned, and licensed for the intended work use.

## Task 2: Build the visible menu-bar shell and meeting detector

Create the Swift package and a menu-bar app with Idle, Candidate, Capturing, Stopping, and Failed states. Observe Zoom and Teams app processes and accessible window/control state. Add hysteresis: require positive meeting UI evidence plus audio activity before auto-start; require several minutes of neither signal before auto-stop. Show an explicit recording/transcribing indicator and pause/skip/stop controls. If Accessibility permission or reliable call state is missing, provide manual start.

Write detector state-transition tests using fake process/window/audio observations before implementation. Test idle launch, meeting join, lobby, mute, short silence, leave, and permission loss. Keep accessibility prompts specific and triggered only when needed.

## Task 3: Capture app audio and microphone without writing audio files

Use ScreenCaptureKit to capture the selected Zoom/Teams app audio and microphone. Convert both to mono 16 kHz PCM in memory and feed a 30-second ring buffer. Include monotonic timestamps and source labels. Preserve the worker's existing committed transcript if capture ends or worker communication fails. The app must never create an audio file or send audio to a remote endpoint.

Write tests proving the ring buffer remains at or below its configured cap, discards only the oldest unprocessed samples according to explicit lag policy, preserves timestamp monotonicity, and stops both sources when paused/stopped.

## Task 4: Add worker protocol and live transcription

Define newline-delimited JSON messages:

```json
{"type":"audio_window","session_id":"...","start_ms":0,"sample_rate_hz":16000,"samples_base64":"..."}
{"type":"segment","session_id":"...","segment":{"id":"...","start_ms":0,"end_ms":2400,"text":"...","stability":"final"}}
{"type":"status","state":"ready|loading|transcribing|behind|failed","message":"..."}
{"type":"stop","session_id":"..."}
```

Reject oversized or malformed messages at the boundary. The Swift client streams windows to the worker; the worker emits provisional updates and confirms final text only after repeated overlapping windows agree. Track stable segments so overlapping windows never duplicate committed text. When stop arrives, flush the last window and return completion. Add fake-worker integration coverage for backpressure, malformed output, crash, and clean stop.

## Task 5: Persist transcript and produce notes after stop

Save each finalized transcript segment immediately to a per-session JSON file using atomic replacement. Save session start/end, ASR model ID/revision, and app version. On stop, unload Whisper, load the pinned local note model, extract notes from manageable transcript sections, consolidate across sections, and validate each evidence ID against the transcript. Export Markdown with summary, decisions, actions, open questions, and timestamp links; also export transcript JSON. Mark notes as a draft. If the notes model fails, transcript export still succeeds.

Test malformed/nonexistent evidence IDs, names and dates not present in the transcript, empty transcript, and note generation failure. Unknown owners/dates must remain null rather than guessed.

## Task 6: Run the end-to-end trial and document the result

Document setup and permissions in README. On the target M5, run one short Zoom and one Teams call with headphones. Exercise app launch without a meeting, lobby, mute, silence, pause/resume, leave/rejoin, capture permission denial, and worker termination. Measure transcript lag, real-time factor, and memory peak. Confirm all meeting output remains local and no audio file is created. Report detected/ missed/false starts and review a corrected transcript for Swiss German names, numbers, negation, and decisions.

Commit each complete task as a focused conventional commit after the repository checks pass. Do not push because no remote is configured.
