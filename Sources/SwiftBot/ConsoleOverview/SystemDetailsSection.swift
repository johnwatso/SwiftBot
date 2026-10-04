import SwiftUI

/// Read-only facts about the host, styled like a macOS inspector: a quiet
/// glyph and label column, values beside them, spacing rather than rules
/// between rows. No preferences live here; those belong in Settings.
struct SystemDetailsSection: View {
    let details: HostDetails
    let meshRole: String

    var body: some View {
        ConsoleSection("System") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 14) {
                SystemRow("Computer", symbol: "desktopcomputer") {
                    Text(details.computerName)
                }
                SystemRow("Hardware", symbol: "cpu") {
                    Text(details.hardware)
                }
                SystemRow("macOS", symbol: "apple.logo") {
                    Text(details.operatingSystem)
                }
                SystemRow("SwiftBot", symbol: "app.badge") {
                    Text(details.versionWithBuild)
                    Caption(details.buildChannel)
                }
                SystemRow("SwiftMesh Role", symbol: "point.3.connected.trianglepath.dotted") {
                    Text(meshRole)
                }
            }
        }
    }
}

/// One inspector row: glyph and label in the leading column, value beside it.
private struct SystemRow<Value: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var value: Value

    init(_ title: String, symbol: String, @ViewBuilder value: () -> Value) {
        self.title = title
        self.symbol = symbol
        self.value = value()
    }

    var body: some View {
        GridRow {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
            }
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.leading)

            VStack(alignment: .leading, spacing: 2) {
                value
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
