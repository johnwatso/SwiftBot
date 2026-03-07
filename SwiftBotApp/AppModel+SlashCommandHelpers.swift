import Foundation

extension AppModel {
    func allSlashCommandDefinitions() -> [[String: Any]] {
        return [
            ["name": "help", "description": "Show help for SwiftBot", "type": 1, "options": [["type": 3, "name": "command", "description": "Optional command name", "required": false]]],
            ["name": "ping", "description": "Check if bot is alive", "type": 1],
            ["name": "roll", "description": "Roll dice, example: 2d6", "type": 1, "options": [["type": 3, "name": "notation", "description": "Dice notation NdS", "required": true]]],
            ["name": "8ball", "description": "Ask the magic 8-ball", "type": 1, "options": [["type": 3, "name": "question", "description": "Your yes/no question", "required": true]]],
            ["name": "poll", "description": "Create a simple poll prompt", "type": 1, "options": [["type": 3, "name": "question", "description": "Poll question", "required": true]]],
            ["name": "userinfo", "description": "Show user info", "type": 1],
            ["name": "cluster", "description": "Cluster status/probe/test", "type": 1, "options": [["type": 3, "name": "action", "description": "status | test | probe", "required": false, "choices": [["name": "status", "value": "status"], ["name": "test", "value": "test"], ["name": "probe", "value": "probe"]]]]],
            ["name": "debug", "description": "Admin diagnostics", "type": 1],
            ["name": "notifystatus", "description": "Show notification config status", "type": 1],
            ["name": "setchannel", "description": "Set this channel as notifications channel", "type": 1],
            ["name": "ignorechannel", "description": "Manage ignored voice channels", "type": 1, "options": [
                ["type": 3, "name": "action", "description": "add | remove | list", "required": true, "choices": [["name": "add", "value": "add"], ["name": "remove", "value": "remove"], ["name": "list", "value": "list"]]],
                ["type": 7, "name": "channel", "description": "Channel for add/remove", "required": false]
            ]],
            ["name": "weekly", "description": "Show weekly summary", "type": 1],
            ["name": "image", "description": "Generate an image with OpenAI", "type": 1, "options": [["type": 3, "name": "prompt", "description": "Image prompt", "required": true]]],
            ["name": "wiki", "description": "Query WikiBridge", "type": 1, "options": [["type": 3, "name": "query", "description": "Your wiki query", "required": true]]],
            ["name": "compare", "description": "Compare two THE FINALS weapons", "type": 1, "options": [
                ["type": 3, "name": "weapon_a", "description": "First weapon", "required": true],
                ["type": 3, "name": "weapon_b", "description": "Second weapon", "required": true]
            ]],
            ["name": "meta", "description": "Fetch current THE FINALS meta from Skycoach", "type": 1]
        ]
    }

    func buildSlashCommandDefinitions() -> [[String: Any]] {
        guard settings.commandsEnabled, settings.slashCommandsEnabled else { return [] }
        return allSlashCommandDefinitions().filter { raw in
            guard let name = raw["name"] as? String else { return true }
            return isCommandEnabled(name: name, surface: "slash")
        }
    }

    func slashOptionString(named name: String, in data: [String: DiscordJSON]) -> String? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .string(value)? = map["value"] {
                return value
            }
        }
        return nil
    }

    func slashOptionChannelID(named name: String, in data: [String: DiscordJSON]) -> String? {
        guard case let .array(options)? = data["options"] else { return nil }
        for option in options {
            guard case let .object(map) = option,
                  case let .string(optionName)? = map["name"],
                  optionName == name else { continue }
            if case let .string(value)? = map["value"] {
                return value
            }
        }
        return nil
    }
}
