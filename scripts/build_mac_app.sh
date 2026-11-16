#!/usr/bin/env bash
# Builds dist/lautli.app. Ad-hoc signed unless SIGN_IDENTITY names a Developer ID certificate.
# VERSION and BUILD_NUMBER default to a dev value and the git commit count.
# With SPARKLE_PUBLIC_ED_KEY set, the app is stamped for Sparkle auto-update (SUFeedURL defaults to the
# appcast.xml asset of the latest GitHub Release). Without it the app builds with updates disabled.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_bundle="$repo_root/dist/lautli.app"
version="${VERSION:-0.0.0-dev}"
build_number="${BUILD_NUMBER:-$(git -C "$repo_root" rev-list --count HEAD)}"
sign_identity="${SIGN_IDENTITY:--}"
feed_url="${SPARKLE_FEED_URL:-https://github.com/ameetmadan/lautli/releases/latest/download/appcast.xml}"

swift build --package-path "$repo_root/macos" --configuration release
rm -rf "$app_bundle"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources/worker-src/scripts"
cp "$repo_root/macos/.build/release/LautliApp" "$app_bundle/Contents/MacOS/LautliApp"

# Embed Sparkle (resolved by SwiftPM as a binary artifact) and let the executable find it.
sparkle_framework="$(find "$repo_root/macos/.build/artifacts" -type d -name Sparkle.framework -path '*macos*' | head -n 1)"
[ -n "$sparkle_framework" ] || { echo "Sparkle.framework not found in macos/.build/artifacts" >&2; exit 1; }
mkdir -p "$app_bundle/Contents/Frameworks"
ditto "$sparkle_framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$app_bundle/Contents/MacOS/LautliApp" 2>/dev/null || true
cp "$repo_root/macos/Info.plist" "$app_bundle/Contents/Info.plist"
cp -R "$repo_root"/macos/Resources/*.lproj "$app_bundle/Contents/Resources/"
cp "$repo_root/macos/Resources/AppIcon.icns" "$app_bundle/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${version#v}" "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_bundle/Contents/Info.plist"
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  plist="$app_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$plist"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$plist"
fi

worker_src="$app_bundle/Contents/Resources/worker-src"
rsync -a --exclude '__pycache__' "$repo_root/worker" "$worker_src/"
cp "$repo_root/scripts/__init__.py" "$repo_root/scripts/asr_probe.py" "$worker_src/scripts/"
cp "$repo_root/requirements.txt" "$worker_src/requirements.txt"

# Sign inside-out (no --deep) so every Sparkle helper gets the hardened runtime and a secure timestamp.
sign() {
  if [ "$sign_identity" = "-" ]; then
    codesign --force --sign - "$@"
  else
    codesign --force --timestamp --options runtime --sign "$sign_identity" "$@"
  fi
}
sparkle="$app_bundle/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$sparkle/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/XPCServices/Downloader.xpc"
sign "$sparkle/Autoupdate"
sign "$sparkle/Updater.app"
sign "$app_bundle/Contents/Frameworks/Sparkle.framework"
sign --entitlements "$repo_root/macos/Lautli.entitlements" "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf 'Built %s (version %s, build %s)\n' "$app_bundle" "$version" "$build_number"
