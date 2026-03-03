import Foundation

import Foundation

struct AMDService {
    struct DriverInfo {
        let releaseNotes: ReleaseNotes
        let embedJSON: String
        let rawDebug: String
    }

    private let sitemapURL = URL(string: "https://www.amd.com/en.sitemap.xml")!
    private let userAgent = "Mozilla/5.0 (UpdateEngine)"
    private let formatter = EmbedFormatter()

    func fetchLatestDriver() async throws -> DriverInfo {
        let sitemapRequest = makeRequest(url: sitemapURL)
        let (sitemapData, _) = try await URLSession.shared.data(for: sitemapRequest)
        let rawSitemap = String(data: sitemapData, encoding: .utf8) ?? ""

        let entries = parseSitemapEntries(from: rawSitemap)
        guard let latestEntry = entries.max(by: { $0.lastModified < $1.lastModified }) else {
            throw AMDServiceError.noReleaseNotesFound
        }

        let releaseRequest = makeRequest(url: latestEntry.url)
        let (releaseData, _) = try await URLSession.shared.data(for: releaseRequest)
        let rawReleaseHTML = String(data: releaseData, encoding: .utf8) ?? ""

        let detectedVersion = firstCapture(
            pattern: #"Adrenalin Edition\s*([0-9]+(?:\.[0-9]+)+)\s*Release Notes"#,
            in: rawReleaseHTML
        )
        let version = detectedVersion ?? latestEntry.version.replacingOccurrences(of: "-", with: ".")
        let releaseDate = extractReleaseDate(from: rawReleaseHTML, fallback: latestEntry.lastModified)
        let sections = parseStructuredSections(from: rawReleaseHTML)

        // Build ReleaseNotes model
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
        
        // Format using unified formatter
        let embedJSON = formatter.format(releaseNotes: releaseNotes)
        
        let debugRaw = """
        AMD sitemap XML:
        \(rawSitemap)

        AMD release notes HTML:
        \(rawReleaseHTML)
        """

        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: embedJSON,
            rawDebug: debugRaw
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
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let xmlRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, options: [], range: xmlRange)

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
        if let published = firstCapture(pattern: #""datePublished"\s*:\s*"([^"]+)""#, in: html),
           let parsed = parseISODate(published) {
            return formatDate(parsed)
        }

        if let updated = firstCapture(pattern: #"(?is)<meta\s+property="og:updated_time"\s+content="([^"]+)""#, in: html),
           let parsed = parseDateWithZoneOffset(updated) {
            return formatDate(parsed)
        }

        return formatDate(fallback)
    }

    private func parseStructuredSections(from html: String) -> [ReleaseSection] {
        var sections: [ReleaseSection] = []
        
        // Section headers to look for
        let sectionHeaders = [
            "Highlights",
            "New Game Support",
            "Fixed Issues",
            "Known Issues",
            "Improvements"
        ]
        
        for header in sectionHeaders {
            if let section = extractSection(header: header, from: html) {
                sections.append(section)
            }
        }
        
        return sections
    }
    
    private func extractSection(header: String, from html: String) -> ReleaseSection? {
        // Pattern to capture section content between h2 headers
        let sectionPattern = #"(?is)<h2><a id="\#(header.replacingOccurrences(of: " ", with: "_"))"></a>\#(header)</h2>(.*?)(?:<h2>|$)"#
        
        guard let sectionContent = firstCapture(pattern: sectionPattern, in: html) else {
            return nil
        }
        
        // Parse bullets with hierarchy
        let bullets = parseBulletsWithHierarchy(from: sectionContent)
        
        if bullets.isEmpty {
            return nil
        }
        
        return ReleaseSection(title: header, bullets: bullets)
    }
    
    private func parseBulletsWithHierarchy(from html: String) -> [Bullet] {
        var bullets: [Bullet] = []
        
        // Pattern for main list items with optional nested lists
        let mainBulletPattern = #"(?is)<li>\s*(?:<b>)?([^<]+)(?:</b>)?\s*(?:<ul>(.*?)</ul>)?\s*</li>"#
        
        guard let regex = try? NSRegularExpression(pattern: mainBulletPattern, options: []) else {
            return []
        }
        
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, options: [], range: range)
        
        for match in matches {
            guard match.numberOfRanges > 1,
                  let textRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            
            let mainText = cleanHTML(String(html[textRange]))
            
            // Extract sub-bullets if present
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
            pattern: #"(?is)<meta\s+property="og:description"\s+content="([^"]+)""#,
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
        if let date = regular.date(from: value) {
            return date
        }
        return nil
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
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }

    private func allCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else {
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
        guard let data = text.data(using: .utf8) else {
            return text
        }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return text
        }
        return attributed.string
    }
}

private struct SitemapEntry {
    let url: URL
    let version: String
    let lastModified: Date
}

private enum AMDServiceError: LocalizedError {
    case noReleaseNotesFound

    var errorDescription: String? {
        switch self {
        case .noReleaseNotesFound:
            return "No AMD Radeon Adrenalin release notes were found."
        }
    }
}
