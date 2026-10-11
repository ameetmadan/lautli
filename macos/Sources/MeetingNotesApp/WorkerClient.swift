import Foundation

@MainActor
final class WorkerClient: ObservableObject {
    enum State: Equatable {
        case stopped, starting, ready, transcribing, failed(String)
    }

    @Published private(set) var state: State = .stopped
    var onSegment: (([String: Any]) -> Void)?
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var outputRemainder = Data()
    private let sessionID = UUID().uuidString
    private var audioBySource: [AudioSource: (startMs: Int64, samples: [Float])] = [:]
    private var writeBusy = false
    private let writer = DispatchQueue(label: "worker.stdin.writer")

    func start(projectDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
        guard !process.isRunning else { return }
        state = .starting
        process.executableURL = projectDirectory.appending(path: ".venv/bin/python")
        process.arguments = ["-m", "worker.meeting_worker.main"]
        process.currentDirectoryURL = projectDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { @MainActor in self?.consumeOutput(bytes) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                if process.terminationStatus != 0 { self?.state = .failed("Local transcription worker exited unexpectedly.") }
                else { self?.state = .stopped }
            }
        }
        do { try process.run() }
        catch { state = .failed("Could not start local worker: \(error.localizedDescription)") }
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

    func stop() {
        guard process.isRunning else { return }
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
                case "ready": state = .ready
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
}
