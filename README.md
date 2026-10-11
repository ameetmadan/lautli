# Swiss German Meeting Notes

A macOS menu-bar app that detects Zoom and Microsoft Teams meetings, transcribes them live in Swiss German on your Mac, and writes a Standard German transcript and summary. Audio and transcription never leave the Mac, and audio is never saved.

## Install

1. Download `MeetingNotes-<version>.dmg` from the [latest release](../../releases/latest) and open it.
2. Drag **Meeting Notes** to **Applications** and open it.

**Requirements.** An Apple Silicon Mac (M1 or newer) on macOS 15 or newer, about 7 GB of free disk space and an internet connection for the first launch. Intel Macs are not supported. Standard German meeting notes additionally need macOS 26 or newer with Apple Intelligence turned on. Without it you still get the full transcript.

### If macOS refuses to open the app

Early releases are not yet notarized by Apple, so Gatekeeper blocks the first launch. Do one of:

- Control-click **Meeting Notes** in Applications, choose **Open**, then **Open** again.
- Or open **System Settings → Privacy & Security**, scroll down and choose **Open Anyway**.
- Or run `xattr -dr com.apple.quarantine "/Applications/Meeting Notes.app"` in Terminal.

A Mac managed by your employer may block unnotarized apps entirely. Ask your IT team, or wait for a notarized release.

## First launch

The app walks you through everything:

1. **Welcome.** Read the recording notice and confirm you will tell participants that meetings are transcribed.
2. **Download.** It downloads a private Python runtime, the speech libraries and the Swiss German model (about 4 GB, one time). The download resumes if it is interrupted.
3. **Permissions.** Each one is explained before macOS asks: Microphone (your voice), Screen Recording (only to hear Zoom or Teams audio, nothing on screen is recorded) and Accessibility (to notice that a meeting started).
4. **Try it.** Play a Swiss German video in your browser and watch the transcript appear.

Afterwards Meeting Notes sits in the menu bar. It starts by itself when a Zoom or Teams meeting begins and the menu-bar icon shows when it is listening.

## Using it

- **Menu bar icon.** Shows loading, idle, listening, paused or a problem. Open the menu to pause, resume, or stop and save.
- **Listen to an app.** If automatic detection misses a call, choose the meeting app manually.
- **Transcript window.** Live text with copy and export. After a meeting ends, **Open transcript** and **Show in Finder** appear.
- **Where files go.** `~/Documents/Meeting Notes/` holds `Transkript <date>.md` and, on macOS 26+, `Notizen <date>.md` with a summary, decisions, tasks and open questions. Review notes before sharing them: a local model wrote them.
- **Settings.** Permissions status, microphone choice, launch at login and **Export diagnostics**.

Use headphones. With speakers the microphone hears the other participants too and lines can appear twice. There is no echo cancellation.

## Troubleshooting

| Problem | What to do |
|---|---|
| Nothing is transcribed | Open Settings and check all three permissions are allowed. macOS occasionally asks for Screen Recording again. |
| Menu shows a worker problem | Choose **Restart worker** in the menu. |
| Download fails or stalls | Check your connection and choose **Try again**. On a corporate network, make sure `github.com`, `pypi.org`, `files.pythonhosted.org` and `huggingface.co` are reachable. |
| Transcript stops after plugging in headphones | The app restarts capture automatically. If it cannot, choose **Dismiss** and listen again. |
| Need help | **Settings → Export diagnostics** saves a zip of logs to your Desktop. It contains no transcripts or audio. |

To remove everything, delete the app, `~/Library/Application Support/Meeting Notes` and optionally `~/Documents/Meeting Notes`.

## Privacy

See [PRIVACY.md](PRIVACY.md). In short: everything runs on your Mac, there is no telemetry, and audio is never saved. The only network use is the one-time download of the runtime and model.

## Validation status

The model has been exercised on synthetic Standard German on an M1 Pro with 16 GB, not yet on real Swiss German meetings, real Zoom or Teams calls, or the lowest supported hardware. Expect rough edges and review transcripts before relying on them. Tracking issue: #7.

## Developing

See [CONTRIBUTING.md](CONTRIBUTING.md). Third-party licenses are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
