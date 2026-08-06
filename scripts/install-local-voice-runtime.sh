#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
support_dir="$HOME/Library/Application Support/TARST/VoiceRuntime"
python_bin="${PYTHON_BIN:-python3}"

mkdir -p "$support_dir"
"$python_bin" -m venv "$support_dir/venv"
"$support_dir/venv/bin/python3" -m pip install --upgrade pip
"$support_dir/venv/bin/python3" -m pip install "openwakeword==0.6.0" "silero-vad==6.2.0"
"$support_dir/venv/bin/python3" - <<'PY'
from openwakeword.utils import download_models

# This downloads only openWakeWord's shared feature models. TARST's own
# wake-word models are imported separately, so no third-party wake phrase is
# enabled or bundled with the application.
download_models(["tarst-custom-model-placeholder"])
PY
cp "$root_dir/macos/TARST/Runtime/local_voice_detector.py" "$support_dir/local_voice_detector.py"

echo "Installed local openWakeWord + Silero VAD runtime in: $support_dir"
echo "Next: import TARST.onnx and Hey-TARST.onnx in TARST Settings."
