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

/// Shared sizing for any `LazyVGrid` that hosts `DashboardMetricCard`. Keeping
/// these in one place ensures Overview and the per-feature metric rails render
/// cards at the same width and spacing.
enum DashboardMetricGrid {
    static let minItemWidth: CGFloat = 180
    static let spacing: CGFloat = 12
    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minItemWidth), spacing: spacing)]
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

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let symbol: String
    var detail: String = ""
    let color: Color
    var appleIntelligenceGlowEnabled = false
    @State private var isHovering = false
    @State private var glowOpacity = 0.0
    @State private var playPulse = false
    @State private var pulseTask: Task<Void, Never>?

    private let cornerRadius: CGFloat = 14

    init(
        title: String,
        value: String,
        subtitle: String,
        symbol: String,
        detail: String = "",
        color: Color,
        appleIntelligenceGlowEnabled: Bool = false
    ) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.symbol = symbol
        self.detail = detail
        self.color = color
        self.appleIntelligenceGlowEnabled = appleIntelligenceGlowEnabled
    }

    init(metric: DashboardMetricDescriptor) {
        self.init(
            title: metric.title,
            value: metric.value,
            subtitle: metric.subtitle,
            symbol: metric.symbol,
            detail: metric.detail,
            color: metric.color,
            appleIntelligenceGlowEnabled: metric.appleIntelligenceGlowEnabled
        )
    }

    private var isGlowActive: Bool {
        appleIntelligenceGlowEnabled && isHovering
    }

    private var shouldRenderGlow: Bool {
        isGlowActive || glowOpacity > 0.001
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            VStack(alignment: .leading, spacing: 1) {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // Always render the detail row (with a non-breaking space when
                // empty) so every card has the same intrinsic height. Without
                // this, LazyVGrid sizes each row to its tallest card and rows
                // with no detail-having cards visually shrink.
                Text(detail.isEmpty ? "\u{00A0}" : detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .dashboardSurface(
            cornerRadius: cornerRadius,
            fillOpacity: 0.035,
            strokeOpacity: 0.07,
            shadowOpacity: 0.02
        )
        .anchorPreference(key: DashboardMetricGlowPreferenceKey.self, value: .bounds) { bounds in
            guard shouldRenderGlow || playPulse else { return [] }
            return [
                DashboardMetricGlowPreference(
                    bounds: bounds,
                    cornerRadius: cornerRadius,
                    glowOpacity: glowOpacity,
                    isAnimating: isGlowActive,
                    showsPulse: playPulse
                )
            ]
        }
        .onHover { hovering in
            let wasHovering = isHovering
            isHovering = hovering

            if hovering && appleIntelligenceGlowEnabled && !wasHovering {
                startGlowPulse()
            } else if !hovering {
                pulseTask?.cancel()
                playPulse = false
            }

            updateGlowState()
        }
        .onAppear {
            updateGlowState(animated: false)
        }
        .onChange(of: appleIntelligenceGlowEnabled) { _, enabled in
            if !enabled {
                pulseTask?.cancel()
                playPulse = false
            }
            updateGlowState()
        }
        .onDisappear {
            pulseTask?.cancel()
            playPulse = false
        }
    }

    private func startGlowPulse() {
        pulseTask?.cancel()
        playPulse = true
        pulseTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                playPulse = false
                pulseTask = nil
            }
        }
    }

    private func updateGlowState(animated: Bool = true) {
        let targetOpacity = isGlowActive ? 1.0 : 0.0

        if animated {
            withAnimation(.easeInOut(duration: isGlowActive ? 0.18 : 0.32)) {
                glowOpacity = targetOpacity
            }
        } else {
            glowOpacity = targetOpacity
        }
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

struct PreferencesTabContainer<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .padding(.bottom, 32)
        }
        .fadingEdges(top: 16, bottom: 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Leading-label / trailing-control row. Use inside PreferencesCard for
/// dense, scannable forms. The label column has a fixed width so adjacent
/// rows align cleanly; pass `caption` for the small helper text that would
/// otherwise sit underneath a stacked field.
struct PreferencesFormRow<Control: View>: View {
    let label: String
    let caption: String?
    let labelWidth: CGFloat
    let control: Control

    init(
        _ label: String,
        caption: String? = nil,
        labelWidth: CGFloat = 160,
        @ViewBuilder control: () -> Control
    ) {
        self.label = label
        self.caption = caption
        self.labelWidth = labelWidth
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .frame(width: labelWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                control
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Single-line toggle row: label left, switch trailing. Replaces the
/// HStack { Text; Spacer; Toggle } pattern repeated across preferences.
struct PreferencesInlineToggle: View {
    let title: String
    let caption: String?
    @Binding var isOn: Bool

    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self._isOn = isOn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// Banner for surfaces that are editable on a Failover node and push their
/// edits up to the Primary (which remains the single writer). Distinguishes
/// "you can edit, it just round-trips" from the lock-icon read-only state.
struct PreferencesSyncsToPrimaryBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
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

/// Compact status surface for the top of a preferences tab. Mirrors
/// SwiftMiner's pattern: tinted icon · title + subtitle · trailing accessory.
/// Drop the `accessory` slot to omit the trailing element.
struct SettingsStatusRow<Accessory: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String?
    let accessory: Accessory

    init(
        systemImage: String,
        tint: Color = .accentColor,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.12))
                    .frame(width: 30, height: 30)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            accessory
        }
    }
}

/// Small inline status pill — e.g. "HTTPS · ON". Use multiple in an HStack to
/// build a status strip ("HTTPS · Cloudflare · Public URL · Auth").
struct SettingsStatusBadge: View {
    let systemImage: String?
    let label: String
    let tint: Color

    init(_ label: String, systemImage: String? = nil, tint: Color = .secondary) {
        self.label = label
        self.systemImage = systemImage
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(label)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule(style: .continuous))
    }
}

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

    init(
        readOnlyBannerText: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.readOnlyBannerText = readOnlyBannerText
        self.content = content()
    }

    var body: some View {
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
    }
}

/// Secondary caption row used beneath form controls. Mirrors SwiftMiner's
/// `SettingsSecondaryText` so prefs no longer scatter
/// `Text(...).font(.caption).foregroundStyle(.secondary)` inline.
struct SettingsSecondaryText: View {
    let text: String
    var tint: Color = .secondary

    init(_ text: String, tint: Color = .secondary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 1)
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
