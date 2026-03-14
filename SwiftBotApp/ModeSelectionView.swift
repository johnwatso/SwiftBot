import SwiftUI

// MARK: - Mode Selection View

struct ModeSelectionView: View {
    @EnvironmentObject var app: AppModel
    @Binding var mode: SetupMode?

    private var availableModes: [SetupMode] {
        SetupMode.allCases.filter { setupMode in
            setupMode != .remote || app.remoteControlFeatureEnabled
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            ForEach(availableModes) { setupMode in
                ModeSelectionButton(mode: setupMode) {
                    mode = setupMode
                }
            }
        }
    }
}

// MARK: - Mode Selection Button

private struct ModeSelectionButton: View {
    let mode: SetupMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.title2)

                Text(mode.title)
                    .font(.headline)

                Text(mode.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)
            .padding(20)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var selectedMode: SetupMode?

    ModeSelectionView(mode: $selectedMode)
        .padding()
        .frame(width: 500, height: 400)
        .environmentObject(AppModel())
}
