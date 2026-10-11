import SwiftUI

private enum OnboardingStep: Int, CaseIterable {
    case welcome, setup, permissions, tryIt, done

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .setup: "Download the model"
        case .permissions: "Permissions"
        case .tryIt: "Try it"
        case .done: "All set"
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var model: MenuBarModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = OnboardingStep.welcome
    @State private var testBrowser = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)").font(.caption).foregroundStyle(.secondary)
            Text(step.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
            content
            Spacer(minLength: 0)
            HStack {
                if step != .welcome, step != .done {
                    Button("Back") { step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                Button(step == .done ? "Finish" : "Continue", action: advance)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdvance)
            }
        }
        .padding(24)
        .frame(width: 560, height: 460)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            model.permissions.startPolling()
        }
        .onDisappear { model.permissions.stopPolling() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .setup: setup
        case .permissions: permissions
        case .tryIt: tryIt
        case .done: done
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Notes listens to your Zoom and Teams calls and writes down what is said in Swiss German.")
            Label("Everything runs on this Mac. Nothing is sent to a server.", systemImage: "lock.shield")
            Label("Audio is never saved. Only the text is stored in your Documents folder.", systemImage: "waveform.slash")
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recording notice").font(.headline)
                    Text("Transcribing a conversation can require the consent of everyone in it, depending on Swiss and EU law and your employer's rules. Tell participants before you transcribe. A menu-bar icon stays visible while Meeting Notes is listening.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Toggle("I will tell participants that the meeting is transcribed", isOn: $model.recordingNoticeAcknowledged)
                }.padding(4)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Notes downloads its speech model once, about 4 GB in total, and stores it in Application Support. You need an internet connection for this step only.")
            ForEach(SetupStep.allCases, id: \.self) { item in
                HStack {
                    if model.setup.completed.contains(item) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if case .running(let progress) = model.setup.state, progress.step == item {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.secondary)
                    }
                    Text(item.title)
                }.accessibilityElement(children: .combine)
            }
            switch model.setup.state {
            case .idle:
                Button("Download now") { model.setup.start() }
            case .running(let progress):
                if let fraction = progress.fraction {
                    ProgressView(value: fraction).accessibilityLabel("Download progress")
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(progress.detail).font(.callout).foregroundStyle(.secondary)
                Text("You can close this window. The download continues and resumes if interrupted.").font(.caption).foregroundStyle(.secondary)
            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                Button("Try again") { model.setup.start() }
            }
        }
        .onAppear { model.setup.start() }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Each permission is explained before macOS asks. You can change them later in Settings.")
            ForEach(Permission.allCases) { permission in
                PermissionRow(permission: permission, granted: model.permissions.granted.contains(permission))
            }
            Text("macOS may ask you to reopen Meeting Notes after you allow Screen Recording.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a Swiss German video, for example from [SRF](https://www.srf.ch/meteo), in your browser and start playback. Then choose the browser here. Only that browser's sound is transcribed, not your microphone.")
            if model.browserTestBundleIdentifier == nil {
                if model.runningBrowsers.isEmpty {
                    Text("No supported browser is open. Open Safari, Chrome, Firefox, Edge, Brave or Arc first.").foregroundStyle(.secondary)
                } else {
                    Picker("Browser", selection: $testBrowser) {
                        Text("Choose…").tag("")
                        ForEach(model.runningBrowsers) { Text($0.name).tag($0.bundleIdentifier) }
                    }
                    Button("Start test") { model.startBrowserTest(bundleIdentifier: testBrowser) }
                        .disabled(testBrowser.isEmpty || model.worker.state != .ready)
                    if model.worker.state != .ready { Text("The model is still loading…").font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                Button("Stop test") { model.stopBrowserTest() }
            }
            if case .error(let message) = model.menuState { Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            ScrollView {
                Text(model.liveTranscriptText.isEmpty ? "The transcript appears here." : model.liveTranscriptText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(model.liveTranscriptText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 140)
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Live transcript")
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting Notes now waits in the menu bar. It starts by itself when a Zoom or Teams meeting begins.")
            Label("Transcripts are saved in \(MenuBarModel.transcriptFolder.path)", systemImage: "folder")
            Button("Show in Finder") { NSWorkspace.shared.open(MenuBarModel.transcriptFolder) }
            Toggle("Open Meeting Notes when I log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .welcome: model.recordingNoticeAcknowledged
        case .setup: model.setup.isReady
        default: true
        }
    }

    private func advance() {
        if step == .done {
            model.onboardingCompleted = true
            model.updateCapture(for: model.monitor.activeMeetingBundleIdentifier)
            dismiss()
        } else {
            if model.browserTestBundleIdentifier != nil { model.stopBrowserTest() }
            step = OnboardingStep(rawValue: step.rawValue + 1) ?? .done
        }
    }
}
