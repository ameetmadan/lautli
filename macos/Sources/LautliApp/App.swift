import SwiftUI

@main
struct LautliApp: App {
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                .environment(\.locale, model.language.locale)
        } label: {
            Image(systemName: model.menuState.symbol)
                .accessibilityLabel(tr("lautli: \(model.menuState.accessibilityName)"))
        }
        .menuBarExtraStyle(.window)

        Window(tr("Welcome to lautli"), id: "onboarding") {
            OnboardingView(model: model)
                .environment(\.locale, model.language.locale)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.onboardingCompleted ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        Window(tr("Transcript"), id: "transcript") {
            TranscriptView(model: model)
                .environment(\.locale, model.language.locale)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(tr("lautli Settings"), id: "settings") {
            SettingsView(model: model)
                .environment(\.locale, model.language.locale)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
