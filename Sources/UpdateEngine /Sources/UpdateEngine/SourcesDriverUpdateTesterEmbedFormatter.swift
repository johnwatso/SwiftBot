import Foundation

// MARK: - Shared Release Notes Model

struct ReleaseNotes {
    let title: String
    let author: String
    let url: String
    let version: String
    let date: String
    let sections: [ReleaseSection]
    let thumbnailURL: String
    let color: Int
}

struct ReleaseSection {
    let title: String
    let bullets: [Bullet]
}

struct Bullet {
    let text: String
    let subBullets: [String]
    
    init(text: String, subBullets: [String] = []) {
        self.text = text
        self.subBullets = subBullets
    }
}

// MARK: - Unified Embed Formatter

struct EmbedFormatter {
    
    // Discord character limits
    private let titleLimit = 256
    private let descriptionLimit = 4096
    private let fieldLimit = 1024
    private let totalLimit = 6000
    
    // Shared date formatter
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM dd, yyyy"
        return formatter
    }()
    
    func format(releaseNotes: ReleaseNotes) -> String {
        // Build description from sections
        let description = formatSections(releaseNotes.sections)
        
        // Truncate if needed
        let truncatedDescription = truncateIfNeeded(description, limit: descriptionLimit)
        
        // Build embed structure
        let embed: [String: Any] = [
            "author": [
                "name": releaseNotes.author
            ],
            "title": truncate(releaseNotes.title, limit: titleLimit),
            "url": releaseNotes.url,
            "description": truncatedDescription,
            "color": releaseNotes.color,
            "thumbnail": [
                "url": releaseNotes.thumbnailURL
            ],
            "fields": buildFields(version: releaseNotes.version, date: releaseNotes.date)
        ]
        
        let payload: [String: Any] = [
            "embeds": [embed]
        ]
        
        return encodeToJSON(payload)
    }
    
    private func formatSections(_ sections: [ReleaseSection]) -> String {
        var formattedSections: [String] = []
        
        for section in sections {
            var sectionText = "**\(section.title)**"
            
            for bullet in section.bullets {
                sectionText += "\n• \(bullet.text)"
                
                // Add nested sub-bullets with indentation
                for subBullet in bullet.subBullets {
                    sectionText += "\n   ◦ \(subBullet)"
                }
            }
            
            formattedSections.append(sectionText)
        }
        
        return formattedSections.joined(separator: "\n\n")
    }
    
    private func buildFields(version: String, date: String) -> [[String: Any]] {
        var fields: [[String: Any]] = []
        
        fields.append([
            "name": "Version",
            "value": version,
            "inline": true
        ])
        
        fields.append([
            "name": "Release Date",
            "value": date,
            "inline": true
        ])
        
        return fields
    }
    
    private func truncate(_ text: String, limit: Int) -> String {
        if text.count <= limit {
            return text
        }
        let truncated = String(text.prefix(limit - 3))
        return truncated + "..."
    }
    
    private func truncateIfNeeded(_ text: String, limit: Int) -> String {
        if text.count <= limit {
            return text
        }
        
        // Find last complete section that fits
        let sections = text.components(separatedBy: "\n\n")
        var result = ""
        
        for section in sections {
            let testResult = result.isEmpty ? section : result + "\n\n" + section
            if testResult.count > limit - 50 { // Leave room for truncation message
                break
            }
            result = testResult
        }
        
        if result.isEmpty {
            return truncate(text, limit: limit)
        }
        
        return result + "\n\n*Content truncated to fit Discord limits*"
    }
    
    private func encodeToJSON(_ payload: [String: Any]) -> String {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "{}"
        }
        return jsonString
    }
}
