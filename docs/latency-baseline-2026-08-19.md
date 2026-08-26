# TARST 端到端语音延迟基线

日期：2026-08-19

## 测量方法

`EndToEndLatencySmokeTest` 使用真实火山 TTS 生成一句用户问题，将 24 kHz PCM 转为 16 kHz，并按每 80 ms 一帧实时送入真实火山 ASR。最后一帧后按照标点 endpoint 策略等待 650 ms，再依次经过：

`ASR final → MiniMax M2.7-highspeed 流式首字 → 中文短语切分 → 同一条火山 TTS WebSocket → 首个 PCM 音频`

运行：

```bash
python3 scripts/run-latency-benchmark.py --runs 5
```

该测试使用真实网络、真实凭据和真实服务，但用户语音由 TTS 合成，且不经过房间麦克风、唤醒词和扬声器播放。因此它是可重复的级联网络基线，不替代真人房间对话的最终 p50/p95。

## 五轮结果

| 指标 | median | p95 |
|---|---:|---:|
| VAD 尾静默（650 ms 策略及调度） | 680 ms | 682 ms |
| ASR finish→final | 101 ms | 125 ms |
| Agent start→首字 | 654 ms | 811 ms |
| Agent start→首个可朗读短语 | 783 ms | 814 ms |
| TTS request→首音频 | 262 ms | 278 ms |
| 用户说完→首音频 | 1821 ms | 1866 ms |

默认 M2-her 五轮原始 `用户说完→首音频`：1686、1828、1821、1866、1620 ms。此前 M2.7-highspeed 五轮为 1782、2755、2589、1842、1876 ms；M2-her 同时降低了典型延迟和服务端长尾。

## 与旧基线的关系

- 旧实现固定等待 1.8 秒静默；当前带句末标点路径约 0.68 秒，仅 endpoint 一项减少约 1.12 秒。
- 旧 M3 三轮首字中位数约 1.71 秒。独立短提示 A/B 中，M2.7/M2.5/M2.1 highspeed 的五轮首字中位数分别为 713/1467/1335 ms；官方定位为多轮文本对话的 M2-her 为 582 ms、p95 785 ms，因此日常语音默认改为 M2-her，M2.7/M3 留给复杂任务。
- 持久 TTS WebSocket 的当前首音频中位数 284 ms，p95 332 ms；独立双 session 测试也显示首次建连约 510 ms、复用后约 262 ms。
- 可重复级联基线已低于第一阶段 `用户说完→首音频 p50 ≤ 2.5 秒` 目标，p95 从 M2.7-highspeed 的约 2.76 秒降至 1.87 秒；仍未达到后续追求的 ≤1.5 秒。

## 插话边界

- `speech_during_response.confirmation_ms` 现在记录首个重叠 VAD 帧到确认打断的时间。
- 曾测试本地唤醒词快路径。完整声学计时只有 3/5 命中，命中耗时约 2.0–2.9 秒，并且有一轮在注入测试语音之前由普通回答自触发；该路径已完整撤回。
- 普通自由文本继续依赖 ASR echo/user 判别，延迟较高；它仍是下一阶段需要优化的部分，不能用分类器内部的 0 ms 确认冒充整体插话指标。

当前新增可恢复的两阶段打断：有 echo anchor 的新后缀出现一次递进证据，或无 anchor 的长差异出现两次递进证据时，先暂停主播放和 far-end reference；确认真人后取消，重新归类为 echo/final/failure 或 800 ms 超时则恢复。最终纯回声 5/5、此前压力测试 10/10 均未出现假暂停或误取消。

同一台 Mac 扬声器注入“停一下……”不是可靠的人声替代：XU316 会把相同空间路径的声音一并当作回声。该最坏情况最新 3 轮为 2 次确认、1 次未确认；一旦暂停，暂停→确认分别为 303/714 ms。它证明暂停后的确认链路有效，但不能替代真人从不同空间位置插话的 p50/p95。

本机 ReSpeaker Lite 的 USB `bcdDevice=0x0207`，对应官方当前 USB 固件 v2.0.7。设备向 macOS 暴露 16 kHz 双输入/双输出，但官方只为 I2S v1.1.0 明确说明 channel 0/1 分别面向 ASR 和唤醒词；不能把该通道语义套到 USB 固件。调整 Mac 扬声器与 USB far-end reference 的启动先后也没有降低 VAD 残留，实验已撤回。

参考：[MiniMax 官方模型列表](https://platform.minimaxi.com/docs/api-reference/api-overview)、[ReSpeaker Lite 官方固件仓库](https://github.com/respeaker/ReSpeaker_Lite/)、[Seeed ReSpeaker Lite 文档](https://wiki.seeedstudio.com/reSpeaker_usb_v3/)。
