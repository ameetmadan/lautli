import Foundation

public enum AudioSource: Hashable {
    case microphone
    case meetingOutput
}

public struct AudioBufferFrame: Equatable {
    public let source: AudioSource
    public let startTimestampMs: Int64
    public let samples: [Float]

    public init(source: AudioSource, startTimestampMs: Int64, samples: [Float]) {
        self.source = source
        self.startTimestampMs = startTimestampMs
        self.samples = samples
    }
}

public enum AudioBufferAppendResult: Equatable {
    case accepted
    case capacityExceeded
    case nonMonotonicTimestamp
}

public final class BoundedAudioBuffer {
    private let lock = NSLock()
    public let maxFrames: Int
    private var frames: [AudioBufferFrame] = []
    private var sampleCount = 0
    private var lastTimestampBySource: [AudioSource: Int64] = [:]
    public var bufferedFrameCount: Int { lock.withLock { sampleCount } }

    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
    }

    public func append(_ frame: AudioBufferFrame) -> AudioBufferAppendResult {
        lock.withLock {
            guard !frame.samples.isEmpty else { return .accepted }
            if let previous = lastTimestampBySource[frame.source], frame.startTimestampMs <= previous {
                return .nonMonotonicTimestamp
            }
            guard frame.samples.count <= maxFrames - sampleCount else { return .capacityExceeded }
            frames.append(frame)
            sampleCount += frame.samples.count
            lastTimestampBySource[frame.source] = frame.startTimestampMs
            return .accepted
        }
    }

    public func drain(maxFrames: Int) -> [AudioBufferFrame] {
        lock.withLock {
            guard maxFrames > 0 else { return [] }
            var remaining = maxFrames
            var output: [AudioBufferFrame] = []
            while remaining > 0, !frames.isEmpty {
                let first = frames.removeFirst()
                if first.samples.count <= remaining {
                    output.append(first)
                    remaining -= first.samples.count
                    sampleCount -= first.samples.count
                } else {
                    let consumed = remaining
                    output.append(AudioBufferFrame(source: first.source, startTimestampMs: first.startTimestampMs, samples: Array(first.samples.prefix(consumed))))
                    frames.insert(AudioBufferFrame(source: first.source, startTimestampMs: first.startTimestampMs + Int64(consumed) * 1_000 / 16_000, samples: Array(first.samples.dropFirst(consumed))), at: 0)
                    sampleCount -= consumed
                    remaining = 0
                }
            }
            return output
        }
    }

    public func clear() {
        lock.withLock {
            frames.removeAll(keepingCapacity: true)
            sampleCount = 0
            lastTimestampBySource.removeAll(keepingCapacity: true)
        }
    }
}
