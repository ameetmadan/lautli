import Foundation

private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var remainder = Data()

    func lines(from chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        remainder.append(chunk)
        var result: [String] = []
        while let newline = remainder.firstIndex(of: 0x0A) {
            result.append(String(decoding: remainder.prefix(upTo: newline), as: UTF8.self))
            remainder.removeSubrange(...newline)
        }
        return result
    }

    func finish() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !remainder.isEmpty else { return nil }
        defer { remainder = Data() }
        return String(decoding: remainder, as: UTF8.self)
    }
}

enum ProcessRunner {
    struct Failure: Error, LocalizedError {
        let status: Int32
        let lastLine: String
        var errorDescription: String? { tr("Exited with status \(Int(status)). \(lastLine)") }
    }

    /// Runs a tool to completion, delivering each line of combined stdout/stderr.
    static func run(
        _ executable: URL, arguments: [String], currentDirectory: URL? = nil,
        environment: [String: String] = [:], onLine: @escaping @Sendable (String) -> Void
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let splitter = LineSplitter()
        let last = LastLine()
        let deliver: @Sendable (String) -> Void = { line in
            last.set(line)
            onLine(line)
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            splitter.lines(from: handle.availableData).forEach(deliver)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                splitter.lines(from: pipe.fileHandleForReading.readDataToEndOfFile()).forEach(deliver)
                if let tail = splitter.finish() { deliver(tail) }
                if process.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: Failure(status: process.terminationStatus, lastLine: last.get())) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    /// Subprocesses (pip, Hugging Face) ignore macOS system proxy settings, which managed Macs commonly rely on.
    static func systemProxyEnvironment() -> [String: String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return [:] }
        var environment: [String: String] = [:]
        for (key, hostKey, portKey, enableKey) in [
            ("HTTPS_PROXY", "HTTPSProxy", "HTTPSPort", "HTTPSEnable"),
            ("HTTP_PROXY", "HTTPProxy", "HTTPPort", "HTTPEnable"),
        ] {
            guard settings[enableKey] as? Int == 1, let host = settings[hostKey] as? String else { continue }
            let port = settings[portKey] as? Int
            environment[key] = "http://\(host)\(port.map { ":\($0)" } ?? "")"
        }
        return environment
    }
}

private final class LastLine: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ line: String) { lock.lock(); value = line; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}
