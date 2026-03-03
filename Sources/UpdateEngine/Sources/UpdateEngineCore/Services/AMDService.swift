import Foundation

public struct AMDService: Sendable {
    public struct DriverInfo: Sendable {
        public let releaseNotes: ReleaseNotes
        public let embedJSON: String
        public let rawDebug: String
        public let releaseIdentifier: String

        public init(
            releaseNotes: ReleaseNotes,
            embedJSON: String,
            rawDebug: String,
            releaseIdentifier: String
        ) {
            self.releaseNotes = releaseNotes
            self.embedJSON = embedJSON
            self.rawDebug = rawDebug
            self.releaseIdentifier = releaseIdentifier
        }
    }

    private let session: URLSession
    private let sitemapURL: URL
    private let userAgent: String
    private let formatter: EmbedFormatter

    public init(
        session: URLSession = .shared,
        sitemapURL: URL = URL(string: "https://www.amd.com/en.sitemap.xml")!,
        userAgent: String = "Mozilla/5.0 (UpdateEngine)",
        formatter: EmbedFormatter = EmbedFormatter()
    ) {
        self.session = session
        self.sitemapURL = sitemapURL
        self.userAgent = userAgent
        self.formatter = formatter
    }

    public func fetchLatestDriver() async throws -> DriverInfo {
        let sitemapRequest = makeRequest(url: sitemapURL)
        let (sitemapData, sitemapResponse) = try await session.data(for: sitemapRequest)
        try validateHTTP(sitemapResponse)

        let rawSitemap = String(data: sitemapData, encoding: .utf8) ?? ""
        let entries = parseSitemapEntries(from: rawSitemap)

        guard let latestEntry = entries.max(by: { $0.lastModified < $1.lastModified }) else {
            throw AMDServiceError.noReleaseNotesFound
        }

        let releaseRequest = makeRequest(url: latestEntry.url)
        let (releaseData, releaseResponse) = try await session.data(for: releaseRequest)
        try validateHTTP(releaseResponse)

        let rawReleaseHTML = String(data: releaseData, encoding: .utf8) ?? ""

        let detectedVersion = firstCapture(
            pattern: #"Adrenalin Edition\s*([0-9]+(?:\.[0-9]+)+)\s*Release Notes"#,
            in: rawReleaseHTML
        )

        let version = detectedVersion ?? latestEntry.version.replacingOccurrences(of: "-", with: ".")
        let releaseDate = extractReleaseDate(from: rawReleaseHTML, fallback: latestEntry.lastModified)
        let sections = parseStructuredSections(from: rawReleaseHTML)

        let releaseNotes = ReleaseNotes(
            title: "AMD Software: Adrenalin Edition \(version) Release Notes",
            author: "AMD Radeon Drivers",
            url: latestEntry.url.absoluteString,
            version: version,
            date: releaseDate,
            sections: sections.isEmpty ? [fallbackSection(from: rawReleaseHTML)] : Array(sections.prefix(3)),
            thumbnailURL: "https://cdn.patchbot.io/games/140/amd-gpu-drivers_sm.webp",
            color: 16711680
        )

        let debugRaw = """
        AMD sitemap XML:
        \(rawSitemap)

        AMD release notes HTML:
        \(rawReleaseHTML)
        """

        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatter.format(releaseNotes: releaseNotes),
            rawDebug: debugRaw,
            releaseIdentifier: latestEntry.url.absoluteString
        )
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        return request
    }

    private func parseSitemapEntries(from xml: String) -> [SitemapEntry] {
        let pattern = #"(?is)<url>\s*<loc>(https://www\.amd\.com/en/resources/support-articles/release-notes/RN-RAD-WIN-([0-9]{2}-[0-9]{1,2}-[0-9]{1,2})\.html)</loc>\s*<lastmod>([^<]+)</lastmod>\s*</url>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let xmlRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: xmlRange)

        return matches.compactMap { match in
            guard
                let urlRange = Range(match.range(at: 1), in: xml),
                let versionRange = Range(match.range(at: 2), in: xml),
                let dateRange = Range(match.range(at: 3), in: xml),
                let url = URL(string: String(xml[urlRange])),
                let lastModified = parseISODate(String(xml[dateRange]))
            else {
                return nil
            }

            return SitemapEntry(
                url: url,
                version: String(xml[versionRange]),
                lastModified: lastModified
            )
        }
    }

    private func extractReleaseDate(from html: String, fallback: Date) -> String {
        if let published = firstCapture(pattern: #"\"datePublished\"\s*:\s*\"([^\"]+)\""#, in: html),
           let parsed = parseISODate(published) {
            return formatDate(parsed)
        }

        if let updated = firstCapture(pattern: #"(?is)<meta\s+property=\"og:updated_time\"\s+content=\"([^\"]+)\""#, in: html),
           let parsed = parseDateWithZoneOffset(updated) {
            return formatDate(parsed)
        }

        return formatDate(fallback)
    }

    private func parseStructuredSections(from html: String) -> [ReleaseSection] {
        let sectionHeaders = [
            "Highlights",
            "New Game Support",
            "Fixed Issues",
            "Known Issues",
            "Improvements"
        ]

        return sectionHeaders.compactMap { extractSection(header: $0, from: html) }
    }

    private func extractSection(header: String, from html: String) -> ReleaseSection? {
        let anchor = header.replacingOccurrences(of: " ", with: "_")
        let sectionPattern = #"(?is)<h2><a id="# + anchor + #""></a>"# + header + #"</h2>(.*?)(?:<h2>|$)"#

        guard let sectionContent = firstCapture(pattern: sectionPattern, in: html) else {
            return nil
        }

        let bullets = parseBulletsWithHierarchy(from: sectionContent)
        guard !bullets.isEmpty else {
            return nil
        }

        return ReleaseSection(title: header, bullets: bullets)
    }

    private func parseBulletsWithHierarchy(from html: String) -> [Bullet] {
        var bullets: [Bullet] = []
        let mainPattern = #"(?is)<li>\s*(?:<b>)?([^<]+)(?:</b>)?\s*(?:<ul>(.*?)</ul>)?\s*</li>"#

        guard let regex = try? NSRegularExpression(pattern: mainPattern) else {
            return []
        }

        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)

        for match in matches {
            guard
                match.numberOfRanges > 1,
                let textRange = Range(match.range(at: 1), in: html)
            else {
                continue
            }

            let mainText = cleanHTML(String(html[textRange]))
            var subBullets: [String] = []

            if match.numberOfRanges > 2,
               let nestedRange = Range(match.range(at: 2), in: html) {
                let nestedHTML = String(html[nestedRange])
                subBullets = allCaptures(pattern: #"(?is)<li>(.*?)</li>"#, in: nestedHTML)
                    .map(cleanHTML)
                    .filter { !$0.isEmpty }
            }

            if !mainText.isEmpty {
                bullets.append(Bullet(text: mainText, subBullets: subBullets))
            }
        }

        return bullets
    }

    private func fallbackSection(from html: String) -> ReleaseSection {
        if let description = firstCapture(
            pattern: #"(?is)<meta\s+property=\"og:description\"\s+content=\"([^\"]+)\""#,
            in: html
        ) {
            let clean = cleanHTML(description)
            if !clean.isEmpty {
                return ReleaseSection(
                    title: "Release Information",
                    bullets: [Bullet(text: clean)]
                )
            }
        }

        return ReleaseSection(
            title: "Release Information",
            bullets: [Bullet(text: "No release notes available.")]
        )
    }

    private func parseISODate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) {
            return date
        }

        let regular = ISO8601DateFormatter()
        regular.formatOptions = [.withInternetDateTime]
        return regular.date(from: value)
    }

    private func parseDateWithZoneOffset(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: value)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM dd, yyyy"
        return formatter.string(from: date)
    }

    private func firstCapture(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
    }

    private func allCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard
                match.numberOfRanges > 1,
                let captureRange = Range(match.range(at: 1), in: text)
            else {
                return nil
            }

            return String(text[captureRange])
        }
    }

    private func cleanHTML(_ raw: String) -> String {
        let noTags = raw.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let decoded = decodeHTMLEntities(noTags)
        let compact = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return compact.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        var output = text
        let entities: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;", "&"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">")
        ]

        for (entity, value) in entities {
            output = output.replacingOccurrences(of: entity, with: value)
        }

        return output
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AMDServiceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw AMDServiceError.httpError(statusCode: http.statusCode)
        }
    }
}

private struct SitemapEntry {
    let url: URL
    let version: String
    let lastModified: Date
}

public enum AMDServiceError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int)
    case noReleaseNotesFound

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "AMD endpoint returned an invalid response object."
        case .httpError(let statusCode):
            return "AMD endpoint request failed with HTTP \(statusCode)."
        case .noReleaseNotesFound:
            return "No AMD Radeon Adrenalin release notes were found."
        }
    }
}
