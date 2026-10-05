import SwiftUI
import Security

struct DashboardMetricDescriptor: Identifiable {
    let id: String
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var detail: String = ""
    let color: Color
    var appleIntelligenceGlowEnabled = false
}

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

private struct SwiftBotDashboardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fillOpacity: Double
    let strokeOpacity: Double
    let shadowOpacity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape
                    .fill(.primary.opacity(fillOpacity))
            )
            .overlay(
                shape
                    .strokeBorder(.primary.opacity(strokeOpacity), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .shadow(color: .black.opacity(shadowOpacity), radius: 3, y: 1)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18, tint: Color = .white.opacity(0.10), stroke: Color = .primary.opacity(0.12)) -> some View {
        modifier(SwiftBotGlassCardModifier(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    func dashboardSurface(
        cornerRadius: CGFloat = 14,
        fillOpacity: Double = 0.035,
        strokeOpacity: Double = 0.07,
        shadowOpacity: Double = 0.025
    ) -> some View {
        modifier(
            SwiftBotDashboardSurfaceModifier(
                cornerRadius: cornerRadius,
                fillOpacity: fillOpacity,
                strokeOpacity: strokeOpacity,
                shadowOpacity: shadowOpacity
            )
        )
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

private struct DashboardMetricGlowPreference {
    let bounds: Anchor<CGRect>
    let cornerRadius: CGFloat
    let glowOpacity: Double
    let isAnimating: Bool
    let showsPulse: Bool
}

private struct DashboardMetricGlowPreferenceKey: PreferenceKey {
    static let defaultValue: [DashboardMetricGlowPreference] = []

    static func reduce(value: inout [DashboardMetricGlowPreference], nextValue: () -> [DashboardMetricGlowPreference]) {
        value.append(contentsOf: nextValue())
    }
}

private struct DashboardMetricGlowLayerModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DashboardMetricGlowPreferenceKey.self) { preferences in
            GeometryReader { proxy in
                ZStack {
                    ForEach(Array(preferences.enumerated()), id: \.offset) { _, preference in
                        let rect = proxy[preference.bounds]

                        ZStack {
                            IntelligenceGlowBorder(
                                cornerRadius: preference.cornerRadius,
                                isAnimating: preference.isAnimating
                            )
                            .opacity(preference.glowOpacity)

                            if preference.showsPulse {
                                IntelligenceGlowPulse(cornerRadius: preference.cornerRadius) {}
                            }
                        }
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                    }
                }
                .allowsHitTesting(false)
            }
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func dashboardMetricGlowLayer() -> some View {
        modifier(DashboardMetricGlowLayerModifier())
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
    var assetImage: String?
    var titleFont: Font = .headline

    var body: some View {
        Label {
            Text(title)
                .font(titleFont)
        } icon: {
            if let assetImage {
                Image(assetImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: systemImage)
                    .imageScale(.medium)
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

enum PreferencesCardDensity {
    case standard
    case compact

    var padding: CGFloat {
        switch self {
        case .standard: return 20
        case .compact: return 14
        }
    }

    var innerSpacing: CGFloat {
        switch self {
        case .standard: return 18
        case .compact: return 12
        }
    }
}

struct PreferencesCard<Content: View>: View {
    let title: String
    let systemImage: String?
    let assetImage: String?
    let subtitle: String?
    let density: PreferencesCardDensity
    let content: Content

    init(
        _ title: String,
        systemImage: String? = nil,
        assetImage: String? = nil,
        subtitle: String? = nil,
        density: PreferencesCardDensity = .compact,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.assetImage = assetImage
        self.subtitle = subtitle
        self.density = density
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: density.innerSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                if let systemImage {
                    SettingsSectionHeader(title: title, systemImage: systemImage, assetImage: assetImage)
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
        .padding(.vertical, density.padding * 0.4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PreferencesCardDisabledModifier: ViewModifier {
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .disabled(isDisabled)
            .opacity(isDisabled ? 0.62 : 1)
    }
}

extension View {
    /// Standard treatment for a PreferencesCard that should be read-only —
    /// disables interaction and dims to 62% opacity. Replaces the
    /// `.disabled(x).opacity(x ? 0.62 : 1)` pair repeated across tabs.
    func preferencesCardDisabled(when isDisabled: Bool) -> some View {
        modifier(PreferencesCardDisabledModifier(isDisabled: isDisabled))
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

/// Presents `AppModel.meshConfigMutationError` as a blocking alert. Attach to
/// any Failover-editable surface so a failed push to the Primary surfaces
/// clearly (block-with-error) rather than silently dropping the edit.
private struct MeshConfigMutationErrorAlert: ViewModifier {
    @EnvironmentObject var app: AppModel

    func body(content: Content) -> some View {
        content.alert(
            "Couldn't sync to Primary",
            isPresented: Binding(
                get: { app.meshConfigMutationError != nil },
                set: { if !$0 { app.meshConfigMutationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { app.meshConfigMutationError = nil }
        } message: {
            Text(app.meshConfigMutationError ?? "")
        }
    }
}

extension View {
    func meshConfigMutationErrorAlert() -> some View {
        modifier(MeshConfigMutationErrorAlert())
    }
}

// MARK: - Phase 2 settings primitives
// SwiftMiner-style status surface, badges, inline actions, and a Form-friendly
// container. Each preferences tab is moving toward a single status row at the
// top + native grouped Form sections below.

/// Utility action button — small, capsule-bordered, with optional icon.
/// Replaces the giant "Open in Browser"-style CTAs.
struct SettingsInlineAction: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .buttonBorderShape(.capsule)
    }
}

/// Form-friendly wrapper for a preferences tab. Renders a native macOS
/// grouped Form, applies consistent insets, and shows the failover read-only
/// banner above the form when requested. Use as:
///
///     SettingsForm(readOnlyBannerText: app.isFailoverManagedNode ? "..." : nil) {
///         Section { ... }
///         Section { ... }
///     }
struct SettingsForm<Content: View>: View {
    let readOnlyBannerText: String?
    let content: Content

    @Environment(\.settingsFormPresentation) private var presentation

    init(
        readOnlyBannerText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.readOnlyBannerText = readOnlyBannerText
        self.content = content()
    }

    var body: some View {
        switch presentation {
        case .window:
            VStack(spacing: 0) {
                if let readOnlyBannerText {
                    PreferencesReadOnlyBanner(text: readOnlyBannerText)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                Form {
                    content
                }
                .formStyle(.grouped)
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .console:
            // A main-window page: the page scrolls, so the form just stacks
            // its section cards (see `ConsoleFormStyle`).
            VStack(alignment: .leading, spacing: 20) {
                if let readOnlyBannerText {
                    PreferencesReadOnlyBanner(text: readOnlyBannerText)
                }
                Form {
                    content
                }
                .formStyle(ConsoleFormStyle())
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }
}

/// Compact settings control: the credential is only editable in a sheet.
/// The sheet holds its own draft, so Cancel cannot change the saved value.
struct SecretSettingsControl: View {
    @Binding var secret: String
    let title: String
    var message = "Stored securely in your macOS Keychain."
    var replacementWarning: String?
    var allowsGeneration = false
    /// Off when the app can create the secret itself, so an empty one isn't
    /// shown as something to fix.
    var isRequired = true
    var emptyLabel = "Not configured"
    var onSave: () -> Void = {}

    @State private var isEditing = false

    private var isConfigured: Bool {
        !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(isConfigured ? "Configured" : emptyLabel, systemImage: isConfigured ? "checkmark.circle.fill" : "key")
                .font(.callout)
                .foregroundStyle(isConfigured || !isRequired ? Color.secondary : Color.orange)
            Button(isConfigured ? "Manage…" : "Add…") { isEditing = true }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel(isConfigured ? "Manage \(title)" : "Add \(title)")
        }
        .sheet(isPresented: $isEditing) {
            SecretEditorSheet(
                title: title,
                message: message,
                initialValue: secret,
                replacementWarning: replacementWarning,
                allowsGeneration: allowsGeneration
            ) { value in
                secret = value
                onSave()
            }
        }
    }
}

private struct SecretEditorSheet: View {
    let title: String
    let message: String
    let initialValue: String
    let replacementWarning: String?
    let allowsGeneration: Bool
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isConfirmingReplacement = false

    init(title: String, message: String, initialValue: String, replacementWarning: String?, allowsGeneration: Bool, onSave: @escaping (String) -> Void) {
        self.title = title
        self.message = message
        self.initialValue = initialValue
        self.replacementWarning = replacementWarning
        self.allowsGeneration = allowsGeneration
        self.onSave = onSave
        _draft = State(initialValue: initialValue)
    }

    private var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft != initialValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(title, systemImage: "key.fill")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            RevealableSecretField(text: $draft, placeholder: title, allowRegenerate: allowsGeneration)
                .accessibilityLabel(title)
            if let replacementWarning, !initialValue.isEmpty {
                Label(replacementWarning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if replacementWarning != nil && !initialValue.isEmpty {
                        isConfirmingReplacement = true
                    } else {
                        save()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(24)
        .frame(width: 480)
        .confirmationDialog("Replace \(title)?", isPresented: $isConfirmingReplacement, titleVisibility: .visible) {
            Button("Replace", role: .destructive) { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(replacementWarning ?? "")
        }
    }

    private func save() {
        onSave(draft)
        dismiss()
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

// MARK: - Premium Scroll Edge Fading

struct FadingEdgesModifier: ViewModifier {
    var top: CGFloat = 20
    var bottom: CGFloat = 20

    func body(content: Content) -> some View {
        content
            .mask(
                VStack(spacing: 0) {
                    if top > 0 {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: top)
                    }

                    Color.black

                    if bottom > 0 {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: bottom)
                    }
                }
            )
    }
}

extension View {
    func fadingEdges(top: CGFloat = 20, bottom: CGFloat = 20) -> some View {
        modifier(FadingEdgesModifier(top: top, bottom: bottom))
    }
}
