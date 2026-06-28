import SwiftUI

/// A text field that pops a variable suggestion list when the user types an
/// open brace followed by partial text (e.g. `{dura` → suggests `{duration}`).
///
/// Use in place of a plain `TextField` for any rule-template input that
/// supports `{variable}` substitution (Message, AI prompt, Log text,
/// Webhook body). Suggestions are filtered to the variables the supplied
/// `triggerKind` actually populates.
struct VariableAutocompleteField: View {
    @Binding var text: String
    let placeholder: String
    let triggerKind: Automations.TriggerKind
    let multiline: Bool

    init(
        text: Binding<String>,
        placeholder: String,
        triggerKind: Automations.TriggerKind,
        multiline: Bool = false
    ) {
        self._text = text
        self.placeholder = placeholder
        self.triggerKind = triggerKind
        self.multiline = multiline
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            field
            if !suggestions.isEmpty {
                suggestionList
            }
        }
    }

    @ViewBuilder
    private var field: some View {
        if multiline {
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
        } else {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }

    // MARK: - Suggestion logic

    /// Returns the partial text after the last unmatched `{`, or nil if not
    /// currently mid-token. "Unmatched" means there's no `}` or whitespace
    /// after the last `{`.
    private var activePartial: String? {
        guard let lastOpen = text.lastIndex(of: "{") else { return nil }
        let after = text[text.index(after: lastOpen)...]
        if after.contains("}") || after.contains(" ") || after.contains("\n") {
            return nil
        }
        return String(after)
    }

    private var suggestions: [Automations.Variable] {
        guard let partial = activePartial else { return [] }
        let lower = partial.lowercased()
        return Automations.Variable.allCases
            .filter { $0.appliesTo(triggerKind) }
            .filter { v in
                guard !lower.isEmpty else { return true }
                // Match against the token without braces and the friendly label.
                let token = v.rawValue.dropFirst().dropLast().lowercased()
                return token.hasPrefix(lower) || v.label.lowercased().contains(lower)
            }
            .prefix(6)
            .map { $0 }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { v in
                Button(action: { commit(v) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "curlybraces")
                            .font(.caption)
                            .foregroundStyle(.tint)
                        Text(v.label)
                            .font(.subheadline)
                        Spacer()
                        Text(v.rawValue)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if v != suggestions.last { Divider() }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private func commit(_ v: Automations.Variable) {
        guard let lastOpen = text.lastIndex(of: "{") else { return }
        let head = text[..<lastOpen]
        text = String(head) + v.rawValue
    }
}
