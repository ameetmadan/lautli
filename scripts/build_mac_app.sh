#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$repo_root/dist/Meeting Notes.app"

swift build --package-path "$repo_root/macos" --configuration release
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS"
cp "$repo_root/macos/.build/release/MeetingNotesApp" "$app_bundle/Contents/MacOS/MeetingNotesApp"
cp "$repo_root/macos/Info.plist" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MeetingNotesProjectRoot $repo_root" "$app_bundle/Contents/Info.plist"
codesign --force --deep --sign - "$app_bundle"
printf 'Built %s\n' "$app_bundle"
