import AVFoundation
import XCTest
@testable import LautliApp

@MainActor
final class FileTranscriptionTests: XCTestCase {
    private func recording(_ root: URL, name: String = "recording.wav", seconds: Double = 0.1) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 44_100)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = 0.1 }
        }
        try file.write(from: buffer)
        return url
    }

    func testDecoderResamplesStereoWithBoundedWindowsAndFinalTail() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let decoder = try AudioFileDecoder(url: recording(root, seconds: 41))
        var counts: [Int] = []
        var starts: [Int64] = []
        while let chunk = try await decoder.next() {
            counts.append(chunk.samples.count)
            starts.append(chunk.startMs)
            XCTAssertLessThanOrEqual(chunk.samples.count, 320_000)
            XCTAssertEqual(chunk.samples[100], 0.1, accuracy: 0.01)
        }
        XCTAssertEqual(starts, [0, 20_000, 40_000])
        XCTAssertEqual(Double(counts.reduce(0, +)), 41 * 16_000, accuracy: 32)
    }

    func testQueueIsolatesFailureAndWritesThreeAssociatedTranscripts() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        worker.onChunk = { chunk in
            queue.receive(["segment": ["id": UUID().uuidString, "text": "Test speech", "stability": "final", "start_ms": chunk.startMs, "end_ms": chunk.startMs + 50]])
        }
        let sources = try (1...3).map { try recording(root, name: "source-\($0).wav") }
        queue.add([root.appending(path: "missing.mp3")] + sources)
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        guard case .failed = queue.jobs[0].state else { return XCTFail("Unreadable input must fail") }
        for job in queue.jobs.dropFirst() {
            guard case .completed(let url) = job.state else { return XCTFail("Later files must complete") }
            let markdown = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(markdown.contains(job.source.lastPathComponent))
            XCTAssertTrue(markdown.contains("[00:00:00] Test speech"))
            XCTAssertEqual(job.progress, 1)
        }
        XCTAssertEqual(worker.starts, [0, 0, 0])
        XCTAssertEqual(Set(queue.jobs.compactMap { if case .completed(let url) = $0.state { url } else { nil } }).count, 3)
    }

    func testLiveMeetingYieldsAtWindowBoundaryAndResumesAtNextTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add([try recording(root, seconds: 41)])
        worker.onChunk = { _ in queue.updateAvailability(workerReady: true, liveSessionActive: true) }
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        XCTAssertEqual(queue.jobs[0].state, .paused)
        XCTAssertEqual(worker.starts, [0])
        XCTAssertEqual(worker.stops, 1)
        worker.onChunk = nil
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        XCTAssertEqual(worker.starts, [0, 20_000, 40_000])
        guard case .completed = queue.jobs[0].state else { return XCTFail("Must finish after resume") }
    }

    func testCancellationDoesNotPublishPartialTranscriptAndNextJobCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add([try recording(root, name: "cancel.wav", seconds: 21), try recording(root, name: "next.wav")])
        worker.onChunk = { _ in
            queue.cancel(queue.jobs[0].id)
            worker.onChunk = nil
        }
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        guard case .completed = queue.jobs[1].state else { return XCTFail("Next job must complete") }
        let outputs = try FileManager.default.contentsOfDirectory(at: root.appending(path: "lautli"), includingPropertiesForKeys: nil)
        XCTAssertEqual(outputs.filter { $0.pathExtension == "md" }.count, 1)
    }

    func testWorkerFailureLeavesLaterJobsQueuedUntilRestartAndAllowsRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        worker.unavailable = true
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add([try recording(root, name: "first.wav"), try recording(root, name: "second.wav")])
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        guard case .failed = queue.jobs[0].state else { return XCTFail("Active file should report worker failure") }
        XCTAssertEqual(queue.jobs[1].state, .queued)
        worker.unavailable = false
        queue.retry(queue.jobs[0].id)
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        for job in queue.jobs {
            guard case .completed = job.state else { return XCTFail("Both jobs should finish after recovery") }
        }
    }

    func testWorkerClientWaitsForSegmentsAndCanReuseStoppedFileSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(support: root, workerSource: root)
        try FileManager.default.createDirectory(at: paths.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.python, withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        let module = root.appending(path: "worker/lautli_worker")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let script = """
        import base64, json, sys
        def emit(value):
            print(json.dumps(value), flush=True)
        emit({"type": "status", "state": "ready"})
        session = None
        for line in sys.stdin:
            value = json.loads(line)
            if value["type"] == "stop":
                assert session is None or session == value["session_id"]
                session = None
                emit({"type": "status", "state": "ready", "message": "Transcription stopped"})
            else:
                assert value["mode"] == "file"
                assert session is None or session == value["session_id"]
                session = value["session_id"]
                emit({"type": "segment", "session_id": session, "segment": {"text": "test"}})
                emit({"type": "window_complete", "session_id": session, "start_ms": value["start_ms"], "sample_count": len(base64.b64decode(value["samples_base64"])) // 4})
        """
        try script.write(to: module.appending(path: "main.py"), atomically: true, encoding: .utf8)
        let worker = WorkerClient()
        defer { worker.terminate() }
        var segments = 0
        worker.onSegment = { _ in segments += 1 }
        worker.start(paths: paths)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while worker.state == .starting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(worker.state, .ready)
        for _ in 0..<2 {
            try await worker.transcribeFileChunk(.init(samples: [0.1, 0.2], startMs: 0))
            try await worker.finishFileSession()
        }
        XCTAssertEqual(segments, 2, "Final segments must arrive before the window acknowledgement resumes the sender")
        XCTAssertEqual(worker.state, .ready)
    }

    func testInvalidAudioFilesHaveDecodeGuidanceAndDoNotBlockValidFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let invalid: [(String, Data)] = [
            ("empty.wav", Data()),
            ("corrupt.wav", Data("RIFF\u{00}\u{00}\u{00}\u{00}WAVEfmt ".utf8)),
            ("unsupported.audio", Data("This is not an audio recording".utf8)),
        ]
        var inputs: [URL] = []
        for (name, bytes) in invalid {
            let url = root.appending(path: name)
            try bytes.write(to: url)
            inputs.append(url)
        }
        let emptyAudio = root.appending(path: "header-only.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let file = try AVAudioFile(forWriting: emptyAudio, settings: format.settings)
            XCTAssertEqual(file.length, 0)
        }
        inputs.append(emptyAudio)
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add(inputs + [root.appending(path: "missing.wav"), try recording(root, name: "valid.wav")])
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        for job in queue.jobs.dropLast() {
            guard case .failed(let message) = job.state else { return XCTFail("Invalid input must fail") }
            XCTAssertEqual(message, FileTranscriptionError.unreadable.localizedDescription)
            XCTAssertFalse(message.contains(root.path), "Do not expose private file paths")
        }
        guard case .completed = queue.jobs.last?.state else { return XCTFail("Valid file after invalid inputs must finish") }
        XCTAssertEqual(worker.starts, [0])
        let finishedStates = queue.jobs.map(\.state)
        await queue.shutdown()
        XCTAssertEqual(queue.jobs.map(\.state), finishedStates, "Shutdown must preserve completed output and failed-job information")
    }

    func testRemovingPendingFilesDuringProcessingPreservesActiveJob() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add([try recording(root, name: "active.wav", seconds: 21), try recording(root, name: "remove.wav"), try recording(root, name: "last.wav")])
        let removed = queue.jobs[1].id
        worker.onChunk = { _ in queue.cancel(removed) }
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        XCTAssertEqual(queue.jobs.map { $0.source.lastPathComponent }, ["active.wav", "last.wav"])
        XCTAssertEqual(worker.starts, [0, 20_000, 0])
        for job in queue.jobs {
            guard case .completed = job.state else { return XCTFail("Remaining jobs must complete") }
        }
    }

    func testCancellingPausedFileDoesNotStopLiveWorkerAndNextJobWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add([try recording(root, name: "pause.wav", seconds: 21), try recording(root, name: "next.wav")])
        worker.onChunk = { _ in queue.updateAvailability(workerReady: true, liveSessionActive: true) }
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        XCTAssertEqual(queue.jobs[0].state, .paused)
        let stops = worker.stops
        queue.cancel(queue.jobs[0].id)
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        XCTAssertEqual(queue.jobs[1].state, .queued)
        XCTAssertEqual(worker.stops, stops, "The paused file has already released the worker")
        XCTAssertFalse(queue.ownsWorker)
        worker.onChunk = nil
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        guard case .completed = queue.jobs[1].state else { return XCTFail("Next file must resume when live ends") }
    }

    func testShutdownWhileWindowInFlightCancelsUnfinishedJobsAndRemovesSnippets() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        worker.holdWindow = true
        worker.onChunk = { chunk in
            queue.receive(["segment": ["id": UUID().uuidString, "text": "Partial text", "stability": "final", "start_ms": chunk.startMs, "end_ms": 50]])
        }
        queue.add([try recording(root, name: "active.wav", seconds: 21), try recording(root, name: "pending.wav")])
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while worker.pendingWindow == nil && ContinuousClock.now < deadline { await Task.yield() }
        guard let pending = worker.pendingWindow else {
            worker.holdWindow = false
            await queue.shutdown()
            return XCTFail("Worker did not receive the first window")
        }
        let acknowledgement = Task { @MainActor in
            pending.resume()
            worker.pendingWindow = nil
        }
        // shutdown sets its flags on this actor before yielding to the acknowledgement task.
        await queue.shutdown()
        await acknowledgement.value
        XCTAssertFalse(queue.ownsWorker)
        XCTAssertEqual(queue.jobs.map(\.state), [.cancelled, .cancelled])
        XCTAssertEqual(worker.starts, [0])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "lautli").path).isEmpty)
    }

    func testShutdownOfPausedFileDoesNotTouchLiveWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FileWorkerStub()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        queue.add([try recording(root, seconds: 21)])
        worker.onChunk = { _ in queue.updateAvailability(workerReady: true, liveSessionActive: true) }
        queue.updateAvailability(workerReady: true, liveSessionActive: false)
        await drain(queue)
        let stops = worker.stops
        await queue.shutdown()
        XCTAssertEqual(queue.jobs[0].state, .cancelled)
        XCTAssertEqual(worker.stops, stops)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "lautli").path).isEmpty)
    }

    private func drain(_ queue: FileTranscriptionQueue) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if !queue.ownsWorker { return }
            await Task.yield()
        }
        XCTFail("Queue did not yield")
        await queue.shutdown()
    }
}

@MainActor
private final class FileWorkerStub: FileTranscriptionWorker {
    var starts: [Int64] = []
    var stops = 0
    var unavailable = false
    var holdWindow = false
    var pendingWindow: CheckedContinuation<Void, Never>?
    var onChunk: ((FileAudioChunk) -> Void)?
    func transcribeFileChunk(_ chunk: FileAudioChunk) async throws {
        if unavailable { throw FileTranscriptionError.workerUnavailable }
        starts.append(chunk.startMs)
        onChunk?(chunk)
        if holdWindow { await withCheckedContinuation { pendingWindow = $0 } }
    }
    func finishFileSession() async throws {
        if unavailable { throw FileTranscriptionError.workerUnavailable }
        stops += 1
    }
}
