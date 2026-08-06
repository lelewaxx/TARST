#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This bootstrap script currently supports Apple Silicon macOS only." >&2
  exit 1
fi

tarst_support="$HOME/Library/Application Support/TARST/Picovoice"
mkdir -p "$tarst_support"

curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 \
  https://raw.githubusercontent.com/Picovoice/porcupine/master/lib/mac/arm64/libpv_porcupine.dylib \
  --output "$tarst_support/libpv_porcupine.dylib"
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 \
  https://raw.githubusercontent.com/Picovoice/cobra/main/lib/mac/arm64/libpv_cobra.dylib \
  --output "$tarst_support/libpv_cobra.dylib"
curl --fail --location --silent --show-error --connect-timeout 10 --max-time 60 \
  https://raw.githubusercontent.com/Picovoice/porcupine/master/lib/common/porcupine_params.pv \
  --output "$tarst_support/porcupine_params.pv"

echo "Installed local Picovoice runtime in: $tarst_support"
