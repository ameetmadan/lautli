import Foundation
import XCTest
@testable import LautliApp

final class SetupTests: XCTestCase {
    private func makePaths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let worker = root.appending(path: "worker-src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: worker, withIntermediateDirectories: true)
        try Data("torch==1\n".utf8).write(to: worker.appending(path: "requirements.txt"))
        return AppPaths(support: root.appending(path: "support", directoryHint: .isDirectory), workerSource: worker)
    }

    private func installFakePython(_ paths: AppPaths) throws {
        try FileManager.default.createDirectory(at: paths.python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: paths.python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.python.path)
    }

    func testFreshInstallNeedsEveryStep() throws {
        XCTAssertEqual(SetupMarkers(paths: try makePaths()).pending, SetupStep.allCases)
    }

    func testCompletedStepsAreSkippedAndEverythingAfterAChangedStepRepeats() throws {
        let paths = try makePaths()
        let markers = SetupMarkers(paths: paths)
        try installFakePython(paths)
        try markers.markComplete(.python)
        XCTAssertEqual(markers.pending, [.dependencies, .model])
        try markers.markComplete(.dependencies)
        try FileManager.default.createDirectory(at: paths.modelDirectory, withIntermediateDirectories: true)
        try Data().write(to: paths.modelDirectory.appending(path: "model.safetensors"))
        try markers.markComplete(.model)
        XCTAssertTrue(markers.pending.isEmpty)

        try Data("torch==2\n".utf8).write(to: paths.requirements)
        XCTAssertEqual(markers.pending, [.dependencies, .model])
    }

    func testMarkerWithoutInstalledPythonDoesNotCount() throws {
        let paths = try makePaths()
        let markers = SetupMarkers(paths: paths)
        try markers.markComplete(.python)
        XCTAssertEqual(markers.pending, SetupStep.allCases)
    }

    func testDownloaderProgressLinesParse() {
        XCTAssertEqual(SetupEvent(line: #"{"type":"progress","bytes":50,"total":200}"#), .progress(0.25))
        XCTAssertEqual(SetupEvent(line: #"{"type":"verifying"}"#), .verifying)
        XCTAssertEqual(SetupEvent(line: #"{"type":"failed","message":"offline"}"#), .failed("offline"))
        XCTAssertNil(SetupEvent(line: "Downloading https://example.test"))
        XCTAssertNil(SetupEvent(line: #"{"type":"progress","bytes":1,"total":0}"#))
    }

    func testSHA256MatchesKnownDigest() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try SetupManager.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
