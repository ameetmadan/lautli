#!/usr/bin/env bash
# Packages dist/lautli.app into dist/lautli-<version>.dmg.
# With NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER set, the DMG is notarized and stapled.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
version="${VERSION:-0.0.0-dev}"
dmg="$repo_root/dist/lautli-${version#v}.dmg"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

cp -R "$repo_root/dist/lautli.app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname "lautli" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null

if [ "${SIGN_IDENTITY:--}" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$dmg"
fi
if [ -n "${NOTARY_KEY_PATH:-}" ]; then
  xcrun notarytool submit "$dmg" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  xcrun stapler staple "$dmg"
fi
printf 'Packaged %s\n' "$dmg"
