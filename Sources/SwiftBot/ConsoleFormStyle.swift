import SwiftUI

// Settings forms shown as main-window pages (Web Interface, SwiftMesh,
// Integrations) render in the console's own visual language instead of the
// Settings window's grouped form: every `Section` becomes a rounded card like
// the Overview's, its header sits inside the card, rows run the full width
// with their controls on the trailing edge, and the footer is a caption.
// The forms themselves are unchanged; `SettingsForm` picks the style from
// the environment, so the same view still works in a grouped Form.

enum SettingsFormPresentation {
    /// The Settings window's grouped form.
    case window
    /// A main-window page in the console style.
    case console
}

private struct SettingsFormPresentationKey: EnvironmentKey {
    static let defaultValue = SettingsFormPresentation.window
}

extension EnvironmentValues {
    var settingsFormPresentation: SettingsFormPresentation {
        get { self[SettingsFormPresentationKey.self] }
        set { self[SettingsFormPresentationKey.self] = newValue }
    }
}

struct ConsoleFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(sections: configuration.content) { section in
                ConsoleFormSection(section: section)
            }
        }
        .labeledContentStyle(ConsoleFormRowStyle())
        .toggleStyle(ConsoleFormToggleStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One section as a card: the header, then its rows in one lighter inner
/// group with soft dividers between them, then the footer as a caption.
private struct ConsoleFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !section.header.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    section.header
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
                // Plain titles, as on the Overview's panels.
                .labelStyle(.titleOnly)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(subviews: section.content) { row in
                    row
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    if row.id != section.content.last?.id {
                        Divider()
                            .opacity(0.45)
                            .padding(.leading, 16)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.background.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.05), lineWidth: 1)
            )

            if !section.footer.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    section.footer
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .consoleSurface()
    }
}

/// "Label ............ value": the label (and its caption, if any) leading,
/// the value or control trailing, as a grouped Form lays out a row.
private struct ConsoleFormRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            RowLabel(label: configuration.label)
            Spacer(minLength: 12)
            configuration.content
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// A switch on the trailing edge with its label (and caption) leading.
private struct ConsoleFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 16) {
            RowLabel(label: configuration.label)
            Spacer(minLength: 12)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// A row's label: the first view is the title; anything after it is a
/// caption, as in a grouped Form.
private struct RowLabel<Label: View>: View {
    let label: Label

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group(subviews: label) { subviews in
                if let title = subviews.first {
                    title
                }
                ForEach(subviews.dropFirst()) { caption in
                    caption
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Console setting components

/// A section's heading: a plain title, as on the Overview's panels.
struct ConsoleSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }
}

/// A native settings row: glyph, title, one short line of description (or a
/// status line), and the control on the trailing edge.
struct ConsoleSettingRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    var brandAsset: String?
    var imageURL: URL? = nil
    var symbolTint: Color = .secondary
    var subtitle: String?
    /// A short status line shown in place of, or above, the description:
    /// "No sign-in method configured", "Tunnel isn't running".
    var status: (text: String, health: ServiceHealth)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if symbol != nil || brandAsset != nil || imageURL != nil {
                glyph
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.05), in: Circle())
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                if let status {
                    Label {
                        Text(status.text)
                    } icon: {
                        if status.health.needsAttention {
                            Image(systemName: status.health.issueSymbol)
                        } else {
                            StatusDot(health: status.health, size: 7)
                        }
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(status.health.needsAttention || status.health == .healthy ? status.health.tint : Color.secondary)
                }
                if let subtitle {
                    // Markdown, so a description can carry a link.
                    Text(LocalizedStringKey(subtitle))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            trailing
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var glyph: some View {
        if let imageURL {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: symbol ?? "person.3.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(symbolTint)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
        } else if let brandAsset {
            Image(brandAsset)
                .resizable()
                .scaledToFit()
                .frame(width: 17, height: 17)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(symbolTint)
        }
    }
}

extension ConsoleSettingRow where Trailing == EmptyView {
    init(
        title: String,
        symbol: String? = nil,
        brandAsset: String? = nil,
        symbolTint: Color = .secondary,
        subtitle: String? = nil,
        status: (text: String, health: ServiceHealth)? = nil
    ) {
        self.init(
            title: title, symbol: symbol, brandAsset: brandAsset, symbolTint: symbolTint,
            subtitle: subtitle, status: status, trailing: { EmptyView() }
        )
    }
}

/// A switch for the trailing edge of a `ConsoleSettingRow`.
struct ConsoleRowSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
    }
}

/// A row that reveals more rows below it; the chevron turns when open.
struct ConsoleDisclosureRow: View {
    let title: String
    var symbol: String?
    var subtitle: String?
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            ConsoleSettingRow(title: title, symbol: symbol, subtitle: subtitle) {
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}
