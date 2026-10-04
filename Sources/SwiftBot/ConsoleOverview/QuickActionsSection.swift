import SwiftUI

/// One row in the Quick Actions list.
struct QuickAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var isEnabled = true
    var isBusy = false
    let perform: () -> Void
}

/// A short list of the console's most useful actions, as plain macOS rows:
/// glyph, title, subtitle, chevron, inset separators.
struct QuickActionsSection: View {
    let actions: [QuickAction]

    var body: some View {
        // Rows carry their own 10pt inset for the hover highlight, so the
        // panel is a little tighter and the heading is inset to match.
        ConsoleSection("Quick Actions", padding: 14, headerInset: 10) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                if index > 0 {
                    ConsoleRowDivider(leadingInset: 42)
                }
                QuickActionRow(action: action)
            }
        }
    }
}

private struct QuickActionRow: View {
    let action: QuickAction
    @State private var isHovering = false

    var body: some View {
        Button(action: action.perform) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(action.title)
                    Text(action.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                if action.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isHovering && action.isEnabled ? 0.045 : 0))
            )
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled || action.isBusy)
        .opacity(action.isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
    }
}
