#!/usr/bin/env bash
# Builds dist/lautli.app. Ad-hoc signed unless SIGN_IDENTITY names a Developer ID certificate.
# VERSION and BUILD_NUMBER default to a dev value and the git commit count.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$repo_root/dist/lautli.app"
version="${VERSION:-0.0.0-dev}"
build_number="${BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
sign_identity="${SIGN_IDENTITY:--}"

swift build --package-path "$repo_root/macos" --configuration release
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources/worker-src/scripts"
cp "$repo_root/macos/.build/release/LautliApp" "$app_bundle/Contents/MacOS/LautliApp"
cp "$repo_root/macos/Info.plist" "$app_bundle/Contents/Info.plist"
cp -R "$repo_root"/macos/Resources/*.lproj "$app_bundle/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"

worker_src="$app_bundle/Contents/Resources/worker-src"
rsync -a --exclude '__pycache__' "$repo_root/worker" "$worker_src/"
cp "$repo_root/scripts/__init__.py" "$repo_root/scripts/asr_probe.py" "$worker_src/scripts/"
cp "$repo_root/requirements.txt" "$worker_src/requirements.txt"

if [ "$sign_identity" = "-" ]; then
  codesign --force --deep --sign - --entitlements "$repo_root/macos/Lautli.entitlements" "$app_bundle"
else
  codesign --force --deep --timestamp --options runtime --sign "$sign_identity" \
    --entitlements "$repo_root/macos/Lautli.entitlements" "$app_bundle"
fi
codesign --verify --deep --strict "$app_bundle"
printf 'Built %s (version %s, build %s)\n' "$app_bundle" "$version" "$build_number"
