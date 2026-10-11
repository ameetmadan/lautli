import Foundation

struct AppPaths: Sendable {
    let support: URL
    let workerSource: URL

    init(support: URL, workerSource: URL) {
        self.support = support
        self.workerSource = workerSource
    }

    /// Environment overrides let tests and development builds point at scratch directories or a repo checkout.
    static let standard: AppPaths = {
        let environment = ProcessInfo.processInfo.environment
        let support = environment["MEETING_NOTES_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "Meeting Notes", directoryHint: .isDirectory)
        let workerSource = environment["MEETING_NOTES_WORKER_SRC"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Bundle.main.resourceURL!.appending(path: "worker-src", directoryHint: .isDirectory)
        return AppPaths(support: support, workerSource: workerSource)
    }()

    var runtime: URL { support.appending(path: "runtime", directoryHint: .isDirectory) }
    var python: URL { runtime.appending(path: "python/bin/python3") }
    var modelDirectory: URL { support.appending(path: "models/flix-swissgerman-full", directoryHint: .isDirectory) }
    var logs: URL { support.appending(path: "logs", directoryHint: .isDirectory) }
    var requirements: URL { workerSource.appending(path: "requirements.txt") }
}
