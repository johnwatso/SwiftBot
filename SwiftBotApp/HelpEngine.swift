import Foundation

// MARK: - Command Catalog

enum CommandCategory: String, CaseIterable {
    case general    = "General"
    case fun        = "Fun"
    case moderation = "Server"
    case cluster    = "SwiftMesh"
    case wiki       = "WikiBridge"
}

struct CommandEntry {
    let name: String
    let aliases: [String]
    let usage: String
    let description: String
    let examples: [String]
    let category: CommandCategory
    let isAdminOnly: Bool
}

struct WikiCommandInfo {
    let trigger: String
    let sourceName: String
    let description: String
}

struct CommandCatalog {
    let entries: [CommandEntry]
    let configuredWikiSources: [String]

    init(entries: [CommandEntry], configuredWikiSources: [String] = []) {
        self.entries = entries
        self.configuredWikiSources = configuredWikiSources
    }

    static func build(prefix: String, wikiCommands: [WikiCommandInfo]) -> CommandCatalog {
        var entries: [CommandEntry] = [
            CommandEntry(
                name: "help",
                aliases: [],
                usage: "\(prefix)help [command]",
                description: "Shows all commands, or detailed help for a specific command.",
                examples: ["\(prefix)help", "\(prefix)help roll"],
                category: .general,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "ping",
                aliases: [],
                usage: "\(prefix)ping",
                description: "Checks if the bot is alive.",
                examples: ["\(prefix)ping"],
                category: .general,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "roll",
                aliases: [],
                usage: "\(prefix)roll NdS",
                description: "Rolls N dice with S sides. For example, 2d6 rolls two six-sided dice.",
                examples: ["\(prefix)roll 2d6", "\(prefix)roll 1d20"],
                category: .fun,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "8ball",
                aliases: [],
                usage: "\(prefix)8ball <question>",
                description: "Asks the magic 8-ball a yes/no question.",
                examples: ["\(prefix)8ball Will it rain today?"],
                category: .fun,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "poll",
                aliases: [],
                usage: "\(prefix)poll \"Question\" \"Option 1\" \"Option 2\"",
                description: "Creates a poll. Members vote by adding reactions to the message.",
                examples: ["\(prefix)poll \"Favourite colour?\" \"Red\" \"Blue\""],
                category: .general,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "userinfo",
                aliases: [],
                usage: "\(prefix)userinfo [@user]",
                description: "Displays info about yourself or a mentioned user.",
                examples: ["\(prefix)userinfo", "\(prefix)userinfo @someone"],
                category: .general,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "setchannel",
                aliases: [],
                usage: "\(prefix)setchannel",
                description: "Sets the current channel as the bot's notification channel.",
                examples: ["\(prefix)setchannel"],
                category: .moderation,
                isAdminOnly: true
            ),
            CommandEntry(
                name: "ignorechannel",
                aliases: [],
                usage: "\(prefix)ignorechannel #channel | list | remove #channel",
                description: "Manages the channel ignore list.",
                examples: ["\(prefix)ignorechannel #spam", "\(prefix)ignorechannel list"],
                category: .moderation,
                isAdminOnly: true
            ),
            CommandEntry(
                name: "notifystatus",
                aliases: [],
                usage: "\(prefix)notifystatus",
                description: "Reports the current notification channel configuration.",
                examples: ["\(prefix)notifystatus"],
                category: .moderation,
                isAdminOnly: false
            ),
            CommandEntry(
                name: "cluster",
                aliases: ["worker"],
                usage: "\(prefix)cluster [status | test | probe]",
                description: "SwiftMesh cluster management — shows status, tests connections, or probes nodes.",
                examples: ["\(prefix)cluster", "\(prefix)cluster status", "\(prefix)cluster probe"],
                category: .cluster,
                isAdminOnly: false
            ),
        ]

        var seen: Set<String> = []
        var sourceSeen: Set<String> = []
        var sources: [String] = []
        for wiki in wikiCommands {
            let sourceName = wiki.sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sourceName.isEmpty && sourceSeen.insert(sourceName.lowercased()).inserted {
                sources.append(sourceName)
            }

            let key = wiki.trigger.lowercased()
            guard seen.insert(key).inserted else { continue }
            let desc = "Gathers info from a configured Wiki source."

            entries.append(CommandEntry(
                name: key,
                aliases: [],
                usage: "\(prefix)\(key) <query>",
                description: desc,
                examples: ["\(prefix)\(key) example query"],
                category: .wiki,
                isAdminOnly: false
            ))
        }

        return CommandCatalog(
            entries: entries,
            configuredWikiSources: sources.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        )
    }

    /// Looks up an entry by command name or alias.
    func entry(for query: String) -> CommandEntry? {
        let q = query.lowercased()
        return entries.first { $0.name == q || $0.aliases.contains(q) }
    }

    /// The set of all approved command names and aliases — used to constrain AI output.
    var approvedNames: Set<String> {
        Set(entries.flatMap { [$0.name] + $0.aliases })
    }
}

// MARK: - Help Renderer

struct HelpRenderer {
    let prefix: String
    let helpSettings: HelpSettings

    static let embedColor = 5793266  // #588AE2 — soft blue

    static let orderedCategories: [CommandCategory] = [.general, .fun, .moderation, .cluster, .wiki]

    // MARK: Embed overview (for `!help` — primary path)

    /// Returns a Discord embed payload for the full command overview.
    /// Fields are always catalog-sourced; AI can optionally supply a description.
    func embedOverview(catalog: CommandCatalog, aiDescription: String? = nil) -> [String: Any] {
        let grouped = Dictionary(grouping: catalog.entries, by: \.category)

        var fields: [[String: Any]] = []
        for category in Self.orderedCategories {
            guard let cmds = grouped[category], !cmds.isEmpty else { continue }
            var value = cmds
                .map { "`\($0.name)` — \($0.description)" }
                .joined(separator: "\n")
            if category == .wiki, !catalog.configuredWikiSources.isEmpty {
                value += "\n\nConfigured wikis: " + catalog.configuredWikiSources.joined(separator: ", ")
            }
            fields.append(["name": category.rawValue, "value": value, "inline": false])
        }

        var footerText = "Type \(prefix)help <command> for usage and examples."
        if !helpSettings.customFooter.trimmed.isEmpty {
            footerText += "  \(helpSettings.customFooter.trimmed)"
        }

        var embed: [String: Any] = [
            "title": "SwiftBot Commands",
            "color": Self.embedColor,
            "fields": fields,
            "footer": ["text": footerText]
        ]

        // Description: AI-generated intro > custom intro > nothing
        if let ai = sanitizedAIIntro(aiDescription) {
            embed["description"] = ai
        } else if !helpSettings.customIntro.trimmed.isEmpty {
            embed["description"] = helpSettings.customIntro.trimmed
        }

        return embed
    }

    // MARK: Text overview (fallback / preview / AI rewrite input)

    func overview(catalog: CommandCatalog) -> String {
        var lines: [String] = []

        if !helpSettings.customIntro.trimmed.isEmpty {
            lines.append(helpSettings.customIntro.trimmed)
        }

        let grouped = Dictionary(grouping: catalog.entries, by: \.category)

        for category in Self.orderedCategories {
            guard let cmds = grouped[category], !cmds.isEmpty else { continue }
            var list = cmds.map { "`\($0.name)` — \($0.description)" }.joined(separator: "\n")
            if category == .wiki, !catalog.configuredWikiSources.isEmpty {
                list += "\nConfigured wikis: " + catalog.configuredWikiSources.joined(separator: ", ")
            }
            lines.append("**\(category.rawValue)**\n\(list)")
        }

        lines.append("*Type `\(prefix)help <command>` for usage and examples.*")

        if !helpSettings.customFooter.trimmed.isEmpty {
            lines.append(helpSettings.customFooter.trimmed)
        }

        return lines.joined(separator: "\n\n")
    }

    // MARK: Detail (for `!help <command>`)

    func detail(for entry: CommandEntry) -> String {
        var lines: [String] = []
        lines.append("**`\(entry.usage)`**")
        lines.append(entry.description)
        if !entry.aliases.isEmpty {
            lines.append("Aliases: " + entry.aliases.map { "`\(prefix)\($0)`" }.joined(separator: ", "))
        }
        if !entry.examples.isEmpty {
            lines.append("Examples: " + entry.examples.map { "`\($0)`" }.joined(separator: " · "))
        }
        if entry.isAdminOnly {
            lines.append("⚙️ Requires server management permissions.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: AI system prompt

    /// Builds a constrained system prompt for the AI intro rewrite.
    /// The AI is only asked for a brief intro/description — the catalog fields are always deterministic.
    func aiIntroPrompt(catalog: CommandCatalog) -> String {
        let approvedList = catalog.entries
            .map { "• \($0.name): \($0.description)" }
            .joined(separator: "\n")
        let toneInstruction: String
        switch helpSettings.tone {
        case .concise:  toneInstruction = "One sentence, very brief."
        case .friendly: toneInstruction = "Warm and friendly, 1–2 sentences."
        case .detailed: toneInstruction = "Informative, 2–3 sentences."
        }
        return """
        You are SwiftBot, a Discord bot. Write a short intro sentence for a help embed listing the bot's commands.
        \(toneInstruction)
        Do NOT list or mention commands — the embed already includes them.
        Do NOT include prefaces or meta text like "Sure!", "Here is", or "short intro sentence".
        The approved commands are (for context only, do not repeat in your reply):
        \(approvedList)
        Reply with only the intro text. No markdown title. No command names.
        """
    }

    /// Filters out meta/instructional echoes so embed descriptions stay natural.
    private func sanitizedAIIntro(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        // Reject common instructional echoes from model outputs.
        if (lower.contains("intro sentence") && lower.contains("help embed")) ||
            lower.contains("listing the bot's commands") ||
            lower.hasPrefix("sure! here's") ||
            lower.hasPrefix("sure, here's") {
            return nil
        }

        return text
    }
}

// MARK: - Private helpers

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
