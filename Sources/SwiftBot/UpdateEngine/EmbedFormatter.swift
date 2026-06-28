import Foundation

/// Converts release notes into Discord embed JSON payloads.
public struct EmbedFormatter: Sendable {
    private let titleLimit = 256
    private let descriptionLimit = 4096

    public init() {}

    public func format(releaseNotes: ReleaseNotes) -> String {
        let description = formatSections(releaseNotes.sections)
        let truncatedDescription = truncateIfNeeded(description, limit: descriptionLimit)

        let embed: [String: Any] = [
            "author": ["name": releaseNotes.author],
            "title": truncate(releaseNotes.title, limit: titleLimit),
            "url": releaseNotes.url,
            "description": truncatedDescription,
            "color": releaseNotes.color,
            "thumbnail": ["url": releaseNotes.thumbnailURL],
            "fields": [
                ["name": "Version", "value": releaseNotes.version, "inline": true],
                ["name": "Release Date", "value": releaseNotes.date, "inline": true]
            ]
        ]

        let payload: [String: Any] = [
            "embeds": [embed]
        ]

        return encodeToJSON(payload)
    }

    private func formatSections(_ sections: [ReleaseSection]) -> String {
        let renderedSections = sections.map { section in
            var sectionText = "**\(section.title)**"
            for bullet in section.bullets {
                sectionText += "\n• \(bullet.text)"
                for subBullet in bullet.subBullets {
                    sectionText += "\n   ◦ \(subBullet)"
                }
            }
            return sectionText
        }

        return renderedSections.joined(separator: "\n\n")
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit - 3)) + "..."
    }

    private func truncateIfNeeded(_ text: String, limit: Int) -> String {
        guard text.count > limit else {
            return text
        }

        let sections = text.components(separatedBy: "\n\n")
        var output = ""

        for section in sections {
            let candidate = output.isEmpty ? section : output + "\n\n" + section
            if candidate.count > limit - 50 {
                break
            }
            output = candidate
        }

        if output.isEmpty {
            return truncate(text, limit: limit)
        }

        return output + "\n\n*Content truncated to fit Discord limits*"
    }

    private func encodeToJSON(_ payload: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }

        return json
    }
}
