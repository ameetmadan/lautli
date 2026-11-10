import AVFoundation
import XCTest
@testable import LautliApp

@MainActor
final class AudioFileDecoderTests: XCTestCase {
    private func scratchDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Writes at most one second at a time, including for the hour-long fixture.
    private func recording(
        at url: URL, sampleRate: Double, channels: AVAudioChannelCount,
        seconds: Double, aac: Bool = false, silent: Bool = false
    ) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        var settings: [String: Any] = aac ? [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: 128_000,
        ] : format.settings
        if !aac { settings[AVLinearPCMIsNonInterleaved] = false }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate)))
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(block.frameCapacity) {
                // Different stereo channels exercise downmixing, not just duplicated mono.
                block.floatChannelData![channel][frame] = silent ? 0 : Float(channel + 1) * 0.1
            }
        }
        var remaining = AVAudioFramePosition(seconds * sampleRate)
        while remaining > 0 {
            block.frameLength = AVAudioFrameCount(min(remaining, AVAudioFramePosition(block.frameCapacity)))
            try file.write(from: block)
            remaining -= AVAudioFramePosition(block.frameLength)
        }
    }

    func testNativeWAVRateAndChannelMatrixLeavesSourcesUnchanged() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(Double, AVAudioChannelCount)] = [
            (8_000, 1), (16_000, 1), (22_050, 2), (44_100, 2), (48_000, 2),
        ]
        for (rate, channels) in cases {
            let source = root.appending(path: "\(Int(rate))-\(channels).wav")
            try recording(at: source, sampleRate: rate, channels: channels, seconds: 1.25)
            let original = try Data(contentsOf: source)
            let decoder = try AudioFileDecoder(url: source)
            var frames = 0
            while let chunk = try await decoder.next() {
                XCTAssertEqual(chunk.startMs, Int64(frames) * 1_000 / 16_000)
                XCTAssertLessThanOrEqual(chunk.samples.count, 20 * 16_000)
                XCTAssertTrue(chunk.samples.allSatisfy(\.isFinite))
                XCTAssertEqual(chunk.samples[chunk.samples.count / 2], channels == 1 ? 0.1 : 0.15, accuracy: 0.005)
                frames += chunk.samples.count
            }
            let sourceFrames = Int(rate * 1.25)
            XCTAssertEqual(Double(frames), Double(sourceFrames) * 16_000 / rate, accuracy: 2, "\(rate) Hz, \(channels) channel(s)")
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testNativeM4AAACDecodesCompleteTimelineAndFinalTail() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "synthetic.m4a")
        try recording(at: source, sampleRate: 44_100, channels: 2, seconds: 21.25, aac: true)
        let original = try Data(contentsOf: source)
        let decoder = try AudioFileDecoder(url: source)
        var frames = 0
        var windows = 0
        while let chunk = try await decoder.next() {
            XCTAssertEqual(chunk.startMs, Int64(frames) * 1_000 / 16_000)
            XCTAssertLessThanOrEqual(chunk.samples.count, 20 * 16_000)
            XCTAssertTrue(chunk.samples.allSatisfy(\.isFinite))
            frames += chunk.samples.count
            windows += 1
        }
        XCTAssertEqual(windows, 2)
        // AAC packet framing can include padding; it must not lose the recording's tail.
        XCTAssertEqual(Double(frames) / 16_000, 21.25, accuracy: 0.05)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testSilentRecordingDecodesAllFramesWithoutInventingSignal() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "silent.wav")
        try recording(at: source, sampleRate: 48_000, channels: 2, seconds: 21.25, silent: true)
        let decoder = try AudioFileDecoder(url: source)
        var frames = 0
        while let chunk = try await decoder.next() {
            XCTAssertEqual(chunk.startMs, Int64(frames) * 1_000 / 16_000)
            XCTAssertTrue(chunk.samples.allSatisfy { abs($0) < 0.000_001 })
            frames += chunk.samples.count
        }
        XCTAssertEqual(frames, 340_000)
    }

    func testHourLongRecordingKeepsWindowsBoundedAndPreservesFinalTail() async throws {
        let root = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appending(path: "one-hour-plus-tail.wav")
        try recording(at: source, sampleRate: 16_000, channels: 1, seconds: 3_601.25)
        let decoder = try AudioFileDecoder(url: source)
        var frames: Int64 = 0
        var windows = 0
        var lastWindowCount = 0
        // Retain counters only; neither fixture generation nor verification materializes the file.
        while let chunk = try await decoder.next() {
            XCTAssertEqual(chunk.startMs, frames * 1_000 / 16_000)
            XCTAssertLessThanOrEqual(chunk.samples.count, 20 * 16_000)
            XCTAssertEqual(chunk.samples[chunk.samples.count / 2], 0.1, accuracy: 0.005)
            frames += Int64(chunk.samples.count)
            lastWindowCount = chunk.samples.count
            windows += 1
        }
        XCTAssertEqual(frames, 57_620_000)
        XCTAssertEqual(windows, 181)
        XCTAssertEqual(lastWindowCount, 20_000)
        let afterEOF = try await decoder.next()
        XCTAssertNil(afterEOF)
    }
}
