# TARST macOS Wake Word + VAD Demo

This is a native menu-bar application for the TARST streaming voice loop: local wake word/VAD, Volcengine ASR/TTS, low-latency M2-her voice responses with M2.7-highspeed/M3 retained for complex tasks, repeatable barge-in, and a 30-second follow-up conversation window. Raw audio is not persisted.

## One-time setup

1. Run `../../scripts/install-local-voice-runtime.sh` from this directory. It creates a local Python virtual environment in Application Support and installs `openWakeWord` and `silero-vad`. Neither needs an account, API key, or network access at runtime.
2. Train or obtain the two English custom ONNX wake-word models: `TARST.onnx` and `Hey-TARST.onnx`. openWakeWord does not ship these custom phrases.
3. Verify and build: `swift run TARSTCoreCheck && ../../scripts/build-macos-app.sh`.
4. Open **TARST → Settings** and import the two `.onnx` models.
5. Grant the macOS microphone permission, then click **开始监听**.

The build script emits `dist/TARST.app`; open it once to grant microphone access. The app keeps only a 1.5-second in-memory PCM ring buffer. The virtual environment, worker, and ONNX models all live in `~/Library/Application Support/TARST` and are never committed to Git.

## MiniMax M3 smoke test

After saving a MiniMax API Key in the TARST settings window, run:

```bash
swift run MiniMaxSmokeTest
```

The test reads the Keychain item directly, sends a fixed short prompt to M3, and prints only HTTP status, elapsed time, and response size. It never prints the key or model text.

Credential storage depends on signing identity. Apple Developer-signed builds prefer the Data Protection Keychain. Local self-signed builds use an AES-GCM encrypted vault under TARST's Application Support directory with 0700/0600 permissions, avoiding repeated login-keychain authorization prompts. Credentials are never placed in source, diagnostics, process arguments, or environment variables.

The current TARST build targets the MiniMax mainland China endpoint (`api.minimaxi.com`). A future region setting must switch both the endpoint and the matching API Key together.
