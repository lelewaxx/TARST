# TARST Runtime Architecture

TARST 的主入口是本机常驻进程，而非网页。网页原型只保留为未来的日记确认与回望界面。

```text
麦克风输入
  → Wake Word（仅在 idle 状态运行）
  → VAD（唤醒后判断说话、停顿与轮次结束）
  → 流式 ASR
  → Intent Router（单次任务 / 陪伴会话）
  → TARST 对话与介入策略
  → 流式 TTS
  → 扬声器
```

## 当前状态机

- `idle`：只等待唤醒词，不记录或保存普通环境音。
- `awake`：已听见唤醒词，使用提示音或极短确认表示“我在”。
- `listening`：VAD 持续跟踪用户说话与有意义的停顿。
- `responding`：TARST 正在回应；用户一开口即中断回应并回到 `listening`。

会话有两种类型：

- `one-shot`：完成一次请求、回应结束即回到 `idle`。
- `companion`：回应结束后仍保持 `listening`，直到用户明确结束或超时。

## 首个真实音频闭环

下一步在 macOS 上接入下列适配器，不把具体供应商耦合进状态机：

1. `WakeWordDetector`：本地检测 “TARST / Hey TARST”。
2. `VoiceActivityDetector`：对短停顿保持耐心，并输出 `SPEECH_STARTED`、`TURN_ENDED`。
3. `AudioCapture`：以 PCM 帧将麦克风流同时送至前两者和 ASR。
4. `SpeechOutput`：支持停止正在播放的 TTS，以实现自然打断。

原始音频默认不落盘；只有用户确认的日记文本才允许写入长期记忆。
