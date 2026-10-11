import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum Permission: CaseIterable, Identifiable {
    case microphone, screenRecording, accessibility

    var id: Self { self }

    var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    var explanation: String {
        switch self {
        case .microphone: "Lets Meeting Notes transcribe your side of the call. Audio is processed on this Mac and never saved."
        case .screenRecording: "Lets Meeting Notes hear Zoom or Teams. It captures only that app's audio. It does not record your screen."
        case .accessibility: "Lets Meeting Notes see that a meeting is running (Mute and Leave buttons) so it can start by itself. It reads no meeting content."
        }
    }

    var settingsURL: URL {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    var isGranted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording: CGPreflightScreenCaptureAccess()
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// Triggers the real system prompt when macOS will still show one, otherwise opens the right Settings pane.
    func request() {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            } else { NSWorkspace.shared.open(settingsURL) }
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() { NSWorkspace.shared.open(settingsURL) }
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(options) { NSWorkspace.shared.open(settingsURL) }
        }
    }
}

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var granted: Set<Permission> = []
    private var timer: Timer?

    init() { refresh() }

    var missing: [Permission] { Permission.allCases.filter { !granted.contains($0) } }

    func refresh() { granted = Set(Permission.allCases.filter(\.isGranted)) }

    /// macOS gives no callback when a permission changes, so poll while a window that shows it is visible.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
