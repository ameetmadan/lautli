import XCTest
@testable import LautliApp

final class MeetingNotesTests: XCTestCase {
    func testPlainSpeechDropsTimestampsAndHeader() {
        let markdown = "# Meeting-Transkript\n\nErstellt: 2026-10-11\n\n- [00:00:01] Guten Morgen.\n- [00:00:05] Wir starten.\n"
        XCTAssertEqual(TranscriptText.plainSpeech(fromMarkdown: markdown), "Guten Morgen.\nWir starten.")
    }

    func testChunksRespectLimitAndKeepEveryLine() {
        let text = (1...10).map { "Zeile \($0) mit etwas Text" }.joined(separator: "\n")
        let pieces = TranscriptText.chunks(text, maxCharacters: 60)
        XCTAssertGreaterThan(pieces.count, 1)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 60 })
        XCTAssertEqual(pieces.joined(separator: "\n"), text)
    }

    func testEmptyTranscriptIsRejected() async {
        do {
            _ = try await MeetingNotes.generate(fromTranscript: "# Meeting-Transkript\n")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? NotesError, .empty)
        }
    }

    func testOnDeviceModelProducesTheRequestedSections() async throws {
        try XCTSkipUnless(MeetingNotes.isAvailable, "Apple Intelligence is not available")
        let markdown = "- [00:00:01] Wir haben beschlossen, das Budget um zehn Prozent zu erhöhen.\n- [00:00:09] Anna übernimmt die Offerte bis Freitag.\n- [00:00:15] Offen ist, wer den Kunden informiert.\n"
        let notes = try await MeetingNotes.generate(fromTranscript: markdown)
        for heading in ["## Zusammenfassung", "## Entscheidungen", "## Aufgaben", "## Offene Fragen"] {
            XCTAssertTrue(notes.contains(heading), "missing \(heading) in:\n\(notes)")
        }
    }
}
