import SwiftUI

// MARK: - Mode Selection View

struct ModeSelectionView: View {
    @Binding var mode: SetupMode?

    var body: some View {
        VStack(spacing: 10) {
            ForEach(SetupMode.allCases) { setupMode in
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
            HStack(spacing: 12) {
                ConsoleIconTile(symbol: mode.icon, size: 40)

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
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .consoleSurface(cornerRadius: 16)
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
