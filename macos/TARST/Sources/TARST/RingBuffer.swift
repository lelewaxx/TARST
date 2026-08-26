import Foundation

/// Keeps only recent in-memory PCM frames. v1 never persists or uploads this data.
public final class PCM16RingBuffer {
    private let capacity: Int
    private var storage: [Int16] = []

    public init(sampleRate: Int = 16_000, seconds: Double = 1.5) {
        capacity = Int(Double(sampleRate) * seconds)
        storage.reserveCapacity(capacity)
    }

    public func append(_ samples: ArraySlice<Int16>) {
        storage.append(contentsOf: samples)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
    }

    public var sampleCount: Int { storage.count }
    public func recent(seconds: Double, sampleRate: Int = 16_000) -> [Int16] {
        Array(storage.suffix(Int(seconds * Double(sampleRate))))
    }
    public func clear() { storage.removeAll(keepingCapacity: true) }
}
