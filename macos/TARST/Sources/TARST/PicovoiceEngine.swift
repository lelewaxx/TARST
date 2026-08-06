import Foundation
import Darwin

enum PicovoiceError: LocalizedError {
    case missingRuntime
    case initializationFailed(String)
    case processingFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime: "Picovoice 本地运行库尚未安装。"
        case .initializationFailed(let detail): "Picovoice 初始化失败：\(detail)"
        case .processingFailed(let detail): "Picovoice 音频处理失败：\(detail)"
        }
    }
}

private typealias PVObject = OpaquePointer
private typealias PorcupineInit = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32, UnsafePointer<UnsafePointer<CChar>?>?, UnsafePointer<Float>?, UnsafeMutablePointer<PVObject?>?) -> Int32
private typealias PorcupineProcess = @convention(c) (PVObject?, UnsafePointer<Int16>?, UnsafeMutablePointer<Int32>?) -> Int32
private typealias PorcupineDelete = @convention(c) (PVObject?) -> Void
private typealias FrameLength = @convention(c) () -> Int32
private typealias SampleRate = @convention(c) () -> Int32
private typealias CobraInit = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<PVObject?>?) -> Int32
private typealias CobraProcess = @convention(c) (PVObject?, UnsafePointer<Int16>?, UnsafeMutablePointer<Float>?) -> Int32
private typealias CobraDelete = @convention(c) (PVObject?) -> Void

private final class DynamicLibrary {
    private let handle: UnsafeMutableRawPointer

    init(_ url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw PicovoiceError.initializationFailed(String(cString: dlerror()))
        }
        self.handle = handle
    }

    deinit { dlclose(handle) }

    func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let pointer = dlsym(handle, name) else {
            throw PicovoiceError.initializationFailed("缺少符号 \(name)")
        }
        return unsafeBitCast(pointer, to: type)
    }
}

/// Swift bridge over Picovoice's official macOS C SDK. It dynamically loads local dylibs,
/// avoiding both network audio processing and a compile-time dependency on proprietary binaries.
final class PicovoiceEngine {
    let frameLength: Int
    let sampleRate: Int
    private let porcupineLibrary: DynamicLibrary
    private let cobraLibrary: DynamicLibrary
    private let porcupineProcess: PorcupineProcess
    private let porcupineDelete: PorcupineDelete
    private let cobraProcess: CobraProcess
    private let cobraDelete: CobraDelete
    private var porcupine: PVObject?
    private var cobra: PVObject?

    init(accessKey: String) throws {
        guard TARSTPaths.isPicovoiceRuntimeInstalled else { throw PicovoiceError.missingRuntime }
        porcupineLibrary = try DynamicLibrary(TARSTPaths.porcupineLibrary)
        cobraLibrary = try DynamicLibrary(TARSTPaths.cobraLibrary)

        let porcupineInit = try porcupineLibrary.symbol("pv_porcupine_init", as: PorcupineInit.self)
        porcupineProcess = try porcupineLibrary.symbol("pv_porcupine_process", as: PorcupineProcess.self)
        porcupineDelete = try porcupineLibrary.symbol("pv_porcupine_delete", as: PorcupineDelete.self)
        let porcupineFrameLength = try porcupineLibrary.symbol("pv_porcupine_frame_length", as: FrameLength.self)
        let pvSampleRate = try porcupineLibrary.symbol("pv_sample_rate", as: SampleRate.self)

        let cobraInit = try cobraLibrary.symbol("pv_cobra_init", as: CobraInit.self)
        cobraProcess = try cobraLibrary.symbol("pv_cobra_process", as: CobraProcess.self)
        cobraDelete = try cobraLibrary.symbol("pv_cobra_delete", as: CobraDelete.self)
        let cobraFrameLength = try cobraLibrary.symbol("pv_cobra_frame_length", as: FrameLength.self)

        frameLength = Int(porcupineFrameLength())
        sampleRate = Int(pvSampleRate())
        guard frameLength == Int(cobraFrameLength()) else {
            throw PicovoiceError.initializationFailed("Wake Word 与 VAD 的帧大小不一致")
        }

        let keywordPaths = [TARSTPaths.tarstKeyword.path, TARSTPaths.heyTarstKeyword.path]
        let sensitivities: [Float] = [0.55, 0.55]
        let keywordPointers = keywordPaths.map { strdup($0) }.map { UnsafePointer($0) }
        defer { keywordPointers.forEach { free(UnsafeMutablePointer(mutating: $0)) } }

        let porcupineStatus = accessKey.withCString { key in
            TARSTPaths.porcupineModel.path.withCString { model in
                "best".withCString { device in
                    sensitivities.withUnsafeBufferPointer { sensitivityBuffer in
                        keywordPointers.withUnsafeBufferPointer { pathBuffer in
                            porcupineInit(key, model, device, Int32(keywordPointers.count), pathBuffer.baseAddress, sensitivityBuffer.baseAddress, &porcupine)
                        }
                    }
                }
            }
        }
        guard porcupineStatus == 0 else {
            throw PicovoiceError.initializationFailed("Porcupine 状态码 \(porcupineStatus)")
        }

        let cobraStatus = accessKey.withCString { key in
            "best".withCString { device in cobraInit(key, device, &cobra) }
        }
        guard cobraStatus == 0 else {
            throw PicovoiceError.initializationFailed("Cobra 状态码 \(cobraStatus)")
        }
    }

    deinit {
        porcupineDelete(porcupine)
        cobraDelete(cobra)
    }

    func process(_ frame: ArraySlice<Int16>) throws -> (keywordIndex: Int?, voiceProbability: Float) {
        guard frame.count == frameLength else {
            throw PicovoiceError.processingFailed("帧大小为 \(frame.count)，期望 \(frameLength)")
        }
        var keywordIndex: Int32 = -1
        var voiceProbability: Float = 0
        let porcupineStatus = frame.withContiguousStorageIfAvailable { samples in
            porcupineProcess(porcupine, samples.baseAddress, &keywordIndex)
        } ?? -1
        let cobraStatus = frame.withContiguousStorageIfAvailable { samples in
            cobraProcess(cobra, samples.baseAddress, &voiceProbability)
        } ?? -1
        guard porcupineStatus == 0, cobraStatus == 0 else {
            throw PicovoiceError.processingFailed("Porcupine \(porcupineStatus)，Cobra \(cobraStatus)")
        }
        return (keywordIndex >= 0 ? Int(keywordIndex) : nil, voiceProbability)
    }
}
