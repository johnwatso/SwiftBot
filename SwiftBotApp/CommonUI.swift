import SwiftUI

struct SwiftBotGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.08, blue: 0.11),
                        Color(red: 0.08, green: 0.12, blue: 0.17),
                        Color(red: 0.10, green: 0.09, blue: 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 520, height: 520)
                    .blur(radius: 80)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.cyan.opacity(0.14))
                    .frame(width: 420, height: 420)
                    .blur(radius: 70)
                    .offset(x: 280, y: -160)

                Circle()
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: 480, height: 480)
                    .blur(radius: 75)
                    .offset(x: 220, y: 260)
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.95, green: 0.98, blue: 1.0),
                        Color(red: 0.89, green: 0.95, blue: 0.98),
                        Color(red: 0.96, green: 0.93, blue: 0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 520, height: 520)
                    .blur(radius: 70)
                    .offset(x: -260, y: -220)

                Circle()
                    .fill(Color.cyan.opacity(0.18))
                    .frame(width: 420, height: 420)
                    .blur(radius: 55)
                    .offset(x: 280, y: -160)

                Circle()
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 480, height: 480)
                    .blur(radius: 65)
                    .offset(x: 220, y: 260)
            }
        }
        .ignoresSafeArea()
    }
}

struct GlassActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thickMaterial))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(configuration.isPressed ? 0.26 : 0.14), lineWidth: 1)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.04 : 0.1), radius: 10, y: 6)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct SwiftBotGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let tint: Color
    let stroke: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.thinMaterial, in: shape)
            .overlay(
                shape
                    .fill(tint.opacity(colorScheme == .dark ? 1.0 : 0.50))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(stroke.opacity(colorScheme == .dark ? 1.0 : 0.90), lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, tint: Color = .white.opacity(0.10), stroke: Color = .white.opacity(0.18)) -> some View {
        modifier(SwiftBotGlassCardModifier(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    func commandCatalogSurface(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
    }

    func sidebarProfileCard() -> some View {
        glassCard(cornerRadius: 24, tint: .white.opacity(0.10), stroke: .white.opacity(0.24))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.08), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
    }
}

struct StickySaveButton: View {
    let label: String
    let systemImage: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(GlassActionButtonStyle())
        .disabled(disabled)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }
}

struct StatusPill: View {
    let status: BotStatus

    private var color: Color {
        switch status {
        case .running: return .green
        case .connecting: return .orange
        case .reconnecting: return .yellow
        case .stopped: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(status.rawValue.capitalized)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.14), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(color.opacity(0.35), lineWidth: 1)
        )
    }
}

struct ViewSectionHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        SettingsSectionHeader(
            title: title,
            systemImage: symbol,
            titleFont: .title2.weight(.semibold)
        )
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let systemImage: String
    var titleFont: Font = .headline

    var body: some View {
        Label {
            Text(title)
                .font(titleFont)
        } icon: {
            Image(systemName: systemImage)
                .imageScale(.medium)
        }
        .labelStyle(.titleAndIcon)
    }
}

struct PreferencesTabContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .padding(.bottom, 84)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct PreferencesCard<Content: View>: View {
    let title: String
    let systemImage: String?
    let subtitle: String?
    let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                if let systemImage {
                    SettingsSectionHeader(title: title, systemImage: systemImage)
                } else {
                    Text(title)
                        .font(.headline)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }
}

struct PreferencesReadOnlyBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}
