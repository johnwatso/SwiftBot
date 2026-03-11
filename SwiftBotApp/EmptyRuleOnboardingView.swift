import SwiftUI

// MARK: - Empty Rule Onboarding

/// Ghost placeholder empty state shown when a rule has no blocks yet.
/// Follows Apple Human Interface Guidelines for empty states.
struct EmptyRuleOnboardingView: View {
    let onAddTriggerTapped: () -> Void

    @State private var arrowPulse: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)

            // Ghost placeholder card
            VStack(spacing: 20) {
                // SF Symbol: bolt.circle
                Image(systemName: "bolt.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary.opacity(0.6))

                VStack(spacing: 8) {
                    Text("No blocks yet")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)

                    Text("Add a trigger to begin building this rule.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                // Primary action button: [ + Add Trigger ]
                Button(action: onAddTriggerTapped) {
                    Label("Add Trigger", systemImage: "plus")
                        .font(.body.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(.accentColor.opacity(0.8))
                .padding(.top, 8)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 40)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)
            .frame(maxWidth: 380)

            Spacer(minLength: 32)

            // Directional hint with subtle pulse toward Block Library
            HStack(spacing: 6) {
                Image(systemName: "arrow.left")
                    .font(.caption.weight(.semibold))
                    .opacity(arrowPulse ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: arrowPulse
                    )
                Text("Drag a trigger from the Block Library")
                    .font(.caption)
            }
            .foregroundStyle(.secondary.opacity(0.8))
            .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { arrowPulse = true }
    }
}
