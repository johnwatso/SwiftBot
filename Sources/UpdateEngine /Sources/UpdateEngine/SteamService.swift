import Foundation

// MARK: - Steam News Source

/// UpdateSource implementation for Steam game patch notes.
/// Uses the official Steam ISteamNews API.
struct SteamNewsSource: UpdateSource {
    let appID: String
    let newsItem: SteamNewsItem
    
    var cacheKey: String {
        "steam-\(appID)"
    }
    
    var version: String {
        // Use date as version since Steam doesn't have version numbers
        newsItem.dateFormatted
    }
    
    init(appID: String, newsItem: SteamNewsItem) {
        self.appID = appID
        self.newsItem = newsItem
    }
}

// MARK: - Steam News Item

struct SteamNewsItem: Sendable {
    let gid: String
    let title: String
    let url: String
    let contents: String
    let date: Int
    let feedLabel: String
    let appID: Int
    
    var dateFormatted: String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "MMMM dd, yyyy"
        let newsDate = Date(timeIntervalSince1970: TimeInterval(date))
        return dateFormatter.string(from: newsDate)
    }
}

// MARK: - Steam Service

struct SteamService {
    struct NewsInfo {
        let newsItem: SteamNewsItem
        let embedJSON: String
        let rawDebug: String
    }
    
    private let formatter = EmbedFormatter()
    
    /// Fetch the most recent news item for a Steam game.
    /// - Parameter appID: The Steam App ID
    /// - Returns: NewsInfo containing the news item and formatted embed
    /// - Throws: SteamServiceError on failure
    func fetchLatestNews(for appID: String) async throws -> NewsInfo {
        guard let appIDInt = Int(appID) else {
            throw SteamServiceError.invalidAppID(appID)
        }
        
        // Build API URL
        let urlString = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appID)&count=4&maxlength=5000"
        guard let url = URL(string: urlString) else {
            throw SteamServiceError.invalidURL
        }
        
        // Make request
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SteamServiceError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SteamServiceError.httpError(statusCode: httpResponse.statusCode)
        }
        
        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        
        // Parse JSON
        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)
        
        // Filter news items by title to find patch/update posts
        let itemsToConsider = Array(apiResponse.appnews.newsitems.prefix(4))
        
        let acceptedSubstrings = ["update", "patch", "hotfix", "notes"]
        let rejectedSubstrings = ["store", "sale", "community", "event", "spotlight"]
        
        func isValidTitle(_ title: String) -> Bool {
            let lower = title.lowercased()
            // Must contain at least one accepted term
            let containsAccepted = acceptedSubstrings.contains { lower.contains($0) }
            if !containsAccepted { return false }
            // Must not contain any rejected term
            let containsRejected = rejectedSubstrings.contains { lower.contains($0) }
            return !containsRejected
        }
        
        // Find the first valid news item
        guard let newsItem = itemsToConsider.first(where: { isValidTitle($0.title) }) else {
            throw SteamServiceError.noNewsItems
        }
        
        // Convert to our model
        let item = SteamNewsItem(
            gid: newsItem.gid,
            title: newsItem.title,
            url: newsItem.url,
            contents: newsItem.contents,
            date: newsItem.date,
            feedLabel: newsItem.feedlabel,
            appID: appIDInt
        )
        
        // Extract first image from contents (if any)
        let dynamicImageURL = extractFirstImageURL(from: newsItem.contents)
        
        // Format release notes and include dynamic image
        let releaseNotes = formatReleaseNotes(item: item, appID: appIDInt, dynamicImageURL: dynamicImageURL)
        let embedJSON = formatter.format(releaseNotes: releaseNotes)
        
        return NewsInfo(
            newsItem: item,
            embedJSON: embedJSON,
            rawDebug: "Steam API Response:\n\(rawJSON)"
        )
    }
    
    // MARK: - Private Methods
    
    private func formatReleaseNotes(item: SteamNewsItem, appID: Int, dynamicImageURL: String?) -> ReleaseNotes {
        // Build dynamic URLs from appID
        let capsuleURL = "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/capsule_616x353.jpg"
        let headerURL = "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/header.jpg"
        
        // Clean contents by removing the first <img ...> tag
        let cleanedContents = removeFirstImageTag(from: item.contents)
        
        // Parse content into sections from cleaned text
        let sections = parseContent(cleanedContents)
        
        // Get app name from feed label or use App ID
        let appName = item.feedLabel.isEmpty ? "Steam App \(appID)" : item.feedLabel
        
        // Build ReleaseNotes
        return ReleaseNotes(
            title: item.title,
            author: appName,
            url: item.url,
            version: item.dateFormatted,
            date: item.dateFormatted,
            sections: sections,
            thumbnailURL: headerURL,
            color: 0x1B2838
        )
    }
    
    private func parseContent(_ content: String) -> [ReleaseSection] {
        // Remove BBCode tags
        var cleaned = content
        
        // Common BBCode patterns
        let bbCodePatterns = [
            ("\\[/?b\\]", "**"),           // Bold
            ("\\[/?i\\]", "*"),             // Italic
            ("\\[/?u\\]", ""),              // Underline (Discord doesn't support)
            ("\\[url=[^\\]]+\\]", ""),      // URL start tag
            ("\\[/url\\]", ""),             // URL end tag
            ("\\[img\\][^\\[]+\\[/img\\]", ""), // Images
            ("\\[list\\]", ""),             // List start
            ("\\[/list\\]", ""),            // List end
            ("\\[\\*\\]", "• ")             // List items
        ]
        
        for (pattern, replacement) in bbCodePatterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        
        // Split into lines and group into sections
        let lines = cleaned.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        if lines.isEmpty {
            return [ReleaseSection(
                title: "Patch Notes",
                bullets: [Bullet(text: "No details available.")]
            )]
        }
        
        // Group lines into bullets (max 10 lines to avoid huge embeds)
        let bullets = lines.prefix(10).map { line in
            // Truncate long lines
            let truncated = line.count > 200 ? String(line.prefix(197)) + "..." : line
            return Bullet(text: truncated)
        }
        
        return [ReleaseSection(
            title: "Patch Notes",
            bullets: bullets
        )]
    }
    
    private func extractFirstImageURL(from html: String) -> String? {
        // Look for first <img src="..."> occurrence
        let pattern = "(?is)<img[^>]*src=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, options: [], range: range),
              match.numberOfRanges > 1,
              let urlRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[urlRange])
    }
    
    private func removeFirstImageTag(from html: String) -> String {
        let pattern = "(?is)<img[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return html }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        // Replace only the first occurrence
        if let match = regex.firstMatch(in: html, options: [], range: range), let r = Range(match.range, in: html) {
            var result = html
            result.removeSubrange(r)
            return result
        }
        return html
    }
    
    private func prependCapsuleImage(to sections: [ReleaseSection], appID: Int) -> [ReleaseSection] {
        // Build dynamic URLs
        let capsule = "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/capsule_616x353.jpg"
        let header = "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/header.jpg"
        
        // Discord embeds support a single image; our EmbedFormatter doesn't have an explicit image field.
        // Prepend a synthetic section that renders the capsule image via Markdown, and fall back to header as a link.
        let imageLine = "![ ](\(capsule))"
        let fallbackNote = "If image doesn't load, [open header](\(header))."
        let imageSection = ReleaseSection(
            title: "",
            bullets: [
                Bullet(text: imageLine),
                Bullet(text: fallbackNote)
            ]
        )
        
        // Return with image section first, followed by actual content
        return [imageSection] + sections
    }
}

// MARK: - API Response Models

private struct SteamAPIResponse: Codable {
    let appnews: AppNews
    
    struct AppNews: Codable {
        let appid: Int
        let newsitems: [NewsItem]
        let count: Int
    }
    
    struct NewsItem: Codable {
        let gid: String
        let title: String
        let url: String
        let contents: String
        let feedlabel: String
        let date: Int
        let feedname: String
        let feed_type: Int
        let appid: Int
    }
}

// MARK: - Errors

enum SteamServiceError: LocalizedError {
    case invalidAppID(String)
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case noNewsItems
    
    var errorDescription: String? {
        switch self {
        case .invalidAppID(let appID):
            return "Invalid Steam App ID: \(appID)"
        case .invalidURL:
            return "Failed to construct Steam API URL"
        case .invalidResponse:
            return "Invalid response from Steam API"
        case .httpError(let statusCode):
            return "Steam API returned HTTP \(statusCode)"
        case .noNewsItems:
            return "No news items found for this app"
        }
    }
}

