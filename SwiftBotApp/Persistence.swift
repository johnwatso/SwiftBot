import Foundation

actor ConfigStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = "settings.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SwiftBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> BotSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? decoder.decode(BotSettings.self, from: data)
        else { return BotSettings() }
        return settings
    }

    func save(_ settings: BotSettings) throws {
        let data = try encoder.encode(settings)
        try data.write(to: url, options: .atomic)
    }
}

actor RuleConfigStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(filename: String = "rules.json") {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SwiftBot", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.url = folder.appendingPathComponent(filename)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> [Rule]? {
        guard let data = try? Data(contentsOf: url),
              let rules = try? decoder.decode([Rule].self, from: data)
        else { return nil }
        return rules
    }

    func save(_ rules: [Rule]) throws {
        let data = try encoder.encode(rules)
        try data.write(to: url, options: .atomic)
    }
}

@MainActor
final class LogStore: ObservableObject {
    @Published var lines: [String] = []
    @Published var autoScroll = true

    func append(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        lines.append("[\(stamp)] \(line)")
        if lines.count > 500 {
            lines.removeFirst(lines.count - 500)
        }
    }

    func clear() {
        lines.removeAll()
    }

    func fullLog() -> String {
        lines.joined(separator: "\n")
    }
}
