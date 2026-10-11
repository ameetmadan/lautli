import Foundation
import XCTest
@testable import LautliApp

final class L10nTests: XCTestCase {
    private let macos = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private var resources: URL { macos.appending(path: "Resources", directoryHint: .isDirectory) }

    private func germanStrings() throws -> [String: String] {
        let data = try Data(contentsOf: resources.appending(path: "de.lproj/Localizable.strings"))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }

    private func specifiers(_ text: String) -> [String] {
        text.matches(of: /%(?:\d+\$)?(lld|ld|d|@|\.?\d*f)/).map { String($0.1) }.sorted()
    }

    func testGermanStringsParseAndKeepFormatSpecifiers() throws {
        let german = try germanStrings()
        XCTAssertFalse(german.isEmpty)
        for (key, value) in german {
            XCTAssertEqual(specifiers(key), specifiers(value), "specifiers differ for \(key)")
        }
    }

    func testBundleResolvesTheChosenLanguage() throws {
        let base = try XCTUnwrap(Bundle(path: resources.path))
        XCTAssertEqual(String(localized: "Continue", bundle: L10n.bundle(for: .de, in: base)), "Weiter")
        XCTAssertEqual(String(localized: "Continue", bundle: L10n.bundle(for: .en, in: base)), "Continue")
    }

    func testDefaultLanguageFollowsFirstPreferredLanguage() {
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["de-CH", "en-US"]), .de)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["en-US", "de-CH"]), .en)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: ["fr-CH"]), .en)
        XCTAssertEqual(AppLanguage.systemDefault(preferredLanguages: []), .en)
    }

    /// Best effort: the compiler's string extraction is authoritative, this catches literals added without a translation.
    func testEveryLiteralInTheSourcesHasAGermanValue() throws {
        let placeholder = "\u{1}"
        let germanKeys = Set(try germanStrings().keys.map { $0.replacing(/%(?:\d+\$)?(?:lld|ld|d|@|\.?\d*f)/, with: placeholder) })
        let sources = macos.appending(path: "Sources/LautliApp", directoryHint: .isDirectory)
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let call = /(?:\b(?:tr|Text|Button|Label|Toggle|Section|Picker|Menu|accessibilityLabel)\(|String\(localized:\s*)"((?:[^"\\]|\\.)*)"/
        var missing: [String] = []
        for file in files {
            for match in try String(contentsOf: file, encoding: .utf8).matches(of: call) {
                let key = String(match.1).replacing(/\\\((?:[^()]|\([^()]*\))*\)/, with: placeholder)
                if !germanKeys.contains(key) { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertGreaterThan(files.count, 0)
        XCTAssertEqual(missing, [])
    }
}
