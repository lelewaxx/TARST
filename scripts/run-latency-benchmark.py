#!/usr/bin/env python3
"""Run TARST's credentialed end-to-end latency smoke repeatedly and aggregate it."""

import argparse
import math
import re
import subprocess
from pathlib import Path


METRICS = {
    "VAD tail": "VAD 尾静默",
    "ASR final": "ASR finish→final",
    "agent first text": "Agent start→首字",
    "phrase ready": "Agent start→首个可朗读短语",
    "TTS first audio": "TTS request→首音频",
    "user end→first audio": "用户说完→首音频",
}


def percentile(values, fraction):
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1)
    return ordered[max(index, 0)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--provider", default="minimax_m2_her")
    args = parser.parse_args()
    if args.runs <= 0:
        parser.error("--runs must be greater than zero")

    root = Path(__file__).resolve().parent.parent
    package = root / "macos" / "TARST"
    subprocess.run(
        [
            "swift", "build", "--package-path", str(package),
            "--product", "EndToEndLatencySmokeTest",
        ],
        cwd=root,
        check=True,
    )
    bin_path = subprocess.run(
        ["swift", "build", "--package-path", str(package), "--show-bin-path"],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    executable = Path(bin_path) / "EndToEndLatencySmokeTest"
    values = {name: [] for name in METRICS}

    pattern = re.compile(
        r"(VAD tail|ASR final|agent first text|phrase ready|TTS first audio|"
        r"user end→first audio) (\d+) ms"
    )
    for run in range(1, args.runs + 1):
        result = subprocess.run(
            [str(executable), args.provider],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        output = result.stdout.strip()
        observed = dict((name, int(value)) for name, value in pattern.findall(output))
        missing = set(values) - set(observed)
        if missing:
            raise SystemExit(f"run {run} omitted metrics: {', '.join(sorted(missing))}")
        for name, value in observed.items():
            values[name].append(value)
        print(f"{run:02d}. {output}", flush=True)

    print("\n聚合延迟：")
    for name, label in METRICS.items():
        samples = values[name]
        print(
            f"  {label}: n={len(samples)}, "
            f"median={percentile(samples, 0.5)} ms, "
            f"p95={percentile(samples, 0.95)} ms"
        )


if __name__ == "__main__":
    main()
