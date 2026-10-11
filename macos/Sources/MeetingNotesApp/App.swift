import SwiftUI
import Combine
import AppKit

fileprivate struct BrowserChoice: Identifiable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var automaticStartEnabled = true
    @Published var manuallyListening = false
    @Published var transcriptLines: [String] = []
    @Published fileprivate var captureSuppressed = false
    @Published private(set) var browserTestBundleIdentifier: String?
    let monitor = MeetingMonitor()
    let audioCapture = AudioCapture()
    let worker = WorkerClient()
    private var meetingSubscription: AnyCancellable?
    private var workerSubscription: AnyCancellable?

    init() {
        audioCapture.onSamples = { [weak worker] source, timestamp, samples in
            worker?.appendAudio(source: source, samples: samples, startMs: timestamp)
        }
        worker.onSegment = { [weak self] message in
            guard let segment = message["segment"] as? [String: Any],
                  segment["stability"] as? String == "final",
                  let text = segment["text"] as? String else { return }
            self?.transcriptLines.append(text)
        }
        monitor.start()
        let projectRoot = Bundle.main.infoDictionary?["MeetingNotesProjectRoot"] as? String
        worker.start(projectDirectory: URL(fileURLWithPath: projectRoot ?? FileManager.default.currentDirectoryPath))
        meetingSubscription = monitor.$activeMeetingBundleIdentifier
            .removeDuplicates()
            .sink { [weak self] bundleIdentifier in
                Task { @MainActor in self?.updateCapture(for: bundleIdentifier) }
            }
        workerSubscription = worker.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateCapture(for: self?.monitor.activeMeetingBundleIdentifier) }
            }
    }

    func updateCapture(for bundleIdentifier: String?) {
        let selectedBundleIdentifier = browserTestBundleIdentifier ?? bundleIdentifier
        if selectedBundleIdentifier == nil { captureSuppressed = false }
        let isBrowserTest = browserTestBundleIdentifier != nil
        let canStart = !captureSuppressed && (isBrowserTest || automaticStartEnabled || manuallyListening)
        if let selectedBundleIdentifier, canStart, worker.state == .ready {
            Task { await audioCapture.start(bundleIdentifier: selectedBundleIdentifier, captureMicrophone: !isBrowserTest) }
        } else if selectedBundleIdentifier == nil || !canStart || isWorkerFailed {
            if audioCapture.state == .capturing {
                Task {
                    await audioCapture.stop()
                    worker.stop()
                }
            }
        }
    }

    fileprivate var runningBrowsers: [BrowserChoice] {
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
            return BrowserChoice(bundleIdentifier: bundleIdentifier, name: name)
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
        updateCapture(for: monitor.activeMeetingBundleIdentifier)
    }

    private var isWorkerFailed: Bool {
        if case .failed = worker.state { return true }
        return false
    }

    func shutdown() {
        monitor.stop()
        worker.terminate()
        Task { await audioCapture.stop() }
    }

    var statusText: String {
        if browserTestBundleIdentifier != nil, audioCapture.state == .capturing { return "Testing browser audio locally" }
        if captureSuppressed { return "Listening paused" }
        if case .failed(let message) = audioCapture.state { return message }
        if case .capturing = audioCapture.state { return "Listening locally" }
        if case .starting = worker.state { return "Loading the local Swiss German model…" }
        if case .failed(let message) = worker.state { return message }
        if manuallyListening { return "Listening locally" }
        return switch monitor.detectionState {
        case .idle: "Waiting for Zoom or Teams"
        case .candidate: "Checking for an active meeting…"
        case .capturing: "Meeting detected — capture is being prepared"
        case .failed(let message): message
        }
    }

    var shouldListen: Bool {
        manuallyListening || (automaticStartEnabled && {
            if case .capturing = monitor.detectionState { return true }
            return false
        }())
    }
}

@main
struct MeetingNotesApp: App {
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.statusText, systemImage: model.shouldListen ? "waveform.circle.fill" : "waveform")
                    .font(.headline)
                Text("Audio and transcription stay on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !model.transcriptLines.isEmpty {
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.transcriptLines.suffix(8).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxHeight: 180)
                }
                Toggle("Start automatically for Zoom and Teams", isOn: $model.automaticStartEnabled)
                    .onChange(of: model.automaticStartEnabled) { _, _ in
                        model.updateCapture(for: model.monitor.activeMeetingBundleIdentifier)
                    }
                if !model.monitor.accessibilityAvailable {
                    Button("Allow meeting detection…") { model.monitor.requestAccessibilityAccess() }
                }
                Menu("Test with a Swiss German video…") {
                    if model.runningBrowsers.isEmpty {
                        Text("Open YouTube in Safari, Chrome, Firefox, Edge, Brave, or Arc first.")
                    } else {
                        ForEach(model.runningBrowsers) { browser in
                            Button(browser.name) { model.startBrowserTest(bundleIdentifier: browser.bundleIdentifier) }
                        }
                    }
                }
                Divider()
                if model.browserTestBundleIdentifier != nil {
                    Button("Stop YouTube test") { model.stopBrowserTest() }
                } else {
                    Button(model.audioCapture.state == .capturing ? "Stop listening" : "Resume listening") {
                        if model.audioCapture.state == .capturing {
                            model.captureSuppressed = true
                            Task {
                                await model.audioCapture.stop()
                                model.worker.stop()
                            }
                        } else {
                            model.manuallyListening = true
                            model.captureSuppressed = false
                            model.updateCapture(for: model.monitor.activeMeetingBundleIdentifier)
                        }
                    }
                }
                Button("Quit") {
                    model.shutdown()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(16)
            .frame(width: 300)
        } label: {
            Label("Meeting Notes", systemImage: model.shouldListen ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
