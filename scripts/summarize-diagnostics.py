#!/usr/bin/env python3
"""Summarize TARST's local numeric diagnostics. No audio is read or written."""

import argparse
import json
import math
from pathlib import Path


def percentile(values, fraction):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1)
    return ordered[max(index, 0)]


def format_latency(values):
    if not values:
        return "无数据"
    return (
        f"n={len(values)}, median={percentile(values, 0.5):.0f} ms, "
        f"p95={percentile(values, 0.95):.0f} ms"
    )


def resolve_paths(inputs, last=None):
    paths = []
    for input_path in inputs:
        input_path = input_path.expanduser()
        if input_path.is_dir():
            paths.extend(input_path.glob("diagnostics-*.jsonl"))
        else:
            paths.append(input_path)
    paths = sorted(set(paths), key=lambda path: (path.stat().st_mtime, str(path)))
    if last is not None:
        paths = paths[-last:]
    if not paths:
        raise SystemExit("no diagnostics-*.jsonl files found")
    return paths


def load_events(path):
    events = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            try:
                event = json.loads(line)
                event["_source_path"] = str(path)
                events.append(event)
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}") from error
    return events


def summarize(paths):
    sessions = [load_events(path) for path in paths]
    events = [event for session in sessions for event in session]
    frames = [event for event in events if event.get("type") == "frame"]
    wake_events = [event for event in events if event.get("type") == "wake_accepted"]
    labels = [event for event in events if event.get("type") == "label"]
    attempts = [event for event in labels if event.get("name") == "wake_attempt"]
    agent_frames = [event for event in events if event.get("type") == "agent_stream_frame"]

    tarst_scores = [float(frame.get("tarst_score", 0)) for frame in frames]
    hey_scores = [float(frame.get("hey_tarst_score", 0)) for frame in frames]
    vad_scores = [float(frame.get("vad_probability", 0)) for frame in frames]
    duration_ms = sum(
        max((int(event.get("elapsed_ms", 0)) for event in session), default=0)
        for session in sessions
    )
    vad_flags = [score >= 0.5 for score in vad_scores]
    vad_transitions = sum(left != right for left, right in zip(vad_flags, vad_flags[1:]))
    associated_wakes = {
        index for index, wake in enumerate(wake_events)
        if any(
            attempt.get("_source_path") == wake.get("_source_path") and
            int(attempt.get("elapsed_ms", 0)) - 5_000
            <= int(wake.get("elapsed_ms", -1))
            <= int(attempt.get("elapsed_ms", 0)) + 5_000
            for attempt in attempts
        )
    }
    unassociated_wakes = len(wake_events) - len(associated_wakes)

    if len(paths) == 1:
        print(f"诊断文件：{paths[0]}")
    else:
        print(f"诊断集合：{len(paths)} 个文件（{paths[0].name} → {paths[-1].name}）")
    print(f"累计时长：{duration_ms / 1000:.1f} 秒；检测帧：{len(frames)}")
    print(
        "TARST 分数："
        f"max={max(tarst_scores, default=0):.3f}, p95={percentile(tarst_scores, 0.95):.3f}"
    )
    print(
        "Hey-TARST 分数："
        f"max={max(hey_scores, default=0):.3f}, p95={percentile(hey_scores, 0.95):.3f}"
    )
    print(
        "VAD："
        f"max={max(vad_scores, default=0):.3f}, p95={percentile(vad_scores, 0.95):.3f}, "
        f">=0.50 的帧={sum(vad_flags)} ({sum(vad_flags) / len(vad_flags):.1%}), "
        f"高低切换={vad_transitions} 次"
        if vad_flags else
        "VAD：无检测帧"
    )
    print(
        f"接受的唤醒：{len(wake_events)}；"
        f"未关联测试尝试：{unassociated_wakes}；"
        f"人工标记误唤醒：{sum(label.get('name') == 'false_wake' for label in labels)}"
    )
    print(
        "状态事件："
        f"开始说话={sum(event.get('type') == 'speech_started' for event in events)}，"
        f"结束说话={sum(event.get('type') == 'turn_ended' for event in events)}，"
        f"等待超时={sum(event.get('type') == 'waiting_timed_out' for event in events)}，"
        f"回复期间插话={sum(event.get('type') == 'speech_during_response' for event in events)}"
    )

    vad_tails = [
        int(event["vad_tail_ms"])
        for event in events
        if event.get("type") == "turn_ended" and "vad_tail_ms" in event
    ]
    asr_finalize = [
        int(event["finalize_ms"])
        for event in events
        if event.get("type") == "asr_final" and "finalize_ms" in event
    ]
    agent_first_text = [
        int(event["latency_ms"])
        for event in events
        if event.get("type") == "agent_first_text" and "latency_ms" in event
    ]
    tts_first_audio = [
        int(event["latency_ms"])
        for event in events
        if event.get("type") == "tts_first_audio" and "latency_ms" in event
    ]
    barge_in_confirmation = [
        int(event["confirmation_ms"])
        for event in events
        if event.get("type") == "speech_during_response" and "confirmation_ms" in event
    ]
    barge_in_pause = [
        int(event["candidate_to_pause_ms"])
        for event in events
        if event.get("type") == "barge_in_playback_paused" and "candidate_to_pause_ms" in event
    ]
    pause_to_confirmation = [
        int(event["pause_to_confirmation_ms"])
        for event in events
        if event.get("type") == "speech_during_response" and "pause_to_confirmation_ms" in event
    ]
    end_to_speech = []
    for session in sessions:
        last_turn_end = None
        for event in session:
            if event.get("type") == "turn_ended":
                last_turn_end = int(event.get("elapsed_ms", 0))
            elif event.get("type") == "playback_started" and last_turn_end is not None:
                end_to_speech.append(int(event.get("elapsed_ms", 0)) - last_turn_end)
                last_turn_end = None

    if (vad_tails or asr_finalize or agent_first_text or tts_first_audio
            or end_to_speech or barge_in_confirmation or barge_in_pause or pause_to_confirmation):
        print("延迟基线：")
        print(f"  VAD 尾静默：{format_latency(vad_tails)}")
        print(f"  ASR finish→final：{format_latency(asr_finalize)}")
        print(f"  Agent start→首字：{format_latency(agent_first_text)}")
        print(f"  TTS request→首音频：{format_latency(tts_first_audio)}")
        print(f"  turn end→开始播放：{format_latency(end_to_speech)}")
        print(f"  插话首帧→确认：{format_latency(barge_in_confirmation)}")
        print(f"  插话首帧→暂停：{format_latency(barge_in_pause)}")
        print(f"  暂停→确认：{format_latency(pause_to_confirmation)}")
    if agent_frames:
        relations = {}
        lifecycles = {}
        finish_reasons = {}
        for frame in agent_frames:
            relation = str(frame.get("relation", "none"))
            lifecycle = str(frame.get("lifecycle", "unknown"))
            finish_reason = str(frame.get("finish_reason", "none"))
            relations[relation] = relations.get(relation, 0) + 1
            lifecycles[lifecycle] = lifecycles.get(lifecycle, 0) + 1
            if finish_reason != "none":
                finish_reasons[finish_reason] = finish_reasons.get(finish_reason, 0) + 1
        print(
            "MiniMax 流："
            f"事件={len(agent_frames)}，"
            f"生命周期={format_counts(lifecycles)}，"
            f"文本关系={format_counts(relations)}，"
            f"结束原因={format_counts(finish_reasons)}"
        )

    if not attempts:
        print("尚无人工标记的唤醒尝试。")
        return

    print("\n唤醒尝试（标记后 5 秒窗口）：")
    successes = 0
    valid_attempts = 0
    for number, attempt in enumerate(attempts, 1):
        start = int(attempt.get("elapsed_ms", 0))
        end = start + 5_000
        keyword = attempt.get("keyword", "TARST")
        expected_index = 1 if keyword == "Hey-TARST" else 0
        source = attempt.get("_source_path")
        window_frames = [
            frame for frame in frames
            if frame.get("_source_path") == source
            and start <= int(frame.get("elapsed_ms", -1)) <= end
        ]
        matching_wakes = [
            event for event in wake_events
            if event.get("_source_path") == source
            and start <= int(event.get("elapsed_ms", -1)) <= end
        ]
        preceding_wakes = [
            event for event in wake_events
            if event.get("_source_path") == source
            and start - 5_000 <= int(event.get("elapsed_ms", -1)) < start
        ]
        score_key = "hey_tarst_score" if expected_index == 1 else "tarst_score"
        maximum = max((float(frame.get(score_key, 0)) for frame in window_frames), default=0)
        if matching_wakes:
            successes += 1
            valid_attempts += 1
            trigger_names = ", ".join(
                "Hey-TARST" if int(event.get("keyword_index", 0)) == 1 else "TARST"
                for event in matching_wakes
            )
            print(f"  {number:02d}. {keyword}: 成功，触发模型={trigger_names}，窗口最高分={maximum:.3f}")
        elif preceding_wakes:
            print(f"  {number:02d}. {keyword}: 无效（标记发生在已有唤醒之后），窗口最高分={maximum:.3f}")
        else:
            valid_attempts += 1
            print(f"  {number:02d}. {keyword}: 漏唤醒，窗口最高分={maximum:.3f}")

    if valid_attempts:
        print(f"有效尝试唤醒率：{successes}/{valid_attempts} = {successes / valid_attempts:.1%}")
    print(f"无效标记：{len(attempts) - valid_attempts}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "paths",
        type=Path,
        nargs="+",
        help="diagnostics-*.jsonl files or directories",
    )
    parser.add_argument(
        "--last",
        type=int,
        help="only summarize the newest N resolved files",
    )
    args = parser.parse_args()
    if args.last is not None and args.last <= 0:
        parser.error("--last must be greater than zero")
    summarize(resolve_paths(args.paths, args.last))


def format_counts(counts):
    if not counts:
        return "无"
    return "/".join(f"{key}:{value}" for key, value in sorted(counts.items()))


if __name__ == "__main__":
    main()
