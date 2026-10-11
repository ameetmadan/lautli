import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case en, de

    static let defaultsKey = "appLanguage"

    var id: Self { self }

    /// Always the native name, so people can find their language whatever is selected.
    var displayName: String {
        switch self {
        case .en: "English"
        case .de: "Deutsch"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:))
            ?? systemDefault(preferredLanguages: Locale.preferredLanguages)
    }

    static func systemDefault(preferredLanguages: [String]) -> AppLanguage {
        preferredLanguages.first?.hasPrefix("de") == true ? .de : .en
    }

    static func persist(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
    }
}

enum L10n {
    /// English text is the key, so a missing `.lproj` (as under `swift run`) simply shows English.
    static func bundle(for language: AppLanguage, in base: Bundle = .main) -> Bundle {
        base.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? base
    }
}

/// Localizes a string that is not a SwiftUI literal into the in-app language.
func tr(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: L10n.bundle(for: .current))
}
