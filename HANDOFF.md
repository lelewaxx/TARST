# TARST 开发交接：本地 Wake Word + VAD 阶段

更新时间：2026-08-06  
当前分支：`agent/macos-wake-vad-demo`

## 项目方向

TARST 是一个常驻 macOS 的个人 Voice Agent，而不是网页聊天工具。它的第一层是**状态层**：本地唤醒、判断用户是否正在说话、决定何时听完、作出最小回应。后续才会进入 ASR、LLM、Agent 决策和用户可控记忆。

当前 v1 不接云端 ASR、LLM 或 TTS，不保存原始音频，也不做内容理解或情绪诊断。

## 已完成

- 原网页原型仍保留为参考；主入口已转为原生 macOS SwiftUI 菜单栏应用。
- 菜单栏可显示：待设置、待命、等待说话、倾听、回应、暂停与错误。
- 支持“暂停监听”“设置”“退出”；支持登录 macOS 后自动启动。
- `AVAudioEngine` 以单声道 16 kHz PCM 采集默认麦克风；仅保留 1.5 秒内存环形缓冲，不写入磁盘。
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

应用**还不能识别 “TARST” 或 “Hey TARST”**。这不是故障：openWakeWord 不自带这两个短语的模型。

启动监听前，必须导入两个自定义 ONNX 模型：

- `TARST.onnx`
- `Hey-TARST.onnx`

它们会被保存到 `~/Library/Application Support/TARST/Models/`，并被 `.gitignore` 排除，绝不提交到仓库。

## 下一步：按此顺序继续

### 1. 制定并产出两个唤醒词 ONNX 模型（当前最高优先级）

目标：获得能在本机 openWakeWord 中运行的 `TARST.onnx` 与 `Hey-TARST.onnx`。

建议先做一个**开发级模型**验证完整闭环，再训练更稳健的版本：

1. 阅读 openWakeWord 的自定义模型训练说明：<https://github.com/dscripka/openWakeWord#training-new-models>。
2. 确认模型训练流程、授权要求，以及生成 ONNX 的具体产物格式。
3. 准备正样本：不同距离、音量、速度、情绪、房间和设备下的英文发音；两句分别收集。
4. 准备负样本：日常对话、播客、影视、音乐、相似发音词与环境噪声。负样本决定误唤醒率。
5. 先训练 `TARST`；用真实日常环境测试后，再决定是否保留更长、更不容易误触发的 `Hey TARST`。
6. 将两个 `.onnx` 分别从设置面板导入，确认菜单栏由“待设置”变成“已准备好”。

**不要**把 openWakeWord 自带的 `hey_jarvis` 等示例模型改名为 TARST 使用；它们只适合验证技术管线，不代表能识别 TARST。

### 2. 做真实麦克风验收与阈值调优

导入模型后，使用 AirPods 和 Mac 内置麦克风分别测试：

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

### 4. 再开始 Agent 层（不要提前混入 v1）

当本地入口稳定后，才设计：

- ASR 转录；
- 一次性指令与“陪伴式倾听”两种会话模式；
- TARST 自己掌握的本地、可审计、可删除记忆；
- Agent 决策：做什么、说什么、何时保持沉默；
- 可替换的云端语音模型适配器。

后续编排层优先评估 LiveKit Agents；OpenAI Realtime、Gemini Live、Hume EVI 应当是可替换的能力供应商或对照实验，而不是 TARST 的状态与记忆所有者。

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

## Git 状态

最新功能提交：`891ce6e feat: switch to local openwakeword and silero vad`。

本次交接文档应作为下一次提交推送。继续开发时请从 `agent/macos-wake-vad-demo` 建立新分支，例如：

```bash
git switch agent/macos-wake-vad-demo
git switch -c agent/custom-wakeword-training
```
