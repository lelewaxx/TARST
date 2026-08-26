# 实时 Voice Agent 低延迟架构调研

日期：2026-08-18

## 结论

成熟 Voice Agent 的“快”并不是某一个模型更快，而是同时采用以下模式：

1. 会话级长连接，音频持续双向流动，避免每轮重新握手。
2. VAD 只负责判断有没有人在说话；真正的轮次结束由 STT endpoint 或语义 turn detector 判断。
3. 在轮次尚未最终确认时，提前启动 LLM；部分系统甚至投机启动 TTS。
4. LLM 文本一旦形成可朗读短语就送入流式 TTS，不等待整段回答。
5. 打断先快速暂停播放，再用声学或语义模型确认；若是假打断则从实际播放位置恢复。
6. 每轮记录分阶段延迟，而不是只记录一个总耗时。

## 现有系统的做法

| 系统 | 官方实现中的关键机制 | TARST 可以学习什么 |
|---|---|---|
| OpenAI Realtime | 单个长生命周期 WebSocket 会话持续接收和生成音频；支持 `semantic_vad`、自动中断，以及根据真实播放位置截断历史 | 长连接优先；打断不只停止声音，还要让模型上下文只保留用户真正听到的部分 |
| Gemini Live | 麦克风音频持续送入同一个 realtime session；模型返回增量音频；中断时立即清空尚未播放的音频队列 | 将输入、模型、输出做成真正全双工流，而不是每轮建立多个独立请求 |
| LiveKit Agents | 动态 endpointing；投机启动 LLM，必要时也投机 TTS；自适应声学打断；假打断可恢复播放 | 先投机计算、确认后播放；用专门的打断判别替代固定 VAD 阈值；保留恢复能力 |
| Deepgram Voice Agent | 每轮提供 STT、首 token、首文本、TTS 和总延迟报告；STT endpoint 可在 10 ms 到 300–500 ms 间按场景配置 | TARST 必须拥有同等级的逐段指标；端点等待应按对话类型动态变化 |
| Pipecat | 测量 TTFS、TTFB、TTFA 和文本聚合耗时；本地 VAD 默认只需约 0.2 秒 stop window，再由 Smart Turn 判断语义完整性 | 将“语音停止”和“句意完成”拆开；单纯把固定静默设得很长并不是稳妥方案 |
| ElevenLabs Agents | 收到足够文字和逗号即可开始说，不等完整句号；TTS 使用会话级 WebSocket 和 context，打断时关闭旧 context | TARST 的分句器可更早提交自然短语；火山 TTS 连接应在 companion session 内复用 |

## TARST 当前基线

从最近三次有效本机诊断提取：

- `turn_end → ASR final`：约 83–211 ms，已经较快。
- `Agent start → 首个可见文本`：约 0.7–2.6 s，是当前最大的网络/模型等待项。
- `Agent start → 首个 TTS 请求`：约 1.0–2.6 s，部分轮次还包含分句聚合等待。
- 旧 VAD 固定尾静默：1.8 s；本轮先降至 1.2 s，每轮直接减少约 600 ms。
- 旧日志没有 TTS 首音频和真实 user-to-bot latency；本轮已经新增测点。

## 对 TARST 的实施顺序

### P0：先做到可测量（本轮）

- 每轮记录 `vad_tail_ms`、`ASR finish→final`、`Agent start→首字`、`TTS request→首音频`、`turn end→playback start`。
- 汇总 median 和 p95，任何优化必须同时观察错误率、回答完整性和误打断率。
- 将固定 VAD 尾静默从 1.8 s 降至 1.2 s，并保留状态机回归。

### P1：连接与首音频

- companion session 内复用火山 TTS WebSocket；每句话只创建新 session/context，不重新建立 TCP/TLS/WebSocket。
- 评估复用火山 ASR 连接。当前 ASR 在用户说话期间并行建连，因此优先级低于 TTS。
- 分句器从“句号或 28 字后的逗号”改为按稳定短语刷新，目标是首个自然短语约 12–20 个汉字；不能在词中间硬切。
- 为常用固定提示音或短语使用预合成缓存。

### P2：语义端点与投机生成

- VAD 在约 0.2–0.3 s 静默时产生候选 end-of-speech；用 ASR partial 的标点、稳定度和轻量语义 turn detector 判断是否完整。
- 对高置信度完整 partial 投机启动 LLM；ASR final 一致时直接沿用，不一致则取消 generation。
- 默认只投机 LLM，确认轮次后才播放；在数据证明误投机率足够低后，再试投机 TTS。

### P3：更快且可恢复的打断

- 以流式声学打断分类器替代“等待累计 ASR 文本后比较回答”的主路径。
- VAD 检出重叠真人语音后先快速 duck/pause，而不是马上永久取消；确认真人打断后取消，判定为回声或 backchannel 时恢复。
- 记录实际播放到的字/音频位置，取消时同步裁剪模型历史。

### P4：模型路由与端到端语音对照实验

- 简短日常对话可路由到低首 token 延迟模型；复杂任务继续用 M3。
- 建立端到端 realtime speech-to-speech 适配器作为对照组，但保留当前级联管线，因为级联方案更易审计、替换模型和控制记忆。

## 目标指标

需要用新诊断取得真实 p50/p95 后再冻结数值。第一阶段暂定：

- VAD 尾静默 p50 ≤ 1.25 s，且无明显句中误截断。
- ASR finish→final p95 ≤ 300 ms。
- Agent start→首字 p50 ≤ 1.2 s。
- TTS request→首音频 p50 ≤ 350 ms。
- 用户说完→开始播放 p50 ≤ 2.5 s，后续争取 ≤ 1.5 s。
- 明确停止指令→播放器暂停 p50 ≤ 500 ms；误打断可自动恢复。

## 官方资料

- [OpenAI Agents SDK：Realtime agents guide](https://openai.github.io/openai-agents-python/realtime/guide/)
- [Google Gemini Cookbook：Live API Native Audio](https://github.com/google-gemini/cookbook/blob/main/quickstarts/Get_started_LiveAPI_NativeAudio.py)
- [LiveKit：Turn detection and interruptions](https://docs.livekit.io/agents/build/turns/)
- [LiveKit：Speech and preemptive generation](https://docs.livekit.io/agents/build/audio/)
- [LiveKit：Adaptive interruption handling](https://docs.livekit.io/agents/logic/turns/adaptive-interruption-handling/)
- [Deepgram：Voice Agent Latency Report](https://developers.deepgram.com/docs/voice-agent-latency-report)
- [Deepgram：Endpointing and interim results](https://developers.deepgram.com/docs/understand-endpointing-interim-results)
- [Pipecat：Speech input and turn detection](https://docs.pipecat.ai/pipecat/learn/speech-input)
- [Pipecat：STT latency tuning](https://docs.pipecat.ai/pipecat/fundamentals/stt-latency-tuning)
- [Pipecat：Metrics](https://docs.pipecat.ai/pipecat/fundamentals/metrics)
- [ElevenLabs：Conversation flow](https://elevenlabs.io/docs/eleven-agents/customization/conversation-flow)
- [ElevenLabs：Latency optimization](https://elevenlabs.io/docs/eleven-api/guides/how-to/best-practices/latency-optimization)
- [ElevenLabs：Multi-context WebSocket](https://elevenlabs.io/docs/eleven-api/guides/how-to/websockets/multi-context-web-socket)
