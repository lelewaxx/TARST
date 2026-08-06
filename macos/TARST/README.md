# TARST macOS Wake Word + VAD Demo

This is a native menu-bar application for the first TARST audio loop. It uses no ASR, LLM, cloud TTS, or audio persistence.

## One-time setup

1. Run `../../scripts/install-local-voice-runtime.sh` from this directory. It creates a local Python virtual environment in Application Support and installs `openWakeWord` and `silero-vad`. Neither needs an account, API key, or network access at runtime.
2. Train or obtain the two English custom ONNX wake-word models: `TARST.onnx` and `Hey-TARST.onnx`. openWakeWord does not ship these custom phrases.
3. Verify and build: `swift run TARSTCoreCheck && ../../scripts/build-macos-app.sh`.
4. Open **TARST → Settings** and import the two `.onnx` models.
5. Grant the macOS microphone permission, then click **开始监听**.

The build script emits `dist/TARST.app`; open it once to grant microphone access. The app keeps only a 1.5-second in-memory PCM ring buffer. The virtual environment, worker, and ONNX models all live in `~/Library/Application Support/TARST` and are never committed to Git.
