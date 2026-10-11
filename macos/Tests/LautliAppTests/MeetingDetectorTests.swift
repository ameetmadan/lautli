import XCTest
@testable import LautliApp

final class MeetingDetectorTests: XCTestCase {
    func testIdleAppDoesNotStartCapture() {
        var detector = MeetingDetector()
        let observation = MeetingObservation(
            app: .zoom,
            meetingControlsVisible: false,
            audioOutputActive: false,
            accessibilityAvailable: true,
            timestamp: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(detector.update(observation), .idle)
    }

    func testMeetingRequiresStableControlsAndAudioBeforeCapture() {
        var detector = MeetingDetector()
        let start = Date(timeIntervalSince1970: 0)
        let first = MeetingObservation(
            app: .teams,
            meetingControlsVisible: true,
            audioOutputActive: true,
            accessibilityAvailable: true,
            timestamp: start
        )
        let second = MeetingObservation(
            app: .teams,
            meetingControlsVisible: true,
            audioOutputActive: true,
            accessibilityAvailable: true,
            timestamp: start.addingTimeInterval(3)
        )
        let third = MeetingObservation(
            app: .teams,
            meetingControlsVisible: true,
            audioOutputActive: true,
            accessibilityAvailable: true,
            timestamp: start.addingTimeInterval(6)
        )

        XCTAssertEqual(detector.update(first), .candidate(.teams))
        XCTAssertEqual(detector.update(second), .candidate(.teams))
        XCTAssertEqual(detector.update(third), .capturing(.teams))
    }

    func testMuteOrSilenceDoesNotStopMeetingWhileControlsRemainVisible() {
        var detector = MeetingDetector()
        let start = Date(timeIntervalSince1970: 0)
        for offset in [0.0, 3.0, 6.0] {
            _ = detector.update(
                MeetingObservation(
                    app: .zoom,
                    meetingControlsVisible: true,
                    audioOutputActive: true,
                    accessibilityAvailable: true,
                    timestamp: start.addingTimeInterval(offset)
                )
            )
        }

        let muted = MeetingObservation(
            app: .zoom,
            meetingControlsVisible: true,
            audioOutputActive: false,
            accessibilityAvailable: true,
            timestamp: start.addingTimeInterval(9)
        )
        XCTAssertEqual(detector.update(muted), .capturing(.zoom))
    }

    func testMissingAccessibilityNeverAutoStarts() {
        var detector = MeetingDetector()
        let start = Date(timeIntervalSince1970: 0)
        for offset in [0.0, 3.0, 6.0, 9.0] {
            let state = detector.update(
                MeetingObservation(
                    app: .zoom,
                    meetingControlsVisible: true,
                    audioOutputActive: true,
                    accessibilityAvailable: false,
                    timestamp: start.addingTimeInterval(offset)
                )
            )
            XCTAssertEqual(state, .idle)
        }
    }

    func testLeavingMeetingStopsAfterTenMissingObservations() {
        var detector = MeetingDetector()
        let start = Date(timeIntervalSince1970: 0)
        for offset in [0.0, 3.0, 6.0] {
            _ = detector.update(
                MeetingObservation(
                    app: .zoom,
                    meetingControlsVisible: true,
                    audioOutputActive: true,
                    accessibilityAvailable: true,
                    timestamp: start.addingTimeInterval(offset)
                )
            )
        }
        for sample in 1...9 {
            let state = detector.update(
                MeetingObservation(
                    app: .zoom,
                    meetingControlsVisible: false,
                    audioOutputActive: false,
                    accessibilityAvailable: true,
                    timestamp: start.addingTimeInterval(Double(sample) * 3 + 6)
                )
            )
            XCTAssertEqual(state, .capturing(.zoom))
        }
        let finalState = detector.update(
            MeetingObservation(
                app: .zoom,
                meetingControlsVisible: false,
                audioOutputActive: false,
                accessibilityAvailable: true,
                timestamp: start.addingTimeInterval(36)
            )
        )
        XCTAssertEqual(finalState, .idle)
    }
}
