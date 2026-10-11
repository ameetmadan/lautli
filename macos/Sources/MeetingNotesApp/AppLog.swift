import Foundation

/// Diagnostics only. Never pass transcript text or audio-derived content here: the log is exported for support.
enum AppLog {
    private static let queue = DispatchQueue(label: "app.log")
    private static let maxBytes = 1_000_000

    static func write(_ message: String, paths: AppPaths = .standard) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: paths.logs, withIntermediateDirectories: true)
            let file = paths.logs.appending(path: "app.log")
            if let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size] as? Int), size > maxBytes {
                let archived = paths.logs.appending(path: "app.old.log")
                try? fileManager.removeItem(at: archived)
                try? fileManager.moveItem(at: file, to: archived)
            }
            if !fileManager.fileExists(atPath: file.path) { fileManager.createFile(atPath: file.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
