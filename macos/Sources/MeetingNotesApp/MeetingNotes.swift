import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum NotesError: LocalizedError {
    case unavailable, empty

    var errorDescription: String? {
        switch self {
        case .unavailable: "Meeting notes need macOS 26 or newer with Apple Intelligence turned on."
        case .empty: "The transcript is empty, so there is nothing to summarize."
        }
    }
}

enum TranscriptText {
    /// Removes the `- [hh:mm:ss] ` prefixes the transcript store writes so the model sees plain speech.
    static func plainSpeech(fromMarkdown markdown: String) -> String {
        markdown.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("- ["), let close = line.firstIndex(of: "]") else { return nil }
            let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }.joined(separator: "\n")
    }

    /// Splits on line boundaries so each piece fits the on-device model's small context window.
    static func chunks(_ text: String, maxCharacters: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if !current.isEmpty, current.count + line.count + 1 > maxCharacters {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

enum MeetingNotes {
    static let chunkCharacters = 3_500

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    static func document(for summary: String, startedAt: Date) -> String {
        "# Meeting-Notizen\n\nErstellt: \(ISO8601DateFormatter().string(from: startedAt))\n\n\(summary)\n\nZusammenfassung automatisch auf diesem Mac erstellt. Bitte vor der Weitergabe prüfen.\n"
    }

    static func generate(fromTranscript markdown: String) async throws -> String {
        let speech = TranscriptText.plainSpeech(fromMarkdown: markdown)
        guard !speech.isEmpty else { throw NotesError.empty }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            return try await summarize(speech)
        }
        #endif
        throw NotesError.unavailable
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    private static func summarize(_ speech: String) async throws -> String {
        var partials: [String] = []
        for chunk in TranscriptText.chunks(speech, maxCharacters: chunkCharacters) {
            let session = LanguageModelSession(instructions: "Du fasst Ausschnitte eines Meeting-Transkripts auf Standarddeutsch zusammen. Nenne nur Fakten aus dem Text: Themen, Entscheidungen, Aufgaben mit Verantwortlichen, offene Fragen. Knappe Stichpunkte.")
            partials.append(try await session.respond(to: chunk).content)
        }
        var combined = partials.joined(separator: "\n")
        while combined.count > chunkCharacters {
            let pieces = TranscriptText.chunks(combined, maxCharacters: chunkCharacters)
            var reduced: [String] = []
            for piece in pieces {
                let session = LanguageModelSession(instructions: "Fasse diese Meeting-Stichpunkte zu weniger Stichpunkten auf Standarddeutsch zusammen. Behalte Entscheidungen und Aufgaben.")
                reduced.append(try await session.respond(to: piece).content)
            }
            guard reduced.joined(separator: "\n").count < combined.count else { break }
            combined = reduced.joined(separator: "\n")
        }
        let session = LanguageModelSession(instructions: """
        Du schreibst Meeting-Notizen auf Standarddeutsch aus Stichpunkten. Verwende genau diese Markdown-Überschriften: \
        "## Zusammenfassung", "## Entscheidungen", "## Aufgaben", "## Offene Fragen". \
        Schreibe unter eine Überschrift "–", wenn der Text dazu nichts enthält. Erfinde nichts.
        """)
        return try await session.respond(to: combined).content
    }
    #endif
}
