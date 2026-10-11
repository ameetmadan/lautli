import SwiftUI
import Combine

@MainActor
final class MenuBarModel: ObservableObject {
    @Published var automaticStartEnabled = true
    @Published var manuallyListening = false
    let monitor = MeetingMonitor()
    let audioCapture = AudioCapture()
    private var meetingSubscription: AnyCancellable?

    init() {
        monitor.start()
        meetingSubscription = monitor.$activeMeetingBundleIdentifier
            .removeDuplicates()
            .sink { [weak self] bundleIdentifier in
                Task { @MainActor in
                    guard let self else { return }
                    if let bundleIdentifier { await self.audioCapture.start(bundleIdentifier: bundleIdentifier) }
                    else { await self.audioCapture.stop() }
                }
            }
    }

    var statusText: String {
        if case .failed(let message) = audioCapture.state { return message }
        if case .capturing = audioCapture.state { return "Listening locally" }
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
                Toggle("Start automatically for Zoom and Teams", isOn: $model.automaticStartEnabled)
                if !model.monitor.accessibilityAvailable {
                    Button("Allow meeting detection…") { model.monitor.requestAccessibilityAccess() }
                }
                Divider()
                Button(model.manuallyListening ? "Stop listening" : "Start listening manually") {
                    model.manuallyListening.toggle()
                }
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(16)
            .frame(width: 300)
        } label: {
            Label("Meeting Notes", systemImage: model.shouldListen ? "waveform.circle.fill" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}
