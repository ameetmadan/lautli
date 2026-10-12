# Contributing

## Layout

- `macos/` is the Swift menu-bar app (capture, meeting detection, setup, UI).
- `worker/lautli_worker/` is the Python transcription worker. The app talks to it with JSON lines over stdin/stdout.
- `worker/lautli_worker/mcp_server.py` is the read-only MCP server AI apps connect to. It is standard library only on purpose: a new entry in `requirements.txt` changes the setup digest and sends every existing install back through dependency setup.
- `scripts/` has the app and DMG build scripts, the ASR probe and the WER tool.

The packaged app does not bundle Python or the model. On first launch `SetupManager` downloads a pinned [python-build-standalone](https://github.com/astral-sh/python-build-standalone) runtime, installs `requirements.txt` into it and downloads the pinned model into `~/Library/Application Support/lautli/`. Each step records a marker, so setup is safe to repeat.

## Checks

```sh
swift test --package-path macos
python3.13 -m venv .venv && .venv/bin/python -m pip install -r requirements.txt pytest
.venv/bin/python -m pytest -q
```

An opt-in test runs the whole first-run setup and loads the worker (downloads about 4 GB):

```sh
LAUTLI_E2E=1 LAUTLI_E2E_DIR=/tmp/mn-e2e swift test --package-path macos --filter SetupEndToEndTests
```

## Running a development build

```sh
scripts/build_mac_app.sh
open "dist/lautli.app"
```

Two environment variables redirect the app: `LAUTLI_SUPPORT_DIR` (where setup installs things) and `LAUTLI_WORKER_SRC` (a repo checkout to use instead of the bundled worker). Launch the binary directly to pass them, for example `LAUTLI_SUPPORT_DIR=/tmp/mn "dist/lautli.app/Contents/MacOS/LautliApp"`.

Ad-hoc signed rebuilds look like a new app to macOS, so Screen Recording and Accessibility grants reset after every build. That is expected until releases are signed with a Developer ID.

## Adding a string or translation

The app is in English and German. English text is the key: write it as a literal in SwiftUI (`Text("Open notes")`) or wrap computed and error strings in `tr("...")` so they follow the in-app language. Then add the German value to `macos/Resources/de.lproj/Localizable.strings`. Interpolations become format specifiers in the key, for example `Text("Step \(n) of \(m)")` has the key `"Step %lld of %lld"` and a `String` interpolation is `%@`. `L10nTests` fails when a literal has no German value or the specifiers differ. To list the exact keys the compiler sees, build with `swift build --package-path macos -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc /tmp/strings` and read the `.stringsdata` files.

## Measuring quality

Put 16 kHz mono recordings and matching reference transcripts side by side (`standup.wav`, `standup.txt`) and run:

```sh
.venv/bin/python scripts/evaluate_wer.py path/to/set --model "$HOME/Library/Application Support/lautli/models/flix-swissgerman-full"
```

It prints per-file word error rate, real-time factor and peak memory. Keep recordings of real meetings out of the repository.

## Releasing

Every merge to `main` releases automatically. `.github/workflows/release.yml` picks the next version from the conventional commits since the last tag (`feat:` or a `!` breaking change bumps the minor version, anything else bumps the patch), builds the app, packages the DMG and publishes a GitHub Release marked Latest, which creates the tag. To choose a version yourself, push a `vX.Y.Z` tag instead. Without signing secrets it publishes an ad-hoc signed pre-release. To sign and notarize, add these repository secrets: `DEVELOPER_ID_CERT_BASE64`, `DEVELOPER_ID_CERT_PASSWORD`, `NOTARY_KEY_BASE64` (App Store Connect API key, `.p8`), `NOTARY_KEY_ID` and `NOTARY_ISSUER`.

## Model and licensing

The pinned checkpoint is `Flix-AI/flix-swissgerman-full` at revision `a9c347a904af5d31b28c537ac732e0618aed6136` (Apache-2.0). Do not substitute the CC-BY-NC Swiss German Turbo conversion for work meetings.

## Decisions

- **Runtime.** First-run download of Python and libraries instead of bundling them. A bundled PyTorch means hundreds of unsigned libraries to sign and notarize and a multi-gigabyte DMG. The cost is a longer first launch and a network requirement.
- **Apple Silicon only.** The model needs MPS to run in real time. Windows and Linux are tracked in #1, starting with the device-agnostic worker.
- **Echo.** No echo cancellation. The app documents headphones as the supported setup.
- **Auto-update.** Not implemented. Sparkle needs a Developer ID signature and an EdDSA key; add it together with signing.
