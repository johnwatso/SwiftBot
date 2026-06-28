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
        VStack(spacing: 10) {
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
    @Environment(\.colorScheme) private var colorScheme

    let mode: SetupMode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: mode.icon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(
                        Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.11),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title)
                        .font(.headline)

                    Text(mode.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .background(
                Color.white.opacity(colorScheme == .dark ? 0.07 : 0.18),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
