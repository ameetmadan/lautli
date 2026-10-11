import AVFoundation
import CoreMedia
import ScreenCaptureKit

private final class SampleBufferBox: @unchecked Sendable {
    let value: CMSampleBuffer
    init(_ value: CMSampleBuffer) { self.value = value }
}

@MainActor
final class AudioCapture: NSObject, ObservableObject {
    enum State: Equatable {
        case stopped
        case capturing
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    let buffer = BoundedAudioBuffer(maxFrames: 30 * 16_000)
    var onSamples: ((AudioSource, Int64, [Float]) -> Void)?
    private(set) var activeBundleIdentifier: String?
    private var stream: SCStream?
    private var lastTimestampBySource: [AudioSource: Int64] = [:]

    func start(bundleIdentifier: String, captureMicrophone: Bool = true) async {
        if activeBundleIdentifier == bundleIdentifier, state == .capturing { return }
        if stream != nil { await stop() }
        guard stream == nil else { return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.owningApplication?.bundleIdentifier == bundleIdentifier }) else {
                state = .failed("No shareable meeting window. Check Screen Recording permission.")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.capturesAudio = true
            configuration.captureMicrophone = captureMicrophone
            configuration.sampleRate = 16_000
            configuration.channelCount = 1
            configuration.excludesCurrentProcessAudio = true
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.meeting.output"))
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "audio.meeting.microphone"))
            self.stream = stream
            try await stream.startCapture()
            activeBundleIdentifier = bundleIdentifier
            state = .capturing
        } catch {
            state = .failed("Audio capture could not start: \(error.localizedDescription)")
            await stop()
        }
    }

    func stop() async {
        guard let stream else { state = .stopped; return }
        self.stream = nil
        activeBundleIdentifier = nil
        do { try await stream.stopCapture() }
        catch { state = .failed("Audio capture did not stop cleanly: \(error.localizedDescription)"); return }
        if case .failed = state { return }
        state = .stopped
    }

    private func receive(_ sampleBuffer: CMSampleBuffer, source: AudioSource) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let list = copyAudioBufferList(sampleBuffer) else { return }
        var inputDescription = asbd
        guard let inputFormat = AVAudioFormat(streamDescription: &inputDescription),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, bufferListNoCopy: UnsafePointer(list), deallocator: nil)
        else {
            list.deallocate()
            state = .failed("Meeting audio format could not be decoded.")
            Task { await stop() }
            return
        }
        inputBuffer.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(inputBuffer.frameLength) * 16_000 / asbd.mSampleRate + 1))
        else {
            list.deallocate()
            state = .failed("Audio resampling could not be initialized.")
            Task { await stop() }
            return
        }
        var suppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            guard !suppliedInput else { status.pointee = .noDataNow; return nil }
            suppliedInput = true
            status.pointee = .haveData
            return inputBuffer
        }
        list.deallocate()
        guard conversionStatus != .error, outputBuffer.frameLength > 0, let channelData = outputBuffer.floatChannelData?[0] else {
            state = .failed("Audio could not be converted to 16 kHz mono PCM.")
            Task { await stop() }
            return
        }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isNumeric else {
            state = .failed("Audio timestamps were unavailable; capture stopped to protect ordering.")
            Task { await stop() }
            return
        }
        let timestamp = Int64(presentationTime.seconds * 1_000)
        let start = max(timestamp, lastTimestampBySource[source].map { $0 + 1 } ?? 0)
        let result = buffer.append(AudioBufferFrame(source: source, startTimestampMs: start, samples: samples))
        switch result {
        case .accepted:
            lastTimestampBySource[source] = start
            onSamples?(source, start, samples)
            _ = buffer.drain(maxFrames: samples.count)
        case .capacityExceeded:
            state = .failed("Audio buffer reached 30 seconds. Capture stopped so no speech is silently discarded.")
            Task { await stop() }
        case .nonMonotonicTimestamp:
            state = .failed("Audio timestamps moved backwards. Capture stopped to protect transcript order.")
            Task { await stop() }
        }
    }

    private func copyAudioBufferList(_ sampleBuffer: CMSampleBuffer) -> UnsafeMutablePointer<AudioBufferList>? {
        var needed = 0
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &needed, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &blockBuffer
        )
        guard status == noErr, needed > 0 else { return nil }
        let allocationCount = (needed + MemoryLayout<AudioBufferList>.stride - 1) / MemoryLayout<AudioBufferList>.stride
        let storage = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: allocationCount)
        let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: storage,
            bufferListSize: needed, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &blockBuffer
        )
        guard result == noErr else { storage.deallocate(); return nil }
        return storage
    }
}

extension AudioCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let source: AudioSource
        switch type {
        case .audio: source = .meetingOutput
        case .microphone: source = .microphone
        case .screen: return
        @unknown default: return
        }
        let box = SampleBufferBox(sampleBuffer)
        Task { @MainActor in receive(box.value, source: source) }
    }
}

extension AudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in state = .failed("ScreenCaptureKit stopped: \(error.localizedDescription)") }
    }
}
