# TARST Runtime Architecture

TARST 的主入口是本机常驻进程，而非网页。网页原型只保留为未来的日记确认与回望界面。

```text
麦克风输入（Swift 独占）
  → Wake Word（idle 时激活一次会话；会话内后续轮次无需重复唤醒）
  → VAD（唤醒后判断说话、停顿与轮次结束）
  ├→ 流式 ASR（partial 仅显示，final 才提交）
  └→ 独立声学通道（仅分析当前用户轮的韵律与表达线索）
       → Turn Fusion（final 文本 + 带置信度的声学观察）
       → TARST Agent（模式、工具策略、记忆策略）
       → 语义分句器（把 token 流整理为可朗读短句）
       → 流式 TTS（音频块）
       → 可打断播放器
```

完整设计与实施顺序见 [`streaming-voice-agent-design.md`](./streaming-voice-agent-design.md)。第一版默认采用可审计的级联管线，同时保留端到端实时语音适配器作为后续对照实验。

## 模型与 Agent Runtime

TARST 自行实现会话、Agent loop、工具权限、记忆策略和取消语义；模型 SDK 只是可替换的传输适配器。Runtime 建议作为本机 Node.js/TypeScript 子进程，通过 stdin/stdout JSON Lines 与 Swift App 通信。它只接收 ASR final 和当前轮的声学观察，永不接收或保存原始 PCM。

- 默认语音模型：面向多轮文本对话的 `M2-her` 通过 OpenAI-compatible API 和官方 `openai` SDK 调用，以降低首 token 及长尾延迟。
- 复杂任务模型：保留 `MiniMax-M2.7-highspeed` 与原生 `MiniMax-M3` Provider；后续由每轮复杂度路由，而不是让所有日常语音都承担复杂模型延迟。
- Provider 边界：`LLMProvider` 屏蔽 M3 原生流式 API 与 OpenAI-compatible 流的事件差异，业务状态机不能依赖供应商事件。
- M3 的 OpenAI-compatible 支持必须单独 smoke test；在官方兼容文档明确支持前，不把它视为既定能力。

每个 Agent 事件都携带 `sessionID`、`turnID` 和 `generationID`。用户插话时 Swift 递增 generation，并同时取消 Runtime、TTS 与播放器；任何旧 generation 的迟到事件都丢弃。

## 独立声学通道与表达记录

声学通道不属于 ASR，也不以单次输出诊断用户情绪。它与 ASR 并行读取同一段唤醒后、VAD 确认的当前用户轮 PCM，并产生带置信度的观察，例如语速、停顿比例、能量、音高变化、唤醒度与效价。低置信度、噪声、片段太短或疑似多人声都应输出“不判断”。

- 单轮观察只用于让当前回复更克制、更具同理心；Agent 必须把它当作可被用户否定的线索，不能据此断言情绪或心理状态。
- 原始 PCM 默认只在内存中存在，分析服务默认本地运行，不写入诊断或记忆。
- 情绪趋势和表达模式仅在用户显式开启后，以可查看、可删除的聚合摘要保存；单轮标签、原始音频和人格结论均不保存。
- “表达提高”属于用户主动开启的 coaching 模式：用户指定目标后，系统才提供非评判、可执行的反馈。它不用于医疗、心理诊断或风险判断。

## 当前状态机

- `idle`：只等待唤醒词，不记录或保存普通环境音。
- `awake`：已听见唤醒词，使用提示音或极短确认表示“我在”。
- `listening`：VAD 持续跟踪用户说话与有意义的停顿。
- `transcribing`：用户本轮已经结束，等待 ASR 最终文本。
- `thinking`：Agent 正在生成文本或调用工具。
- `responding`：TARST 正在流式回应；播放期 ASR 探针区分扬声器回声与真人插话，确认真人后取消 Agent、TTS 与播放器并回到 `listening`。
- `follow-up`：回答播放完后等待下一句话；30 秒内直接说话即可开启下一轮，无需重复 “Hey Tars”。

会话有两种类型：

- `one-shot`：完成一次请求、回应结束即回到 `idle`。
- `companion`：回应结束后进入 30 秒 `follow-up` 窗口；每次新回答结束都会刷新窗口，静默超时后才回到 `idle`。

## 首个真实音频闭环

下一步在 macOS 上接入下列适配器，不把具体供应商耦合进状态机：

1. `WakeWordDetector`：本地检测 “TARST / Hey TARST”。
2. `VoiceActivityDetector`：对短停顿保持耐心，并输出 `SPEECH_STARTED`、`TURN_ENDED`。
3. `AudioCapture`：以 PCM 帧将麦克风流同时送至前两者、ASR 和独立声学通道，且始终只有一个麦克风所有者。
4. `VoiceSession`：统一级联和端到端实时语音供应商的事件、取消与错误协议。
5. `SpeechChunker`：将 Agent token 流整理成自然中文短句，而不是逐 token 朗读。
6. `StreamingSpeechOutput`：边收边播，并以 generation ID 丢弃取消后的迟到音频。

原始音频默认不落盘；只有用户确认的日记文本才允许写入长期记忆。
