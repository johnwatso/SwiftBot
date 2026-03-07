import Foundation

public struct SteamNewsItem: Sendable, Codable, Hashable {
    public let gid: String
    public let title: String
    public let url: String
    public let contents: String
    public let date: Int
    public let feedLabel: String
    public let appID: Int

    public init(
        gid: String,
        title: String,
        url: String,
        contents: String,
        date: Int,
        feedLabel: String,
        appID: Int
    ) {
        self.gid = gid
        self.title = title
        self.url = url
        self.contents = contents
        self.date = date
        self.feedLabel = feedLabel
        self.appID = appID
    }

    public var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM dd, yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(date)))
    }
}

public struct SteamService: Sendable {
    public struct NewsInfo: Sendable {
        public let newsItem: SteamNewsItem
        public let embedJSON: String
        public let rawDebug: String
        public let releaseIdentifier: String

        public init(newsItem: SteamNewsItem, embedJSON: String, rawDebug: String, releaseIdentifier: String) {
            self.newsItem = newsItem
            self.embedJSON = embedJSON
            self.rawDebug = rawDebug
            self.releaseIdentifier = releaseIdentifier
        }
    }

    private let session: URLSession
    private let formatter: EmbedFormatter

    public init(session: URLSession = .shared, formatter: EmbedFormatter = EmbedFormatter()) {
        self.session = session
        self.formatter = formatter
    }

    public func fetchLatestNews(for appID: String) async throws -> NewsInfo {
        guard let appIDInt = Int(appID) else {
            throw SteamServiceError.invalidAppID(appID)
        }

        let urlString = "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=\(appID)&count=100&maxlength=5000"
        guard let url = URL(string: urlString) else {
            throw SteamServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        let decoder = JSONDecoder()
        let apiResponse = try decoder.decode(SteamAPIResponse.self, from: data)

        let acceptedSubstrings = ["update", "patch", "hotfix", "notes"]
        let rejectedSubstrings = ["store", "sale", "community", "event", "spotlight"]

        func isValidTitle(_ title: String) -> Bool {
            let lower = title.lowercased()
            let containsAccepted = acceptedSubstrings.contains { lower.contains($0) }
            let containsRejected = rejectedSubstrings.contains { lower.contains($0) }
            return containsAccepted && !containsRejected
        }

        let matchingItems = apiResponse.appnews.newsitems.filter { isValidTitle($0.title) }
        guard let newsItem = matchingItems.max(by: { compareNewsItems($0, $1) < 0 }) else {
            throw SteamServiceError.noNewsItems
        }

        let item = SteamNewsItem(
            gid: newsItem.gid,
            title: newsItem.title,
            url: newsItem.url,
            contents: newsItem.contents,
            date: newsItem.date,
            feedLabel: newsItem.feedlabel,
            appID: appIDInt
        )

        let releaseNotes = formatReleaseNotes(item: item, appID: appIDInt)
        let embedJSON = formatter.format(releaseNotes: releaseNotes)

        return NewsInfo(
            newsItem: item,
            embedJSON: embedJSON,
            rawDebug: "Steam API Response:\n\(rawJSON)",
            releaseIdentifier: item.gid
        )
    }

    private func compareNewsItems(_ lhs: SteamAPIResponse.NewsItem, _ rhs: SteamAPIResponse.NewsItem) -> Int {
        if lhs.date != rhs.date {
            return lhs.date < rhs.date ? -1 : 1
        }

        guard let leftGID = UInt64(lhs.gid), let rightGID = UInt64(rhs.gid), leftGID != rightGID else {
            return 0
        }
        return leftGID < rightGID ? -1 : 1
    }

    private func formatReleaseNotes(item: SteamNewsItem, appID: Int) -> ReleaseNotes {
        let headerURL = "https://cdn.akamai.steamstatic.com/steam/apps/\(appID)/header.jpg"
        let cleanedContents = removeFirstImageTag(from: item.contents)
        let sections = parseContent(cleanedContents)
        let appName = item.feedLabel.isEmpty ? "Steam App \(appID)" : item.feedLabel

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
        var cleaned = content
        let bbCodePatterns = [
            ("\\[/?b\\]", "**"),
            ("\\[/?i\\]", "*"),
            ("\\[/?u\\]", ""),
            ("\\[url=[^\\]]+\\]", ""),
            ("\\[/url\\]", ""),
            ("\\[img\\][^\\[]+\\[/img\\]", ""),
            ("\\[list\\]", ""),
            ("\\[/list\\]", ""),
            ("\\[\\*\\]", "• ")
        ]

        for (pattern, replacement) in bbCodePatterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }

        let lines = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            return [ReleaseSection(title: "Patch Notes", bullets: [Bullet(text: "No details available.")])]
        }

        let bullets = lines.prefix(10).map { line in
            let truncated = line.count > 200 ? String(line.prefix(197)) + "..." : line
            return Bullet(text: truncated)
        }

        return [ReleaseSection(title: "Patch Notes", bullets: bullets)]
    }

    private func removeFirstImageTag(from html: String) -> String {
        let pattern = "(?is)<img[^>]*>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return html
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard
            let match = regex.firstMatch(in: html, range: range),
            let replacementRange = Range(match.range, in: html)
        else {
            return html
        }

        var output = html
        output.removeSubrange(replacementRange)
        return output
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SteamServiceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw SteamServiceError.httpError(statusCode: http.statusCode)
        }
    }
}

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
        let date: Int
        let feedlabel: String
    }
}

public enum SteamServiceError: LocalizedError, Sendable {
    case invalidAppID(String)
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int)
    case noNewsItems

    public var errorDescription: String? {
        switch self {
        case .invalidAppID(let appID):
            return "Invalid Steam App ID: \(appID)."
        case .invalidURL:
            return "Failed to build Steam API URL."
        case .invalidResponse:
            return "Steam API returned an invalid response object."
        case .httpError(let statusCode):
            return "Steam API request failed with HTTP \(statusCode)."
        case .noNewsItems:
            return "No Steam update/news items matched the filter criteria."
        }
    }
}
