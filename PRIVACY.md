# Privacy

Meeting Notes processes meeting audio only on your Mac.

- **No telemetry.** The app sends no analytics, usage data or crash reports.
- **Audio is never saved.** Audio is converted to text in memory and discarded.
- **Transcripts stay local.** Text is written to `~/Documents/Meeting Notes/`. Standard German notes are created by Apple's on-device model on macOS 26 or newer. Nothing is uploaded.
- **Network use.** The first launch downloads the Python runtime (GitHub), Python libraries (PyPI) and the speech model (Hugging Face). Those services see an ordinary download request from your IP address. After set-up, the worker runs fully offline.
- **Permissions.** Microphone for your voice, Screen Recording only to hear the meeting app's audio (no screen content is captured or stored) and Accessibility only to notice that a meeting window is open.
- **Logs.** The app keeps technical logs in `~/Library/Application Support/Meeting Notes/logs/`. They contain no transcript text or audio. **Settings → Export diagnostics** creates a zip only when you ask, and you decide whether to share it.
- **Recording consent.** Transcribing a conversation can require the consent of everyone in it. You are responsible for informing participants. The app asks you to confirm this once.

If crash reporting is ever added, it will be opt-in and documented here first.
