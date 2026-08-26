@preconcurrency import AVFoundation
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import TARSTCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = TARSTCoordinator()
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var listeningMenuItem: NSMenuItem!
    private var tarstModelStatusItem: NSMenuItem!
    private var heyTarstModelStatusItem: NSMenuItem!
    private var volcengineStatusItem: NSMenuItem!
    private var miniMaxStatusItem: NSMenuItem!
    private var autoLaunchMenuItem: NSMenuItem!
    private var diagnosticsToggleMenuItem: NSMenuItem!
    private var tarstAttemptMenuItem: NSMenuItem!
    private var heyTarstAttemptMenuItem: NSMenuItem!
    private var falseWakeMenuItem: NSMenuItem!
    private var volcengineSettingsController: VolcengineSettingsWindowController?
    private var miniMaxSettingsController: MiniMaxSettingsWindowController?
    private var ttsSmokeClient: VolcengineTTSClient?
    private var ttsSmokeBytes = 0
    private var ttsSmokeChunks = 0
    private var ttsSmokeReported = false
    private var acousticSmokeRuntime: AudioRuntime?
    private var acousticSmokeURL: URL?
    private var interruptionSmokeRuntime: AudioRuntime?
    private var interruptionSmokeURL: URL?
    private var startupSmokeRuntime: AudioRuntime?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        configureStatusItem()
        coordinator.onChange = { [weak self] in self?.refreshMenu() }
        coordinator.refreshConfiguration()

        if CommandLine.arguments.contains("--preflight-smoke") {
            runPreflightSmoke()
            return
        }
        if CommandLine.arguments.contains("--keychain-storage-smoke") {
            runKeychainStorageSmoke()
            return
        }
        if CommandLine.arguments.contains("--aec-smoke") {
            runAcousticEchoSmoke()
            return
        }
        if CommandLine.arguments.contains("--interruption-smoke") {
            runInterruptionSmoke()
            return
        }
        if CommandLine.arguments.contains("--runtime-startup-smoke") {
            runRuntimeStartupSmoke()
            return
        }

        // This is deliberately an explicit developer-only launch mode. Running
        // from the signed app gives Keychain the same ACL identity as TARST's
        // normal session, unlike an unsigned `swift run` helper.
        if CommandLine.arguments.contains("--tts-smoke") {
            runTTSSmoke()
            return
        }

        // A locally-built, ad-hoc signed app may be rejected; the setting remains
        // user controllable in the native menu.
        try? SMAppService.mainApp.register()
        refreshMenu()

        // Enables an end-to-end local smoke test without UI automation.
        if CommandLine.arguments.contains("--start-listening"), let action = listeningMenuItem.action {
            NSApplication.shared.sendAction(action, to: listeningMenuItem.target, from: listeningMenuItem)
        }
    }

    private func runPreflightSmoke() {
        DispatchQueue.global().async {
            do {
                guard let voice = try VolcengineCredentialsStore().load(allowInteraction: false), voice.isComplete,
                      let miniMax = try MiniMaxCredentialsStore().load(allowInteraction: false), miniMax.isComplete else {
                    throw NSError(
                        domain: "TARST.Preflight",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "凭据缺失或需要交互授权。"]
                    )
                }
                let player = PCMPlayer()
                guard player.hasHardwareEchoReference else {
                    throw NSError(
                        domain: "TARST.Preflight",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "ReSpeaker Lite 回声参考输出不可用。"]
                    )
                }
                print("TARST preflight smoke test passed")
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            } catch {
                fputs("TARST preflight smoke test failed: \(error.localizedDescription)\n", stderr)
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func runRuntimeStartupSmoke() {
        let runtime = AudioRuntime()
        startupSmokeRuntime = runtime
        runtime.onEvent = { [weak self, weak runtime] event in
            guard let self, let runtime else { return }
            switch event {
            case .agentConfigured:
                print("TARST runtime startup smoke test passed")
                runtime.stop()
                self.startupSmokeRuntime = nil
                NSApplication.shared.terminate(nil)
            case .error(let error):
                fputs("TARST runtime startup smoke test failed: \(error.localizedDescription)\n", stderr)
                runtime.stop()
                self.startupSmokeRuntime = nil
                NSApplication.shared.terminate(nil)
            default:
                break
            }
        }
        do {
            try runtime.start()
        } catch {
            fputs("TARST runtime startup smoke test failed: \(error.localizedDescription)\n", stderr)
            startupSmokeRuntime = nil
            NSApplication.shared.terminate(nil)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak runtime] in
            guard let self, let runtime, self.startupSmokeRuntime === runtime else { return }
            fputs("TARST runtime startup smoke test failed: Agent 配置回执超时。\n", stderr)
            runtime.stop()
            self.startupSmokeRuntime = nil
            NSApplication.shared.terminate(nil)
        }
    }

    private func runKeychainStorageSmoke() {
        DispatchQueue.global().async {
            let service = "com.tarst.storage-smoke.\(UUID().uuidString)"
            struct SmokeValue: Codable, Equatable { let value: String }
            let expected = SmokeValue(value: "not-a-real-credential")
            do {
                try LocalCredentialVault.save(expected, service: service)
                let loaded = try LocalCredentialVault.load(SmokeValue.self, service: service)
                try LocalCredentialVault.delete(service: service)
                guard loaded == expected, !LocalCredentialVault.exists(service: service) else {
                    throw LocalCredentialVaultError.invalidData
                }
            } catch {
                fputs("TARST credential storage smoke test failed: \(error)\n", stderr)
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                return
            }
            print("TARST credential storage smoke test passed")
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    private func runAcousticEchoSmoke() {
        let runtime = AudioRuntime()
        acousticSmokeRuntime = runtime
        do {
            acousticSmokeURL = try runtime.startDiagnostics()
            runtime.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.consumeAcousticSmoke(event) }
            }
            try runtime.start()
            runtime.speakDiagnosticPhrase("这是 TARST 回声消除自动测试。系统正在播放一段完整语音，用来确认麦克风不会把扬声器误认为用户插话。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                self?.finishAcousticSmoke(error: NSError(
                    domain: "TARST.AcousticSmoke",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "回声测试超时。"]
                ))
            }
        } catch {
            finishAcousticSmoke(error: error)
        }
    }

    private func runInterruptionSmoke() {
        let runtime = AudioRuntime()
        interruptionSmokeRuntime = runtime
        do {
            interruptionSmokeURL = try runtime.startDiagnostics()
            runtime.onEvent = { [weak self] event in
                DispatchQueue.main.async { self?.consumeInterruptionSmoke(event) }
            }
            try runtime.start()
            runtime.speakDiagnosticPhrase(
                "现在正在播放一段较长的普通回答，用来验证重叠语音检测是否能够区分扬声器回声和真正的用户插话。"
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                runtime.recordDiagnosticLabel("interruption_injection")
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = [
                    "-v", "Tingting", "-r", "220",
                    "停一下，停一下，我现在想打断你，请先不要继续说了",
                ]
                try? process.run()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finishInterruptionSmoke(error: NSError(
                    domain: "TARST.InterruptionSmoke",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "普通插话测试超时。"]
                ))
            }
        } catch {
            finishInterruptionSmoke(error: error)
        }
    }

    private func consumeInterruptionSmoke(_ event: AudioRuntime.Event) {
        switch event {
        case .speechDuringResponse:
            finishInterruptionSmoke()
        case .agentCompleted:
            finishInterruptionSmoke(error: NSError(
                domain: "TARST.InterruptionSmoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "回答播放完成前没有确认普通插话。"]
            ))
        case .error(let error):
            finishInterruptionSmoke(error: error)
        default:
            break
        }
    }

    private func finishInterruptionSmoke(error: Error? = nil) {
        guard let runtime = interruptionSmokeRuntime else { return }
        interruptionSmokeRuntime = nil
        runtime.stop()
        runtime.stopDiagnostics()
        defer { NSApplication.shared.terminate(nil) }
        if let error {
            fputs("TARST interruption smoke test failed: \(error.localizedDescription)\n", stderr)
            return
        }
        guard let url = interruptionSmokeURL,
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            fputs("TARST interruption smoke test failed: 无法读取诊断。\n", stderr)
            return
        }
        let records = contents.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        guard let injection = records.first(where: {
            $0["type"] as? String == "label" && $0["name"] as? String == "interruption_injection"
        }),
        let interruption = records.first(where: {
            $0["type"] as? String == "speech_during_response"
        }),
        let injectionMs = injection["elapsed_ms"] as? NSNumber,
        let interruptionMs = interruption["elapsed_ms"] as? NSNumber,
        interruptionMs.intValue >= injectionMs.intValue else {
            fputs("TARST interruption smoke test failed: 插话在测试语音之前误触发。\n", stderr)
            return
        }
        print(
            "TARST interruption smoke test passed " +
            "(injection→interrupt \(interruptionMs.intValue - injectionMs.intValue) ms)."
        )
    }

    private func consumeAcousticSmoke(_ event: AudioRuntime.Event) {
        switch event {
        case .agentCompleted:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.finishAcousticSmoke()
            }
        case .speechDuringResponse:
            finishAcousticSmoke(error: NSError(
                domain: "TARST.AcousticSmoke",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "播放音频仍触发了插话。"]
            ))
        case .error(let error):
            finishAcousticSmoke(error: error)
        default:
            break
        }
    }

    private func finishAcousticSmoke(error: Error? = nil) {
        guard let runtime = acousticSmokeRuntime else { return }
        acousticSmokeRuntime = nil
        runtime.stop()
        runtime.stopDiagnostics()
        defer { NSApplication.shared.terminate(nil) }
        if let error {
            fputs("TARST acoustic echo smoke test failed: \(error.localizedDescription)\n", stderr)
            return
        }
        guard let url = acousticSmokeURL,
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            fputs("TARST acoustic echo smoke test failed: 无法读取诊断。\n", stderr)
            return
        }
        let records = contents.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let ttsStart = records.first { $0["type"] as? String == "tts_started" }?["elapsed_ms"] as? NSNumber
        let drained = records.first { $0["type"] as? String == "tts_playback_drained" }?["elapsed_ms"] as? NSNumber
        let startMs = ttsStart?.intValue ?? 0
        let endMs = drained?.intValue ?? Int.max
        let playbackFrames = records.filter {
            guard $0["type"] as? String == "frame", let elapsed = $0["elapsed_ms"] as? NSNumber else { return false }
            return elapsed.intValue >= startMs && elapsed.intValue <= endMs
        }
        let highVAD = playbackFrames.filter { ($0["vad_probability"] as? NSNumber)?.doubleValue ?? 0 >= 0.5 }.count
        let falsePauses = records.filter { $0["type"] as? String == "barge_in_playback_paused" }.count
        let ratio = playbackFrames.isEmpty ? 1 : Double(highVAD) / Double(playbackFrames.count)
        guard playbackFrames.count >= 5 else {
            fputs("TARST acoustic echo smoke test failed: 播放期间检测帧不足。\n", stderr)
            return
        }
        guard falsePauses == 0 else {
            fputs("TARST acoustic echo smoke test failed: 纯回声造成了播放暂停。\n", stderr)
            return
        }
        print("TARST acoustic echo smoke test passed (playback VAD ratio=\(ratio))")
    }

    private func runTTSSmoke() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.finishTTSSmoke(error: NSError(
                domain: "TARST.TTSSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "火山 V3 TTS 验证超时（Keychain 未返回或服务未完成）。"]
            ))
        }
        DispatchQueue.global().async { [weak self] in
            do {
                guard let credentials = try VolcengineCredentialsStore().load(allowInteraction: false), credentials.isTTSComplete else {
                    throw VolcengineASRError.invalidCredentials
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    do {
                        let client = VolcengineTTSClient()
                        self.ttsSmokeClient = client
                        client.onEvent = { [weak self] event in self?.consumeTTSSmoke(event) }
                        try client.synthesize("你好，我是 TARST。这是火山 V3 流式语音合成的完整性验证。", credentials: credentials)
                    } catch {
                        self.finishTTSSmoke(error: error)
                    }
                }
            } catch {
                DispatchQueue.main.async { self?.finishTTSSmoke(error: error) }
            }
        }
    }

    private func consumeTTSSmoke(_ event: VolcengineTTSClient.Event) {
        switch event {
        case .ready:
            break
        case .audio(let data):
            ttsSmokeChunks += 1
            ttsSmokeBytes += data.count
        case .finished:
            guard ttsSmokeChunks > 0, ttsSmokeBytes > 0 else {
                finishTTSSmoke(error: VolcengineASRError.invalidResponse)
                return
            }
            finishTTSSmoke()
        case .failure(let error):
            finishTTSSmoke(error: error)
        }
    }

    private func finishTTSSmoke(error: Error? = nil) {
        guard !ttsSmokeReported else { return }
        ttsSmokeReported = true
        ttsSmokeClient?.cancel()
        ttsSmokeClient = nil
        if let error {
            fputs("Volcengine V3 TTS app smoke test failed: \(error.localizedDescription)\n", stderr)
            NSApplication.shared.terminate(nil)
            return
        }
        print("Volcengine V3 TTS app smoke test passed (\(ttsSmokeChunks) PCM chunks, \(ttsSmokeBytes) bytes).")
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "TARST"

        let menu = NSMenu(title: "TARST")
        menu.delegate = self

        statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        listeningMenuItem = NSMenuItem(title: "", action: #selector(toggleListening(_:)), keyEquivalent: "")
        listeningMenuItem.target = self
        menu.addItem(listeningMenuItem)

        let diagnosticsItem = NSMenuItem(title: "诊断", action: nil, keyEquivalent: "")
        let diagnosticsMenu = NSMenu(title: "诊断")
        diagnosticsToggleMenuItem = NSMenuItem(
            title: "",
            action: #selector(toggleDiagnostics(_:)),
            keyEquivalent: ""
        )
        diagnosticsToggleMenuItem.target = self
        diagnosticsMenu.addItem(diagnosticsToggleMenuItem)
        diagnosticsMenu.addItem(.separator())

        tarstAttemptMenuItem = NSMenuItem(
            title: "标记下一次尝试：TARST",
            action: #selector(markTarstAttempt(_:)),
            keyEquivalent: ""
        )
        tarstAttemptMenuItem.target = self
        diagnosticsMenu.addItem(tarstAttemptMenuItem)

        heyTarstAttemptMenuItem = NSMenuItem(
            title: "标记下一次尝试：Hey TARST",
            action: #selector(markHeyTarstAttempt(_:)),
            keyEquivalent: ""
        )
        heyTarstAttemptMenuItem.target = self
        diagnosticsMenu.addItem(heyTarstAttemptMenuItem)

        falseWakeMenuItem = NSMenuItem(
            title: "标记刚才为误唤醒",
            action: #selector(markFalseWake(_:)),
            keyEquivalent: ""
        )
        falseWakeMenuItem.target = self
        diagnosticsMenu.addItem(falseWakeMenuItem)
        diagnosticsMenu.addItem(.separator())

        let openDiagnosticsItem = NSMenuItem(
            title: "打开诊断文件夹",
            action: #selector(openDiagnosticsDirectory(_:)),
            keyEquivalent: ""
        )
        openDiagnosticsItem.target = self
        diagnosticsMenu.addItem(openDiagnosticsItem)
        diagnosticsItem.submenu = diagnosticsMenu
        menu.addItem(diagnosticsItem)

        let settingsItem = NSMenuItem(title: "设置", action: nil, keyEquivalent: "")
        let settingsMenu = NSMenu(title: "设置")

        tarstModelStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        tarstModelStatusItem.isEnabled = false
        settingsMenu.addItem(tarstModelStatusItem)
        let importTarstItem = NSMenuItem(title: "导入 TARST.onnx…", action: #selector(importTarstModel(_:)), keyEquivalent: "")
        importTarstItem.target = self
        settingsMenu.addItem(importTarstItem)

        heyTarstModelStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        heyTarstModelStatusItem.isEnabled = false
        settingsMenu.addItem(heyTarstModelStatusItem)
        let importHeyTarstItem = NSMenuItem(title: "导入 Hey-TARST.onnx…", action: #selector(importHeyTarstModel(_:)), keyEquivalent: "")
        importHeyTarstItem.target = self
        settingsMenu.addItem(importHeyTarstItem)

        settingsMenu.addItem(.separator())
        volcengineStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        volcengineStatusItem.isEnabled = false
        settingsMenu.addItem(volcengineStatusItem)
        let configureVolcengineItem = NSMenuItem(
            title: "配置火山引擎语音…",
            action: #selector(configureVolcengine(_:)),
            keyEquivalent: ""
        )
        configureVolcengineItem.target = self
        settingsMenu.addItem(configureVolcengineItem)

        miniMaxStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        miniMaxStatusItem.isEnabled = false
        settingsMenu.addItem(miniMaxStatusItem)
        let configureMiniMaxItem = NSMenuItem(
            title: "配置 MiniMax Agent…",
            action: #selector(configureMiniMax(_:)),
            keyEquivalent: ""
        )
        configureMiniMaxItem.target = self
        settingsMenu.addItem(configureMiniMaxItem)

        settingsMenu.addItem(.separator())
        autoLaunchMenuItem = NSMenuItem(title: "登录 macOS 后自动启动", action: #selector(toggleAutoLaunch(_:)), keyEquivalent: "")
        autoLaunchMenuItem.target = self
        settingsMenu.addItem(autoLaunchMenuItem)

        settingsItem.submenu = settingsMenu
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 TARST", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    private func refreshMenu() {
        if let response = coordinator.agentPreview {
            statusMenuItem?.title = "TARST：\(response)"
        } else if let transcript = coordinator.transcriptPreview {
            statusMenuItem?.title = "识别：\(transcript)"
        } else if case .error(let message) = coordinator.status {
            statusMenuItem?.title = "错误：\(message)"
        } else {
            statusMenuItem?.title = "状态：\(coordinator.status.title)"
        }
        listeningMenuItem?.title = coordinator.isListeningEnabled ? "暂停监听" : "开始监听"
        listeningMenuItem?.isEnabled = TARSTPaths.isConfigured || coordinator.isListeningEnabled
        diagnosticsToggleMenuItem?.title = coordinator.isDiagnosticsEnabled ? "停止诊断记录" : "开始诊断记录"
        tarstAttemptMenuItem?.isEnabled = coordinator.isDiagnosticsEnabled
        heyTarstAttemptMenuItem?.isEnabled = coordinator.isDiagnosticsEnabled
        falseWakeMenuItem?.isEnabled = coordinator.isDiagnosticsEnabled

        let tarstInstalled = FileManager.default.fileExists(atPath: TARSTPaths.tarstKeyword.path)
        let heyTarstInstalled = FileManager.default.fileExists(atPath: TARSTPaths.heyTarstKeyword.path)
        tarstModelStatusItem?.title = "TARST 模型：\(tarstInstalled ? "已导入" : "未导入")"
        heyTarstModelStatusItem?.title = "Hey TARST 模型：\(heyTarstInstalled ? "已导入" : "未导入")"
        let voiceStore = VolcengineCredentialsStore()
        switch voiceStore.statusWithoutInteraction() {
        case .available:
            // Deliberately do not read secret data while the status menu is tracking.
            volcengineStatusItem?.title = "火山引擎：已配置"
        case .missing:
            volcengineStatusItem?.title = "火山引擎：未配置"
        case .authorizationRequired:
            volcengineStatusItem?.title = "火山引擎：需要授权"
        case .unavailable:
            volcengineStatusItem?.title = "火山引擎：暂不可用"
        }
        switch MiniMaxCredentialsStore().statusWithoutInteraction() {
        case .available: miniMaxStatusItem?.title = "MiniMax Agent：已配置"
        case .missing: miniMaxStatusItem?.title = "MiniMax Agent：未配置"
        case .authorizationRequired: miniMaxStatusItem?.title = "MiniMax Agent：需要授权"
        case .unavailable: miniMaxStatusItem?.title = "MiniMax Agent：暂不可用"
        }
        autoLaunchMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off

        if let image = NSImage(systemSymbolName: coordinator.status.icon, accessibilityDescription: coordinator.status.title) {
            image.isTemplate = true
            statusItem?.button?.image = image
            statusItem?.button?.title = ""
        }
    }

    @objc private func toggleListening(_ sender: NSMenuItem) {
        coordinator.toggleListening()
    }

    @objc private func toggleDiagnostics(_ sender: NSMenuItem) {
        do {
            try coordinator.toggleDiagnostics()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func markTarstAttempt(_ sender: NSMenuItem) {
        coordinator.markWakeAttempt(keyword: "TARST")
    }

    @objc private func markHeyTarstAttempt(_ sender: NSMenuItem) {
        coordinator.markWakeAttempt(keyword: "Hey-TARST")
    }

    @objc private func markFalseWake(_ sender: NSMenuItem) {
        coordinator.markFalseWake()
    }

    @objc private func openDiagnosticsDirectory(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(TARSTPaths.diagnosticsDirectory)
    }

    @objc private func importTarstModel(_ sender: NSMenuItem) {
        importModel(to: TARSTPaths.tarstKeyword)
    }

    @objc private func importHeyTarstModel(_ sender: NSMenuItem) {
        importModel(to: TARSTPaths.heyTarstKeyword)
    }

    private func importModel(to destination: URL) {
        let panel = NSOpenPanel()
        panel.title = "选择 ONNX 唤醒词模型"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "onnx") ?? .data]
        guard panel.runModal() == .OK, let source = panel.url else { return }

        do {
            try TARSTPaths.importKeyword(from: source, as: destination)
            coordinator.refreshConfiguration()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func toggleAutoLaunch(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func configureVolcengine(_ sender: NSMenuItem) {
        let controller = VolcengineSettingsWindowController { [weak self] in
            self?.coordinator.configurationDidChange()
            self?.refreshMenu()
        }
        volcengineSettingsController = controller
        presentSettingsWindow(controller) { $0.prepareForPresentation() }
    }

    @objc private func configureMiniMax(_ sender: NSMenuItem) {
        let controller = MiniMaxSettingsWindowController { [weak self] in
            self?.coordinator.configurationDidChange()
            self?.refreshMenu()
        }
        miniMaxSettingsController = controller
        presentSettingsWindow(controller) { $0.prepareForPresentation() }
    }

    private func presentSettingsWindow<Controller: NSWindowController>(
        _ controller: Controller,
        focus: @escaping (Controller) -> Void
    ) {
        // NSMenu actions run while menu tracking is active. Deferring one main-loop
        // turn prevents a Keychain authorization dialog from competing with that menu
        // for keyboard focus.
        DispatchQueue.main.async {
            NSApplication.shared.activate(ignoringOtherApps: true)
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            focus(controller)
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        coordinator.stopListening()
        coordinator.stopDiagnostics()
        NSApplication.shared.terminate(nil)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "TARST 需要注意"
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class VolcengineSettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store = VolcengineCredentialsStore()
    private let onChange: () -> Void
    private let appIDField = NSTextField()
    private let tokenField = NSSecureTextField()
    private let asrResourceField = NSTextField()
    private let ttsResourceField = NSTextField()
    private let voiceTypeField = NSTextField()
    private let clusterField = NSTextField()

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "火山引擎语音配置"
        window.center()
        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    private func configureContent() {
        let note = NSTextField(wrappingLabelWithString: "正式签名版使用 macOS Data Protection Keychain；本地自签名版使用仅当前用户可读的 AES-GCM 加密凭据库。凭据不会写入源码或诊断日志。可以先只保存 ASR；填写任意 TTS 字段时，需要同时填写 TTS Resource ID 与 Voice Type。")
        note.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            row("App ID", appIDField),
            row("Access Token", tokenField),
            row("ASR Resource ID", asrResourceField),
            row("TTS Resource ID", ttsResourceField),
            row("TTS Voice Type", voiceTypeField),
            row("TTS Cluster（可选）", clusterField)
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 330
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let deleteButton = NSButton(title: "删除本机凭据", target: self, action: #selector(deleteCredentials(_:)))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(closeWindow(_:)))
        let buttons = NSStackView(views: [deleteButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [note, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window!.contentView!.bottomAnchor, constant: -24),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func row(_ label: String, _ field: NSTextField) -> [NSView] {
        field.placeholderString = label
        return [NSTextField(labelWithString: label), field]
    }

    private func loadExistingCredentials() {
        guard let value = try? store.load() else { return }
        appIDField.stringValue = value.appID
        tokenField.stringValue = value.accessToken
        asrResourceField.stringValue = value.asrResourceID
        ttsResourceField.stringValue = value.ttsResourceID
        voiceTypeField.stringValue = value.ttsVoiceType
        clusterField.stringValue = value.ttsCluster
    }

    func prepareForPresentation() {
        // This may trigger a macOS Keychain authorization prompt. It deliberately
        // runs after the status menu has closed and the window is already key.
        loadExistingCredentials()
        window?.initialFirstResponder = appIDField
        window?.makeFirstResponder(appIDField)
    }

    @objc private func save(_ sender: NSButton) {
        do {
            try store.save(VolcengineVoiceCredentials(
                appID: appIDField.stringValue,
                accessToken: tokenField.stringValue,
                asrResourceID: asrResourceField.stringValue,
                ttsResourceID: ttsResourceField.stringValue,
                ttsVoiceType: voiceTypeField.stringValue,
                ttsCluster: clusterField.stringValue
            ))
            onChange()
            close()
        } catch {
            showCredentialError(error.localizedDescription)
        }
    }

    @objc private func deleteCredentials(_ sender: NSButton) {
        do {
            try store.delete()
            [appIDField, tokenField, asrResourceField, ttsResourceField, voiceTypeField, clusterField]
                .forEach { $0.stringValue = "" }
            onChange()
        } catch {
            showCredentialError(error.localizedDescription)
        }
    }

    @objc private func closeWindow(_ sender: NSButton) { close() }

    private func showCredentialError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存火山引擎配置"
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }
}

@MainActor
final class MiniMaxSettingsWindowController: NSWindowController {
    private let store = MiniMaxCredentialsStore()
    private let onChange: () -> Void
    private let apiKeyField = NSSecureTextField()

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 210),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "MiniMax Agent 配置"
        window.center()
        super.init(window: window)
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    func prepareForPresentation() {
        // See VolcengineSettingsWindowController: Keychain access must not happen
        // while an NSMenu action is still in its tracking loop.
        if let value = try? store.load() { apiKeyField.stringValue = value.apiKey }
        window?.initialFirstResponder = apiKeyField
        window?.makeFirstResponder(apiKeyField)
    }

    private func configureContent() {
        let note = NSTextField(wrappingLabelWithString: "当前使用 MiniMax 中国大陆服务。正式签名版使用 Data Protection Keychain；本地自签名版使用仅当前用户可读的 AES-GCM 加密凭据库。API Key 不会写入源码或诊断日志。")
        note.textColor = .secondaryLabelColor
        apiKeyField.placeholderString = "MiniMax API Key"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "API Key"), apiKeyField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 340
        grid.columnSpacing = 12

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save(_:)))
        saveButton.keyEquivalent = "\r"
        let deleteButton = NSButton(title: "删除本机凭据", target: self, action: #selector(deleteCredentials(_:)))
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(closeWindow(_:)))
        let buttons = NSStackView(views: [deleteButton, NSView(), cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [note, grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 24),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @objc private func save(_ sender: NSButton) {
        do {
            try store.save(MiniMaxCredentials(apiKey: apiKeyField.stringValue))
            onChange()
            close()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func deleteCredentials(_ sender: NSButton) {
        do {
            try store.delete()
            apiKeyField.stringValue = ""
            onChange()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func closeWindow(_ sender: NSButton) { close() }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "无法保存 MiniMax 配置"
        alert.informativeText = message
        alert.beginSheetModal(for: window!)
    }
}

@MainActor
final class TARSTCoordinator: NSObject {
    private(set) var status: TARSTStatus = .needsSetup { didSet { onChange?() } }
    private(set) var isListeningEnabled = false { didSet { onChange?() } }
    private(set) var isDiagnosticsEnabled = false { didSet { onChange?() } }
    var onChange: (() -> Void)?

    private let runtime = AudioRuntime()
    private(set) var transcriptPreview: String?
    private(set) var agentPreview: String?
    override init() {
        super.init()
        runtime.onEvent = { [weak self] event in self?.handle(event) }
        refreshConfiguration()
    }

    func refreshConfiguration() {
        if TARSTPaths.isConfigured {
            if !isListeningEnabled { status = .paused }
        } else {
            status = .needsSetup
        }
    }

    func configurationDidChange() {
        runtime.invalidateCredentialCache()
        refreshConfiguration()
    }

    func toggleListening() {
        isListeningEnabled ? stopListening() : startListening()
    }

    func toggleDiagnostics() throws {
        if isDiagnosticsEnabled {
            stopDiagnostics()
        } else {
            _ = try runtime.startDiagnostics()
            isDiagnosticsEnabled = true
        }
    }

    func stopDiagnostics() {
        runtime.stopDiagnostics()
        isDiagnosticsEnabled = false
    }

    func markWakeAttempt(keyword: String) {
        runtime.recordDiagnosticLabel("wake_attempt", keyword: keyword)
    }

    func markFalseWake() {
        runtime.recordDiagnosticLabel("false_wake")
    }

    func startListening() {
        guard TARSTPaths.isConfigured else {
            status = .needsSetup
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                self?.finishStarting(granted: granted)
            }
        }
    }

    private func finishStarting(granted: Bool) {
        guard granted else {
            status = .error("需要麦克风权限")
            return
        }
        do {
            try runtime.start()
            isListeningEnabled = true
            status = .idle
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stopListening() {
        runtime.stop()
        isListeningEnabled = false
        status = TARSTPaths.isConfigured ? .paused : .needsSetup
    }

    private func handle(_ event: AudioRuntime.Event) {
        switch event {
        case .agentConfigured:
            break
        case .wakeWord:
            transcriptPreview = nil
            agentPreview = nil
            status = .awaitingSpeech
            NSSound.beep()
        case .speechStarted:
            status = .listening
        case .turnEnded:
            status = .transcribing
        case .asrPartial(let text):
            transcriptPreview = text
            status = .transcribing
        case .asrFinal(let text):
            transcriptPreview = text
            status = .responding
        case .agentTextDelta(let text):
            agentPreview = (agentPreview ?? "") + text
            status = .responding
        case .agentCompleted:
            // One wake word opens a short conversational session. After TARST
            // finishes speaking, listen for a follow-up directly instead of
            // forcing the user to say Hey Tars before every turn.
            status = .awaitingSpeech
        case .speechDuringResponse:
            // AudioRuntime has stopped PCM and immediately opened a fresh ASR
            // turn, so the UI must remain in listening rather than falling back
            // to idle (which would make the interruption look ignored).
            status = .listening
        case .waitingTimedOut:
            status = .idle
        case .turnFailed:
            transcriptPreview = "刚才连接中断，请再说一次。"
            status = .awaitingSpeech
        case .error(let error):
            runtime.stop()
            status = .error(error.localizedDescription)
            isListeningEnabled = false
        }
    }
}
