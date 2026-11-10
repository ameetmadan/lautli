import AVFoundation
import XCTest
@testable import LautliApp

/// Uses only generated speech and an already-installed runtime/model. Never downloads a model.
@MainActor
final class FileTranscriptionEndToEndTests: XCTestCase {
    func testInstalledWorkerTranscribesSyntheticBatchAndMcpReadsOutputs() async throws {
        guard ProcessInfo.processInfo.environment["LAUTLI_FILE_E2E"] == "1" else {
            throw XCTSkip("set LAUTLI_FILE_E2E=1 to use the installed runtime/model with generated speech")
        }
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let installed = AppPaths.standard
        guard FileManager.default.isExecutableFile(atPath: installed.python.path),
              FileManager.default.fileExists(atPath: installed.modelDirectory.appending(path: "config.json").path) else {
            throw XCTSkip("An installed lautli runtime and model are required; no downloads are performed")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppPaths(support: root.appending(path: "support"), workerSource: repository)
        try FileManager.default.createDirectory(at: paths.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.modelDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.python, withDestinationURL: installed.python)
        try FileManager.default.createSymbolicLink(at: paths.modelDirectory, withDestinationURL: installed.modelDirectory)
        var sources: [URL] = []
        for index in 1...3 {
            let source = root.appending(path: "synthetic-\(index).aiff")
            try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/say"), arguments: [
                "-v", "Anna", "-o", source.path,
                "Guten Morgen. Wir besprechen heute den Projektplan. Anna sendet das Angebot am Freitag. Vielen Dank.",
            ], onLine: { _ in })
            sources.append(source)
        }
        let originals = try sources.map { try Data(contentsOf: $0) }
        let silent = root.appending(path: "silence.wav")
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            let file = try AVAudioFile(forWriting: silent, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
            buffer.frameLength = 16_000
            for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0 }
            try file.write(from: buffer)
        }
        let corrupt = root.appending(path: "corrupt.wav")
        try Data("not an audio recording".utf8).write(to: corrupt)
        let worker = WorkerClient()
        let queue = FileTranscriptionQueue(worker: worker, documentsRoot: root)
        defer { worker.terminate() }
        worker.onSegment = { queue.receive($0) }
        worker.start(paths: paths)
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(180))
        while worker.state == .starting && ContinuousClock.now < loadDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(worker.state, .ready)
        queue.add([corrupt] + sources + [silent])
        queue.updateAvailability(workerReady: worker.state == .ready, liveSessionActive: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        while queue.ownsWorker && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard !queue.ownsWorker else {
            worker.terminate()
            await queue.shutdown()
            return XCTFail("Synthetic batch timed out")
        }
        guard case .failed(let message) = queue.jobs[0].state else { return XCTFail("Corrupt input must fail") }
        XCTAssertEqual(message, FileTranscriptionError.unreadable.localizedDescription)
        for job in queue.jobs.dropFirst() {
            guard case .completed(let url) = job.state else { return XCTFail("Readable recordings must finish") }
            let markdown = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(markdown.contains(job.source.lastPathComponent))
            if job.source == silent { XCTAssertFalse(markdown.contains("- [")) }
            else { XCTAssertTrue(markdown.contains("- ["), "The real recognizer must produce speech segments") }
        }
        for (source, original) in zip(sources, originals) { XCTAssertEqual(try Data(contentsOf: source), original) }
        // Exercise the real MCP server over JSON-RPC stdio against the Swift-generated files.
        let script = #"""
        import json, os, subprocess, sys
        folder, server = sys.argv[1:]
        def call(name, arguments=None):
            request = {"jsonrpc":"2.0", "id":1, "method":"tools/call", "params":{"name":name, "arguments":arguments or {}}}
            result = subprocess.run([sys.executable, server], input=json.dumps(request)+"\n", text=True, capture_output=True,
                                    env={**os.environ, "LAUTLI_TRANSCRIPT_DIR":folder}, timeout=20, check=True)
            value = json.loads(result.stdout)["result"]
            assert not value["isError"]
            return value["content"][0]["text"]
        meetings = json.loads(call("list_meetings"))
        assert len(meetings) == 4
        assert all(not item["has_notes"] for item in meetings)
        for item in meetings:
            document = call("get_transcript", {"id":item["id"]})
            assert "Quelldatei: " in document and "<untrusted-meeting-content>" in document
        assert "synthetic-1.aiff" in call("search_meetings", {"query":"synthetic-1.aiff"})
        """#
        try await ProcessRunner.run(paths.python, arguments: ["-c", script, root.appending(path: "lautli").path, repository.appending(path: "worker/lautli_worker/mcp_server.py").path], onLine: { _ in })
        let logFiles = try FileManager.default.contentsOfDirectory(at: paths.logs, includingPropertiesForKeys: nil)
        for log in logFiles {
            let contents = try String(contentsOf: log, encoding: .utf8)
            XCTAssertFalse(contents.contains("Guten Morgen"))
            XCTAssertFalse(contents.contains("synthetic-1.aiff"))
        }
        await queue.shutdown()
    }
}
