#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./run_autodl.sh TARST generate
#   ./run_autodl.sh TARST augment
#   ./run_autodl.sh TARST train
#
# Run from the training workspace containing openwakeword/,
# piper-sample-generator/, and the selected YAML file.

MODEL_NAME="${1:?model name required: TARST or Hey-TARST}"
PHASE="${2:?phase required: generate, augment, or train}"
CONFIG="${MODEL_NAME}.yaml"
PYTHON_BIN="${PYTHON_BIN:-python}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Missing $CONFIG in $(pwd)" >&2
  exit 1
fi

export MPLBACKEND="${MPLBACKEND:-Agg}"
export TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD="${TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD:-1}"

case "$PHASE" in
  generate)
    exec "$PYTHON_BIN" -u openwakeword/openwakeword/train.py \
      --training_config "$CONFIG" --generate_clips
    ;;
  augment)
    exec "$PYTHON_BIN" -u openwakeword/openwakeword/train.py \
      --training_config "$CONFIG" --augment_clips
    ;;
  train)
    ulimit -n 65535 2>/dev/null || true
    exec "$PYTHON_BIN" -u openwakeword/openwakeword/train.py \
      --training_config "$CONFIG" --train_model
    ;;
  *)
    echo "Unknown phase: $PHASE" >&2
    exit 1
    ;;
esac
