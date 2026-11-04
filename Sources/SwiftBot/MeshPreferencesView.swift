import SwiftUI

/// Ruru is the entry point for connecting this Mac to the guarded service.
struct MeshPreferencesView: View {
    var body: some View {
        SettingsForm {
            MeshWitnessPreferencesSection()

            Section {
                LabeledContent("Add a backup", value: "Not available yet")
            } header: {
                Text("SwiftMesh")
            } footer: {
                Text("Connecting to Ruru does not yet connect this Mac to another SwiftBot or synchronise its configuration. A Ruru-led backup setup is still being developed.")
            }
        }
    }
}
