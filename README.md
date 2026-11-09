# lautli

A macOS menu-bar app that detects Zoom and Microsoft Teams meetings, transcribes them live in Swiss German on your Mac, and writes a Standard German transcript and summary. Audio and transcription never leave the Mac. Captured audio is never saved; imported recordings are left untouched.

## Install

1. Download `lautli-<version>.dmg` from the [latest release](../../releases/latest) and open it.
2. Drag **lautli** to **Applications** and open it.

**Requirements.** An Apple Silicon Mac (M1 or newer) on macOS 15 or newer, about 7 GB of free disk space and an internet connection for the first launch. Intel Macs are not supported. Standard German meeting notes additionally need macOS 26 or newer with Apple Intelligence turned on. Without it you still get the full transcript.

### If macOS refuses to open the app

Early releases are not yet notarized by Apple, so Gatekeeper blocks the first launch. Do one of:

- Control-click **lautli** in Applications, choose **Open**, then **Open** again.
- Or open **System Settings → Privacy & Security**, scroll down and choose **Open Anyway**.
- Or run `xattr -dr com.apple.quarantine "/Applications/lautli.app"` in Terminal.

A Mac managed by your employer may block unnotarized apps entirely. Ask your IT team, or wait for a notarized release.

## First launch

The app walks you through everything:

1. **Welcome.** Choose English or German, read the recording notice and confirm you will tell participants that meetings are transcribed.
2. **Download.** It downloads a private Python runtime, the speech libraries and the Swiss German model (about 4 GB, one time). The download resumes if it is interrupted.
3. **Permissions.** Each one is explained before macOS asks: Microphone (your voice), Screen Recording (only to hear Zoom or Teams audio, nothing on screen is recorded) and Accessibility (to notice that a meeting started).
4. **Try it.** Play a Swiss German video in your browser and watch the transcript appear.

Afterwards lautli sits in the menu bar. It starts by itself when a Zoom or Teams meeting begins and the menu-bar icon shows when it is listening.

## Using it

- **Menu bar icon.** Shows loading, idle, listening, paused or a problem. Open the menu to pause, resume, or stop and save.
- **Listen to an app.** If automatic detection misses a call, choose the meeting app manually.
- **Transcript window.** Live text with copy and export. After a meeting ends, **Open transcript** and **Show in Finder** appear.
- **Where files go.** `~/Documents/lautli/` holds `Transkript <date>.md` and, on macOS 26+, `Notizen <date>.md` with a summary, decisions, tasks and open questions. Review notes before sharing them: a local model wrote them.
- **Settings.** Language (English or German, switches immediately), permissions status, microphone choice, launch at login and **Export diagnostics**. The app language does not change transcripts or notes.

Use headphones. With speakers the microphone hears the other participants too and lines can appear twice. There is no echo cancellation.

## Transcribing recordings

Choose **Transcribe audio files…** in the menu and select multiple WAV, M4A/AAC or MP3 recordings. macOS decodes and converts the audio locally; unreadable or unsupported files report an error without blocking the rest of the queue. Runtime/model setup must be complete, but file import does not require microphone, Screen Recording or Accessibility permission.

The **Audio file queue…** window shows each recording's processed-audio progress. You can remove pending files, cancel the current file, retry failures, and open completed transcripts or reveal them in Finder. Each recording produces a separate timestamped Markdown transcript in `~/Documents/lautli/`, with the source filename in its header. Timestamps are relative to the recording. Silent files can produce a transcript without speech lines.

Live meetings take priority after the current audio window finishes. The queue resumes from that boundary when live transcription ends. A paused live meeting continues to reserve the worker until you stop it. Cancellation discards that file's partial output; failures retain saved snippets in hidden `.working-*` folders inside the output folder for recovery. Retrying starts the file from the beginning. Quitting clears unfinished jobs, so add those files again next time. Imported files do not generate automatic notes.

File decoding and queue behavior are covered with synthetic WAV recordings, including stereo conversion from 44.1 kHz. Real M4A/MP3 recordings, recordings of at least 60 minutes, live-call handoff and inference performance still need validation before this feature is release-ready. Processing speed depends on your Mac; no completion-time estimate is shown.

## Names and jargon

To stop names and acronyms being misspelled, create `~/Library/Application Support/lautli/vocabulary.txt` with one entry per line: `Ameet` teaches the model a term, `Amit => Ameet` also rewrites a known mistake in the output. Lines starting with `#` are comments. Restart the transcription to apply changes.

## Use your transcripts with an AI app

**Settings → Connect to AI app** copies the setup for Claude Code, Codex, Claude Desktop or Cursor. Paste it into that app once, restart it, and ask things like "list my meetings from this week" or "turn the action points from yesterday's standup into tasks". If the app also has a task tool such as Asana connected, it can create the tasks itself.

The connection is a small read-only server that runs on your Mac and offers four tools: `list_meetings`, `get_transcript`, `get_notes` and `search_meetings`. It reads `~/Documents/lautli/` and nothing else. lautli itself never sends anything anywhere. Once your AI app reads a transcript, though, that app's provider sees the text, so only connect apps you trust with your meetings. A transcript contains other people's words, so keep the approval prompt on for any action that changes something.

macOS may ask whether your AI app can access your Documents folder. Allow it. Setup must be finished first. If you move lautli to another folder, copy the setup again.

## Troubleshooting

| Problem | What to do |
|---|---|
| Nothing is transcribed | Open Settings and check all three permissions are allowed. macOS occasionally asks for Screen Recording again. |
| Menu shows a worker problem | Choose **Restart worker** in the menu. |
| Download fails or stalls | Check your connection and choose **Try again**. On a corporate network, make sure `github.com`, `pypi.org`, `files.pythonhosted.org` and `huggingface.co` are reachable. |
| Transcript stops after plugging in headphones | The app restarts capture automatically. If it cannot, choose **Dismiss** and listen again. |
| Need help | **Settings → Export diagnostics** saves a zip of logs to your Desktop. It contains no transcripts or audio. |

To remove everything, delete the app, `~/Library/Application Support/lautli` and optionally `~/Documents/lautli`.

## Privacy

See [PRIVACY.md](PRIVACY.md). In short: everything runs on your Mac, there is no telemetry, and captured audio is never saved. Imported recordings remain untouched. The only network use is the one-time download of the runtime and model.

## Validation status

The model has been exercised on synthetic Standard German on an M1 Pro with 16 GB, not yet on real Swiss German meetings, real Zoom or Teams calls, or the lowest supported hardware. Expect rough edges and review transcripts before relying on them. Tracking issue: #7.

## License

lautli is licensed under the [Apache License 2.0](LICENSE). Copyright 2026 Ameet Madan. Components it downloads carry their own licenses, listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Developing

See [CONTRIBUTING.md](CONTRIBUTING.md). Third-party licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
