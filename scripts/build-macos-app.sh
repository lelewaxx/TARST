#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$root_dir/macos/TARST"
output_dir="$root_dir/dist"
app_dir="$output_dir/TARST.app"
signing_identity="${TARST_CODESIGN_IDENTITY:-TARST Local Development}"

if ! security find-certificate -c "$signing_identity" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "Missing persistent TARST signing identity: $signing_identity" >&2
  exit 1
fi

swift build --package-path "$package_dir" -c release --product TARST

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/.build/arm64-apple-macosx/release/TARST" "$app_dir/Contents/MacOS/TARST"
cp "$package_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$package_dir/Runtime/local_voice_detector.py" "$app_dir/Contents/Resources/local_voice_detector.py"
mkdir -p "$app_dir/Contents/Resources/agent"
cp -R "$root_dir/agent/src" "$app_dir/Contents/Resources/agent/src"
codesign --force --sign "$signing_identity" "$app_dir"

echo "Built $app_dir"
echo "Open it with: open '$app_dir'"
