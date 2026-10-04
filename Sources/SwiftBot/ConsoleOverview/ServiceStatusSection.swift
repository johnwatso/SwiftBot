import SwiftUI

/// The Overview's health strip: the four core services as equal-width cards
/// in a single row, so all four can be scanned at once. Only when the window
/// is genuinely too narrow for four readable cards does it fall back to 2×2.
struct ServiceStatusSection: View {
    let services: [ConsoleServiceStatus]
    let summary: String
    var onSelect: (ConsoleServiceKind) -> Void

    /// Narrowest a card can be and still read cleanly (icon, name, one line).
    private static let minimumCardWidth: CGFloat = 168
    private static let spacing: CGFloat = 14

    @State private var availableWidth: CGFloat = 0

    private var fitsInOneRow: Bool {
        let needed = Self.minimumCardWidth * CGFloat(services.count) + Self.spacing * CGFloat(services.count - 1)
        // Before the first measurement, assume the normal desktop case.
        return availableWidth == 0 || availableWidth >= needed
    }

    var body: some View {
        ConsoleSection(
            title: "Services",
            accessory: { Text(summary) },
            content: {
                Group {
                    if fitsInOneRow {
                        // Equal widths: every card is offered the same share
                        // and never grows to fit its own text.
                        HStack(alignment: .top, spacing: Self.spacing) {
                            ForEach(services) { card(for: $0) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Grid(horizontalSpacing: Self.spacing, verticalSpacing: Self.spacing) {
                            GridRow { ForEach(services.prefix(2)) { card(for: $0) } }
                            GridRow { ForEach(services.dropFirst(2)) { card(for: $0) } }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
            }
        )
    }

    private func card(for service: ConsoleServiceStatus) -> some View {
        ServiceStatusCard(service: service) { onSelect(service.kind) }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One service: icon and disclosure chevron on top, then name, status dot and
/// label, and one short secondary line. Laid out vertically so it reads well
/// at a quarter of the content width.
struct ServiceStatusCard: View {
    let service: ConsoleServiceStatus
    var action: () -> Void

    @State private var isHovering = false

    private var isActive: Bool {
        service.health != .disabled && service.health != .unavailable
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    ConsoleIconTile(symbol: service.kind.symbol, brandAsset: service.kind.brandAsset, isActive: isActive, size: 42)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .opacity(isHovering ? 1 : 0.55)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(service.kind.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Label {
                        Text(service.summary)
                            .foregroundStyle(service.health.needsAttention ? service.health.tint : Color.primary)
                            .lineLimit(1)
                    } icon: {
                        StatusDot(health: service.health)
                    }
                    .font(.body.weight(.medium))

                    Text(service.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(service.detail)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.background.opacity(isHovering ? 0.75 : 0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(isHovering ? 0.10 : 0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows \(service.kind.title) settings")
    }
}
