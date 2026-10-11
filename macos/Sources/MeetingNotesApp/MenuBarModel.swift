import AppKit
import Combine
import ServiceManagement
import SwiftUI

struct RunningApp: Identifiable, Equatable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

enum MenuState: Equatable {
    case settingUp, loadingModel, idle, listening, paused, error(String)

    var symbol: String {
        switch self {
        case .settingUp, .loadingModel: "arrow.down.circle"
        case .idle: "waveform"
        case .listening: "waveform.circle.fill"
        case .paused: "pause.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    var accessibilityName: String {
        switch self {
        case .settingUp: "Setting up"
        case .loadingModel: "Loading model"
        case .idle: "Idle"
        case .listening: "Listening"
        case .paused: "Paused"
        case .error: "Problem"
        }
    }
}

enum NotesStatus: Equatable {
    case idle, generating, ready(URL), failed(String)
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var automaticStartEnabled = true
    @Published var manuallyListening = false
    @Published var transcriptLines: [String] = []
    @Published private(set) var savedTranscriptURL: URL?
    @Published private(set) var notesStatus: NotesStatus = .idle
    @Published private(set) var storageError: String?
    @Published private(set) var captureError: String?
    @Published private(set) var isPaused = false
    @Published fileprivate var captureSuppressed = false
    @Published private(set) var browserTestBundleIdentifier: String?
    @Published private(set) var manualApp: RunningApp?
    @Published var recordingNoticeAcknowledged = UserDefaults.standard.bool(forKey: "recordingNoticeAcknowledged") {
        didSet { UserDefaults.standard.set(recordingNoticeAcknowledged, forKey: "recordingNoticeAcknowledged") }
    }
    @Published var onboardingCompleted = UserDefaults.standard.bool(forKey: "onboardingCompleted") {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: "onboardingCompleted") }
    }
    let monitor = MeetingMonitor()
    let audioCapture = AudioCapture()
    let worker = WorkerClient()
    let setup = SetupManager()
    let permissions = PermissionsModel()
    private var subscriptions: [AnyCancellable] = []
    private var sessionStore: TranscriptSessionStore?
    private var sessionStartedAt = Date()
    private var sessionEndMs: Int64 = 0
    private var resumeOffsetMs: Int64 = 0
    private var resumingSession = false
    private var isStartingCapture = false
    private var isStoppingCapture = false
    private var isShuttingDown = false
    private var startTask: Task<Void, Never>?
    private var notesTask: Task<Void, Never>?
    private var stopCompletions: [() -> Void] = []

    init() {
        audioCapture.onSamples = { [weak worker] source, timestamp, samples in
            worker?.appendAudio(source: source, samples: samples, startMs: timestamp)
        }
        worker.onSegment = { [weak self] message in
            guard let segment = message["segment"] as? [String: Any],
                  segment["stability"] as? String == "final",
                  let id = segment["id"] as? String,
                  let text = segment["text"] as? String,
                  let startMs = segment["start_ms"] as? Int64,
                  let endMs = segment["end_ms"] as? Int64 else { return }
            guard let self else { return }
            self.transcriptLines.append(text)
            self.sessionEndMs = max(self.sessionEndMs, endMs)
            do {
                try self.sessionStore?.append(.init(id: id, startMs: startMs, endMs: endMs, text: text, source: segment["source"] as? String))
            } catch {
                self.storageError = "Could not save transcript snippets: \(error.localizedDescription)"
            }
        }
        // Views read nested models through this one, so their changes must invalidate it too.
        subscriptions = [
            monitor.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            audioCapture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            worker.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            setup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            permissions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            monitor.$activeMeetingBundleIdentifier.removeDuplicates().sink { [weak self] bundleIdentifier in
                Task { @MainActor in self?.updateCapture(for: bundleIdentifier) }
            },
            worker.$state.removeDuplicates().sink { [weak self] _ in
                Task { @MainActor in self?.updateCapture(for: self?.monitor.activeMeetingBundleIdentifier) }
            },
            setup.$state.removeDuplicates().sink { [weak self] state in
                Task { @MainActor in
                    guard state == .ready, self?.worker.state == .stopped else { return }
                    self?.worker.start()
                }
            },
            audioCapture.$state.removeDuplicates().sink { [weak self] state in
                guard case .failed(let message) = state else { return }
                Task { @MainActor in self?.handleCaptureFailure(message) }
            },
        ]
        monitor.start()
        if onboardingCompleted { setup.start() }
        if setup.isReady { worker.start() }
    }

    private var consentRequired: Bool { !recordingNoticeAcknowledged }

    private var selectedBundleIdentifier: String? {
        browserTestBundleIdentifier ?? manualApp?.bundleIdentifier ?? monitor.activeMeetingBundleIdentifier
    }

    func updateCapture(for bundleIdentifier: String?) {
        guard !isShuttingDown else { return }
        let selectedBundleIdentifier = browserTestBundleIdentifier ?? manualApp?.bundleIdentifier ?? bundleIdentifier
        if selectedBundleIdentifier == nil {
            captureSuppressed = false
            isPaused = false
        }
        let isBrowserTest = browserTestBundleIdentifier != nil
        let isManual = manualApp != nil
        let wantsCapture = isBrowserTest || isManual || automaticStartEnabled || manuallyListening
        let canStart = !captureSuppressed && !isPaused && !consentRequired && wantsCapture
        if let selectedBundleIdentifier, canStart, worker.state == .ready {
            if audioCapture.state == .capturing, audioCapture.activeBundleIdentifier == selectedBundleIdentifier { return }
            if audioCapture.state == .capturing || isStoppingCapture {
                finishCapture { [weak self] in self?.updateCapture(for: self?.monitor.activeMeetingBundleIdentifier) }
                return
            }
            guard !isStartingCapture else { return }
            if sessionStore != nil, !resumingSession {
                finishCapture { [weak self] in self?.updateCapture(for: self?.monitor.activeMeetingBundleIdentifier) }
                return
            }
            isStartingCapture = true
            if sessionStore == nil {
                do {
                    sessionStore = try TranscriptSessionStore()
                    sessionStartedAt = Date()
                    sessionEndMs = 0
                    resumeOffsetMs = 0
                    storageError = nil
                    transcriptLines.removeAll()
                } catch {
                    storageError = "Could not create a transcript in Documents: \(error.localizedDescription)"
                    isStartingCapture = false
                    return
                }
            }
            captureError = nil
            let offset = resumeOffsetMs
            startTask = Task { [weak self] in
                guard let self else { return }
                await self.audioCapture.start(bundleIdentifier: selectedBundleIdentifier, captureMicrophone: !isBrowserTest, startOffsetMs: offset)
                self.isStartingCapture = false
                self.startTask = nil
                if self.audioCapture.state != .capturing {
                    if self.resumingSession {
                        self.isPaused = true
                    } else {
                        self.sessionStore?.discard()
                        self.sessionStore = nil
                    }
                } else if !self.isShuttingDown {
                    self.resumingSession = false
                    self.updateCapture(for: self.monitor.activeMeetingBundleIdentifier)
                }
            }
        } else if selectedBundleIdentifier == nil || (!canStart && !isPaused) || isWorkerFailed {
            if !isStartingCapture && (audioCapture.state == .capturing || sessionStore != nil) { finishCapture() }
        }
    }

    private func handleCaptureFailure(_ message: String) {
        guard !isShuttingDown else { return }
        captureError = message
        AppLog.write("capture failed: \(message)")
        browserTestBundleIdentifier = nil
        manualApp = nil
        isPaused = false
        resumingSession = false
        if sessionStore != nil, !isStartingCapture { finishCapture() }
    }

    func dismissError() {
        captureError = nil
        storageError = nil
        if case .failed = audioCapture.state { Task { await audioCapture.stop() } }
    }

    // MARK: Choosing what to listen to

    var runningBrowsers: [RunningApp] {
        let supported: [String: String] = [
            "com.apple.Safari": "Safari",
            "com.google.Chrome": "Google Chrome",
            "org.mozilla.firefox": "Firefox",
            "com.microsoft.edgemac": "Microsoft Edge",
            "com.brave.Browser": "Brave",
            "company.thebrowser.Browser": "Arc",
        ]
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard let bundleIdentifier = application.bundleIdentifier,
                  let name = supported[bundleIdentifier] else { return nil }
            return RunningApp(bundleIdentifier: bundleIdentifier, name: name)
        }
    }

    /// Fallback for when automatic detection misses a call: any visible app can be chosen by hand.
    var listenableApps: [RunningApp] {
        let own = Bundle.main.bundleIdentifier
        let apps = NSWorkspace.shared.runningApplications.compactMap { application -> RunningApp? in
            guard application.activationPolicy == .regular, let id = application.bundleIdentifier, id != own,
                  let name = application.localizedName else { return nil }
            return RunningApp(bundleIdentifier: id, name: name)
        }
        let preferred = ["us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams"]
        return apps.sorted { lhs, rhs in
            let l = preferred.contains(lhs.bundleIdentifier), r = preferred.contains(rhs.bundleIdentifier)
            return l != r ? l : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func startBrowserTest(bundleIdentifier: String) {
        browserTestBundleIdentifier = bundleIdentifier
        captureSuppressed = false
        transcriptLines.removeAll()
        updateCapture(for: monitor.activeMeetingBundleIdentifier)
    }

    func stopBrowserTest() {
        browserTestBundleIdentifier = nil
        captureSuppressed = true
        finishCapture { [weak self] in
            self?.captureSuppressed = false
            self?.updateCapture(for: self?.monitor.activeMeetingBundleIdentifier)
        }
    }

    func listen(to app: RunningApp) {
        manualApp = app
        captureSuppressed = false
        isPaused = false
        updateCapture(for: monitor.activeMeetingBundleIdentifier)
    }

    // MARK: Pause, resume, stop

    var isCapturing: Bool { audioCapture.state == .capturing }

    func pause() {
        guard isCapturing, !isPaused, !isStoppingCapture else { return }
        isPaused = true
        Task { [weak self] in
            guard let self else { return }
            await audioCapture.stop()
            worker.stop()
        }
    }

    func resume() {
        guard isPaused else { return }
        resumeOffsetMs = sessionEndMs + 1_000
        resumingSession = true
        isPaused = false
        updateCapture(for: monitor.activeMeetingBundleIdentifier)
    }

    func stopListening() {
        captureSuppressed = true
        manualApp = nil
        isPaused = false
        resumingSession = false
        finishCapture()
    }

    func listenToDetectedMeeting() {
        manuallyListening = true
        captureSuppressed = false
        updateCapture(for: monitor.activeMeetingBundleIdentifier)
    }

    private func finishCapture(completion: (() -> Void)? = nil) {
        if isStoppingCapture {
            if let completion { stopCompletions.append(completion) }
            return
        }
        isStoppingCapture = true
        Task { [weak self] in
            guard let self else { return }
            await audioCapture.stop()
            worker.stop { [weak self] in
                self?.completeCaptureStop(completion: completion)
            }
        }
    }

    private func completeCaptureStop(completion: (() -> Void)?) {
        do {
            if let url = try sessionStore?.finalize() {
                savedTranscriptURL = url
                generateNotes(for: url)
            }
            sessionStore = nil
        } catch {
            let recoveryPath = sessionStore?.workingDirectoryPath ?? "Documents/Meeting Notes"
            storageError = "Could not merge transcript: \(error.localizedDescription). Text snippets remain at \(recoveryPath)"
            sessionStore = nil
        }
        sessionEndMs = 0
        resumeOffsetMs = 0
        isStoppingCapture = false
        completion?()
        let queuedCompletions = stopCompletions
        stopCompletions.removeAll()
        queuedCompletions.forEach { $0() }
    }

    // MARK: Notes and transcript files

    func generateNotes(for transcriptURL: URL? = nil) {
        guard let transcriptURL = transcriptURL ?? savedTranscriptURL, MeetingNotes.isAvailable else { return }
        notesTask?.cancel()
        notesStatus = .generating
        let startedAt = sessionStartedAt
        notesTask = Task { [weak self] in
            do {
                let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
                let summary = try await MeetingNotes.generate(fromTranscript: markdown)
                let name = transcriptURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Transkript", with: "Notizen")
                let output = transcriptURL.deletingLastPathComponent().appending(path: "\(name).md")
                try Data(MeetingNotes.document(for: summary, startedAt: startedAt).utf8).write(to: output, options: .atomic)
                self?.notesStatus = .ready(output)
            } catch is CancellationError {
            } catch {
                AppLog.write("notes failed: \(type(of: error))")
                self?.notesStatus = .failed(error.localizedDescription)
            }
        }
    }

    var notesAvailable: Bool { MeetingNotes.isAvailable }

    func openTranscript() { savedTranscriptURL.map { NSWorkspace.shared.open($0) } }

    func revealTranscript() {
        if let url = savedTranscriptURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(Self.transcriptFolder) }
    }

    func openNotes() { if case .ready(let url) = notesStatus { NSWorkspace.shared.open(url) } }

    static var transcriptFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Meeting Notes", directoryHint: .isDirectory)
    }

    var liveTranscriptText: String { transcriptLines.joined(separator: "\n") }

    func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(liveTranscriptText, forType: .string)
    }

    func exportTranscript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Transkript.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Data(liveTranscriptText.utf8).write(to: url, options: .atomic) }
        catch { storageError = "Could not export transcript: \(error.localizedDescription)" }
    }

    // MARK: Worker, login item, shutdown

    func restartWorker() {
        captureError = nil
        worker.restart()
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            storageError = "Could not change launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    private var isWorkerFailed: Bool {
        if case .failed = worker.state { return true }
        return false
    }

    func shutdown() async {
        isShuttingDown = true
        notesTask?.cancel()
        monitor.stop()
        await startTask?.value
        await audioCapture.stop()
        await withCheckedContinuation { continuation in
            worker.stop { continuation.resume() }
        }
        worker.terminate()
        do {
            if let url = try sessionStore?.finalize() { savedTranscriptURL = url }
            sessionStore = nil
        } catch {
            storageError = "Could not merge transcript in Documents: \(error.localizedDescription)"
        }
    }

    // MARK: Presentation

    var menuState: MenuState {
        if case .failed(let message) = setup.state { return .error(message) }
        if let storageError { return .error(storageError) }
        if let captureError { return .error(captureError) }
        if case .failed(let message) = worker.state { return .error(message) }
        if !setup.isReady { return .settingUp }
        if isPaused { return .paused }
        if audioCapture.state == .capturing { return .listening }
        if worker.state == .starting || worker.state == .stopped { return .loadingModel }
        return .idle
    }

    var statusText: String {
        switch menuState {
        case .error(let message): return message
        case .settingUp: return "Set-up is not finished"
        case .loadingModel: return "Loading the local Swiss German model…"
        case .paused: return "Paused. Nothing is being recorded."
        case .listening:
            if browserTestBundleIdentifier != nil { return "Testing browser audio locally" }
            return "Listening locally"
        case .idle:
            if consentRequired { return "Read the recording notice to start" }
            if manuallyListening { return "Waiting for the meeting to start" }
            return switch monitor.detectionState {
            case .idle: "Waiting for Zoom or Teams"
            case .candidate: "Checking for an active meeting…"
            case .capturing: "Meeting detected — capture is being prepared"
            case .failed(let message): message
            }
        }
    }

    var shouldListen: Bool { menuState == .listening }
}
