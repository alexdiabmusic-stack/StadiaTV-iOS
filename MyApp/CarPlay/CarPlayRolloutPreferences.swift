import SwiftUI

struct CarPlayRolloutPreferences: View {
    @Bindable private var rollout = CarPlayRollout.shared

    var body: some View {
        Section {
            Toggle("Personalized CarPlay Home", isOn: $rollout.personalizedHome)
            Toggle("Sports Now Playing", isOn: $rollout.sportsMode)
            Toggle("Sports Drive", isOn: $rollout.sportsDrive)
            Toggle("Downloads in CarPlay", isOn: $rollout.offlineLibrary)
            Toggle("MiniPlayer", isOn: $rollout.miniPlayer)
            Button("Use Basic Experience") { rollout.useBasicExperience() }
            Button("Enable Advanced Experience") { rollout.enableAdvancedExperience() }
        } header: {
            Text("CarPlay")
        } footer: {
            Text("Changes apply while connected. Sports Now Playing and MiniPlayer require a supported iOS version. Your current audio and saved downloads are preserved.")
        }
    }
}
