import SwiftUI
import Security

struct SwiftBotGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.34 : 0.24),
                    Color(nsColor: .underPageBackgroundColor).opacity(colorScheme == .dark ? 0.24 : 0.16),
                    Color(nsColor: .windowBackgroundColor).opacity(colorScheme == .dark ? 0.18 : 0.10)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Color.primary
                .opacity(colorScheme == .dark ? 0.030 : 0.012)
        }
        .ignoresSafeArea()
    }
}

struct GlassActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(configuration.isPressed ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.primary.opacity(configuration.isPressed ? 0.18 : 0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0.02 : 0.05), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
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
                    .fill(tint.opacity(colorScheme == .dark ? 0.45 : 0.25))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(stroke.opacity(colorScheme == .dark ? 0.35 : 0.25), lineWidth: 1)
                    .allowsHitTesting(false)
            )
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, tint: Color = .white.opacity(0.10), stroke: Color = .primary.opacity(0.12)) -> some View {
        modifier(SwiftBotGlassCardModifier(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    func commandCatalogSurface(cornerRadius: CGFloat = 16) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
            )
    }

    func sidebarProfileCard() -> some View {
        glassCard(cornerRadius: 24, tint: .white.opacity(0.05), stroke: .white.opacity(0.15))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.06), .clear],
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

/// Reusable field for editing a sensitive value (mesh shared secret, etc.)
/// where the user still needs to copy and inspect the plaintext.
///
/// SwiftUI's built-in `SecureField` blocks the system Copy command and the
/// right-click menu on macOS, which makes setting up the SwiftMesh shared
/// secret painful — you can't paste the same value across nodes without
/// retyping it. This view keeps the masked default for shoulder-surfing
/// safety but offers a reveal toggle, an always-available Copy button, and
/// an optional Regenerate action that fills the binding with a fresh
/// URL-safe random token.
struct RevealableSecretField: View {
    @Binding var text: String
    var placeholder: String = "Secret"
    /// When true, exposes a Regenerate button that overwrites `text` with a
    /// freshly generated 32-character URL-safe random token. Off by default
    /// so existing call sites can opt in.
    var allowRegenerate: Bool = false
    var regenerateLength: Int = 32

    @State private var isRevealed = false
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            // Auto-fill behaviors that complicate pasting between nodes:
            // disable autocorrect and the macOS smart-completion path so a
            // pasted token keeps its exact bytes.
            .disableAutocorrection(true)
            .textContentType(.password)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(isRevealed ? "Hide secret" : "Show secret")

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation(.easeOut(duration: 0.15)) { justCopied = true }
                Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    withAnimation(.easeOut(duration: 0.25)) { justCopied = false }
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(justCopied ? .green : .primary)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
            .disabled(text.isEmpty)

            if allowRegenerate {
                Button {
                    text = Self.generateSecret(length: regenerateLength)
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help("Generate a new random secret")
            }
        }
    }

    /// Generates a URL-safe random token of the requested length.
    static func generateSecret(length: Int = 32) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }
}
