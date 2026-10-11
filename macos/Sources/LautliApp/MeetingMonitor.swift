import AppKit
@preconcurrency import ApplicationServices
import CoreAudio
import Foundation

@MainActor
public final class MeetingMonitor: ObservableObject {
    @Published public private(set) var detectionState: MeetingDetectionState = .idle
    @Published public private(set) var accessibilityAvailable = AXIsProcessTrusted()
    @Published public private(set) var activeMeetingBundleIdentifier: String?

    private var detector = MeetingDetector()
    private var pollingTask: Task<Void, Never>?

    public init() {}

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func requestAccessibilityAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibilityAvailable = AXIsProcessTrusted()
    }

    private func poll() {
        accessibilityAvailable = AXIsProcessTrusted()
        let running = NSWorkspace.shared.runningApplications
        let candidates = running.compactMap { app -> (MeetingApp, NSRunningApplication)? in
            switch app.bundleIdentifier {
            case "us.zoom.xos": (MeetingApp.zoom, app)
            case "com.microsoft.teams2", "com.microsoft.teams": (MeetingApp.teams, app)
            default: nil
            }
        }

        let observation = candidates.first { app, runningApp in
            Self.hasMeetingControls(processID: runningApp.processIdentifier, app: app)
        }.map { app, runningApp in
            MeetingObservation(
                app: app,
                meetingControlsVisible: true,
                audioOutputActive: Self.isOutputActive(processID: runningApp.processIdentifier),
                accessibilityAvailable: accessibilityAvailable,
                timestamp: Date()
            )
        } ?? MeetingObservation(
            app: candidates.first?.0,
            meetingControlsVisible: false,
            audioOutputActive: false,
            accessibilityAvailable: accessibilityAvailable,
            timestamp: Date()
        )

        detectionState = detector.update(observation)
        if case .capturing = detectionState {
            activeMeetingBundleIdentifier = candidates.first(where: { $0.0 == observation.app })?.1.bundleIdentifier
        } else {
            activeMeetingBundleIdentifier = nil
        }
    }

    private static func hasMeetingControls(processID: pid_t, app: MeetingApp) -> Bool {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement]
        else { return false }

        return windows.contains { window in
            containsMeetingControl(window, app: app, depth: 0)
        }
    }

    private static func containsMeetingControl(_ element: AXUIElement, app: MeetingApp, depth: Int) -> Bool {
        guard depth < 5 else { return false }
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { continue }
            if let text = value as? String, isMeetingControl(text, app: app) { return true }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement]
        else { return false }

        return children.contains { containsMeetingControl($0, app: app, depth: depth + 1) }
    }

    private static func isMeetingControl(_ value: String, app: MeetingApp) -> Bool {
        let text = value.lowercased()
        let common = ["mute", "unmute", "leave meeting", "end meeting", "stummschalten", "besprechung verlassen"]
        let appSpecific = app == .zoom ? ["participants", "teilnehmer"] : ["people", "personen", "call"]
        return (common + appSpecific).contains { text.contains($0) }
    }

    private static func isOutputActive(processID: pid_t) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0
        else { return false }

        var processObjects = [AudioObjectID](repeating: 0, count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, &processObjects) == noErr else {
            return false
        }

        for processObject in processObjects {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var foundProcessID: pid_t = -1
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(processObject, &pidAddress, 0, nil, &pidSize, &foundProcessID) == noErr,
                  foundProcessID == processID
            else { continue }

            var activeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isActive: UInt32 = 0
            var activeSize = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(processObject, &activeAddress, 0, nil, &activeSize, &isActive) == noErr && isActive != 0
        }
        return false
    }
}
