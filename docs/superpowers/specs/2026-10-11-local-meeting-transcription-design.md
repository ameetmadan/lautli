# Local Meeting Transcription Prototype

## Goal

Build a macOS prototype the user can try in a Zoom or Microsoft Teams standup: it detects an active native-app meeting, transcribes Swiss German locally while the meeting is happening, and produces editable Standard German notes after the meeting. It must not depend on the meeting being recorded by Zoom or Teams.

## User and success criteria

The user has a MacBook Pro M5 with 24 GB RAM, attends Zoom and Teams meetings, wants all audio and inference to stay local, and wants Standard German notes after the meeting. The near-term goal is a usable experiment tomorrow, not a polished or unattended production product.

Success for the prototype means:

1. A visible menu-bar app can detect an active Zoom or Teams meeting and start/stop capture, with manual start/stop available as a fallback.
2. Remote meeting audio and the user's microphone reach a local Swiss German Whisper model, and stable timestamped transcript segments appear during the meeting.
3. Audio is held only in a bounded in-memory buffer and is discarded after transcription; no audio file is written by this app.
4. On stop, a local text model produces an editable Standard German summary, decisions, action items, and open questions, linked to transcript timestamps.
5. The app reports capture, permission, or model failures visibly rather than silently losing audio or inventing a successful transcript.

## Scope

### In scope

- macOS menu-bar application for native Zoom and Teams applications.
- Automatic meeting detection with explicit active state, visible capture indicator, pause, skip, and stop controls.
- Local application audio and microphone capture suitable for meetings held with headphones; combine the sources for the first prototype.
- A bounded sliding audio window, voice activity handling, chunked Whisper inference, and a stabilization policy that avoids repeatedly showing changing text as final.
- Swiss German speech transcription into Standard German, with timestamps.
- On-device note generation after capture ends, with each note item referencing transcript segment IDs/timestamps.
- Local transcript and note export (Markdown plus JSON); no audio retention.
- A manual test mode that captures a selected browser's audio to evaluate Swiss German transcription on public videos; this does not expand automatic meeting detection to browsers.
- A short end-to-end trial and evaluation procedure on the user's laptop.

### Out of scope

- Browser-hosted Zoom/Teams meetings, Google Meet, and in-person meeting detection.
- Cloud inference, uploads, accounts, sync, a backend, or shared team notes.
- Speaker identity attribution beyond optional “microphone” versus “meeting audio.”
- Recording audio to disk, diarization, training or fine-tuning a model, calendar access, and a polished editor.
- Guaranteeing perfect meeting detection or transcript accuracy. The app must expose manual controls and uncertainty.

## Proposed architecture

Use a native SwiftUI/AppKit menu-bar shell for lifecycle, status, permissions, meeting detection, and audio capture. Use Apple's ScreenCaptureKit for selected meeting-application audio plus microphone capture. A small local Python worker owns MLX Whisper inference and local note generation; the Swift shell communicates with it over newline-delimited JSON on stdin/stdout. No network service is part of inference or note generation. Model downloads occur during setup and are pinned by revision.

The meeting detector watches known Zoom and Teams processes and observes their accessible meeting-window/call-control state. Audio activity is corroborating evidence, not sufficient by itself to start: opening the app or joining a quiet lobby must not trigger capture. The detector state machine is `idle -> candidate -> capturing -> stopping -> idle`; require a meeting-window signal plus corroboration, debounce start and stop, and offer a menu-bar override. If accessibility state is unavailable or ambiguous, prompt the user to start manually. Detection of meetings across app versions is a prototype risk and must be tested against the installed clients.

Capture feeds a bounded ring buffer. The worker processes overlapping windows and commits only stable transcript prefixes with monotonic timestamps. Temporary inference lag is surfaced as a “transcription behind” state; it must not grow memory without bound. When stopped, flush the remaining window, discard audio buffers, persist transcript and run metadata, then generate notes from transcript segments in sections and reconcile actions/decisions across sections. The note prompt requires evidence references and leaves unknown owners/dates unspecified. The UI labels notes as a draft.

The first model candidate is a Swiss German Whisper checkpoint with Standard German output, converted to or already available in MLX format. Model/runtime compatibility and transcription throughput on the M5 are explicit go/no-go checks; do not silently fall back to cloud or a different unreviewed model. Use a compact quantized local language model for notes, loaded after Whisper is released where practical to control memory pressure. Persist model IDs, revisions, and settings with every session.

## Data contracts

```text
MeetingState = idle | candidate | capturing | stopping | failed

AudioFrame {
  source: microphone | meeting_output
  sample_rate_hz: Int
  captured_at_monotonic_ms: Int64
  pcm: in-memory samples
}

TranscriptSegment {
  id: String
  start_ms: Int64
  end_ms: Int64
  text: String
  stability: provisional | final
  source: microphone | meeting_output | mixed
}

MeetingTranscript {
  session_id: String
  started_at: ISO8601
  ended_at: ISO8601
  asr_model_id: String
  asr_revision: String
  segments: [TranscriptSegment]
}

NoteItem {
  kind: summary | decision | action | open_question
  text: String
  owner: String?             // null unless supported by transcript
  due_date: String?          // null unless supported by transcript
  evidence_segment_ids: [String]
}
```

Audio samples are never included in worker messages after their processing window expires and are never serialized to disk. Session output consists of transcript, notes, model/run metadata, and application logs without transcript text or personal data.

## Failure behavior and privacy

- If microphone or screen/audio permissions are denied, show the exact permission needed and keep capture stopped.
- If meeting detection is uncertain, wait for manual start rather than capture a non-meeting by default.
- If the worker crashes or inference falls behind, keep the app responsive, show the condition, cap the buffer, and allow stopping/exporting completed segments.
- If note generation fails, preserve transcript and provide transcript export.
- Make capture state visible at all times and provide a one-step pause/stop action.
- Do not send audio or transcript to external services. Do not log audio, transcript text, meeting titles, participant names, or other personal data.

## Validation

On the target Mac, test one short Zoom call and one Teams call with headphones, including lobby/no-call, mute, silence, app launch without a meeting, pause/resume, and leave/rejoin. Verify that the app captures both the remote voice and local microphone, auto-starts and stops correctly, keeps the audio buffer bounded, and creates timestamped transcript segments. Measure real-time factor (audio duration divided by processing time), memory peak, and transcription lag; if inference cannot keep up, the prototype is not ready for unattended use. Compare output against a manually corrected transcript and review names, numbers, negation, commitments, and note evidence. Confirm that no audio files or network inference requests are produced.

## Decisions and open risks

- Batch transcription is replaced by live local transcription because the user may not have a Zoom/Teams recording.
- Manual controls remain available because automatic detection depends on app UI state and permissions.
- Original meeting audio is not retained, matching local-first intent; this means transcript corrections cannot be checked against or rerun from a saved recording.
- Whisper streaming is simulated by overlapping-window inference plus stable-prefix commitment; it is not a stateful streaming Whisper model.
- Specific MLX checkpoint conversion/runtime compatibility, model quality on business meetings, and M5 throughput must be proven before choosing final model revisions.
- Work-laptop management policies or OS permission restrictions may prevent audio capture or accessibility monitoring.
