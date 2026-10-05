import SwiftUI
import AppKit
import RecordingsKit
import UniformTypeIdentifiers

/// Host-side folder management; browsing and playback stay in the Web Interface.
struct RecordingsPage: View {
    @EnvironmentObject private var app: AppModel
    @State private var library: MediaLibraryPayload?
    @State private var isScanning = false
    @State private var scanGeneration = 0
    @State private var folderStatuses: [UUID: String] = [:]

    var body: some View {
        ConsoleSettingsPage(title: "Recordings", subtitle: "Recording folders and playback copies on this Mac.") {
            HStack(spacing: 12) {
                Button(isScanning ? "Scanning…" : "Refresh", systemImage: "arrow.clockwise") {
                    Task { await refresh(force: true) }
                }
                .buttonStyle(.glass)
                .disabled(isScanning)
                Button("Open Web Interface", systemImage: "arrow.up.forward.app") { app.launchAdminWebUI() }
                    .buttonStyle(.glassProminent)
                    .disabled(!app.settings.adminWebUI.enabled)
            }
        } summary: {
            ServiceSummaryCard(
                title: "Local Library",
                symbol: "video.fill",
                health: libraryHealth.health,
                summary: libraryHealth.summary,
                detail: libraryHealth.detail,
                facts: [
                    ("Folders", String(app.localRecordingSources.count)),
                    ("Enabled", String(app.localRecordingSources.filter(\.isEnabled).count)),
                    ("Indexed Recordings", library.map { String($0.items.count) } ?? "—"),
                    ("Last Scan", library?.generatedAt.formatted(date: .omitted, time: .shortened) ?? "—")
                ]
            )
        } content: {
            SettingsForm {
                LocalRecordingsPreferencesSection(folderStatuses: folderStatuses)
            }
        }
        .task(id: app.localRecordingSources) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private var libraryHealth: (health: ServiceHealth, summary: String, detail: String) {
        let enabled = app.localRecordingSources.filter(\.isEnabled)
        if app.localRecordingSources.isEmpty {
            return (.disabled, "No Folders", "Add a recording folder below. Browse and play recordings in the Web Interface.")
        }
        if enabled.isEmpty {
            return (.disabled, "Off", "Every folder is turned off.")
        }
        let unavailable = enabled.filter { folderStatuses[$0.id]?.hasPrefix("Unavailable") == true }
        if !unavailable.isEmpty {
            let names = unavailable.map { $0.name.isEmpty ? $0.normalizedRootPath : $0.name }
            return (.warning, "Folder Unavailable", "Check the path, volume, or access for: \(names.joined(separator: ", ")).")
        }
        if isScanning && library == nil {
            return (.pending, "Scanning", "Indexing recording folders on this Mac.")
        }
        return (.healthy, "Ready", "Browse and play recordings in the Web Interface.")
    }

    private func refresh(force: Bool = false) async {
        // A cancelled scan must not clear the spinner of the scan replacing it.
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        defer { if generation == scanGeneration { isScanning = false } }
        let sources = app.localRecordingSources
        let statuses = await Task.detached(priority: .utility) {
            var result: [UUID: String] = [:]
            for source in sources {
                if !source.isEnabled {
                    result[source.id] = "Disabled"
                } else if source.normalizedRootPath.isEmpty {
                    result[source.id] = "Choose a folder"
                } else {
                    let url = URL(fileURLWithPath: source.normalizedRootPath, isDirectory: true)
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    result[source.id] = isDirectory && FileManager.default.isReadableFile(atPath: url.path)
                        ? "Available" : "Unavailable — check the path, volume, or access permissions"
                }
            }
            return result
        }.value
        guard !Task.isCancelled else { return }
        folderStatuses = statuses
        if force { await app.mediaLibraryIndexer.invalidate() }
        let snapshot = await app.localMediaLibrarySnapshot()
        guard !Task.isCancelled else { return }
        library = snapshot
    }
}

enum RecordingsDashboardSummary {
    @MainActor
    static func overviewMetric(app: AppModel) -> DashboardMetricDescriptor {
        DashboardMetricDescriptor(
            id: "recentMedia",
            title: "New Recordings",
            value: "\(app.recentMediaCount24h)",
            subtitle: "last 24 hours",
            symbol: "film.fill",
            detail: "Across media sources",
            color: .teal
        )
    }

    @MainActor
    static func metrics(
        app: AppModel,
        items: [AdminWebMediaItemPayload],
        topGameName: String,
        topClipCount: Int,
        remoteNodeText: String,
        remoteNodeColor: Color
    ) -> [DashboardMetricDescriptor] {
        let lastAddedText: String = {
            guard let date = items.map(\.modifiedAt).max() else { return "No videos yet" }
            return date.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
        }()

        return [
            overviewMetric(app: app),
            DashboardMetricDescriptor(
                id: "recordings-most-clips",
                title: "Most Clips",
                value: topGameName,
                subtitle: "\(topClipCount) clips",
                symbol: "trophy.fill",
                color: .orange
            ),
            DashboardMetricDescriptor(
                id: "recordings-watched",
                title: "Watched",
                value: "\(app.mediaPlaybackStarts)",
                subtitle: "\(app.mediaPlaybackUniqueItemCount) unique",
                symbol: "play.rectangle.fill",
                color: .cyan
            ),
            DashboardMetricDescriptor(
                id: "recordings-last-added",
                title: "Last Added",
                value: lastAddedText,
                subtitle: "\(items.count) indexed",
                symbol: "clock.fill",
                color: .mint
            ),
            DashboardMetricDescriptor(
                id: "recordings-remote-node",
                title: "Remote Node",
                value: remoteNodeText,
                subtitle: app.settings.clusterMode.displayName,
                symbol: "desktopcomputer.and.arrow.down",
                color: remoteNodeColor
            )
        ]
    }
}

actor RecordingSteamArtworkService {
    static let shared = RecordingSteamArtworkService()

    /// v2: matches saved before the word-order check could be a different
    /// game ("Modern Warfare 4" → 2007's "Call of Duty 4: Modern Warfare").
    private let defaultsKey = "swiftbot.recordings.steamArtworkAppIDs.v2"
    private let manualDefaultsKey = "swiftbot.recordings.steamArtworkManualOverrides"
    private let steamSearchURL = "https://store.steampowered.com/api/storesearch/"
    private let steamCDNBaseURL = "https://cdn.cloudflare.steamstatic.com/steam/apps/"
    private var manualOverrides: [String: String]
    private var cache: [String: String]
    private var failedLookups: Set<String> = []
    private var portraitDataCache: [String: Data] = [:]
    private var gameDetailsCache: [String: (expires: Date, data: Data)] = [:]
    /// Twitch box-art results for games Steam doesn't have; nil = none found.
    private var twitchResults: [String: URL?] = [:]
    private let twitchBoxArtBaseURL = "https://static-cdn.jtvnw.net/ttv-boxart/"

    init() {
        manualOverrides = UserDefaults.standard.dictionary(forKey: manualDefaultsKey) as? [String: String] ?? [:]
        cache = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    func setManualAppID(for gameName: String, appID: String) {
        let normalized = Self.normalized(gameName)
        let trimmed = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            manualOverrides.removeValue(forKey: normalized)
        } else {
            manualOverrides[normalized] = trimmed
        }
        gameDetailsCache.removeValue(forKey: normalized)
        cache.removeValue(forKey: normalized)
        portraitDataCache.removeValue(forKey: normalized)
        twitchResults.removeValue(forKey: normalized)
        failedLookups.remove(normalized)
        UserDefaults.standard.set(manualOverrides, forKey: manualDefaultsKey)
        UserDefaults.standard.set(cache, forKey: defaultsKey)
    }

    func portraitURL(for gameName: String) async -> URL? {
        let normalized = Self.normalized(gameName)
        guard !normalized.isEmpty, normalized != "unknown", normalized != "unlabeled" else { return nil }

        if let appID = manualOverrides[normalized] ?? Self.knownAppIDs[normalized] ?? cache[normalized] {
            return URL(string: "\(steamCDNBaseURL)\(appID)/library_600x900.jpg")
        }

        guard !failedLookups.contains(normalized),
              let appID = await lookupAppID(for: gameName, normalized: normalized) else {
            return await twitchBoxArtURL(for: gameName, normalized: normalized)
        }

        cache[normalized] = appID
        UserDefaults.standard.set(cache, forKey: defaultsKey)
        return URL(string: "\(steamCDNBaseURL)\(appID)/library_600x900.jpg")
    }

    /// Store metadata stays server-side so the WebUI needs no external API access.
    func gameDetailsData(for gameName: String) async -> Data? {
        let key = Self.normalized(gameName)
        if let cached = gameDetailsCache[key], cached.expires > Date() { return cached.data }
        var appID = manualOverrides[key] ?? Self.knownAppIDs[key]
        if appID == nil {
            // Metadata requires an exact title match; artwork's loose search can
            // otherwise select a sequel or unrelated game with a similar name.
            let term = gameName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+?#"))) ?? ""
            if let search = await steamJSON("\(steamSearchURL)?term=\(term)&cc=US&l=en&v=1"),
               let items = search["items"] as? [[String: Any]],
               let match = items.first(where: { Self.normalized($0["name"] as? String ?? "") == key }),
               let id = match["id"] as? Int {
                appID = String(id)
            }
        }
        guard let appID, !appID.isEmpty, appID.allSatisfy({ $0.isNumber }) else { return nil }
        let store = await steamJSON("https://store.steampowered.com/api/appdetails?appids=\(appID)&cc=US&l=en")
        let input = "{\"appid\":\(appID),\"languages\":[\"all\"],\"review_type\":0,\"purchase_type\":1,\"num_per_page\":1}"
        let encoded = input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+?#"))) ?? ""
        let reviews = await steamJSON("https://api.steampowered.com/IUserReviewsService/GetAppReviews/v1/?input_json=\(encoded)")
        guard let entry = store?[appID] as? [String: Any], entry["success"] as? Bool == true,
              let details = entry["data"] as? [String: Any] else { return nil }
        var result: [String: Any] = [
            "appID": appID,
            "description": details["short_description"] as? String ?? "",
            "developers": details["developers"] as? [String] ?? [],
            "genres": (details["genres"] as? [[String: Any]] ?? []).compactMap { $0["description"] as? String }
        ]
        if let response = reviews?["response"] as? [String: Any],
           let summary = response["query_summary"] as? [String: Any],
           let total = summary["total_reviews"] as? Int, total > 0,
           let positive = summary["total_positive"] as? Int {
            result["reviewCount"] = total
            result["positivePercent"] = Int((Double(positive) / Double(total) * 100).rounded())
            result["reviewLabel"] = summary["review_score_desc"] as? String ?? "Steam user reviews"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result) else { return nil }
        gameDetailsCache[key] = (Date().addingTimeInterval(3600), data)
        return data
    }

    private func steamJSON(_ address: String) async -> [String: Any]? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Steam titles matching `term`, for Fix Match. Not cached: it's typed.
    func searchGames(term: String) async -> [(id: String, name: String)] {
        guard var components = URLComponents(string: steamSearchURL) else { return [] }
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "cc", value: "US"),
            URLQueryItem(name: "l", value: "en")
        ]
        guard let address = components.url?.absoluteString,
              let items = await steamJSON(address)?["items"] as? [[String: Any]] else { return [] }
        return items.prefix(10).compactMap { item in
            guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
            return (String(id), name)
        }
    }

    private func lookupAppID(for gameName: String, normalized: String) async -> String? {
        guard var components = URLComponents(string: steamSearchURL) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "term", value: gameName),
            URLQueryItem(name: "cc", value: "US"),
            URLQueryItem(name: "l", value: "en"),
            URLQueryItem(name: "v", value: "1")
        ]
        guard let url = components.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 8
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                return nil
            }

            let candidates: [(id: String, name: String)] = items.compactMap { item in
                guard let id = item["id"] as? Int, let name = item["name"] as? String else { return nil }
                return (String(id), name)
            }

            if let exact = candidates.first(where: { Self.normalized($0.name) == normalized }),
               await portraitExists(appID: exact.id) {
                return exact.id
            }

            // Otherwise only a title with the same words in the same order:
            // Steam ranks "Call of Duty 4: Modern Warfare" first for "Modern
            // Warfare 4", and a wrong poster is worse than Twitch's or none.
            for candidate in candidates where Self.containsInOrder(gameName, within: candidate.name) {
                if await portraitExists(appID: candidate.id) {
                    return candidate.id
                }
            }
        } catch {
            return nil
        }

        failedLookups.insert(normalized)
        return nil
    }

    /// Poster bytes for the WebUI, which can't load Steam's CDN directly
    /// under its content-security policy. Kept in memory for the session.
    func portraitData(for gameName: String) async -> Data? {
        let normalized = Self.normalized(gameName)
        if let cached = portraitDataCache[normalized] { return cached }
        guard let url = await portraitURL(for: gameName) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty else {
            return nil
        }
        portraitDataCache[normalized] = data
        return data
    }

    /// Twitch box art by game name, for games not on Steam (e.g. Minecraft).
    /// Name URLs only resolve for long-established games; anything else
    /// redirects to Twitch's "404_boxart" placeholder, which counts as none.
    private func twitchBoxArtURL(for gameName: String, normalized: String) async -> URL? {
        if let known = twitchResults[normalized] { return known }
        let name = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let url = URL(string: "\(twitchBoxArtBaseURL)\(encoded)-600x800.jpg") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        var found: URL?
        if let (_, response) = try? await URLSession.shared.data(for: request),
           let http = response as? HTTPURLResponse,
           http.statusCode == 200,
           http.url?.path.contains("404_boxart") == false {
            found = url
        }
        twitchResults[normalized] = found
        return found
    }

    private func portraitExists(appID: String) async -> Bool {
        guard let url = URL(string: "\(steamCDNBaseURL)\(appID)/library_600x900.jpg") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// Whether every word of `name` appears in `title`, in the same order.
    static func containsInOrder(_ name: String, within title: String) -> Bool {
        let words = { (text: String) in
            text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        var remaining = words(title)[...]
        for word in words(name) {
            guard let index = remaining.firstIndex(of: word) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "™", with: "")
    }

    private static let knownAppIDs: [String: String] = [
        "the finals": "2073850",
        "call of duty": "1938090",
        "counter-strike 2": "730",
        "counter-strike": "730",
        "dota 2": "570",
        "apex legends": "1172470",
        "pubg: battlegrounds": "578080",
        "pubg": "578080",
        "destiny 2": "1085660",
        "warframe": "230410",
        "rust": "252490",
        "grand theft auto v": "271590",
        "red dead redemption 2": "1174180",
        "helldivers 2": "553850",
        "palworld": "1623730",
        "cyberpunk 2077": "1091500",
        "valheim": "892970",
        "elden ring": "1245620",
        "baldur's gate 3": "1086940",
        "no man's sky": "275850",
        "stardew valley": "413150",
        "terraria": "105600"
    ]
}

enum RecordingCustomArtworkStore {
    private static let defaultsKey = "swiftbot.recordings.customArtworkURLs"

    static func customArtworkURL(for gameName: String) -> URL? {
        guard let path = artworkMap()[key(for: gameName)] else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func setCustomArtwork(from sourceURL: URL, for gameName: String) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        clearCustomArtwork(for: gameName)

        let destination = try artworkDirectory()
            .appendingPathComponent(key(for: gameName))
            .appendingPathExtension(preferredExtension(for: sourceURL))

        try FileManager.default.copyItem(at: sourceURL, to: destination)

        var map = artworkMap()
        map[key(for: gameName)] = destination.path
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    static func clearCustomArtwork(for gameName: String) {
        var map = artworkMap()
        if let path = map.removeValue(forKey: key(for: gameName)) {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    private static func artworkMap() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    private static func artworkDirectory() throws -> URL {
        let directory = SwiftBotStorage.folderURL()
            .appendingPathComponent("RecordingsArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func preferredExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let supported = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"])
        return supported.contains(ext) ? ext : "png"
    }

    private static func key(for gameName: String) -> String {
        let normalized = gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = normalized.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "unknown" : collapsed
    }
}

private extension NSImage {
    static func recordingGameImage(named gameName: String) -> NSImage? {
        let fileName: String
        switch gameName {
        case "THE FINALS":
            fileName = "the-finals"
        case "Minecraft":
            fileName = "minecraft"
        case "Call of Duty":
            fileName = "call-of-duty"
        default:
            return nil
        }
        guard let url = Bundle.main.url(forResource: fileName, withExtension: "png", subdirectory: "admin/games") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

/// Serves a game's poster to the WebUI: custom artwork first, then Steam.
enum RecordingGameArtworkResponder {
    static func response(for gameName: String) async -> BinaryHTTPResponse? {
        let headers = ["Cache-Control": "private, max-age=86400"]
        if let url = RecordingCustomArtworkStore.customArtworkURL(for: gameName),
           let data = try? Data(contentsOf: url) {
            let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            return BinaryHTTPResponse(status: "200 OK", contentType: type, headers: headers, body: data)
        }
        guard let data = await RecordingSteamArtworkService.shared.portraitData(for: gameName) else {
            return nil
        }
        return BinaryHTTPResponse(status: "200 OK", contentType: "image/jpeg", headers: headers, body: data)
    }
}

struct LocalRecordingsPreferencesSection: View {
    @EnvironmentObject private var app: AppModel
    var folderStatuses: [UUID: String] = [:]

    /// Asks for the folder first, so a new row never starts out blank.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        app.mediaLibrarySettings.sources.append(
            MediaLibrarySource(name: url.lastPathComponent, rootPath: url.path)
        )
    }

    private func sourceBinding(for source: MediaLibrarySource) -> Binding<MediaLibrarySource> {
        Binding(
            get: { app.mediaLibrarySettings.sources.first { $0.id == source.id } ?? source },
            set: { newValue in
                guard let index = app.mediaLibrarySettings.sources.firstIndex(where: { $0.id == source.id }) else { return }
                app.mediaLibrarySettings.sources[index] = newValue
            }
        )
    }

    var body: some View {
        Section {
            if app.localRecordingSources.isEmpty {
                ConsoleSettingRow(title: "No folders yet", symbol: "folder", subtitle: "Add the folder your recordings are saved to.")
            }

            // Bind rows by ID, not array position, so removing a folder can't
            // leave another row pointing at a stale index.
            ForEach(app.localRecordingSources) { source in
                RecordingSourceRow(source: sourceBinding(for: source), status: folderStatuses[source.id]) {
                    app.mediaLibrarySettings.sources.removeAll { $0.id == source.id }
                }
            }

            HStack {
                Spacer()
                Button("Add Folder…", systemImage: "plus") { addFolder() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        } header: {
            Text("Folders")
        }
        Section {
            Toggle(isOn: $app.mediaLibrarySettings.fastStartOptimizationEnabled) {
                Text("Fast Start Copies")
                Text("Create optimized MP4 copies for smoother playback. Original recordings are kept.")
            }
            if app.mediaLibrarySettings.fastStartOptimizationEnabled {
                RecordingFastStartFolderRow(path: $app.mediaLibrarySettings.fastStartOutputPath)
            }
        } header: {
            Text("Playback Copies")
        }
    }
}

private struct RecordingFastStartFolderRow: View {
    @Binding var path: String

    var body: some View {
        ConsoleSettingRow(title: "Fast Start Folder", symbol: "folder") {
            HStack(spacing: 8) {
                TextField("~/Movies/SwiftBot Fast Start", text: $path)
                    .textFieldStyle(.plain)
                    .font(.subheadline)

                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url {
                        path = url.path
                    }
                } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("Choose folder")
                .accessibilityLabel("Choose Fast Start output folder")
            }
        }
    }
}

private struct RecordingSourceRow: View {
    @Binding var source: MediaLibrarySource
    var status: String?
    let onDelete: () -> Void

    private var isUnavailable: Bool { status?.hasPrefix("Unavailable") == true }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: isUnavailable ? "exclamationmark.triangle" : "folder")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isUnavailable ? Color.orange : Color.secondary)
                .frame(width: 30, height: 30)
                .background(.primary.opacity(0.05), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                TextField("Folder name", text: $source.name)
                    .textFieldStyle(.plain)
                    .font(.body.weight(.medium))
                Text(source.normalizedRootPath.isEmpty ? "No folder chosen" : source.normalizedRootPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(source.normalizedRootPath)
                    .textSelection(.enabled)
                if let status, status != "Available", status != "Disabled" {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(isUnavailable ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            Button("Change…") { chooseFolder() }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityLabel("Choose folder for \(source.name)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove folder")
            .accessibilityLabel("Remove folder \(source.name)")

            ConsoleRowSwitch(isOn: $source.isEnabled)
                .accessibilityLabel("Enable recording folder \(source.name)")
        }
        .frame(minHeight: 32)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !source.normalizedRootPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: source.normalizedRootPath, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            source.rootPath = url.path
        }
    }
}
