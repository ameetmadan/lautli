import Foundation

struct TranscriptSegment: Codable, Equatable, Identifiable {
    let id: String
    let startMs: Int64
    let endMs: Int64
    let text: String
    let source: String?
}

final class TranscriptSessionStore {
    private let root: URL
    private let snippetsDirectory: URL
    private let startedAt: Date
    private var storedIDs = Set<String>()
    var workingDirectoryPath: String { snippetsDirectory.path }

    init(documentsRoot: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], startedAt: Date = Date()) throws {
        self.root = documentsRoot.appending(path: "Meeting Notes", directoryHint: .isDirectory)
        self.startedAt = startedAt
        self.snippetsDirectory = root.appending(path: ".working-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: snippetsDirectory, withIntermediateDirectories: true)
    }

    func append(_ segment: TranscriptSegment) throws {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !storedIDs.contains(segment.id) else { return }
        let data = try JSONEncoder().encode(segment)
        try data.write(to: snippetsDirectory.appending(path: "\(segment.id).json"), options: .atomic)
        storedIDs.insert(segment.id)
    }

    @discardableResult
    func finalize() throws -> URL {
        let files = try FileManager.default.contentsOfDirectory(at: snippetsDirectory, includingPropertiesForKeys: nil)
        let segments = try files.filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(TranscriptSegment.self, from: Data(contentsOf: $0)) }
            .sorted { ($0.startMs, $0.id) < ($1.startMs, $1.id) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_CH")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let suffix = UUID().uuidString.prefix(8)
        let output = root.appending(path: "Transkript \(formatter.string(from: startedAt))-\(suffix).md")
        let body = segments.map { "- [\(timestamp($0.startMs))] \($0.text)" }.joined(separator: "\n")
        let document = "# Meeting-Transkript\n\nErstellt: \(ISO8601DateFormatter().string(from: startedAt))\n\n\(body)\n"
        try Data(document.utf8).write(to: output, options: .atomic)
        try FileManager.default.removeItem(at: snippetsDirectory)
        return output
    }

    func discard() {
        try? FileManager.default.removeItem(at: snippetsDirectory)
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let seconds = max(0, milliseconds / 1_000)
        return String(format: "%02lld:%02lld:%02lld", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
    }
}
