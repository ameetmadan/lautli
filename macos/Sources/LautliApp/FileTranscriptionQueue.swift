import Foundation

@MainActor
protocol FileTranscriptionWorker: AnyObject {
    func transcribeFileChunk(_ chunk: FileAudioChunk) async throws
    func finishFileSession() async throws
}

struct FileTranscriptionJob: Identifiable {
    enum State: Equatable {
        case queued, processing, paused, completed(URL), failed(String), cancelled
    }
    let id = UUID()
    let source: URL
    var state: State = .queued
    var progress: Double = 0
}

/// Owns file decoding, persistence and the worker until the current window has finished.
@MainActor
final class FileTranscriptionQueue: ObservableObject {
    @Published private(set) var jobs: [FileTranscriptionJob] = []
    private(set) var ownsWorker = false
    var onYield: (() -> Void)?
    private let worker: any FileTranscriptionWorker
    private let documentsRoot: URL
    private var liveSessionActive = false
    private var workerReady = false
    private var shuttingDown = false
    private var task: Task<Void, Never>?
    private var decoder: AudioFileDecoder?
    private var store: TranscriptSessionStore?
    private var activeID: UUID?
    private var cancellationRequested = false
    private var segmentError: Error?

    init(worker: any FileTranscriptionWorker, documentsRoot: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.worker = worker
        self.documentsRoot = documentsRoot
    }

    func add(_ urls: [URL]) {
        jobs.append(contentsOf: urls.map { FileTranscriptionJob(source: $0) })
        startIfPossible()
    }

    func updateAvailability(workerReady: Bool, liveSessionActive: Bool) {
        self.workerReady = workerReady
        self.liveSessionActive = liveSessionActive
        startIfPossible()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if activeID == id {
            cancellationRequested = true
            if task == nil {
                store?.discard()
                clearActive()
                jobs[index].state = .cancelled
                startIfPossible()
            }
        } else if jobs[index].state == .queued { jobs.remove(at: index) }
    }

    func retry(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), case .failed = jobs[index].state else { return }
        jobs[index].state = .queued
        jobs[index].progress = 0
        startIfPossible()
    }

    func receive(_ message: [String: Any]) {
        guard ownsWorker, let value = message["segment"] as? [String: Any],
              value["stability"] as? String == "final",
              let id = value["id"] as? String, let text = value["text"] as? String,
              let start = value["start_ms"] as? Int64, let end = value["end_ms"] as? Int64 else { return }
        do { try store?.append(.init(id: id, startMs: start, endMs: end, text: text, source: value["source"] as? String)) }
        catch { segmentError = error }
    }

    private func startIfPossible() {
        guard task == nil, workerReady, !liveSessionActive, !shuttingDown,
              activeID != nil || jobs.contains(where: { $0.state == .queued }) else { return }
        // Reserve synchronously so capture cannot start before the task runs.
        ownsWorker = true
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !liveSessionActive && !shuttingDown && workerReady {
            guard let index = jobs.firstIndex(where: { $0.id == activeID || (activeID == nil && $0.state == .queued) }) else { break }
            let id = jobs[index].id
            let source = jobs[index].source
            do {
                if activeID == nil {
                    activeID = id
                    decoder = try AudioFileDecoder(url: source)
                    store = try TranscriptSessionStore(documentsRoot: documentsRoot, sourceFilename: source.lastPathComponent)
                }
                updateJob(id) { $0.state = .processing }
                guard let decoder else { throw FileTranscriptionError.unreadable }
                if let chunk = try await decoder.next() {
                    // Finish an already-read chunk before yielding, so resume cannot skip audio.
                    try await worker.transcribeFileChunk(chunk)
                    if let segmentError { throw segmentError }
                    let processed = Double(chunk.startMs) / 1_000 + Double(chunk.samples.count) / 16_000
                    updateJob(id) { $0.progress = min(1, processed / decoder.duration) }
                } else {
                    try await worker.finishFileSession()
                    if cancellationRequested {
                        store?.discard()
                        updateJob(id) { $0.state = .cancelled }
                    } else if let url = try store?.finalize() {
                        updateJob(id) { $0.state = .completed(url); $0.progress = 1 }
                    }
                    clearActive()
                    continue
                }
                if cancellationRequested {
                    try await worker.finishFileSession()
                    store?.discard()
                    updateJob(id) { $0.state = .cancelled }
                    clearActive()
                }
            } catch {
                // Keep snippets on disk for recovery if decoding, inference or storage fails.
                try? await worker.finishFileSession()
                let message = (error as? FileTranscriptionError)?.localizedDescription
                    ?? tr("File transcription failed. Saved snippets remain in Documents/lautli. Retry the file after checking its format and the worker.")
                updateJob(id) { $0.state = .failed(message) }
                clearActive()
                if let failure = error as? FileTranscriptionError, case .workerUnavailable = failure {
                    workerReady = false
                }
                if !workerReady { break }
            }
        }
        if let id = activeID {
            do {
                try await worker.finishFileSession()
                if cancellationRequested {
                    store?.discard()
                    updateJob(id) { $0.state = .cancelled }
                    clearActive()
                } else { updateJob(id) { $0.state = .paused } }
            } catch {
                updateJob(id) { $0.state = .failed(tr("The transcription worker is unavailable. Restart it and retry the file.")) }
                clearActive()
            }
        }
        ownsWorker = false
        task = nil
        onYield?()
        startIfPossible()
    }

    private func updateJob(_ id: UUID, _ update: (inout FileTranscriptionJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        update(&jobs[index])
    }

    private func clearActive() {
        activeID = nil
        decoder = nil
        store = nil
        cancellationRequested = false
        segmentError = nil
    }

    func shutdown() async {
        shuttingDown = true
        cancellationRequested = true
        await task?.value
        store?.discard()
        clearActive()
    }
}
