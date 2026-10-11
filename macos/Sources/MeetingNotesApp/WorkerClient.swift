import Foundation

private final class WorkerOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var drainScheduled = false

    func append(_ bytes: Data) -> Bool {
        guard !bytes.isEmpty else { return false }
        lock.lock()
        data.append(bytes)
        let shouldSchedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        return shouldSchedule
    }

    func nextChunk() -> Data? {
        lock.lock()
        guard !data.isEmpty else {
            drainScheduled = false
            lock.unlock()
            return nil
        }
        let chunk = data
        data = Data()
        lock.unlock()
        return chunk
    }
}

@MainActor
final class WorkerClient: ObservableObject {
    enum State: Equatable {
        case stopped, starting, ready, transcribing, failed(String)
    }

    @Published private(set) var state: State = .stopped
    var onSegment: (([String: Any]) -> Void)?
    var onStopComplete: (() -> Void)?
    private var process = Process()
    private var input = Pipe()
    private var output = Pipe()
    private var paths = AppPaths.standard
    private var outputBuffer = WorkerOutputBuffer()
    nonisolated private let stdoutReadQueue = DispatchQueue(label: "worker.stdout.reader")
    private var outputRemainder = Data()
    private let sessionID = UUID().uuidString
    private var audioBySource: [AudioSource: (startMs: Int64, samples: [Float])] = [:]
    private var writeBusy = false
    private let writer = DispatchQueue(label: "worker.stdin.writer")

    func start(paths: AppPaths = .standard) {
        guard !process.isRunning else { return }
        self.paths = paths
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        self.process = process
        self.input = input
        self.output = output
        outputRemainder = Data()
        writeBusy = false
        state = .starting
        process.executableURL = paths.python
        process.arguments = ["-m", "worker.meeting_worker.main"]
        process.currentDirectoryURL = paths.workerSource
        process.environment = ProcessInfo.processInfo.environment.merging([
            "WHISPER_MODEL_PATH": paths.modelDirectory.path,
            "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
            // The worker lives inside the signed app bundle; writing bytecode there would break its signature.
            "PYTHONDONTWRITEBYTECODE": "1",
        ]) { _, new in new }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Self.openWorkerLog(paths) ?? FileHandle.nullDevice
        let outputBuffer = WorkerOutputBuffer()
        self.outputBuffer = outputBuffer
        let stdoutReadQueue = self.stdoutReadQueue
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            stdoutReadQueue.async {
                let bytes = handle.availableData
                guard !bytes.isEmpty, outputBuffer.append(bytes) else { return }
                Task { @MainActor in self?.drainPendingOutput() }
            }
        }
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            output.fileHandleForReading.readabilityHandler = nil
            self.stdoutReadQueue.sync {
                let trailingOutput = output.fileHandleForReading.readDataToEndOfFile()
                _ = outputBuffer.append(trailingOutput)
            }
            Task { @MainActor in
                guard finished === self.process else { return }
                self.drainPendingOutput()
                if finished.terminationStatus != 0 {
                    self.state = .failed("Local transcription worker exited unexpectedly.")
                    AppLog.write("worker exited with status \(finished.terminationStatus)", paths: self.paths)
                } else { self.state = .stopped }
                self.onStopComplete?()
                self.onStopComplete = nil
            }
        }
        do { try process.run() }
        catch { state = .failed("Could not start local worker: \(error.localizedDescription)") }
    }

    /// Replaces a failed or stopped worker with a fresh process.
    func restart() {
        terminate()
        process = Process()
        audioBySource.removeAll()
        start(paths: paths)
    }

    private static func openWorkerLog(_ paths: AppPaths) -> FileHandle? {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        let log = paths.logs.appending(path: "worker.log")
        let previous = paths.logs.appending(path: "worker.old.log")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: log, to: previous)
        fileManager.createFile(atPath: log.path, contents: nil)
        return try? FileHandle(forWritingTo: log)
    }

    func appendAudio(source: AudioSource, samples: [Float], startMs: Int64) {
        guard state == .ready || state == .transcribing, !samples.isEmpty else { return }
        var stream = audioBySource[source] ?? (startMs, [])
        if stream.samples.isEmpty { stream.startMs = startMs }
        stream.samples.append(contentsOf: samples)
        guard stream.samples.count <= 30 * 16_000 else {
            state = .failed("Audio worker fell behind by 30 seconds. Capture stopped to preserve speech.")
            return
        }
        if stream.samples.count >= 10 * 16_000 {
            guard !writeBusy else { audioBySource[source] = stream; return }
            let window = Array(stream.samples.prefix(10 * 16_000))
            let windowStart = stream.startMs
            stream.samples = Array(stream.samples.dropFirst(5 * 16_000))
            stream.startMs += 5_000
            writeBusy = true
            audioBySource[source] = stream
            writeAudioWindow(samples: window, startMs: windowStart, source: source)
            return
        }
        audioBySource[source] = stream
    }

    private func writeAudioWindow(samples: [Float], startMs: Int64, source: AudioSource) {
        var pcm = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
        }
        let message: [String: Any] = [
            "type": "audio_window", "session_id": sessionID,
            "start_ms": startMs, "sample_rate_hz": 16_000,
            "samples_base64": pcm.base64EncodedString(), "source": source.rawValue,
        ]
        guard let data = encoded(message) else { return }
        enqueue(data)
    }

    func stop(completion: (() -> Void)? = nil) {
        onStopComplete = completion
        guard process.isRunning else {
            onStopComplete?()
            onStopComplete = nil
            return
        }
        for (source, stream) in audioBySource where !stream.samples.isEmpty {
            writeAudioWindow(samples: stream.samples, startMs: stream.startMs, source: source)
        }
        audioBySource.removeAll()
        write(["type": "stop", "session_id": sessionID])
    }

    func terminate() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        input.fileHandleForWriting.closeFile()
    }

    private func write(_ message: [String: Any]) {
        guard let data = encoded(message) else { return }
        enqueue(data)
    }

    private func encoded(_ message: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              data.count <= 4 * 1024 * 1024 else {
            state = .failed("Audio window could not be encoded within the protocol limit.")
            return nil
        }
        return data + Data([0x0A])
    }

    private func enqueue(_ data: Data) {
        let fileHandle = input.fileHandleForWriting
        writer.async { [weak self] in
            do { try fileHandle.write(contentsOf: data) }
            catch { Task { @MainActor [weak self] in self?.state = .failed("Local worker stopped accepting audio.") } }
            Task { @MainActor [weak self] in self?.writeBusy = false }
        }
    }

    private func consumeOutput(_ bytes: Data) {
        outputRemainder.append(bytes)
        while let newline = outputRemainder.firstIndex(of: 0x0A) {
            let line = outputRemainder.prefix(upTo: newline)
            outputRemainder.removeSubrange(...newline)
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = value["type"] as? String else {
                state = .failed("Worker sent malformed output; transcription stopped.")
                stop()
                return
            }
            if type == "status", let name = value["state"] as? String {
                switch name {
                case "loading": state = .starting
                case "ready":
                    state = .ready
                    if value["message"] as? String == "Transcription stopped" {
                        onStopComplete?()
                        onStopComplete = nil
                    }
                case "transcribing", "behind": state = .transcribing
                case "failed": state = .failed(value["message"] as? String ?? "Local worker failed.")
                default: state = .failed("Worker sent an unknown status.")
                }
            } else if type == "segment" {
                onSegment?(value)
            } else {
                state = .failed("Worker sent an unknown message.")
                stop()
                return
            }
        }
    }

    private func drainPendingOutput() {
        while let bytes = outputBuffer.nextChunk() { consumeOutput(bytes) }
    }
}
