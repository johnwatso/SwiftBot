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
        VStack(alignment: .leading, spacing: 20) {
            ForEach(sections: configuration.content) { section in
                ConsoleFormSection(section: section)
            }
        }
        .labeledContentStyle(ConsoleFormRowStyle())
        .toggleStyle(ConsoleFormToggleStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One section as a card: header, rows separated by soft hairlines, footer.
private struct ConsoleFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !section.header.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    section.header
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .textCase(nil)
                .padding(.bottom, 10)
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(subviews: section.content) { row in
                    // Only rows with something in them: conditional content
                    // that's switched off leaves empty subviews behind.
                    row
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                    if row.id != section.content.last?.id {
                        Divider().opacity(0.5)
                    }
                }
            }

            if !section.footer.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    section.footer
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
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
