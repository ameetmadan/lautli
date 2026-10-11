import Foundation
import XCTest
@testable import MeetingNotesApp

/// Downloads about 4 GB. Run with MEETING_NOTES_E2E=1 (optionally MEETING_NOTES_E2E_DIR to reuse a directory between runs).
@MainActor
final class SetupEndToEndTests: XCTestCase {
    func testFreshMacReachesWorkerReady() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEETING_NOTES_E2E"] != nil else { throw XCTSkip("set MEETING_NOTES_E2E=1 to run the network test") }
        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let support = environment["MEETING_NOTES_E2E_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "mn-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = AppPaths(support: support, workerSource: repoRoot)

        let setup = SetupManager(paths: paths)
        setup.start()
        let deadline = Date().addingTimeInterval(45 * 60)
        while !setup.isReady, Date() < deadline {
            if case .failed(let message) = setup.state { return XCTFail(message) }
            try await Task.sleep(for: .seconds(2))
        }
        XCTAssertTrue(setup.isReady)

        let worker = WorkerClient()
        worker.start(paths: paths)
        while worker.state != .ready, Date() < deadline {
            if case .failed(let message) = worker.state { return XCTFail(message) }
            try await Task.sleep(for: .seconds(1))
        }
        XCTAssertEqual(worker.state, .ready)
        worker.terminate()
    }
}
