# TARST 开发交接：本地 Wake Word + VAD 阶段

更新时间：2026-08-16
当前分支：`agent/macos-wake-vad-demo`

## 项目方向

TARST 是一个常驻 macOS 的个人 Voice Agent，而不是网页聊天工具。它的第一层是**状态层**：本地唤醒、判断用户是否正在说话、决定何时听完、作出最小回应。后续才会进入 ASR、LLM、Agent 决策和用户可控记忆。

当前 v1 不接云端 ASR、LLM 或 TTS，不保存原始音频，也不做内容理解或情绪诊断。

## 已完成

- 原网页原型仍保留为参考；主入口已转为原生 macOS AppKit 菜单栏应用。
- 菜单栏可显示：待设置、待命、等待说话、倾听、回应、暂停与错误。
- 支持“暂停监听”“设置”“退出”；支持登录 macOS 后自动启动。
- `AVAudioEngine` 以硬件原生格式采集默认麦克风，再在内存中转换为单声道 16 kHz PCM；仅保留 1.5 秒内存环形缓冲，不写入磁盘。
- 已实现固定交互状态机：
  1. `idle`：仅检测唤醒词；
  2. 检测到唤醒词：提示音，进入等待说话；
  3. 6 秒未说话：回到 `idle`；
  4. 检测到说话：进入 `listening`；
  5. 连续静默 1.8 秒或最长 45 秒：本轮结束；
  6. macOS 本地 Tingting 语音说“嗯，我在。”；
  7. 播放时若用户说话，立即停止回复并回到 `idle`。
- 已从 Picovoice 完全迁移：不再需要公司邮箱、账户、AccessKey、`.ppn` 模型或 Keychain。
- 已使用本地 `openWakeWord + Silero VAD`：
  - Swift 应用仍独占麦克风；
  - 音频帧通过本机 stdin 管道交给 Python 检测器；
  - Python 检测器将唤醒分数与 Silero 语音概率通过 stdout 回传；
  - 运行时不进行网络请求或音频上传。
- 本机 Python 虚拟环境已安装到：
  `~/Library/Application Support/TARST/VoiceRuntime/venv`
- 已验证：Swift 编译、状态机检查、以及静音 16 kHz PCM 经本地检测器得到 Silero VAD 概率输出。

### 自定义唤醒词训练

- 已完成 `TARST` 和 `Hey-TARST` 两个开发级自定义唤醒词模型的训练。
- 训练从 Google Colab 迁移到 AutoDL RTX 4090 D 服务器，工作目录为服务器数据盘上的 `TARST` 项目目录。
- 已完成 Piper 语音生成、数据增强、openWakeWord 特征提取和 DNN 训练。
- 已生成并验证两个 ONNX 模型：
  - `TARST.onnx`
  - `Hey-TARST.onnx`
- 两个模型均通过 ONNX checker 和 ONNX Runtime 验证，输入形状为 `[1, 16, 96]`，输出形状为 `[1, 1]`。
- `Hey-TARST` 本次开发级训练指标：Accuracy `92.47%`、Recall `86.05%`、False positives/hour `23.27`。这是合成语音和开发验证集上的基线，不能替代真实麦克风验收。
- `TARST` 本次开发级训练指标约为：Accuracy `89.5%`、Recall `79.2%`、False positives/hour `39.6`，同样只作为开发基线。
- 训练过程中出现的 `onnx_tf` 缺失只影响 TFLite 导出，不影响 ONNX 生成、验证或当前 macOS 运行时。无需因此重训。
- 两个模型已下载到本地，并已通过 TARST 设置面板导入到：
  `~/Library/Application Support/TARST/Models/`

### Wake Word + VAD 开发阶段验收

2026-08-15，用户确认本阶段按**开发阶段验收通过**收口。该结论表示本地入口已经足以支持下一阶段开发，不代表生产级声学或安全验收。

- 两个 ONNX 模型已导入本机并能由 openWakeWord 正常加载。
- 菜单栏应用已经改为原生 AppKit 菜单，避开 macOS 26 上 SwiftUI 菜单动作崩溃。
- 麦克风按硬件原生格式采集，再在内存中转换为单声道 16 kHz，解决 Core Audio 格式不匹配崩溃。
- 已加入本地诊断模式，只保存模型分数、VAD 概率、状态事件和人工标签，不保存 PCM、音频或转录文本。
- 重新核算的历史有效唤醒尝试为 `21/21`；两个短语均能完成真实麦克风唤醒。
- 唤醒后加入静音门控，必须先观察至少 160 ms 稳定静音，才允许 VAD 把后续声音当作正文，避免唤醒词尾音直接启动倾听。
- 修复后验证过一轮完整 VAD 对话，以及一轮唤醒后保持沉默并在约 6 秒正确超时。
- 当前阈值保持不变：wake `0.55`，VAD `0.50`。
- `TARSTCoreCheck`、Python 语法检查、生产构建和 App 签名检查均通过。

以下事项经用户确认暂缓，不阻塞进入下一阶段：

- 30–60 分钟以上的被动误唤醒率测试尚未完成；主动测试中曾人工确认 1 次误唤醒。
- Mac 内置麦克风、AirPods 和更多噪声/距离条件尚未形成完整对照数据。
- 回复期间插话、45 秒最长轮次和更多 VAD 边界条件尚未完成系统性真实麦克风验收。
- 授权 PCM fixture 和检测器异常退出的自动化适配器测试仍待补齐。

## 当前代码位置

| 内容 | 位置 |
| --- | --- |
| 原生应用 UI 与菜单栏 | `macos/TARST/Sources/TARSTApp/TARSTApp.swift` |
| 音频采集、帧转发、状态事件 | `macos/TARST/Sources/TARST/AudioRuntime.swift` |
| 本地 Python 检测器 | `macos/TARST/Runtime/local_voice_detector.py` |
| 状态机规则 | `macos/TARST/Sources/TARST/SessionController.swift` |
| 配置与本机模型路径 | `macos/TARST/Sources/TARST/Configuration.swift` |
| 安装本地运行环境 | `scripts/install-local-voice-runtime.sh` |
| 打包 macOS App | `scripts/build-macos-app.sh` |
| 状态机冒烟检查 | `macos/TARST/Sources/TARSTCoreCheck/main.swift` |

## 当前不能做什么（重要）

应用只有在两个模型都导入后才能识别 “TARST” 或 “Hey TARST”。openWakeWord 不自带这两个短语的模型；本项目已经训练出模型，但尚未把模型打包进 App，而是通过设置面板导入。

启动监听前，必须导入两个自定义 ONNX 模型：

- `TARST.onnx`
- `Hey-TARST.onnx`

它们会被保存到 `~/Library/Application Support/TARST/Models/`，并被 `.gitignore` 排除，绝不提交到仓库。

## 已完成的验收与后续保留项

### 1. 导入模型并做真实麦克风验收（开发阶段已通过）

将本地已经下载的 `TARST.onnx` 和 `Hey-TARST.onnx` 分别导入 TARST 设置面板，确认菜单栏从“待设置”变成已配置状态，然后进行真实麦克风测试。

重点测试：

- `TARST` 与 `Hey TARST` 是否各自能唤醒；
- 普通谈话、播客、音乐和相似短语是否误触发；
- Mac 内置麦克风与 AirPods 的差异；
- 唤醒后等待说话、连续静默结束、最长 45 秒限制和插话打断；
- 记录每次漏唤醒、误唤醒和 VAD 误判案例。

当前模型是开发级基线。如果真实测试误唤醒率不够低，再准备更丰富、明确授权的真实正负样本进行第二轮训练。

**不要**把 openWakeWord 自带的 `hey_jarvis` 等示例模型改名为 TARST 使用；它们只适合验证技术管线，不代表能识别 TARST。

### 2. 做阈值调优与模型迭代（按需恢复）

根据第一轮真实验收记录，使用 AirPods 和 Mac 内置麦克风分别测试：

- `TARST` 与 `Hey TARST` 是否各自能唤醒；
- 普通谈话、播客、音乐是否误触发；
- 唤醒后 6 秒不说话是否回到待命；
- 停顿少于 1.8 秒时是否继续倾听；
- 说完后是否只回复一次；
- 回复期间插话是否立刻打断；
- 暂停或退出后是否释放麦克风。

初始阈值目前在 `local_voice_detector.py`：

- wake threshold：`0.55`
- VAD threshold：`0.50`

不要先凭感觉全局调低阈值；应记录漏唤醒、误唤醒、VAD 误判三类案例后再调。

### 3. 补齐可重复的适配器测试

为 Python 检测器加入录制好的 16 kHz PCM fixture 测试，至少覆盖：

- 两个唤醒词各自触发；
- 普通说话不触发；
- 静音的 VAD 概率低；
- 说话帧的 VAD 概率高；
- 进程退出或返回坏 JSON 时，Swift UI 进入错误状态而不是卡住。

测试音频只能来自有明确授权的录音，并且不要提交私人日常对话。

### 4. 保持训练流程可复现

训练相关文件已提交到 `training/`：

- `TARST.yaml`、`Hey-TARST.yaml`：包含 ACAV 特征数据路径的完整配置；
- `TARST_autodl.yaml`、`Hey-TARST_autodl.yaml`：本次 AutoDL 开发训练使用的轻量配置；
- `TARST_colab_training.ipynb`：Colab 流程；
- `scripts/apply_autodl_compat.sh`：应用 Piper 和 openWakeWord 兼容修复；
- `scripts/run_autodl.sh`：执行生成、增强或训练阶段。

训练数据、音频、特征文件、虚拟环境和模型中间产物均被忽略，没有提交到 GitHub。服务器密码和 SSH 信息也不得写入仓库。

### 5. 下一阶段：流式 ASR + Agent + TTS

本阶段架构设计已开始，完整方案见 `docs/streaming-voice-agent-design.md`。已确定：

- 第一版使用流式 ASR → 流式文本 Agent → 语义分句 → 流式 TTS 的级联管线；
- ASR 临时文本只用于显示，最终文本才允许进入 Agent、工具和记忆；
- 使用 generation ID 同时取消 Agent、TTS 和播放器，实现插话打断；
- 当前 macOS Tingting 声音只作为离线故障回退，默认声音通过中文盲听选择；
- 保留端到端实时语音适配器，后续与级联方案对照，不让供应商拥有 TARST 的状态与记忆。

已加入“设置 → 配置火山引擎语音…”入口，可保存 App ID、Access Token、ASR/TTS Resource ID、TTS Voice Type 和可选 Cluster。凭据以 generic-password 项保存到 macOS Keychain（service：`com.tarst.voice.volcengine`），不会写入仓库或诊断日志。当前仅完成安全配置与本地字段校验，尚未发起 ASR/TTS 网络请求。

此前曾计划优先评估 LiveKit Agents；该计划已被下方 2026-08-16 的“自研 Agent Runtime”决定取代。OpenAI Realtime、Gemini Live、Hume EVI 仍只作为可替换能力供应商或对照实验，不作为 TARST 的状态与记忆所有者。

## 2026-08-16 Agent 方向最终决策

用户决定**自行编写 TARST Agent Runtime**，以理解并掌握 Agent 的核心机制。后续不以 Hermes、OpenClaw、OpenAI Agents SDK、LangChain 或 LangGraph 作为 TARST 的主运行时。

这里的“自行编写”不是重新训练大模型，而是自行实现模型外部的 Agent 系统：

- 流式模型客户端与事件协议；
- conversation/session 管理；
- system prompt 组装；
- tool calling 循环；
- 工具注册、参数校验和执行结果回填；
- 权限策略与高风险操作确认；
- 短期上下文、长期记忆候选、确认写入和删除；
- one-shot / companion 模式；
- 取消、超时、重试、崩溃恢复与诊断。

框架边界说明：OpenAI Agents SDK 与 LangChain 都属于帮助开发者编排模型、工具和会话的框架，但不是模型本身。OpenAI Agents SDK 更贴近 Agent loop、tools、handoffs、guardrails 和 tracing；LangChain/LangGraph 更偏通用模型组件和显式工作流图。TARST 当前选择直接调用 MiniMax API，并只按需引入底层网络、JSON、数据库等普通库，以避免过早依赖大型 Agent 框架。

Hermes 与 OpenClaw 可继续作为设计参考和对照实现，但不进入第一版运行依赖；Pi 是终端编程 Agent，也不作为 TARST 的生活型语音 Runtime。

### MiniMax 模型层

- Agent 模型供应商确定为 MiniMax。
- 默认策略改为优先实测 `MiniMax-M3`：普通短语音轮优先低延迟/非深度思考配置，复杂规划和工具调用可开启深度思考；`MiniMax-M2.7-highspeed` 保留为首句延迟异常或“极速回应”时的回退。
- MiniMax 当前 OpenAI-compatible 文档明确列出 M2 系列，未明确列出 M3；必须为 M3 与 OpenAI-compatible 模型分别实现 `LLMProvider` 适配器，并先完成 M3 协议 smoke test，不能假设 M3 一定可由 `openai` SDK 直接调用。
- TARST Agent 必须通过自有 `LLMProvider` 接口调用模型，不能让业务状态机直接依赖 MiniMax SDK 的具体事件类型。
- 需要新增 MiniMax API Key 的 Keychain 配置入口；密钥不得写入源码、仓库或诊断日志。

### 独立声学/情绪通道已纳入架构

- 情绪与表达分析不属于 ASR。它与 ASR 并行处理同一段唤醒后、VAD 确认的当前用户轮 PCM，最终以带置信度的 `AcousticObservation` 与 ASR final 融合后才提供给 Agent。
- EchoMind 是用于评测共情语音语言模型的 benchmark，不是可直接部署的情绪识别模型；后续选择具体声学模型前，必须以中文、真实麦克风、文本与语气冲突样本进行独立评测。
- 单轮声学观察仅用于更克制的当前回复，不能自动写入记忆、触发工具或推断心理健康状态。低置信度、噪声、片段过短或疑似多人声必须输出“不判断”。
- 原始音频不落盘；情绪趋势、表达模式记录和表达 coaching 均默认关闭，只有用户显式开启后才保存可查看、可删除的聚合摘要。

### 火山引擎 ASR / TTS 已确认

本机已有火山凭据位于 `/Users/lelew/Desktop/剪辑/koubo-edit/.env`。仅复用了以下变量，未读取或使用最后一行 `HOTWORDS`：

- `VOLCENGINE_APP_ID`
- `VOLCENGINE_ACCESS_TOKEN`
- `VOLCENGINE_ASR_RESOURCE_ID`

不要复制或记录这些变量的实际值到仓库、日志或交接文档。

已完成以下真实鉴权与链路验证：

- 流式 ASR WebSocket：`wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`
- ASR Resource ID：`volc.bigasr.sauc.duration`
- ASR WebSocket 握手返回 `HTTP 101 Switching Protocols`；尚未发送真实语音完成流式转录验收。
- 流式 TTS WebSocket：`wss://openspeech.bytedance.com/api/v3/tts/bidirection`
- TTS Resource ID：`seed-tts-2.0`
- Voice Type：`zh_female_vv_uranus_bigtts`
- 使用短句“你好，我是 TARST。”完成 V3 双向流式 TTS；收到 5 个 PCM 音频块，共 `85790` bytes，约 `1.787s`，证明鉴权、资源和音色均可用。

上述正式选择已保存到 macOS Keychain：

- service：`com.tarst.voice.volcengine`
- account：`default`

Keychain 内容包括 App ID、Access Token、ASR/TTS Resource ID 和 Voice Type；不应在调试输出中打印整个凭据对象。

### macOS 配置入口

最新 App 已加入：`TARST 菜单栏 → 设置 → 配置火山引擎语音…`。

设置窗口支持 App ID、Access Token、ASR/TTS Resource ID、Voice Type 和可选 Cluster，并分别显示 ASR/TTS 是否配置。凭据由 `VolcengineCredentialsStore` 保存到 Keychain。相关文件：

- `macos/TARST/Sources/TARST/VolcengineCredentials.swift`
- `macos/TARST/Sources/TARSTApp/TARSTApp.swift`

Debug build、`TARSTCoreCheck`、Production build 和 codesign 验证均已通过。当前生成物为 `dist/TARST.app`。

### 重要的当前限制

火山 ASR/TTS 目前只是完成独立探测和凭据配置，**尚未接入 TARST 的真实运行状态机**。当前 App 在 VAD 结束后仍由 `AVSpeechSynthesizer` 的 Tingting 播放“嗯，我在。”，不能误认为完整语音 Agent 已经连通。

### 下一窗口从这里开始

按以下顺序继续，先实现最小闭环，不先做长期记忆或多 Agent：

1. 已完成：本机 Node.js Agent Runtime 骨架、`AgentSession`、JSON Lines 协议、假流式 Provider 与 generation 取消测试已位于 `agent/`；它不接收音频、不需要 API Key。
2. 已完成：MiniMax API Key 已有独立 Keychain 配置入口（service：`com.tarst.agent.minimax`）；中国大陆服务使用 `api.minimaxi.com`。`MiniMax-M2.7-highspeed` OpenAI-compatible Provider 与 `MiniMax-M3` 原生 SSE Provider 均已完成无网络单测；M3 真实流式 smoke test 已返回 HTTP 200、首个可见文本约 2.9 秒、2 个文本 delta（不记录密钥或回复正文）。
3. 已完成：Swift `AgentRuntimeClient` 会启动本机 Node 子进程，以 JSON Lines 接收 `runtime.ready`、配置完成、文本 delta、完成/取消/失败事件；它从 Keychain 读取 MiniMax Key 后，仅通过子进程 stdin 发送一次 `runtime.configure`，绝不放入命令行、环境变量、日志或磁盘。Node Runtime 已改为先配置 `MiniMax-M3` 原生 SSE Provider，而非 Fake Provider。真实 bridge smoke test 已通过（M3 配置完成、收到 2 个文本 delta；不记录密钥或回复正文）。打包脚本会将 `agent/src` 加入 App Resources。当前 Node 使用开发机已安装的 Node.js，尚非自包含发布方案。
4. 已完成待真实麦克风验收：`VolcengineASRClient` 使用 `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel` 的二进制 WebSocket 协议，送入 16 kHz / 16-bit / mono PCM。Silero VAD 仍是唯一的开始和结束裁决；开始时预送小段纯内存 PCM 尾部，结束时发送 ASR final frame。`partial` 仅显示在菜单中，`final` 仅保留为当前菜单的临时文本，二者均不写入诊断或文件。当前尚未将 final 自动提交 Agent，因此固定 Tingting 回复已移除。ASR 凭据改为用户点击“开始监听”时预取一次并仅缓存于该次监听会话内，绝不在唤醒或实时音频路径读取 Keychain，因此不会在说话时触发本机密码弹窗。Release build 已通过；仍需用真实麦克风说一轮话，确认服务端响应帧未启用额外压缩以及实际转录结果。
5. 加入独立声学通道适配器与 `AcousticObservation`，但首版只在内存中输出观察，不记录趋势或启用 coaching。
6. 将已有 Agent Runtime Client 接到已验收的 ASR final，形成最小 Agent loop：system prompt + conversation history + MiniMax streaming；第一版不开放真实副作用工具。
7. 实现语义分句器，将 MiniMax 文本流整理为自然中文短句。
8. 实现火山 V3 双向流式 TTS 客户端和 PCM 播放器，替换正常路径上的 Tingting。
9. 用 generation ID 串联 Agent、TTS 和播放器取消，完成用户插话打断。
10. 验收首个闭环：`Wake → VAD → ASR final + AcousticObservation → MiniMax → TTS PCM → 扬声器`。
11. 闭环稳定后，再设计工具系统、权限确认、用户确认的长期记忆、表达 coaching、Skills、Cron 和主动性。

自研 Agent 的第一版原则：单 Agent、少工具、显式状态、所有副作用需确认、记忆默认不写入、原始音频不落盘、每层都可替换和单独测试。

## 本机操作命令

在仓库根目录执行：

```bash
# 若以后需要重建本地 Python 运行环境
scripts/install-local-voice-runtime.sh

# 编译与状态机检查
swift build --package-path macos/TARST --product TARST
swift run --package-path macos/TARST TARSTCoreCheck

# 构建可打开的菜单栏应用
scripts/build-macos-app.sh
open dist/TARST.app
```

构建 App 不可再使用 ad-hoc 签名：它会随着每次重新构建改变 Keychain 视角下的 App 身份，并反复触发密码授权。本机已创建固定的 `TARST Local Development` 签名身份，`scripts/build-macos-app.sh` 默认使用它（可用 `TARST_CODESIGN_IDENTITY` 覆盖）。首次用此稳定身份读取之前由 ad-hoc 版本保存的既有 Keychain 项时，用户需要在 macOS 提示中选择“始终允许”并完成一次授权；之后同一身份的所有构建不应重复询问。该自签名仅用于本机开发，不用于对外分发或公证。

## Git 状态

最新功能提交：`891ce6e feat: switch to local openwakeword and silero vad`。

训练流程提交：`c0c7f70 Add reproducible wake-word training workflow`，已推送到 `origin/agent/macos-wake-vad-demo`。

本次交接文档修改应作为下一次提交推送。继续开发时请从 `agent/macos-wake-vad-demo` 建立新分支，例如：

```bash
git switch agent/macos-wake-vad-demo
git switch -c agent/custom-wakeword-training
```

---

## 2026-08-18 最新交接：已接入语音 Agent，但当前对话流仍有阻塞性 Bug

> **本节优先级高于上文的“尚未接入”历史描述。** 当前工作区是未提交的持续开发状态，不能只依据旧的 v1 说明判断功能是否存在。

### 当前已经接入并构建的链路

正常路径现在是：

`Wake Word → Silero VAD → 火山 ASR final → MiniMax-M3 流 → 中文分句 → 火山 V3 双向 TTS → 24 kHz PCM → AVAudioEngine 扬声器`

- `AudioRuntime.swift` 已在 ASR final 后自动提交给 `AgentRuntimeClient`；不再使用 Tingting 固定回复。
- `agent/` 是本机 Node JSON-Lines Agent Runtime；MiniMax API Key 只从 Keychain 读出后经 stdin 一次性送给子进程。
- 火山 V3 TTS 客户端：`macos/TARST/Sources/TARST/VolcengineTTSClient.swift`。
  - 端点：`wss://openspeech.bytedance.com/api/v3/tts/bidirection`
  - V3 事件序列已实现：连接 1/50、会话 100/150、任务 200、结束会话 102、PCM 352、完成 359/152。
  - 首包偶发 `Socket is not connected` 已做最多 5 次、每次 120 ms 的短重试。
  - 已将 V3 编码/解析提取为 `VolcengineTTSWire`；`TARSTCoreCheck` 覆盖无 payload 完成帧、PCM 帧、连接帧、会话帧。不要删除“完成帧先于 payload 解析”的逻辑：服务端 completion 帧可以没有 payload。
- PCM 播放器：`macos/TARST/Sources/TARST/PCMPlayer.swift`。
  - 播放 24 kHz 单声道 Int16 PCM。
  - 通过 `.dataPlayedBack` 追踪真正已播放的 buffer；**收到 TTS 网络结束帧不等于已经播放结束**。
  - 使用 generation 防止取消前的 completion callback 影响新一轮播放。
- 中文分句器：`ChineseSentenceChunker.swift`，按 `。！？；` 立即出句，长段落在 `，、 ` 附近切分，Agent completion 时 flush 尾段。
- 取消与插话：
  - `AudioRuntime.cancelAgentGeneration()` 会取消 Agent、当前 TTS、未播 TTS 队列和 PCM 播放。
  - `SessionController` 已修复：回复中检测到人声后应进入下一轮 `.listening`，而不是 `.idle`；随后静音会正确触发 ASR `finish`。
  - ASR/TTS 回调均按客户端实例身份校验；被取消/替换 socket 的迟到回调必须丢弃，不能把旧错误当作当前回合错误。
- 诊断只记录状态事件，不含音频、转录文本、回复或密钥。新增 TTS 事件：`tts_started`、`tts_stream_finished`、`tts_playback_drained`、`tts_cancelled`。

### 已完成的自动验证

最近一次构建使用：

```bash
npm test
swift run --package-path macos/TARST TARSTCoreCheck
scripts/build-macos-app.sh
codesign --verify --deep --strict dist/TARST.app
```

- Node 测试当前为 **16/16 通过**。
- `TARSTCoreCheck` 通过，包含状态机插话回合、分句和 V3 frame 解析断言。
- Release App 已由固定 `TARST Local Development` 身份签名，路径为 `dist/TARST.app`。
- 历史真实火山 V3 TTS 冒烟曾收到 PCM（例如 3–5 块、约 55–86 KB），说明凭据、资源 ID 与音色可用。

### 当前未解决的阻塞 Bug（用户最新反馈）

用户在最新版本中仍然遇到：**TARST 无法完成一轮对话；菜单中能看到“准备传回的话”持续改写/变化。** 用户明确反馈“仍然有这个问题，没修复好”。不要把前述自动测试当成此问题已解决。

最可能的故障面及已做尝试：

1. **MiniMax M3 流事件到底是增量还是累计快照。**
   - 原实现为：`choice.delta.content ?? choice.message.content`，直接作为 `agent.text_delta` 发出。
   - 若 `message.content` 是累计全文，会造成 UI 不断追加、分句器重复入队、TTS 一直延伸。
   - 已在 `agent/src/providers/minimax-m3-provider.mjs` 增加 `VisibleTextAccumulator`：若新文本以已发文本为前缀，则只发新增后缀；重复/缩短快照不发。
   - 新增 Node 回归测试：累计 `message.content`、重复累计 `delta.content`，均通过。
   - **但用户已在此改动后的版本复测，仍报告问题。** 因此不能继续假设只是简单累计快照；需要获得真实 M3 SSE 的安全结构化元数据来确认。

2. **真实流可能是“修订式”文本，而不是严格前缀增长。**
   - 现有 accumulator 对非前缀变化仍把它视为真 delta 追加；若 M3/网关频繁重写最后片段，仍可能产生重复。
   - 下一步应在 provider 内为每个 SSE frame 记录**不含文本内容**的诊断元数据，例如：`source=delta/message`、候选长度、已发长度、与已发文本的关系（equal/prefix/shorter/divergent）、`finish_reason`、choice index、事件计数、时间戳。
   - 绝不把 SSE 正文、用户文本、模型文本、API key 写入诊断。可记录长度和关系分类。
   - 基于一轮真实复现，判断是否需要：
     - 正确读取 M3 原生 frame 的另一字段；
     - 对修订流使用 longest-common-prefix 的“显示快照”协议，同时仅在句子稳定后送 TTS；或
     - 在 Provider 层仅接受严格 append-only visible token，忽略修订快照直至 `finish_reason`。

3. **Agent runtime 的最终完成事件未必到达。**
   - `agent/src/agent-runtime.mjs` 只有 `provider.stream()` 自然结束后才发 `agent.text_completed` 和 `agent.completed`。
   - 若 SSE 没有正确识别 `[DONE]`、尾帧没有空行、或流保持打开，TTS/界面不会收束。
   - 检查 `parseSSE()`：当前只用空行分帧，结尾再解析 `eventData(pending)`；要用真实诊断确认是否收到 `[DONE]`、是否有 `finish_reason`、是否出现悬挂连接。
   - 应加入 Provider 的**每轮无内容/总时长超时**，在安全结束或失败时一定发出可见 `agent.failed`，避免 UI 永远“回应中”。超时数值需保守（例如首 token 15 s、流空闲 10–15 s、总轮次 90 s），但先记录原因。

4. **需要将“UI 快照”和“可朗读增量”明确分离。**
   - 当前 `agent.text_delta` 同时驱动 `agentPreview += text` 和 `ChineseSentenceChunker.append(text)`。
   - 对可修订模型流，这两个职责不应共用同一事件：UI 可以用完整可替换 snapshot；TTS 只能使用确认过、不可撤回的稳定句子/增量。
   - 新窗口应优先决定/实现显式协议（建议 `agent.text_snapshot` 与 `agent.stable_text_delta` 两种事件），而不是继续在 UI 层用字符串猜测。

### 其它已知问题与注意点

- 终端运行的 `VolcengineTTSSmokeTest` 有时会阻塞在 macOS Keychain 的 `SecItemCopyMatching`，不是火山 socket 故障。测试已被改为后台读取并有 30 秒超时；在非交互 Keychain ACL 不允许时会输出超时。
- 在 `TARST.app --tts-smoke` 中也观察到非交互 Keychain 获取超时；正常用户点击“开始监听”使用可交互路径。不要因此改成把凭据写入文件或环境变量。
- `AudioRuntime` 的普通 `start()` 会预取语音与 MiniMax 凭据，避免实时音频路径触发 Keychain 提示。
- 当前真实声学插话仍未完成最终验收；先解决模型流收束问题，再继续评估打断的体感。
- 工作树包含大量未提交改动和未跟踪文件，均为本轮/用户现有开发状态；不要 `git reset --hard`、`git checkout --` 或清理未跟踪文件。

### 新窗口建议的第一步

1. 运行当前 App、开启“诊断”、复现一次持续改写问题。
2. 增加上述**无文本** M3 frame/生命周期诊断，先拿到真实事件关系与结束原因。
3. 依据结果修正 Provider/协议；不要先改 VAD、TTS 声音或 Keychain。
4. 修正后重新运行 `npm test`、`TARSTCoreCheck`、构建+codesign，并由用户进行一次正常轮次与一次中途打断验收。

## 2026-08-18 续建：MiniMax 安全流诊断与超时保护已完成

- `MiniMaxM3Provider` 现在为每个 SSE 帧产生不含正文的结构化元数据：来源、候选长度、累计发出长度、关系分类、`finish_reason`、choice index、事件序号与生命周期。
- 元数据经 `agent.stream_diagnostic` 透传到 Swift，只在用户开启诊断时写入 `agent_stream_frame`；不包含用户文本、模型文本或 API key。
- 新增三层必收束保护：首数据块 15 秒、流空闲 15 秒、整轮 90 秒。超时会产生安全的 `agent.failed`，不再无限保持“回应中”。用户取消会立即解除等待。
- `scripts/summarize-diagnostics.py` 已能汇总 MiniMax 生命周期、文本关系和结束原因。
- 当前自动验证：Node **19/19** 通过，`TARSTCoreCheck` 通过。
- 下一步不应继续猜测修订语义：构建 App，开启诊断复现一轮，然后依据 `divergent/prefix/equal/shorter` 与 `done/stream_closed` 的真实分布，决定是否拆分 `agent.text_snapshot` 和 `agent.stable_text_delta`。

## 2026-08-18 真实诊断结论与回声自打断修复

- `diagnostics-20260818-213102.jsonl` 证明 MiniMax 原生 M3 的 `delta.content` 是普通连续片段：例如 `5 + 21 + 39 + 1 = 66`，尾部 `message.content` 也是完整 66 字。Provider 输出和最终文本长度一致，不是修订式快照。
- 真正导致回答说不完整的是扬声器回声：三轮回复后均出现 `speech_during_response → tts_cancelled`，随后 TARST 把自己的声音送入 ASR 并开始下一轮，因此界面看起来像回答被不断修改。
- 曾尝试让 `PCMPlayer` 与麦克风共用 `AVAudioEngine` 并启用 VoiceProcessingIO，但在用户的 ReSpeaker Lite 上 339 帧的 VAD 最高仅 0.009，输入几乎变成静音，导致两个唤醒词都无法触发。该尝试已完整撤回，麦克风和播放器继续使用独立引擎。
- 只要 TTS 正在合成、排队或 PCM 尚未播放完，VAD 不再触发自动插话；高 VAD 只记录为 `playback_voice_ignored`。这是当前可靠性优先的策略，意味着 TARST 正在出声时暂时不能自然插话，后续应在验证 AEC 稳定后再恢复。
- 火山与 MiniMax 凭据现在缓存于当前 App 进程内。停止/重新开始监听不会再次读 Keychain；只有重启 App，或用户保存/删除配置使缓存失效时才读取。
- 自动验证保持 Node **19/19**、`TARSTCoreCheck` 通过。

### 后续状态机边界修复

- 恢复唤醒后的一轮诊断显示：`turn_ended` 后仅 6 ms 就出现 `speech_during_response`。这是同一用户语句的迟到 VAD 尾帧，并非新插话；它会取消刚开始的回复并打开重复 ASR，最终让 UI 进入感叹号错误状态。
- `SessionController` 的 responding 状态现记录开始时间，并在前 0.8 秒拒绝插话。播放期间 VAD 门控仍然有效。
- `AudioRuntime` 现在为错误记录不含正文的 `runtime_error`，仅保存 NSError domain/code，便于定位感叹号来源。

## 2026-08-18 插话与 Keychain 最终修复路径

- 播放期间全部禁止 VAD 虽能阻止回声，却也让用户无法插话，已撤销这种全禁用策略。
- 官方资料确认 ReSpeaker Lite 的 XU316 带板载 AEC，但需要 far-end 播放参考。当前系统默认输出是 Mac mini 扬声器，而 ReSpeaker Lite 只作为默认输入，因此此前板载 AEC 没有参考信号。
- `PCMPlayer` 现在继续向默认扬声器播放，同时把相同 PCM 复制到 ReSpeaker Lite 的 USB 输出作为纯 far-end 参考。自动声学测试显示播放回声高 VAD 从几乎全程降至 `2/26` 帧（7.7%）。
- `SessionController` 新增 0.24 秒连续高 VAD 确认，过滤剩余的短回声尖峰；确认后仍使用 0.5 秒 pre-roll 开启 ASR，所以不会丢失真人插话开头。
- 签名 App 新增 `--preflight-smoke`：以禁止交互方式读取两组凭据并确认 ReSpeaker 回声输出。连续运行两次均通过，证明 v2 Keychain 条目的 ACL 已绑定固定签名且不需要密码。
- 新增 `--aec-smoke`，通过真实火山 TTS、默认扬声器、ReSpeaker 输入及本地 VAD 自动验证回声不会触发插话。
- ReSpeaker Lite 以双通道输入暴露给 macOS；USB 固件的实际通道布局需以本机声学 smoke 结果为准，不能直接套用 I2S 文档中的 channel 0 定义。采集转换已停止默认双通道下混。
- 两个单通道的声学 smoke 均未稳定通过，因此没有依赖固定通道。最终方案增加播放期 ASR 探针：VAD 先启动候选识别，候选只以长度和 echo/user/undetermined 分类写入诊断；与当前回复高度相似的文本视为回声，明确不同或含“停一下/等等”等指令的文本才确认插话、取消 TTS，并用 0.5 秒 pre-roll 开始正式 ASR。
- 后续发现 v2 仍属于 legacy login keychain：即使 ACL 显示固定签名 `OK` 且设置禁止交互，`SecItemCopyMatching` 仍可阻塞在 securityd 解密并弹出登录密码。
- 正式 Apple Developer 签名优先使用 v3 Data Protection Keychain。当前机器只有自签名证书，没有 TeamIdentifier；Data Protection Keychain 返回 missing-entitlement，强行加入伪 entitlement 会被 macOS 直接以 137 拒绝，相关实验已撤回。
- 本地自签名构建改用 `LocalCredentialVault`：AES-GCM 加密，密钥材料绑定设备 UUID、UID 和 service；目录权限 0700、文件权限 0600。源码、日志、命令行和环境变量都不含凭据。新用户首次配置直接写该保险库，之后不访问 login keychain；现有 v1/v2 用户只在首次迁移读取时可能需要最后一次授权。
- `--keychain-storage-smoke` 使用临时假数据验证本地加密保险库的 add/read/delete。签名 App 连续运行两次均通过且无系统授权。

## 2026-08-18 连续插话、连续会话与权限回归完成

- 用户最新诊断 `diagnostics-20260818-222819.jsonl` 中，首次播放期 ASR 探针正确识别一次真人插话，但后续回答期间产生 307 次 `echo` 判定。原因是火山 ASR partial 为累计文本；当真人新话接在长段扬声器回声之后，旧分类器按整段 bigram 比例计算，回声前缀会淹没真人后缀。
- 新增有状态 `InterruptionProbeTracker`：先剥离能由当前回答解释的最长前缀，再对新后缀收集渐进证据；“停一下/等等/好了/可以了”等明确指令立即生效，普通识别差异需连续增长或足够长才确认，减少回声识别误差造成的误停。
- 修复取消竞态：`agent.cancelled` 现在按 `generationID` 处理。旧回答的迟到取消回执不再清空新 generation、触发 `agentCompleted` 或把正在监听的新一轮改回等待态。
- 回答播放完成后不再直接回到 `idle`。一次 “Tars / Hey Tars” 会打开 companion session；每次回答结束后进入 30 秒 follow-up 窗口，用户可直接继续说话，每轮回答后刷新窗口，静默超时才恢复唤醒词待命。
- 本机迁移后的两份凭据保险库均存在且权限为 0600。当前 Release 签名 App 的 `--keychain-storage-smoke` 连续两次通过，`--preflight-smoke` 连续两次通过，均无系统密码提示；`--aec-smoke` 也通过，播放 VAD ratio 为 0.877，但回声未触发错误插话。
- 最终自动验证：Node 19/19、`TARSTCoreCheck`、Release 构建、严格 codesign、`git diff --check` 全部通过。

## 2026-08-18 Agent 启动竞态修复

- 用户日志 `diagnostics-20260818-224012.jsonl` 显示唤醒、VAD、ASR 均正常：`asr_final` 出现在 11.632 秒，但之后没有 `agent_started`、模型流或 TTS 事件。
- 根因是 `AudioRuntime.startAgent()` 启动本地 Node 子进程后才登记 client，且 `consumeAgent()` 在音频引擎尚未把 `isRunning` 置为 true 时会丢弃 `runtime.configured`。本机加密凭据让启动更快后，这个时序窗口更容易命中；ASR final 因而只进入 pending 队列，永远不会提交模型。
- 现在先清空 readiness、登记 client identity，再启动子进程；`runtime.configured` 允许在麦克风初始化期间生效，其他生成事件仍要求运行中。所有回调还会核对 client identity，停止或替换后的旧子进程不能污染状态。
- 新增无文本诊断事件 `agent_configured`，以及签名 App 参数 `--runtime-startup-smoke`，覆盖真实凭据、Node bridge、本地检测器、麦克风启动与提前配置回执。修复后的 Release smoke 已通过；真实 MiniMax bridge 也通过并在约 1.3 秒收到文本。

## 2026-08-18 多轮插话后的 ASR socket 57 修复

- 用户诊断 `diagnostics-20260818-224523.jsonl` 中，前三次 `asr_final → agent_started → agent_completed` 正常；最后一次插话在 46.668 秒确认、49.056 秒结束说话，随后没有 ASR final，而是 `NSPOSIXErrorDomain/57` 并关闭整个监听。
- 根因是旧 `VolcengineASRClient` 在 `URLSessionWebSocketTask.resume()` 后立即并发发送配置、pre-roll、实时 PCM 和 finish；没有等待 `didOpenWithProtocol`，也没有串行发送队列。连续插话快速关闭旧 probe 并建立正式 ASR 时，finish 偶发落到尚未连接的 socket。
- ASR client 现使用独立串行状态队列和 `URLSessionWebSocketDelegate`：open 前缓存所有包；open 后严格按配置、PCM、finish 顺序逐包发送；final/failure 只发一次；停止时清理 session、task 和待发数据。
- 当前轮 ASR 的临时网络错误不再作为全局 fatal error 停止 TARST，而是记录 `asr_turn_failed`、回到 30 秒 follow-up，并在界面提示“刚才连接中断，请再说一次”。
- 新增 `VolcengineASRRoundTripSmokeTest`：真实 TTS 生成 PCM、24 kHz 下采样至 16 kHz，随后故意在 ASR socket 刚创建时立即排入全部音频和 finish。测试通过，收到 54 个 partial 和 29 字 final。
- 完整回归通过：Node 19/19、Swift core、Release build/codesign、两次 preflight、runtime startup smoke、AEC smoke；AEC 播放 VAD ratio 0.871 且未误触发插话。

## 2026-08-18 第二轮回答被截断：整段会话结论

- 用户诊断 `diagnostics-20260818-225341.jsonl` 中第一轮回答完整 drain；第二轮模型 60 字完整结束、4 段 TTS 也全部完成流传输，但 PCM 尚未 drain 时，probe 的累计候选从 41 字 `echo` 变成 43 字 `user`，随即触发 `speech_during_response → tts_cancelled`。因此第二轮不是模型少答或 TTS 少合成，而是回声探针误取消了仍在播放的尾部。
- 原 tracker 有两个过于激进的入口：对整个累计候选先搜索“好了/可以了”等停止短语；以及单次无法锚定的长识别差异达到 8 字便立即确认真人。两者现在都收紧：先排除可由当前回答解释的内容；长候选中的停止短语只有位于明确的新后缀时才立即生效；普通差异必须在至少两个递进 partial 中持续出现。
- 第三轮在 60.708 秒完整 drain 后仅 71 ms 又出现 `speech_started`，证明 companion follow-up 会把房间里的播放尾音当成新一轮。`awaitingSpeech` 现有 350 ms 的 post-playback cooldown；之后立即接受 VAD。ASR 仍发送最近 500 ms pre-roll，所以用户紧接回答说话时，冷却期内的开头不会丢失。
- CoreCheck 新增“回答自己包含停止短语仍为 echo”“单次较长 ASR 修订不能取消”“drain 后 350 ms 内高 VAD 不能开启幽灵轮次”断言。
- 回归再次通过：真实 TTS→ASR round trip（54 partials、25 字 final）、Node 19/19、Swift core、Release build/codesign、两次 preflight、runtime startup smoke、AEC smoke；AEC ratio 0.826，未误插话。

## 2026-08-18 实时 Voice Agent 延迟调研与 P0 优化

- 新增 `docs/voice-agent-latency-research.md`，基于 OpenAI Realtime、Gemini Live、LiveKit、Deepgram、Pipecat 和 ElevenLabs 官方资料比较长连接、动态/语义 endpointing、投机 LLM/TTS、短语级流式 TTS、自适应打断、假打断恢复、播放位置同步和逐阶段 metrics。
- 最近三次有效本机诊断的旧基线：ASR finish→final 约 83–211 ms；Agent start→首文本约 0.7–2.6 s；Agent start→首个 TTS request 约 1.0–2.6 s。旧日志没有独立 VAD tail 和 TTS first audio。
- `AudioRuntime` 新增不含正文的 `vad_tail_ms`、`asr_started`、`asr_final.finalize_ms`、`agent_first_text.latency_ms`、`tts_first_audio.latency_ms` 和 `playback_started`。`scripts/summarize-diagnostics.py` 输出 median/p95 以及 turn end→开始播放。
- 第一轮低风险优化把固定 VAD turn silence 从 1.8 s 降到 1.2 s，理论上每轮直接减少约 600 ms；post-playback 350 ms cooldown 和 500 ms pre-roll 保持不变。
- 初次 AEC 回归暴露纯扬声器回声的 ASR 字符替换会在多个 progressive partial 后被误判真人。分类器现在除 bigram 外增加有序字符 LCS，相似阈值为 bigram 0.45 或 LCS/candidate 0.72；明确用户差异仍需递进证据。新增字符替换回声断言。
- 最终 AEC smoke 连续 3 次通过，播放 VAD ratio 分别约 0.856/0.886/0.836，均未误打断。延迟目标仍为 active；下一优先级是会话级持久 TTS WebSocket、短语级更早 flush、语义 endpointing/投机 LLM，以及可暂停恢复的快速打断。

## 2026-08-18 Voice Agent P1：长连接、模型路由与动态收尾

- 火山 V3 TTS 已改为会话级持久 WebSocket：App 启动时预热连接，每个短语只新建 TTS session，不再重复 TCP/TLS/WebSocket 握手；当前短语失败会重连并最多重试一次。真实连续两轮 smoke 的首音频为 510 ms（首次建连）和 262 ms（连接复用），复用节省约 248 ms。
- 中文分句器不再等到 28 字才处理逗号；稳定文本达到 12 字后会在最早的自然逗号、冒号或空格处提交 TTS，同时仍禁止词中硬切。
- MiniMax 同提示词 A/B（各 3 次）：M3 首文本中位数约 1712 ms，M2.7-highspeed 约 924 ms，后者快约 46%。语音默认切至 `minimax_m27_highspeed`，M3 provider 保留给后续复杂任务路由。
- endpointing 从单一 1.2 秒静默改为两档：稳定 ASR partial 以完整句末标点结束时使用 650 ms，否则保持 1.2 秒，诊断以 `endpoint_mode=punctuation/silence` 区分。相比旧 1.8 秒固定尾静默，普通路径理论减少 600 ms，明确标点路径理论减少 1150 ms。
- 播放期 ASR probe 会在累计纯回声达到 24 字且持续 2.5 秒后轮换，保留 500 ms pre-roll，避免很长的回声前缀掩盖后来用户的真实后缀。
- 曾加入“播放期再次检测到 TARST 立即打断”的快路径，但真实 AEC smoke 证明回答自身包含 TARST 时会自打断，已撤回。无精确 echo anchor 的普通差异现在至少需要 12 字和 3 次递进证据；有 anchor 的用户后缀仍为 2 次，明确“停一下/等等”等短指令仍立即生效。
- 最终自动回归：Node 20/20、`TARSTCoreCheck`、真实持久 TTS、真实 TTS→ASR round trip、Release build、严格 codesign、`git diff --check` 均通过；固定签名 App 两次 preflight 和 runtime startup smoke 通过。收紧插话后 AEC smoke 连续 5 次通过，播放 VAD ratio 约 0.908/0.920/0.885/0.881/0.833，均未误取消回答。
- 仍需用用户正常对话日志取得新版端到端 `turn_end→playback_started` p50/p95。不要仅凭理论节省宣称已达到最终 ≤1.5 秒目标；后续重点是语义 turn detector、投机 LLM，以及可暂停/恢复而非直接取消的打断。

## 2026-08-19 可重复端到端基线与插话快路径

- 新增 `EndToEndLatencySmokeTest` 和 `scripts/run-latency-benchmark.py`。测试用真实 TTS 生成用户问题、按 80 ms 帧实时送入真实 ASR，再经过真实 MiniMax、短语切分和持久 TTS；五轮自动输出 median/p95。`scripts/summarize-diagnostics.py` 也支持目录、多个文件和 `--last N`，且按文件隔离 turn 配对，避免不同会话 elapsed time 错配。
- 预连接 MiniMax API host 后，最新五轮：VAD tail 680/682 ms、ASR final 101/125 ms、Agent 首字 817/1701 ms、TTS 首音频 286/314 ms、用户说完→首音频 1876/2755 ms（median/p95）。p50 达到第一阶段 ≤2.5 秒目标，p95 仍由模型首 token 长尾主导。
- 官方当前 highspeed 模型同为约 100 tps。相同短提示各五轮：M2.7-highspeed 首字 median/p95 713/1474 ms，M2.5-highspeed 1467/1654 ms，M2.1-highspeed 1335/1387 ms；继续以 M2.7-highspeed 为语音默认。
- 新增 `speech_during_response.confirmation_ms`。曾测试 TARST/Hey Tars 本地快路径：完整声学计时仅 3/5 命中、约 2.0–2.9 秒，且有一轮在测试语音注入前被普通回答误触发；因此已完整撤回，不能把分类器命中后的 0 ms 当作用户体感。
- 曾尝试播放首音频时预热并持续发送 ASR probe，但五轮 AEC 中出现一次误打断，已撤回。普通无 echo anchor 的差异改为至少 18 字、4 次递进证据；有明确 echo anchor 仍为 2 次。撤回后高回声 smoke 连续 10/10 通过。
- `docs/latency-baseline-2026-08-19.md` 记录完整方法、数字和限制：合成实时语音基线不等于真人房间 p50/p95；普通自由文本插话仍慢，不能用唤醒词快路径的 0 ms 冒充整体插话指标。
- 本机 USB 描述符 `bcdDevice=0x0207`，已是 ReSpeaker Lite 官方当前 USB v2.0.7 固件。官方仅为 I2S v1.1.0 定义 ASR/唤醒双通道语义，USB 的两个输入通道不能照搬。尝试让 USB far-end reference 比 Mac 扬声器先启动，五轮 VAD ratio 仍约 0.86–0.92，无收益后已撤回。

## 2026-08-19 可恢复的两阶段插话

- `InterruptionProbeTracker` 新增 `suspectedUser`，把“疑似真人”与最终 `user` 分开。有 echo anchor 时一次递进后缀即可进入疑似；无 anchor 必须至少 12 字、两次递进。最终取消仍保持 anchor 两次、无 anchor 至少 18 字四次递进。
- 疑似真人时 `PCMPlayer` 同时暂停主扬声器和 ReSpeaker far-end reference；确认真人后正常取消，重新归类为 echo/final/failure 时恢复，若没有新证据则 800 ms 自动恢复。generation 防止旧 timeout 恢复已经取消或更新的播放。
- 新增诊断：`barge_in_playback_paused.candidate_to_pause_ms`、`barge_in_playback_resumed.paused_ms/reason`、`speech_during_response.pause_to_confirmation_ms`；汇总脚本输出三段插话延迟。
- `--interruption-smoke` 用同一 Mac 扬声器注入中文打断，只能作为最坏声学路径；XU316 会把同方向声音连同回答一起消除。最新 3 轮为 2 次确认、1 次未确认，暂停→确认 303/714 ms。不能拿它替代真人不同位置插话。
- 纯回声回归在新机制下先后 10/10 和最终 5/5 通过，且 `barge_in_playback_paused=0`；`--aec-smoke` 现在会把任何纯回声暂停也视为失败，防止“未取消但回答频繁停顿”的假通过。

## 2026-08-19 M2-her 日常语音路由

- 官方文档没有关闭 M2.7 reasoning 的参数；`reasoning_split` 只分离思考内容。官方将 `M2-her` 定位为多轮文本对话/角色一致性模型，当前中国区 OpenAI-compatible endpoint 与本机凭据可用。
- 相同短提示五轮首字：M2-her median/p95 582/785 ms；M2.7-highspeed 713/1474 ms；M2.5-highspeed 1467/1654 ms；M2.1-highspeed 1335/1387 ms。
- 完整 ASR→模型→短语→持久 TTS 五轮：M2-her 的首字 median/p95 654/811 ms，首个可朗读短语 783/814 ms，用户说完→首音频 1821/1866 ms。M2.7-highspeed 对应端到端为 1876/2755 ms。
- 日常语音默认已切为 `minimax_m2_her`；M2.7-highspeed、M3 provider 均保留，后续复杂任务路由使用。基准工具支持 `--provider` 做持续 A/B。
