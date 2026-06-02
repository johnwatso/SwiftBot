import Foundation

enum GatewayEventPresentation {
    static func displayName(for eventName: String) -> String {
        switch eventName {
        case "-", "":
            return "None"
        case "READY":
            return "Connected"
        case "GUILD_CREATE":
            return "Server Available"
        case "GUILD_DELETE":
            return "Server Removed"
        case "GUILD_MEMBER_ADD":
            return "Member Joined"
        case "GUILD_MEMBER_REMOVE":
            return "Member Left"
        case "CHANNEL_CREATE":
            return "Channel Created"
        case "CHANNEL_UPDATE":
            return "Channel Updated"
        case "CHANNEL_DELETE":
            return "Channel Deleted"
        case "MESSAGE_CREATE":
            return "Message Received"
        case "MESSAGE_REACTION_ADD":
            return "Reaction Added"
        case "INTERACTION_CREATE":
            return "Interaction Received"
        case "VOICE_STATE_UPDATE":
            return "Voice State Changed"
        case "VOICE_SERVER_UPDATE":
            return "Voice Server Updated"
        default:
            return eventName
                .split(separator: "_")
                .map { word in
                    word.prefix(1).uppercased() + word.dropFirst().lowercased()
                }
                .joined(separator: " ")
        }
    }

    static func statusDetail(for eventName: String) -> String {
        eventName == "-"
            ? "Awaiting gateway events"
            : "Last event: \(displayName(for: eventName))"
    }

    static func replaceProtocolNames(in text: String) -> String {
        var output = text
        for eventName in knownEventNames {
            output = output.replacingOccurrences(
                of: eventName,
                with: displayName(for: eventName)
            )
        }
        return output
    }

    private static let knownEventNames = [
        "MESSAGE_REACTION_ADD",
        "GUILD_MEMBER_REMOVE",
        "VOICE_SERVER_UPDATE",
        "VOICE_STATE_UPDATE",
        "INTERACTION_CREATE",
        "GUILD_MEMBER_ADD",
        "MESSAGE_CREATE",
        "CHANNEL_CREATE",
        "CHANNEL_UPDATE",
        "CHANNEL_DELETE",
        "GUILD_CREATE",
        "GUILD_DELETE",
        "READY"
    ]
}
