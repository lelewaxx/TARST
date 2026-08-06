import AVFoundation
import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import TARSTCore

@main
struct TARSTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = TARSTCoordinator()

    var body: some Scene {
        MenuBarExtra("TARST", systemImage: coordinator.status.icon) {
            MenuContent(coordinator: coordinator)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(coordinator: coordinator)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A locally-built, ad-hoc signed app may be rejected by macOS; the setting remains user controllable.
        try? SMAppService.mainApp.register()
    }
}

@MainActor
final class TARSTCoordinator: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var status: TARSTStatus = .needsSetup
    @Published private(set) var isListeningEnabled = false
    @Published var setupMessage = "导入本地 Picovoice 运行库、两个唤醒词模型，并保存 AccessKey。"

    private let runtime = AudioRuntime()
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
        runtime.onEvent = { [weak self] event in self?.handle(event) }
        refreshConfiguration()
    }

    func refreshConfiguration() {
        if TARSTPaths.isConfigured {
            setupMessage = "已准备好。启动监听后，试着说 “TARST” 或 “Hey TARST”。"
            if !isListeningEnabled { status = .paused }
        } else {
            status = .needsSetup
        }
    }

    func toggleListening() {
        isListeningEnabled ? stopListening() : startListening()
    }

    func startListening() {
        guard TARSTPaths.isConfigured, let accessKey = KeychainStore.readAccessKey() else {
            status = .needsSetup
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                guard granted else {
                    self.status = .error("需要麦克风权限")
                    return
                }
                do {
                    try self.runtime.start(accessKey: accessKey)
                    self.isListeningEnabled = true
                    self.status = .idle
                } catch {
                    self.status = .error(error.localizedDescription)
                }
            }
        }
    }

    func stopListening() {
        synthesizer.stopSpeaking(at: .immediate)
        runtime.stop()
        isListeningEnabled = false
        status = TARSTPaths.isConfigured ? .paused : .needsSetup
    }

    private func handle(_ event: AudioRuntime.Event) {
        switch event {
        case .wakeWord:
            status = .awaitingSpeech
            NSSound.beep()
        case .speechStarted:
            status = .listening
        case .turnEnded:
            status = .responding
            runtime.beginResponse()
            let utterance = AVSpeechUtterance(string: "嗯，我在。")
            utterance.voice = AVSpeechSynthesisVoice(identifier: "com.apple.voice.compact.zh-CN.Tingting")
            utterance.rate = 0.45
            synthesizer.speak(utterance)
        case .speechDuringResponse:
            synthesizer.stopSpeaking(at: .immediate)
            status = .idle
        case .waitingTimedOut:
            status = .idle
        case .error(let error):
            status = .error(error.localizedDescription)
            isListeningEnabled = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        runtime.returnToIdle()
        status = .idle
    }
}

private struct MenuContent: View {
    @ObservedObject var coordinator: TARSTCoordinator
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("tarst.").font(.system(.title2, design: .monospaced))
            Text(coordinator.status.title).foregroundStyle(.secondary)
            Divider()
            Button(coordinator.isListeningEnabled ? "暂停监听" : "开始监听") {
                coordinator.toggleListening()
            }
            Button("设置…") { openSettings() }
            Divider()
            Button("退出 TARST") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 235)
    }
}

private struct SettingsView: View {
    @ObservedObject var coordinator: TARSTCoordinator
    @State private var accessKey = KeychainStore.readAccessKey() ?? ""
    @State private var importing: KeywordTarget?
    @State private var autoLaunch = SMAppService.mainApp.status == .enabled

    private enum KeywordTarget: String, Identifiable { case tarst, heyTarst; var id: String { rawValue } }

    var body: some View {
        Form {
            Section("本地 Picovoice 设置") {
                SecureField("AccessKey", text: $accessKey)
                Text("仅保存到此 Mac 的 Keychain，不会提交到 Git。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("保存 AccessKey") {
                    do {
                        try KeychainStore.saveAccessKey(accessKey.trimmingCharacters(in: .whitespacesAndNewlines))
                        coordinator.refreshConfiguration()
                    } catch { coordinator.setupMessage = error.localizedDescription }
                }
                Link("下载本地运行库说明", destination: URL(string: "https://picovoice.ai/docs/quick-start/porcupine-c/")!)
            }

            Section("唤醒词模型") {
                modelRow("TARST", destination: TARSTPaths.tarstKeyword, target: .tarst)
                modelRow("Hey TARST", destination: TARSTPaths.heyTarstKeyword, target: .heyTarst)
            }

            Section("常驻") {
                Toggle("登录 macOS 后自动启动", isOn: $autoLaunch)
                    .onChange(of: autoLaunch) { _, enabled in
                        do {
                            enabled ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister()
                        } catch { coordinator.setupMessage = error.localizedDescription }
                    }
            }

            Text(coordinator.setupMessage).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520)
        .fileImporter(isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }), allowedContentTypes: [.data]) { result in
            guard let target = importing else { return }
            importing = nil
            do {
                let source = try result.get()
                let destination = target == .tarst ? TARSTPaths.tarstKeyword : TARSTPaths.heyTarstKeyword
                try TARSTPaths.importKeyword(from: source, as: destination)
                coordinator.refreshConfiguration()
            } catch { coordinator.setupMessage = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func modelRow(_ label: String, destination: URL, target: KeywordTarget) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(FileManager.default.fileExists(atPath: destination.path) ? "已导入" : "未导入")
                .foregroundStyle(.secondary)
            Button("导入 .ppn") { importing = target }
        }
    }
}
