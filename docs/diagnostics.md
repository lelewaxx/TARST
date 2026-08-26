# TARST 本地诊断模式

诊断模式只记录模型分数、VAD 概率、状态事件、设备名称、人工标签，以及 MiniMax 流帧的结构化元数据。它不记录 PCM、原始音频、用户说话内容、模型回复正文或密钥，也不会因为诊断而额外发起网络请求。

MiniMax 元数据包括帧序号、文本来源、候选长度、累计发出长度、文本关系分类、`finish_reason` 和流生命周期。关系分类可用于判断服务端返回的是普通增量、累计快照还是修订式文本，但无法从诊断文件恢复正文。

## 测试流程

1. 在菜单栏选择 `TARST → 诊断 → 开始诊断记录`。
2. 选择 `TARST → 开始监听`。
3. 每次准备说唤醒词前，先选择 `标记下一次尝试：TARST` 或 `标记下一次尝试：Hey TARST`，随后在 5 秒内说出对应短语。
4. 若没有主动说唤醒词却发生唤醒，选择 `标记刚才为误唤醒`。
5. 至少完成一轮正常问答；若菜单中的回复持续改写，等待它完成或显示明确的超时错误。
6. 测试结束后选择 `停止诊断记录`。
7. 选择 `打开诊断文件夹` 找到最新的 `diagnostics-*.jsonl`。

汇总命令：

```bash
scripts/summarize-diagnostics.py "$HOME/Library/Application Support/TARST/Diagnostics/diagnostics-YYYYMMDD-HHMMSS.jsonl"
```

诊断文件不会进入 Git，可在 Finder 中直接删除。
