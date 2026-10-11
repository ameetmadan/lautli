import AppKit
import Foundation

enum Diagnostics {
    /// Bundles logs and basic system facts. Transcripts and audio are never included.
    @MainActor
    static func export(paths: AppPaths = .standard) throws -> URL {
        let fileManager = FileManager.default
        let staging = fileManager.temporaryDirectory.appending(path: "Meeting Notes Diagnostics", directoryHint: .isDirectory)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        for name in ["app.log", "app.old.log", "worker.log", "worker.old.log", "setup.log"] {
            let source = paths.logs.appending(path: name)
            if fileManager.fileExists(atPath: source.path) { try fileManager.copyItem(at: source, to: staging.appending(path: name)) }
        }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let facts = """
        Meeting Notes \(version)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Physical memory: \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB
        Permissions: \(Permission.allCases.map { "\($0)=\($0.isGranted)" }.joined(separator: ", "))
        Setup complete: \(SetupMarkers(paths: paths).pending.isEmpty)
        """
        try Data(facts.utf8).write(to: staging.appending(path: "system.txt"))

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let desktop = fileManager.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let archive = desktop.appending(path: "Meeting Notes Diagnostics \(formatter.string(from: Date())).zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", staging.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        try? fileManager.removeItem(at: staging)
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return archive
    }
}
