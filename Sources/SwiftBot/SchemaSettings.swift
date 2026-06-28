import SwiftUI

enum SettingType: Hashable {
    case toggle
    case picker(options: [String])
    case text
    case secureText
}

struct Setting: Identifiable, Hashable {
    let key: String
    let title: String
    let description: String?
    let type: SettingType

    var id: String { key }

    init(key: String, title: String, description: String? = nil, type: SettingType) {
        self.key = key
        self.title = title
        self.description = description
        self.type = type
    }
}

struct SettingSection: Identifiable, Hashable {
    let title: String
    let settings: [Setting]

    var id: String { title }
}

enum SettingValue: Hashable {
    case toggle(Bool)
    case text(String)

    var boolValue: Bool? {
        guard case .toggle(let value) = self else { return nil }
        return value
    }

    var textValue: String? {
        guard case .text(let value) = self else { return nil }
        return value
    }
}

struct SettingsView: View {
    let sections: [SettingSection]
    @Binding var values: [String: SettingValue]
    var onChange: ((String, SettingValue) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(section.settings.enumerated()), id: \.element.id) { index, setting in
                            SettingRow(setting: setting, value: binding(for: setting))
                            if index < section.settings.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    private func binding(for setting: Setting) -> Binding<SettingValue> {
        Binding(
            get: { values[setting.key] ?? setting.defaultValue },
            set: { updated in
                values[setting.key] = updated
                onChange?(setting.key, updated)
            }
        )
    }
}

struct SettingRow: View {
    let setting: Setting
    @Binding var value: SettingValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch setting.type {
            case .toggle:
                Toggle(setting.title, isOn: toggleBinding)
                    .toggleStyle(.switch)
            case .picker(let options):
                Picker(setting.title, selection: textBinding) {
                    ForEach(options, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .pickerStyle(.menu)
            case .text:
                TextField(setting.title, text: textBinding)
            case .secureText:
                SecureField(setting.title, text: textBinding)
            }

            if let description = setting.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { value.boolValue ?? false },
            set: { updated in value = .toggle(updated) }
        )
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { value.textValue ?? "" },
            set: { updated in value = .text(updated) }
        )
    }
}

private extension Setting {
    var defaultValue: SettingValue {
        switch type {
        case .toggle:
            return .toggle(false)
        case .picker(let options):
            return .text(options.first ?? "")
        case .text:
            return .text("")
        case .secureText:
            return .text("")
        }
    }
}
