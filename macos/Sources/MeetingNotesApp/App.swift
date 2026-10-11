import SwiftUI

@main
struct MeetingNotesApp: App {
    @StateObject private var model = MenuBarModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuState.symbol)
                .accessibilityLabel("Meeting Notes: \(model.menuState.accessibilityName)")
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to Meeting Notes", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(model.onboardingCompleted ? .suppressed : .presented)
        .restorationBehavior(.disabled)

        Window("Transcript", id: "transcript") {
            TranscriptView(model: model)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Meeting Notes Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}
