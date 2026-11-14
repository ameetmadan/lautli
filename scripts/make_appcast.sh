#!/usr/bin/env bash
# Writes dist/appcast.xml for dist/lautli-<version>.dmg, signed with the Sparkle EdDSA private key.
# Requires SPARKLE_PRIVATE_ED_KEY_FILE (file holding the key exported by `generate_keys -x`) and TAG (e.g. v1.2.3).
# The appcast is uploaded as a Release asset; the app reads releases/latest/download/appcast.xml.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${TAG:?TAG is required}"
key_file="${SPARKLE_PRIVATE_ED_KEY_FILE:?SPARKLE_PRIVATE_ED_KEY_FILE is required}"
repository="${GITHUB_REPOSITORY:-ameetmadan/lautli}"
dmg="$repo_root/dist/lautli-${tag#v}.dmg"
tool="$(find "$repo_root/macos/.build/artifacts" -type f -name generate_appcast | head -n 1)"
[ -n "$tool" ] || { echo "generate_appcast not found; run swift build first" >&2; exit 1; }

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
cp "$dmg" "$staging/"
"$tool" --ed-key-file "$key_file" \
  --download-url-prefix "https://github.com/$repository/releases/download/$tag/" \
  --link "https://github.com/$repository/releases/tag/$tag" \
  -o "$repo_root/dist/appcast.xml" "$staging"
printf 'Wrote %s\n' "$repo_root/dist/appcast.xml"
