import XCTest
@testable import LautliApp

final class AudioBufferTests: XCTestCase {
    func testBufferNeverExceedsLimitAndDoesNotDiscardUnprocessedSamples() {
        let buffer = BoundedAudioBuffer(maxFrames: 5)
        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .meetingOutput, startTimestampMs: 0, samples: [1, 2, 3, 4])),
            .accepted
        )
        XCTAssertEqual(buffer.bufferedFrameCount, 4)
        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .meetingOutput, startTimestampMs: 250, samples: [5, 6])),
            .capacityExceeded
        )
        XCTAssertEqual(buffer.bufferedFrameCount, 4)
        XCTAssertEqual(buffer.drain(maxFrames: 5).flatMap(\.samples), [1, 2, 3, 4])
    }

    func testBufferPreservesSourceAndMonotonicTimestamps() {
        let buffer = BoundedAudioBuffer(maxFrames: 8)
        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .microphone, startTimestampMs: 100, samples: [1, 2])),
            .accepted
        )
        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .microphone, startTimestampMs: 200, samples: [3])),
            .accepted
        )
        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .microphone, startTimestampMs: 150, samples: [4])),
            .nonMonotonicTimestamp
        )

        let frames = buffer.drain(maxFrames: 8)
        XCTAssertEqual(frames.map(\.startTimestampMs), [100, 200])
        XCTAssertTrue(frames.allSatisfy { $0.source == .microphone })
    }

    func testPauseClearDropsOnlyBufferedSamples() {
        let buffer = BoundedAudioBuffer(maxFrames: 8)
        _ = buffer.append(AudioBufferFrame(source: .meetingOutput, startTimestampMs: 0, samples: [1, 2]))
        buffer.clear()
        XCTAssertEqual(buffer.bufferedFrameCount, 0)
        XCTAssertEqual(buffer.drain(maxFrames: 8), [])
    }

    func testNewSessionCanRestartTimestampsAfterPreviousFramesWereDrained() {
        let buffer = BoundedAudioBuffer(maxFrames: 8)
        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .meetingOutput, startTimestampMs: 12_000, samples: [1, 2])),
            .accepted
        )
        _ = buffer.drain(maxFrames: 8)

        buffer.clear()

        XCTAssertEqual(
            buffer.append(AudioBufferFrame(source: .meetingOutput, startTimestampMs: 0, samples: [3, 4])),
            .accepted
        )
    }
}
