import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.openWindow) private var openWindow

    private func show(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(model.statusText, systemImage: model.menuState.symbol)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("Audio and transcription stay on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let notice = model.audioCapture.notice {
                Text(notice).font(.caption)
            }
            if let microphone = model.audioCapture.microphoneName {
                Text("Microphone: \(microphone)").font(.caption).foregroundStyle(.secondary)
            }
            stateActions
            if model.onboardingCompleted, let missing = model.permissions.missing.first {
                Button("\(missing.title) permission needed…") { show("settings") }
            }
            if !model.transcriptLines.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.transcriptLines.suffix(6).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 140)
                .accessibilityLabel("Latest transcript lines")
            }
            if let savedURL = model.savedTranscriptURL {
                Divider()
                Text("Saved to \(savedURL.path)").font(.caption2).textSelection(.enabled)
                HStack {
                    Button("Open transcript") { model.openTranscript() }
                    Button("Show in Finder") { model.revealTranscript() }
                }
                notesRow
            }
            Divider()
            Toggle("Start automatically for Zoom and Teams", isOn: $model.automaticStartEnabled)
                .onChange(of: model.automaticStartEnabled) { _, _ in
                    model.updateCapture(for: model.monitor.activeMeetingBundleIdentifier)
                }
            if !model.monitor.accessibilityAvailable {
                Button("Allow meeting detection…") { model.monitor.requestAccessibilityAccess() }
            }
            listenControls
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
            Button("Transcript…") { show("transcript") }
            Button("Settings…") { show("settings") }
            Button("Quit") {
                Task {
                    await model.shutdown()
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    @ViewBuilder private var stateActions: some View {
        switch model.menuState {
        case .error:
            HStack {
                if case .failed = model.worker.state { Button("Restart worker") { model.restartWorker() } }
                if case .failed = model.setup.state { Button("Try again") { model.setup.start() } }
                Button("Dismiss") { model.dismissError() }
            }
        case .settingUp:
            Button(model.onboardingCompleted ? "Show set-up progress…" : "Finish set-up…") { show("onboarding") }
        case .idle where !model.recordingNoticeAcknowledged:
            Button("Finish set-up…") { show("onboarding") }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var notesRow: some View {
        if model.notesAvailable {
            switch model.notesStatus {
            case .idle: Button("Create Standard German notes") { model.generateNotes() }
            case .generating: Label("Creating notes…", systemImage: "hourglass").font(.caption)
            case .ready: Button("Open notes") { model.openNotes() }
            case .failed(let message): Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var listenControls: some View {
        if model.browserTestBundleIdentifier != nil {
            Button("Stop YouTube test") { model.stopBrowserTest() }
        } else if model.isPaused {
            HStack {
                Button("Resume") { model.resume() }
                Button("Stop and save") { model.stopListening() }
            }
        } else if model.isCapturing {
            HStack {
                Button("Pause") { model.pause() }
                Button("Stop and save") { model.stopListening() }
            }
        } else {
            if case .capturing = model.monitor.detectionState, !model.automaticStartEnabled {
                Button("Listen to this meeting") { model.listenToDetectedMeeting() }
            }
            Menu("Listen to an app…") {
                ForEach(model.listenableApps) { app in
                    Button(app.name) { model.listen(to: app) }
                }
            }
            .disabled(model.worker.state != .ready || !model.recordingNoticeAcknowledged)
        }
    }
}
