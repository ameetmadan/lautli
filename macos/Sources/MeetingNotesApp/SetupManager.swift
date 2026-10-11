import CryptoKit
import Foundation

enum PythonRuntime {
    static let url = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261009/cpython-3.13.16%2B20261009-aarch64-apple-darwin-install_only.tar.gz")!
    static let sha256 = "3338fcd572a670ec45ac9ef75480b95595ea9b6b5dd320952fcf5df185089941"
}

let modelRevision = "a9c347a904af5d31b28c537ac732e0618aed6136"
let requiredFreeBytes: Int64 = 7_000_000_000

enum SetupStep: Int, CaseIterable, Comparable, Sendable {
    case python, dependencies, model

    static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .python: "Python runtime"
        case .dependencies: "Speech libraries"
        case .model: "Swiss German model"
        }
    }
}

struct SetupProgress: Equatable, Sendable {
    var step: SetupStep
    var fraction: Double?
    var detail: String
}

enum SetupState: Equatable {
    case idle
    case running(SetupProgress)
    case ready
    case failed(String)
}

/// Each step leaves a marker holding what it installed, so setup converges after crashes, updates and retries.
struct SetupMarkers {
    let paths: AppPaths

    private func marker(_ step: SetupStep) -> URL { paths.support.appending(path: ".setup-\(step.rawValue)") }

    func requirementsDigest() -> String {
        let data = (try? Data(contentsOf: paths.requirements)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func expected(_ step: SetupStep) -> String {
        switch step {
        case .python: PythonRuntime.sha256
        case .dependencies: requirementsDigest()
        case .model: modelRevision
        }
    }

    func isComplete(_ step: SetupStep) -> Bool {
        guard (try? String(contentsOf: marker(step), encoding: .utf8)) == expected(step) else { return false }
        switch step {
        case .python: return FileManager.default.isExecutableFile(atPath: paths.python.path)
        case .dependencies: return true
        case .model: return FileManager.default.fileExists(atPath: paths.modelDirectory.appending(path: "model.safetensors").path)
        }
    }

    func markComplete(_ step: SetupStep) throws {
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        try Data(expected(step).utf8).write(to: marker(step), options: .atomic)
    }

    func invalidate(_ step: SetupStep) { try? FileManager.default.removeItem(at: marker(step)) }

    /// A changed step invalidates everything built on top of it.
    var pending: [SetupStep] {
        guard let first = SetupStep.allCases.first(where: { !isComplete($0) }) else { return [] }
        return SetupStep.allCases.filter { $0 >= first }
    }
}

@MainActor
final class SetupManager: ObservableObject {
    @Published private(set) var state: SetupState = .idle
    @Published private(set) var completed: Set<SetupStep> = []
    private let paths: AppPaths
    private var task: Task<Void, Never>?

    init(paths: AppPaths = .standard) {
        self.paths = paths
        refresh()
    }

    var isReady: Bool { state == .ready }

    func refresh() {
        let markers = SetupMarkers(paths: paths)
        completed = Set(SetupStep.allCases.filter { markers.isComplete($0) && !markers.pending.contains($0) })
        if markers.pending.isEmpty { state = .ready }
        else if case .ready = state { state = .idle }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.run()
            self?.task = nil
        }
    }

    private func run() async {
        let markers = SetupMarkers(paths: paths)
        do {
            try ensureDiskSpace(markers)
            for step in markers.pending {
                try Task.checkCancellation()
                state = .running(SetupProgress(step: step, fraction: nil, detail: "Starting…"))
                markers.invalidate(step)
                switch step {
                case .python: try await installPython()
                case .dependencies: try await installDependencies()
                case .model: try await downloadModel()
                }
                try markers.markComplete(step)
                completed.insert(step)
                AppLog.write("setup step finished: \(step.title)", paths: paths)
            }
            state = .ready
        } catch {
            AppLog.write("setup failed: \(error.localizedDescription)", paths: paths)
            state = .failed("\(error.localizedDescription) Check your internet connection and try again.")
        }
    }

    private func ensureDiskSpace(_ markers: SetupMarkers) throws {
        guard !markers.pending.isEmpty else { return }
        try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let available = try paths.support.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage ?? .max
        guard available >= requiredFreeBytes else {
            throw SetupError.diskSpace
        }
    }

    private func update(_ step: SetupStep, fraction: Double?, detail: String) {
        state = .running(SetupProgress(step: step, fraction: fraction, detail: detail))
    }

    private func installPython() async throws {
        try FileManager.default.createDirectory(at: paths.runtime, withIntermediateDirectories: true)
        let archive = paths.runtime.appending(path: "python.tar.gz")
        defer { try? FileManager.default.removeItem(at: archive) }
        let downloader = FileDownloader(destination: archive) { [weak self] fraction in
            Task { @MainActor in self?.update(.python, fraction: fraction, detail: "Downloading Python…") }
        }
        try await downloader.download(PythonRuntime.url)
        update(.python, fraction: nil, detail: "Verifying download…")
        guard try Self.sha256(of: archive) == PythonRuntime.sha256 else { throw SetupError.checksum("Python runtime") }
        update(.python, fraction: nil, detail: "Unpacking Python…")
        let staging = paths.runtime.appending(path: "staging", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", staging.path]) { _ in }
        let installed = paths.runtime.appending(path: "python", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: installed)
        try FileManager.default.moveItem(at: staging.appending(path: "python"), to: installed)
        try? FileManager.default.removeItem(at: staging)
    }

    private func installDependencies() async throws {
        update(.dependencies, fraction: nil, detail: "Installing speech libraries (about 1 GB)…")
        let log = paths.logs.appending(path: "setup.log")
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        try await ProcessRunner.run(
            paths.python,
            arguments: ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--only-binary", ":all:", "-r", paths.requirements.path],
            environment: ProcessRunner.systemProxyEnvironment()
        ) { [weak self] line in
            Self.append(line, to: log)
            guard line.hasPrefix("Collecting ") || line.hasPrefix("Downloading ") || line.hasPrefix("Installing ") else { return }
            Task { @MainActor in self?.update(.dependencies, fraction: nil, detail: String(line.prefix(60))) }
        }
    }

    private func downloadModel() async throws {
        update(.model, fraction: 0, detail: "Downloading the Swiss German model (about 3 GB)…")
        let log = paths.logs.appending(path: "setup.log")
        try FileManager.default.createDirectory(at: paths.modelDirectory, withIntermediateDirectories: true)
        let failureBox = FailureBox()
        do {
            try await ProcessRunner.run(
                paths.python,
                arguments: ["-m", "worker.meeting_worker.download_model", paths.modelDirectory.path],
                currentDirectory: paths.workerSource,
                environment: ProcessRunner.systemProxyEnvironment()
            ) { [weak self] line in
                Self.append(line, to: log)
                guard let event = SetupEvent(line: line) else { return }
                switch event {
                case .progress(let fraction): Task { @MainActor in self?.update(.model, fraction: fraction, detail: Self.percent(fraction, "Downloading the Swiss German model…")) }
                case .verifying: Task { @MainActor in self?.update(.model, fraction: nil, detail: "Verifying the model…") }
                case .failed(let message): failureBox.set(message)
                case .done: break
                }
            }
        } catch {
            throw SetupError.model(failureBox.get() ?? error.localizedDescription)
        }
    }

    nonisolated private static func percent(_ fraction: Double, _ text: String) -> String { "\(text) \(Int(fraction * 100))%" }

    nonisolated private static func append(_ line: String, to url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) { fileManager.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let block = try handle.read(upToCount: 4 * 1024 * 1024), !block.isEmpty { hasher.update(data: block) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum SetupError: LocalizedError {
    case diskSpace, checksum(String), model(String)

    var errorDescription: String? {
        switch self {
        case .diskSpace: "Meeting Notes needs about 7 GB of free disk space for the speech model and libraries."
        case .checksum(let name): "The downloaded \(name) failed its integrity check."
        case .model(let message): "The model download failed: \(message)."
        }
    }
}

enum SetupEvent: Equatable {
    case progress(Double), verifying, done, failed(String)

    init?(line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "progress":
            guard let bytes = object["bytes"] as? Double, let total = object["total"] as? Double, total > 0 else { return nil }
            self = .progress(min(1, bytes / total))
        case "verifying": self = .verifying
        case "done": self = .done
        case "failed": self = .failed(object["message"] as? String ?? "unknown error")
        default: return nil
        }
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?
    func set(_ value: String) { lock.lock(); message = value; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return message }
}
