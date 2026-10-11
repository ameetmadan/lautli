import SwiftUI

@main
struct MeetingNotesApp: App {
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
                .environment(\.locale, model.language.locale)
        } label: {
            Image(systemName: model.menuState.symbol)
                .accessibilityLabel(tr("Meeting Notes: \(model.menuState.accessibilityName)"))
        }
        .menuBarExtraStyle(.window)

        Window(tr("Welcome to Meeting Notes"), id: "onboarding") {
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

        Window(tr("Meeting Notes Settings"), id: "settings") {
            SettingsView(model: model)
                .environment(\.locale, model.language.locale)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
