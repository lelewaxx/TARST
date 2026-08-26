# TARST 本机 Agent Runtime

此目录是 TARST 自研 Agent Runtime 的第一阶段：不接云端模型、不接音频、也不执行工具。它通过 stdin/stdout 的 JSON Lines 协议接收一轮已经完成的 ASR 文本，流式返回统一的 Agent 事件。

Swift App 是协议客户端：它保留麦克风、ASR、TTS、播放器和取消按钮的所有权。Runtime 只处理文本、当前轮的可选 `acoustic_observation` 与短期会话上下文。

## 协议

每行 stdin 都是一个 JSON 对象。

开始一轮：

```json
{"type":"turn.start","session_id":"session-1","turn_id":"turn-1","generation_id":"generation-1","text":"你好","acoustic_observation":{"quality":"usable","confidence":0.8}}
```

取消正在进行的 generation：

```json
{"type":"generation.cancel","generation_id":"generation-1"}
```

Runtime 会将 `runtime.ready`、`agent.text_delta`、`agent.text_completed`、`agent.completed`、`agent.cancelled` 或 `agent.failed` 写入 stdout。每个事件都回显 session、turn 与 generation 标识，Swift 必须忽略不是当前 generation 的事件。

运行本地假模型：

```bash
npm run agent:runtime
```

协议和取消行为由 `npm test` 覆盖。真实 MiniMax Provider 进入下一阶段；届时它只能实现 `LLMProvider`，不能越过 Runtime 改变会话或工具策略。
