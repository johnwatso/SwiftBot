import Foundation

struct PatchySwiftMinerCampaignAnnouncement: Codable, Equatable {
    struct DropArtwork: Codable, Equatable {
        let dropId: String
        let name: String
        let imageURL: String
    }

    let eventId: String
    let campaignId: String
    let campaignName: String
    let gameId: String
    let gameName: String
    let status: String
    let startsAt: String?
    let endsAt: String?
    let dropCount: Int
    let gameArtworkURL: String?
    let dropArtwork: [DropArtwork]
    let occurredAt: String?
}

enum PatchySwiftMinerCampaignRouter {
    private struct Envelope: Codable {
        let eventId: String
        let data: Payload
    }

    private struct Payload: Codable {
        let campaignId: String
        let campaignName: String
        let gameId: String
        let gameName: String
        let status: String
        let startsAt: String?
        let endsAt: String?
        let dropCount: Int?
        let gameArtworkURL: String?
        let dropArtwork: [PatchySwiftMinerCampaignAnnouncement.DropArtwork]?
        let occurredAt: String?
    }

    static func decodeAnnouncement(from body: Data) throws -> PatchySwiftMinerCampaignAnnouncement {
        let envelope = try JSONDecoder().decode(Envelope.self, from: body)
        return PatchySwiftMinerCampaignAnnouncement(
            eventId: envelope.eventId,
            campaignId: envelope.data.campaignId,
            campaignName: envelope.data.campaignName,
            gameId: envelope.data.gameId,
            gameName: envelope.data.gameName,
            status: envelope.data.status,
            startsAt: envelope.data.startsAt,
            endsAt: envelope.data.endsAt,
            dropCount: envelope.data.dropCount ?? envelope.data.dropArtwork?.count ?? 0,
            gameArtworkURL: envelope.data.gameArtworkURL,
            dropArtwork: Array((envelope.data.dropArtwork ?? []).prefix(3)),
            occurredAt: envelope.data.occurredAt
        )
    }

    static func target(_ target: PatchySourceTarget, matches announcement: PatchySwiftMinerCampaignAnnouncement) -> Bool {
        guard target.source == .swiftMiner else { return false }
        let configured = normalizedGame(target.swiftMinerGameName)
        guard !configured.isEmpty else { return false }

        let gameId = normalizedGame(announcement.gameId)
        let gameName = normalizedGame(announcement.gameName)
        if configured == gameId || configured == gameName { return true }
        return configured.count >= 3 && (gameName.contains(configured) || configured.contains(gameName))
    }

    static func fallbackMessage(for announcement: PatchySwiftMinerCampaignAnnouncement) -> String {
        "New SwiftMiner campaign: \(announcement.gameName) - \(announcement.campaignName)"
    }

    static func embedJSON(
        for announcement: PatchySwiftMinerCampaignAnnouncement,
        target: PatchySourceTarget
    ) -> String {
        let color = PatchyEmbedAccent.discordColorInt(hex: target.embedColorHex, source: target.source)
        var campaignEmbed: [String: Any] = [
            "title": "New Drops campaign",
            "description": "**\(announcement.gameName)**\n\(announcement.campaignName)",
            "color": color,
            "fields": campaignFields(for: announcement),
            "footer": ["text": "SwiftMiner via Patchy"]
        ]
        if let url = validURLString(announcement.gameArtworkURL) {
            campaignEmbed["image"] = ["url": url]
        }

        var embeds = [campaignEmbed]
        for drop in announcement.dropArtwork.prefix(3) {
            guard let url = validURLString(drop.imageURL) else { continue }
            embeds.append([
                "title": drop.name,
                "color": color,
                "image": ["url": url]
            ])
        }

        let payload: [String: Any] = ["embeds": embeds]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return json
    }

    static func sampleAnnouncement(gameName: String) -> PatchySwiftMinerCampaignAnnouncement {
        let game = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedGame = game.isEmpty ? "The Finals" : game
        return PatchySwiftMinerCampaignAnnouncement(
            eventId: "evt_patchy_swiftminer_test",
            campaignId: "campaign_patchy_test",
            campaignName: "\(resolvedGame) Twitch Drops",
            gameId: resolvedGame.lowercased().replacingOccurrences(of: " ", with: "-"),
            gameName: resolvedGame,
            status: "active",
            startsAt: nil,
            endsAt: nil,
            dropCount: 3,
            gameArtworkURL: nil,
            dropArtwork: [],
            occurredAt: nil
        )
    }

    private static func campaignFields(for announcement: PatchySwiftMinerCampaignAnnouncement) -> [[String: Any]] {
        var fields: [[String: Any]] = [
            ["name": "Status", "value": announcement.status.capitalized, "inline": true],
            ["name": "Drops", "value": "\(announcement.dropCount)", "inline": true]
        ]
        if let endsAt = discordTimestamp(from: announcement.endsAt) {
            fields.append(["name": "Ends", "value": endsAt, "inline": true])
        }
        return fields
    }

    private static func discordTimestamp(from isoString: String?) -> String? {
        guard let isoString, let date = ISO8601DateFormatter().date(from: isoString) else { return nil }
        return "<t:\(Int(date.timeIntervalSince1970)):R>"
    }

    private static func validURLString(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url.absoluteString
    }

    private static func normalizedGame(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
