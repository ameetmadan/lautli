import Foundation
import Sparkle

/// Wraps Sparkle. Updates are only enabled in release builds that were stamped with an EdDSA public key
/// (`SUPublicEDKey`) and a feed URL (`SUFeedURL`) by `scripts/build_mac_app.sh`. Development builds, tests and
/// ad-hoc builds without a key never start the updater, so they never contact the network or show Sparkle errors.
@MainActor
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController?

    init(info: [String: Any]? = Bundle.main.infoDictionary) {
        if Self.isConfigured(info: info) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated static func isConfigured(info: [String: Any]?) -> Bool {
        func value(_ key: String) -> String {
            (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !value("SUPublicEDKey").isEmpty, let feed = URL(string: value("SUFeedURL")) else { return false }
        return feed.scheme == "https"
    }
}
