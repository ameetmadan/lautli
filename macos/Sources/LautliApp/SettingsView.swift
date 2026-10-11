import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: MenuBarModel
    @AppStorage(MicrophoneChoice.preferenceKey) private var microphoneID = ""
    @State private var message: String?

    var body: some View {
        Form {
            Section("Permissions") {
                ForEach(Permission.allCases) { permission in
                    PermissionRow(permission: permission, granted: model.permissions.granted.contains(permission))
                }
                Text("macOS occasionally asks again for Screen Recording. If a permission shows as missing here, allow it in System Settings and reopen lautli.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Microphone") {
                Picker("Input", selection: $microphoneID) {
                    Text("System default").tag("")
                    ForEach(MicrophoneChoice.devices(), id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                Text("Applies to the next meeting. Use the input your meeting app uses. With speakers instead of headphones, the microphone also hears the other participants and lines can repeat, so headphones are recommended.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("General") {
                Picker("Language", selection: $model.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Toggle("Open lautli when I log in", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("I will tell participants that meetings are transcribed", isOn: $model.recordingNoticeAcknowledged)
                Button("Export diagnostics…") {
                    do {
                        let archive = try Diagnostics.export()
                        NSWorkspace.shared.activateFileViewerSelecting([archive])
                        message = tr("Saved \(archive.lastPathComponent) to your Desktop. It contains logs only, no transcripts or audio.")
                    } catch { message = tr("Could not export diagnostics: \(error.localizedDescription)") }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            model.permissions.startPolling()
        }
        .onDisappear { model.permissions.stopPolling() }
    }
}
