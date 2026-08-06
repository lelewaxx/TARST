# TARST macOS Wake Word + VAD Demo

This is a native menu-bar application for the first TARST audio loop. It uses no ASR, LLM, cloud TTS, or audio persistence.

## One-time setup

1. Create a free Picovoice Console account and generate two **English / macOS** custom keywords: `TARST` and `Hey TARST`.
2. Run `../../scripts/install-picovoice-macos.sh` from this directory. It downloads the official local arm64 runtime libraries into Application Support; they are not committed.
3. Verify and build: `swift run TARSTCoreCheck && ../../scripts/build-macos-app.sh`.
4. Open **TARST → Settings**, paste the Picovoice AccessKey, and import each downloaded `.ppn` model.
5. Grant the macOS microphone permission, then click **开始监听**.

The build script emits `dist/TARST.app`; open it once to grant microphone access. The app keeps only a 1.5-second in-memory PCM ring buffer. `AccessKey` lives in Keychain; keyword models and runtime assets live in `~/Library/Application Support/TARST`.
