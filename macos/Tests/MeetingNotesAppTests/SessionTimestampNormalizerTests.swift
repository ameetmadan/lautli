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
