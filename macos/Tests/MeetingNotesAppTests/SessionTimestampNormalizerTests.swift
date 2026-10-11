import XCTest
@testable import MeetingNotesApp

final class SessionTimestampNormalizerTests: XCTestCase {
    func testCaptureTimestampsAreRelativeToFirstSampleAndMonotonicPerSource() {
        var normalizer = SessionTimestampNormalizer()
        XCTAssertEqual(normalizer.normalize(987_654_321, source: .meetingOutput), 0)
        XCTAssertEqual(normalizer.normalize(987_654_821, source: .meetingOutput), 500)
        XCTAssertEqual(normalizer.normalize(987_654_821, source: .meetingOutput), 501)
        XCTAssertEqual(normalizer.normalize(987_654_421, source: .microphone), 100)
    }
}

final class ResumedSessionTimestampTests: XCTestCase {
    func testResumedCaptureContinuesAfterTheOffset() {
        var normalizer = SessionTimestampNormalizer(offsetMs: 60_000)
        XCTAssertEqual(normalizer.normalize(5_000, source: .microphone), 60_000)
        XCTAssertEqual(normalizer.normalize(5_250, source: .microphone), 60_250)
    }
}
