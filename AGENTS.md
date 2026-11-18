# AGENTS.md

lautli: a macOS menu-bar app (Swift, `macos/`) that talks to a local Python transcription worker (`worker/lautli_worker/`) over JSON lines. Read `CONTRIBUTING.md` first (layout, protocol, setup flow, string translation).

## Toolchain

- Python from `.python-version` (matches the runtime the app downloads at first launch); pip with `requirements.txt` (runtime, exact pins) and `requirements-dev.txt` (adds pytest and ruff). Swift Package Manager in `macos/`.
- `worker/lautli_worker/mcp_server.py` is standard library only on purpose: a new `requirements.txt` entry resets setup for every existing install.

## Verify a change

```sh
swift test --package-path macos                      # macOS only
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/ruff check .                               # PY-001 / PY-002: lint plus typed signatures
.venv/bin/python -m pytest -q
```

CI (`ci.yml`) runs these on macOS and, for the Python side, on Windows; `dependency-audit.yml` runs `pip-audit -r requirements.txt`.

## Does not exist

- No Swift lint step and no Python typecheck (ruff's `ANN` rules only check that signatures are annotated). Do not claim either passed.

## Never run as verification

- `LAUTLI_E2E=1` and `LAUTLI_FILE_E2E=1` tests download about 4 GB or need an installed model; run them only when asked.
- `scripts/build_mac_app.sh`, `make_dmg.sh`, `make_appcast.sh` build and sign release artifacts; `release.yml` publishes on `main` pushes.

## Conventions

Standards live in `ameetmadan/standards`. PR titles and commits follow Conventional Commits; branches are `<type>/<short-description>` off `main`.
