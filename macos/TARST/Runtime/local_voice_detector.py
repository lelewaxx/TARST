#!/usr/bin/env python3
"""Local stdin/stdout detector used by TARST. No network or audio files are used."""
import argparse
import json
import sys

import numpy as np
import torch
from openwakeword.model import Model
from silero_vad import load_silero_vad

SAMPLE_RATE = 16_000
FRAME_SAMPLES = 1_280  # 80 ms; openWakeWord's recommended frame size.


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", action="append", required=True)
    parser.add_argument("--wake-threshold", type=float, default=0.55)
    parser.add_argument("--vad-threshold", type=float, default=0.50)
    return parser.parse_args()


def main():
    args = parse_args()
    wake_model = Model(wakeword_models=args.model, inference_framework="onnx")
    vad_model = load_silero_vad(onnx=True)
    model_names = list(wake_model.models.keys())
    vad_buffer = np.empty(0, dtype=np.int16)

    while True:
        raw = sys.stdin.buffer.read(FRAME_SAMPLES * 2)
        if not raw:
            return
        if len(raw) != FRAME_SAMPLES * 2:
            return
        samples = np.frombuffer(raw, dtype=np.int16).copy()
        scores = wake_model.predict(samples)
        keyword_index = None
        for index, model_name in enumerate(model_names):
            score = float(scores.get(model_name, 0.0))
            if score >= args.wake_threshold:
                keyword_index = index
                break

        # Silero VAD's 16 kHz ONNX model takes 512-sample (32 ms) chunks, while
        # openWakeWord prefers 1280-sample (80 ms) chunks. Keep both models local
        # and report the highest Silero probability observed for this 80 ms window.
        vad_buffer = np.concatenate((vad_buffer, samples))
        probabilities = []
        while len(vad_buffer) >= 512:
            chunk, vad_buffer = vad_buffer[:512], vad_buffer[512:]
            normalized = torch.from_numpy(chunk.astype(np.float32) / 32768.0)
            probability = vad_model(normalized, SAMPLE_RATE)
            probabilities.append(float(probability.item()))
        speech_probability = max(probabilities, default=0.0)
        print(json.dumps({"keyword_index": keyword_index, "voice_probability": speech_probability}), flush=True)


if __name__ == "__main__":
    main()
