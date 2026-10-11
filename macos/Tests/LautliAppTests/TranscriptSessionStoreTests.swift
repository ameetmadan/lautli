import Foundation
import XCTest
@testable import LautliApp

final class TranscriptSessionStoreTests: XCTestCase {
    func testFinalizedSegmentsAreMergedInTimestampOrderAndWorkingSnippetsAreRemoved() throws {
        let documents = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = try TranscriptSessionStore(documentsRoot: documents, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.append(.init(id: "second", startMs: 12_000, endMs: 13_000, text: "Zweite Aussage", source: "meetingOutput"))
        try store.append(.init(id: "first", startMs: 2_000, endMs: 3_000, text: "Erste Aussage", source: "meetingOutput"))
        try store.append(.init(id: "first", startMs: 2_000, endMs: 3_000, text: "Duplikat", source: "meetingOutput"))

        let output = try store.finalize()
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("[00:00:02] Erste Aussage"))
        XCTAssertTrue(text.contains("[00:00:12] Zweite Aussage"))
        XCTAssertFalse(text.contains("Duplikat"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "Erste Aussage")).lowerBound, try XCTUnwrap(text.range(of: "Zweite Aussage")).lowerBound)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: documents.appending(path: "lautli").path).count, 1)
    }
}
