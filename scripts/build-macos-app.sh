#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$root_dir/macos/TARST"
output_dir="$root_dir/dist"
app_dir="$output_dir/TARST.app"

swift build --package-path "$package_dir" -c release --product TARST

rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$package_dir/.build/arm64-apple-macosx/release/TARST" "$app_dir/Contents/MacOS/TARST"
cp "$package_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$package_dir/Runtime/local_voice_detector.py" "$app_dir/Contents/Resources/local_voice_detector.py"
codesign --force --sign - "$app_dir"

echo "Built $app_dir"
echo "Open it with: open '$app_dir'"
