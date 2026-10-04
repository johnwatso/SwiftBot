import SwiftUI

extension ServiceHealth {
    /// Green for healthy, orange for warnings, red only when actually broken,
    /// neutral grey for everything that's off, unavailable or on its way up.
    var tint: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        case .disabled, .unavailable, .pending: return .secondary
        }
    }

    /// Glyph for an issue line; only warnings and errors get one.
    var issueSymbol: String {
        self == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
    }
}

/// The small colored dot that leads every status line.
struct StatusDot: View {
    let health: ServiceHealth
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(health.tint)
            .opacity(health == .disabled || health == .unavailable ? 0.45 : 1)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "● Running" capsule beside the bot's name.
struct StatusBadge: View {
    let health: ServiceHealth
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            StatusDot(health: health, size: 7)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(health.needsAttention || health == .healthy ? health.tint : Color.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(health.tint.opacity(health == .healthy || health.needsAttention ? 0.13 : 0.08), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

/// A titled Overview section: a soft, rounded translucent panel with its
/// heading inside and generous padding. `accessory` sits at the trailing end
/// of the heading; `headerInset` lines the heading up with rows that carry
/// their own horizontal padding (hover highlights).
struct ConsoleSection<Content: View, Accessory: View>: View {
    let title: String
    var padding: CGFloat = 22
    var headerInset: CGFloat = 0
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                accessory
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, headerInset)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .consoleSurface()
    }
}

extension ConsoleSection where Accessory == EmptyView {
    init(
        _ title: String,
        padding: CGFloat = 22,
        headerInset: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, padding: padding, headerInset: headerInset, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// The soft translucent surface every Overview section sits on. Shares
    /// the dashboard's surface so the console reads as part of the same app.
    func consoleSurface(cornerRadius: CGFloat = 20) -> some View {
        dashboardSurface(cornerRadius: cornerRadius, fillOpacity: 0.04, strokeOpacity: 0.07, shadowOpacity: 0.02)
    }
}

/// A service glyph on a quiet rounded square: accent glyph, neutral fill.
/// Grey when the service is off, so the eye goes to what's running.
///
/// With a `brandAsset`, the service's own full-color logo is drawn instead of
/// the symbol, and desaturated when the service is off.
struct ConsoleIconTile: View {
    let symbol: String
    var brandAsset: String?
    var isActive = true
    var size: CGFloat = 32

    var body: some View {
        glyph
            .frame(width: size, height: size)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let brandAsset {
            Image(brandAsset)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.58, height: size * 0.58)
                .saturation(isActive ? 1 : 0)
                .opacity(isActive ? 1 : 0.55)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        }
    }
}

/// A full-width hairline between rows in a grouped box.
struct ConsoleRowDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Divider().padding(.leading, leadingInset)
    }
}

extension Duration {
    /// "4d 7h 12m"; minutes are the finest unit since the readout ticks slowly.
    var uptimeText: String {
        formatted(.units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 3))
    }
}

/// One service that needs attention, as a compact tinted row at the foot of
/// a status card: "Cloudflare Tunnel error", what's wrong, and Show.
/// Shared by the Overview's summary card and each service page's card.
struct ConsoleIssueRow: View {
    let issue: ConsoleServiceStatus
    var onShow: (() -> Void)?

    /// "error", "not listening": the summary as a sentence fragment.
    private var state: String {
        issue.summary.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "…"))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: issue.health == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(issue.health.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(issue.kind.title) \(state)")
                    .font(.callout.weight(.semibold))
                Text(issue.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 16)
            if let onShow {
                Button("Show", action: onShow)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(issue.health.tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
