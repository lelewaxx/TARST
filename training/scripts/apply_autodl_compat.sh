#!/usr/bin/env bash
set -euo pipefail

# Apply the compatibility fixes used by the TARST AutoDL training environment.
# Run this from the training workspace after cloning openWakeWord and Piper.

OPENWAKEWORD_DIR="${OPENWAKEWORD_DIR:-openwakeword}"
PIPER_DIR="${PIPER_DIR:-piper-sample-generator}"

python - "$PIPER_DIR/generate_samples.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "torch.load(model_path)"
new = "torch.load(model_path, weights_only=False)"
if new not in text:
    if old not in text:
        raise SystemExit(f"Cannot find the expected torch.load call in {path}")
    text = text.replace(old, new, 1)
    path.write_text(text)
    print(f"patched {path}")
else:
    print(f"already patched {path}")
PY

python - "$OPENWAKEWORD_DIR/openwakeword/train.py" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "n_cpus = n_cpus//2"
new = "n_cpus = min(n_cpus//2, 8)"
count = text.count(new)
text = text.replace(old, new)
path.write_text(text)
print(f"worker cap present {text.count(new)} time(s) in {path}")
if text.count(new) < 2:
    raise SystemExit("Expected two worker-cap locations in openWakeWord train.py")
PY

echo "AutoDL compatibility patches applied."
