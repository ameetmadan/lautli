import AVFoundation

struct FileAudioChunk: Sendable {
    let samples: [Float]
    let startMs: Int64
}

/// Keeps only the converter's input buffer and one output window in memory.
actor AudioFileDecoder {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private var outputFrames: Int64 = 0
    private var ended = false
    let duration: Double

    init(url: URL) throws {
        do { file = try AVAudioFile(forReading: url) }
        catch { throw FileTranscriptionError.unreadable }
        guard file.length > 0,
              file.processingFormat.sampleRate > 0,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
            throw FileTranscriptionError.unreadable
        }
        converter.downmix = true
        self.converter = converter
        outputFormat = format
        duration = Double(file.length) / file.processingFormat.sampleRate
    }

    func next() throws -> FileAudioChunk? {
        guard !ended else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 20 * 16_000) else {
            throw FileTranscriptionError.unreadable
        }
        var readError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { [file] count, inputStatus in
            if file.framePosition >= file.length {
                inputStatus.pointee = .endOfStream
                return nil
            }
            guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(count, 65_536)) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            do {
                try file.read(into: input)
                inputStatus.pointee = .haveData
                return input
            } catch {
                readError = error
                inputStatus.pointee = .endOfStream
                return nil
            }
        }
        if readError != nil || conversionError != nil || status == .error { throw FileTranscriptionError.unreadable }
        if status == .endOfStream { ended = true }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            if ended { return nil }
            throw FileTranscriptionError.unreadable
        }
        let chunk = FileAudioChunk(samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))), startMs: outputFrames * 1_000 / 16_000)
        outputFrames += Int64(output.frameLength)
        return chunk
    }
}

enum FileTranscriptionError: LocalizedError {
    case unreadable, workerUnavailable
    var errorDescription: String? {
        switch self {
        case .unreadable: tr("Could not decode this audio file. Try a readable WAV, M4A or MP3 recording.")
        case .workerUnavailable: tr("The transcription worker is unavailable. Restart it and retry the file.")
        }
    }
}
