import Foundation

struct DriverInfo {
    let version: String
    let releaseDate: String
    let downloadURL: String
    let highlights: [String]
}

enum DiscordWebhookError: Error {
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int)
}

actor DiscordWebhookService {
    
    /// Builds a Discord webhook payload with embed structure
    func buildDriverEmbed(vendor: String, driverInfo: DriverInfo, roleMention: String) -> [String: Any] {
        let color: Int
        let thumbnailURL: String
        
        switch vendor {
        case "NVIDIA":
            color = 0x76B900 // NVIDIA green
            thumbnailURL = "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a4/NVIDIA_logo.svg/200px-NVIDIA_logo.svg.png"
        case "AMD":
            color = 0xED1C24 // AMD red
            thumbnailURL = "https://upload.wikimedia.org/wikipedia/commons/thumb/7/7c/AMD_Logo.svg/200px-AMD_Logo.svg.png"
        default:
            color = 0x5865F2 // Discord blurple
            thumbnailURL = ""
        }
        
        // Build highlights field
        let highlightsText = driverInfo.highlights.isEmpty
            ? "No highlights available"
            : driverInfo.highlights.map { "• \($0)" }.joined(separator: "\n")
        
        let embed: [String: Any] = [
            "title": "\(vendor) Driver Update",
            "description": "A new driver version is available!",
            "color": color,
            "thumbnail": [
                "url": thumbnailURL
            ],
            "fields": [
                [
                    "name": "Version",
                    "value": driverInfo.version,
                    "inline": true
                ],
                [
                    "name": "Release Date",
                    "value": driverInfo.releaseDate,
                    "inline": true
                ],
                [
                    "name": "Download URL",
                    "value": "[\(vendor) Download](\(driverInfo.downloadURL))",
                    "inline": false
                ],
                [
                    "name": "Highlights",
                    "value": highlightsText,
                    "inline": false
                ]
            ],
            "footer": [
                "text": "Driver Update Tester"
            ],
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        
        return [
            "content": roleMention,
            "embeds": [embed]
        ]
    }
    
    /// Sends the webhook payload to Discord
    func sendWebhook(payload: [String: Any], webhookURL: String) async throws {
        guard let url = URL(string: webhookURL) else {
            throw DiscordWebhookError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DiscordWebhookError.networkError(URLError(.badServerResponse))
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw DiscordWebhookError.httpError(statusCode: httpResponse.statusCode)
        }
    }
}
