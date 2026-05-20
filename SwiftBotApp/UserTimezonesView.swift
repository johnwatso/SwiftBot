import SwiftUI

// MARK: - Command Settings Sheet

struct CommandSettingsSheet: View {
    let commandName: String
    let onClose: () -> Void

    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 460, idealHeight: 560)
    }

    private var headerTitle: String {
        switch commandName.lowercased() {
        case "timestamp": return "Configure /timestamp"
        default: return "Configure /\(commandName)"
        }
    }

    private var headerSubtitle: String {
        switch commandName.lowercased() {
        case "timestamp":
            return "Map each Discord user to their IANA time zone so /timestamp interprets times like \"6pm friday\" in the right zone."
        default:
            return ""
        }
    }

    private var headerIcon: String {
        switch commandName.lowercased() {
        case "timestamp": return "clock.badge.checkmark"
        default: return "gearshape.fill"
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: headerIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(.title3.weight(.semibold))
                if !headerSubtitle.isEmpty {
                    Text(headerSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var content: some View {
        switch commandName.lowercased() {
        case "timestamp":
            UserTimezonesEditor()
        default:
            Text("No configuration available for /\(commandName).")
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done") {
                onClose()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - User Timezones Editor

struct UserTimezonesEditor: View {
    @EnvironmentObject var app: AppModel

    @State private var newUserID: String = ""
    @State private var newTimeZoneID: String = TimeZone.current.identifier
    @State private var addPickerSelection: String = ""

    private static let allTimeZoneIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    private var sortedMappings: [(userID: String, timeZoneID: String)] {
        app.settings.userTimezones
            .map { (userID: $0.key, timeZoneID: $0.value) }
            .sorted { lhs, rhs in
                displayName(for: lhs.userID).localizedCaseInsensitiveCompare(displayName(for: rhs.userID))
                    == .orderedAscending
            }
    }

    private func displayName(for userID: String) -> String {
        if let name = app.knownUsersById[userID], !name.isEmpty {
            return name
        }
        return "Unknown user"
    }

    /// Only real humans: must be in the guild-member set, must not be a bot,
    /// and must have a non-empty username we can show.
    private var humanUsers: [(id: String, name: String)] {
        let bots = app.knownBotUserIds
        let members = app.knownGuildMemberIds
        return app.knownUsersById
            .filter { entry in
                guard !entry.value.isEmpty else { return false }
                guard members.contains(entry.key) else { return false }
                return !bots.contains(entry.key)
            }
            .map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var unassignedKnownUsers: [(id: String, name: String)] {
        let assigned = Set(app.settings.userTimezones.keys)
        return humanUsers.filter { !assigned.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            mappingsSection
            Divider().opacity(0.4)
            addSection
            tip
        }
    }

    private var mappingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Mappings")
                    .font(.headline)
                Spacer()
                Text("\(sortedMappings.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.fill.tertiary, in: Capsule())
            }

            if sortedMappings.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .foregroundStyle(.secondary)
                    Text("No users configured yet. Add one below — until then, /timestamp uses this Mac's time zone (`\(TimeZone.current.identifier)`) and warns the user.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    ForEach(sortedMappings, id: \.userID) { mapping in
                        mappingRow(userID: mapping.userID, currentTZ: mapping.timeZoneID)
                    }
                }
            }
        }
    }

    private func mappingRow(userID: String, currentTZ: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
            Text(displayName(for: userID))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Spacer()
            TimeZoneSearchField(selection: Binding(
                get: { currentTZ },
                set: { newValue in
                    app.settings.userTimezones[userID] = newValue
                    app.persistSettingsQuietly()
                }
            ))
            .frame(maxWidth: 260)
            Button(role: .destructive) {
                app.settings.userTimezones.removeValue(forKey: userID)
                app.persistSettingsQuietly()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove this mapping")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a User")
                .font(.headline)

            HStack(spacing: 8) {
                if unassignedKnownUsers.isEmpty {
                    TextField("Discord user ID", text: $newUserID)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Picker("", selection: $addPickerSelection) {
                        Text("Pick a known user…").tag("")
                        ForEach(unassignedKnownUsers, id: \.id) { user in
                            Text(user.name).tag(user.id)
                        }
                        Divider()
                        Text("Enter ID manually…").tag("__manual__")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)

                    if addPickerSelection == "__manual__" {
                        TextField("User ID", text: $newUserID)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                    }
                }

                TimeZoneSearchField(selection: $newTimeZoneID)
                    .frame(maxWidth: 260)

                Button {
                    addMapping()
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAddMapping)
            }
        }
    }

    private var tip: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("IANA identifiers look like `America/New_York`, `Europe/London`, `Australia/Sydney`. Discord timestamps render in each viewer's local zone — what we configure here only affects how SwiftBot interprets the user's input.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canAddMapping: Bool {
        let id = resolvedNewUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, TimeZone(identifier: newTimeZoneID) != nil else { return false }
        return !app.settings.userTimezones.keys.contains(id)
    }

    private var resolvedNewUserID: String {
        if !unassignedKnownUsers.isEmpty,
           addPickerSelection != "",
           addPickerSelection != "__manual__" {
            return addPickerSelection
        }
        return newUserID
    }

    private func addMapping() {
        let id = resolvedNewUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, TimeZone(identifier: newTimeZoneID) != nil else { return }
        app.settings.userTimezones[id] = newTimeZoneID
        app.persistSettingsQuietly()
        newUserID = ""
        addPickerSelection = ""
    }

}

// MARK: - Time Zone Search Field

struct TimeZoneSearchField: View {
    @Binding var selection: String

    @State private var query: String = ""
    @State private var showingPopover = false

    private static let allIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    private var matches: [String] {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else {
            // No query: show a sensible default list — selection first, then a curated common set, then everything else.
            let curated = [
                "America/Los_Angeles", "America/Denver", "America/Chicago",
                "America/New_York", "America/Sao_Paulo",
                "Europe/London", "Europe/Berlin", "Europe/Paris", "Europe/Madrid", "Europe/Rome",
                "Africa/Johannesburg",
                "Asia/Dubai", "Asia/Kolkata", "Asia/Singapore",
                "Asia/Shanghai", "Asia/Tokyo",
                "Australia/Perth", "Australia/Sydney",
                "Pacific/Auckland"
            ]
            var seen: Set<String> = []
            var ordered: [String] = []
            for id in [selection] + curated where Self.allIdentifiers.contains(id) {
                if seen.insert(id).inserted { ordered.append(id) }
            }
            return ordered
        }
        let normalized = raw.replacingOccurrences(of: " ", with: "_")
        return Self.allIdentifiers.filter { id in
            id.lowercased().contains(normalized)
        }.prefix(80).map { $0 }
    }

    var body: some View {
        Button {
            showingPopover = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Self.displayLabel(for: selection))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Type a city — e.g. London, New York, Sydney", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if matches.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "questionmark.circle")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No matches.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Try a different city or region.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches, id: \.self) { identifier in
                            resultRow(identifier)
                        }
                    }
                }
            }
        }
        .frame(width: 360, height: 340)
    }

    private func resultRow(_ identifier: String) -> some View {
        Button {
            selection = identifier
            showingPopover = false
            query = ""
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.cityName(for: identifier))
                        .font(.subheadline.weight(.medium))
                    Text(identifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(Self.offsetLabel(for: identifier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if identifier == selection {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                identifier == selection
                    ? Color.blue.opacity(0.12)
                    : Color.clear
            )
        }
        .buttonStyle(.plain)
    }

    private static func displayLabel(for identifier: String) -> String {
        let city = cityName(for: identifier)
        let offset = offsetLabel(for: identifier)
        return offset.isEmpty ? city : "\(city) (\(offset))"
    }

    private static func cityName(for identifier: String) -> String {
        let parts = identifier.split(separator: "/")
        if let last = parts.last {
            return last.replacingOccurrences(of: "_", with: " ")
        }
        return identifier
    }

    private static func offsetLabel(for identifier: String) -> String {
        guard let tz = TimeZone(identifier: identifier) else { return "" }
        let seconds = tz.secondsFromGMT(for: Date())
        let sign = seconds >= 0 ? "+" : "-"
        let abs = Swift.abs(seconds)
        let hours = abs / 3600
        let minutes = (abs % 3600) / 60
        if minutes == 0 {
            return "GMT\(sign)\(hours)"
        }
        return String(format: "GMT%@%d:%02d", sign, hours, minutes)
    }
}
