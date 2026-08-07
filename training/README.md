# TARST 自定义唤醒词训练

本目录只保存训练配置和流程说明。训练生成的音频、特征、模型和外部数据都不提交到仓库。

## 推荐环境

openWakeWord 官方自动训练 Notebook 当前主要面向 Linux，因为合成语音步骤依赖 Piper。首次训练建议使用 Google Colab GPU 或 Linux GPU 环境；macOS 负责最终导入和麦克风验收。

官方参考：

- <https://github.com/dscripka/openWakeWord/blob/main/notebooks/automatic_model_training.ipynb>
- <https://github.com/dscripka/openWakeWord/blob/main/examples/custom_model.yml>

## 数据目录

在训练工作目录中准备以下内容：

```text
training-workspace/
├── openwakeword/
├── piper-sample-generator/
├── mit_rirs/
├── background_clips/
├── openwakeword_features_ACAV100M_2000_hrs_16bit.npy
├── validation_set_features.npy
├── TARST.yaml
└── Hey-TARST.yaml
```

`background_clips/` 应包含 16 kHz WAV 格式的普通语音、噪声和音乐。优先使用有明确授权的数据集。不要把私人日常对话放入训练集。

## 训练步骤

先按照官方 Notebook 完成依赖安装、Piper 模型下载、RIR/背景音频和预计算特征下载，然后将本目录的 YAML 文件复制到训练工作目录。

以 `TARST` 为例：

```bash
python openwakeword/openwakeword/train.py \
  --training_config TARST.yaml \
  --generate_clips

python openwakeword/openwakeword/train.py \
  --training_config TARST.yaml \
  --augment_clips

python openwakeword/openwakeword/train.py \
  --training_config TARST.yaml \
  --train_model
```

输出模型位于：

```text
TARST_model/TARST.onnx
```

`Hey-TARST` 使用相同的三步，只需将配置文件替换为 `Hey-TARST.yaml`。

### AutoDL 兼容脚本

AutoDL/Python 3.11 环境中，先对官方源码应用本项目实际使用过的兼容修复：

```bash
bash training/scripts/apply_autodl_compat.sh
```

随后可使用统一脚本执行各阶段：

```bash
bash training/scripts/run_autodl.sh TARST generate
bash training/scripts/run_autodl.sh TARST augment
bash training/scripts/run_autodl.sh TARST train
```

训练 `Hey-TARST` 时，将第一个参数改为 `Hey-TARST`。正式训练建议使用对应的
`*_autodl.yaml`，并准备该配置中指定的验证特征文件。

## 开始前必须试听

自动流程会用 Piper 合成 `TARST`。正式训练前先生成少量样本并试听，确认所有样本都接近我们想要的发音。若 TTS 把短语读错，应先调整拼写或发音变体，不能直接训练错误发音。

## 训练后的验收

不要只看训练指标。将 ONNX 文件复制到 macOS 后，在 Mac 内置麦克风和 AirPods 上分别测试：漏唤醒、普通谈话误唤醒、播客/音乐误唤醒、远距离说话和轻声说话。TARST 当前运行时的初始 wake threshold 是 `0.55`，应根据记录的真实案例调节。
