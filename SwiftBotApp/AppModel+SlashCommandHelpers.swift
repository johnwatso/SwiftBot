import Foundation

extension AppModel {
    func allSlashCommandDefinitions() -> [[String: Any]] {
        var definitions: [[String: Any]] = [
            ["name": "help", "description": "Show help for SwiftBot", "type": 1, "options": [["type": 3, "name": "command", "description": "Optional command name", "required": false]]],
            ["name": "ping", "description": "Check if bot is alive", "type": 1],
            ["name": "roll", "description": "Roll dice, example: 2d6", "type": 1, "options": [["type": 3, "name": "notation", "description": "Dice notation NdS", "required": true]]],
            ["name": "8ball", "description": "Ask the magic 8-ball", "type": 1, "options": [["type": 3, "name": "question", "description": "Your yes/no question", "required": true]]],
            ["name": "poll", "description": "Create a simple poll prompt", "type": 1, "options": [["type": 3, "name": "question", "description": "Poll question", "required": true]]],
            ["name": "userinfo", "description": "Show user info", "type": 1],
            // swiftlint:disable:next line_length
            ["name": "cluster", "description": "Cluster status/probe/test", "type": 1, "options": [["type": 3, "name": "action", "description": "status | test | probe", "required": false, "choices": [["name": "status", "value": "status"], ["name": "test", "value": "test"], ["name": "probe", "value": "probe"]]]]],
            ["name": "debug", "description": "Admin diagnostics", "type": 1],
            ["name": "notifystatus", "description": "Show notification config status", "type": 1],
            ["name": "setchannel", "description": "Set this channel as notifications channel", "type": 1],
            ["name": "ignorechannel", "description": "Manage ignored voice channels", "type": 1, "options": [
                ["type": 3, "name": "action", "description": "add | remove | list", "required": true, "choices": [["name": "add", "value": "add"], ["name": "remove", "value": "remove"], ["name": "list", "value": "list"]]],
                ["type": 7, "name": "channel", "description": "Channel for add/remove", "required": false]
            ]],
            ["name": "weekly", "description": "Show weekly summary", "type": 1],
            ["name": "bugreport", "description": "Show bug tracking status counts", "type": 1],
            ["name": "logabug", "description": "Create a tracked bug from typed error text", "type": 1, "options": [["type": 3, "name": "error", "description": "Bug/error details", "required": true]]],
            ["name": "featurerequest", "description": "Submit a feature request to swiftbot-dev", "type": 1, "options": [
                ["type": 3, "name": "feature", "description": "Feature request details", "required": true],
                ["type": 3, "name": "reason", "description": "Why this feature is needed (optional)", "required": false]
            ]],
            ["name": "image", "description": "Generate an image with OpenAI", "type": 1, "options": [["type": 3, "name": "prompt", "description": "Image prompt", "required": true]]],
            ["name": "music", "description": "Search music and get Apple/Spotify/YouTube links", "type": 1, "options": [
                ["type": 5, "name": "help", "description": "Show detailed music + playlist help", "required": false],
                ["type": 3, "name": "query", "description": "Track lookup query", "required": false],
                ["type": 3, "name": "title", "description": "Song title", "required": false],
                ["type": 3, "name": "artist", "description": "Artist name", "required": false]
            ]],
            ["name": "miner", "description": "Check or set up your SwiftMiner drops miner", "type": 1, "options": [
                ["type": 3, "name": "action", "description": "status | setup | health", "required": false, "choices": [
                    ["name": "status", "value": "status"],
                    ["name": "setup", "value": "setup"],
                    ["name": "health", "value": "health"]
                ]]
            ]],
            ["name": "playlist", "description": "Import a playlist URL into a thread with per-track links", "type": 1, "options": [
                ["type": 3, "name": "url", "description": "Playlist URL (Spotify/Apple/YouTube)", "required": true],
                ["type": 3, "name": "name", "description": "Optional thread name", "required": false],
                ["type": 4, "name": "limit", "description": "Max tracks to import (1-100)", "required": false]
            ]],
            ["name": "wiki", "description": "Query WikiBridge", "type": 1, "options": [["type": 3, "name": "query", "description": "Your wiki query", "required": true]]],
            ["name": "compare", "description": "Compare two THE FINALS weapons", "type": 1, "options": [
                ["type": 3, "name": "weapon_a", "description": "First weapon", "required": true],
                ["type": 3, "name": "weapon_b", "description": "Second weapon", "required": true]
            ]],
            ["name": "meta", "description": "Fetch current THE FINALS meta from Skycoach", "type": 1],
            ["name": "steam", "description": "Search Steam for game info and player counts", "type": 1, "options": [
                ["type": 3, "name": "action", "description": "Game name to search for", "required": true]
            ]],
            ["name": "timestamp", "description": "Convert a natural-language time into a Discord timestamp", "type": 1, "options": [
                ["type": 3, "name": "when", "description": "e.g. 6pm, 6pm friday, 6:15 friday the 13th, in 2 hours", "required": true]
            ]],
            ["name": "sweep", "description": "Run, preview, or pause Sweep rules", "type": 1, "options": [
                ["type": 3, "name": "action", "description": "run | preview | pause | resume | status", "required": false, "choices": [
                    ["name": "run", "value": "run"],
                    ["name": "preview", "value": "preview"],
                    ["name": "pause", "value": "pause"],
                    ["name": "resume", "value": "resume"],
                    ["name": "status", "value": "status"]
                ]]
            ]]
        ]

        var existingNames = Set(definitions.compactMap { $0["name"] as? String })
        for source in orderedEnabledWikiSources() {
            for command in source.commands where command.enabled {
                let name = discordSlashSafeWikiCommandName(command.trigger)
                guard !name.isEmpty, !existingNames.contains(name) else { continue }
                existingNames.insert(name)

                let description = command.description.trimmingCharacters(in: .whitespacesAndNewlines)
                definitions.append([
                    "name": name,
                    "description": description.isEmpty ? "Query \(source.name)" : String(description.prefix(100)),
                    "type": 1,
                    "options": [[
                        "type": 3,
                        "name": "query",
                        "description": "Wiki query",
                        "required": true
                    ]]
                ])
            }
        }

        return definitions
    }

    func buildSlashCommandDefinitions() -> [[String: Any]] {
        guard settings.commandsEnabled, settings.slashCommandsEnabled else { return [] }
        return allSlashCommandDefinitions().filter { raw in
            guard let name = raw["name"] as? String else { return true }
            return isCommandEnabled(name: name, surface: "slash")
        }
    }

    func discordSlashSafeWikiCommandName(_ trigger: String) -> String {
        let normalized = normalizedWikiCommandTrigger(trigger)
        let characters = normalized.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(characters)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !collapsed.isEmpty else { return "" }
        return String(collapsed.prefix(32))
    }
}
