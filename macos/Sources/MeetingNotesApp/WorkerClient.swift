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
    private var nextWindowStartMs: Int64 = 0

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

    func send(samples: [Float], startMs: Int64) {
        guard state == .ready || state == .transcribing, !samples.isEmpty else { return }
        var pcm = Data(capacity: samples.count * MemoryLayout<Float>.size)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { pcm.append(contentsOf: $0) }
        }
        let message: [String: Any] = [
            "type": "audio_window", "session_id": sessionID,
            "start_ms": startMs, "sample_rate_hz": 16_000,
            "samples_base64": pcm.base64EncodedString(),
        ]
        write(message)
        nextWindowStartMs = max(nextWindowStartMs, startMs + Int64(samples.count * 1000 / 16_000))
    }

    func stop() {
        guard process.isRunning else { return }
        write(["type": "stop", "session_id": sessionID])
        input.fileHandleForWriting.closeFile()
    }

    private func write(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]),
              data.count <= 4 * 1024 * 1024 else {
            state = .failed("Audio window could not be encoded within the protocol limit.")
            return
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: data + Data([0x0A]))
        } catch {
            state = .failed("Local worker stopped accepting audio.")
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
