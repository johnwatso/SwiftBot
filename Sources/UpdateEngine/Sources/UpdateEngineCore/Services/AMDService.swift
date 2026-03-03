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
        let cleanedReleaseHTML = removeScriptAndStyleBlocks(rawReleaseHTML)

        let detectedVersion = firstCapture(
            pattern: #"Adrenalin Edition\s*([0-9]+(?:\.[0-9]+)+)\s*Release Notes"#,
            in: cleanedReleaseHTML
        )

        let version = detectedVersion ?? latestEntry.version.replacingOccurrences(of: "-", with: ".")
        let releaseDate = extractReleaseDate(from: cleanedReleaseHTML, fallback: latestEntry.lastModified)
        let sections = parseSummarySections(from: cleanedReleaseHTML)

        let releaseNotes = ReleaseNotes(
            title: "AMD Software: Adrenalin Edition \(version) Release Notes",
            author: "AMD Radeon Drivers",
            url: latestEntry.url.absoluteString,
            version: version,
            date: releaseDate,
            sections: sections,
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

    private func parseSummarySections(from html: String) -> [ReleaseSection] {
        if let highlights = extractSections(headerCandidates: ["Highlights"], from: html) {
            return highlights
        }

        if let fixedIssues = extractSections(headerCandidates: ["Fixed Issues"], from: html) {
            return fixedIssues
        }

        if let knownIssues = extractSections(headerCandidates: ["Known Issues"], from: html) {
            return knownIssues
        }

        if let fixedIssues = extractNamedListSection(named: "Fixed Issues", from: html) {
            return [fixedIssues]
        }

        if let knownIssues = extractNamedListSection(named: "Known Issues", from: html) {
            return [knownIssues]
        }

        if let firstParagraph = firstMeaningfulParagraph(in: html) {
            return [
                ReleaseSection(
                    title: "Release Information",
                    bullets: [Bullet(text: firstParagraph)]
                )
            ]
        }

        return [fallbackSection(from: html)]
    }

    private func extractSections(headerCandidates: [String], from html: String) -> [ReleaseSection]? {
        guard let section = extractSectionBlock(headerCandidates: headerCandidates, from: html) else {
            return nil
        }

        let bullets = parseBulletsWithHierarchy(from: section.content)
        if !bullets.isEmpty {
            let splitSections = splitBulletsIntoSections(defaultTitle: section.title, bullets: bullets)
            if !splitSections.isEmpty {
                return splitSections
            }
        }

        guard let paragraph = firstMeaningfulParagraph(in: section.content) else {
            return nil
        }

        return [ReleaseSection(title: section.title, bullets: [Bullet(text: paragraph)])]
    }

    private func extractNamedListSection(named name: String, from html: String) -> ReleaseSection? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?is)<li[^>]*>\s*(?:<(?:b|strong)[^>]*>)?\s*"# + escapedName + #"\s*(?:</(?:b|strong)>)?\s*(<ul[^>]*>.*?</ul>)\s*</li>"#

        guard let sublistHTML = firstCapture(pattern: pattern, in: html) else {
            return nil
        }

        let bullets = parseBulletsWithHierarchy(from: sublistHTML)
        guard !bullets.isEmpty else {
            return nil
        }

        return ReleaseSection(title: name, bullets: bullets)
    }

    private func extractSectionBlock(headerCandidates: [String], from html: String) -> SectionBlock? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<h[1-6][^>]*>(.*?)</h[1-6]>"#) else {
            return nil
        }

        let headers = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)).compactMap { match -> HeaderMatch? in
            guard
                match.numberOfRanges > 1,
                let bodyRange = Range(match.range(at: 1), in: html),
                let fullRange = Range(match.range(at: 0), in: html)
            else {
                return nil
            }

            let rawTitle = String(html[bodyRange])
            let normalizedTitle = normalizeHeaderTitle(cleanHTML(rawTitle, preserveNewlines: false))
            return HeaderMatch(title: cleanHTML(rawTitle, preserveNewlines: false), normalizedTitle: normalizedTitle, range: fullRange)
        }

        guard !headers.isEmpty else {
            return nil
        }

        let normalizedCandidates = Set(headerCandidates.map(normalizeHeaderTitle))
        guard let matchedIndex = headers.firstIndex(where: { normalizedCandidates.contains($0.normalizedTitle) }) else {
            return nil
        }

        let match = headers[matchedIndex]
        let contentStart = match.range.upperBound
        let contentEnd = matchedIndex + 1 < headers.count ? headers[matchedIndex + 1].range.lowerBound : html.endIndex
        guard contentStart < contentEnd else {
            return nil
        }

        let content = String(html[contentStart..<contentEnd])
        let title = headerCandidates.first(where: { normalizeHeaderTitle($0) == match.normalizedTitle }) ?? match.title
        return SectionBlock(title: title, content: content)
    }

    private func normalizeHeaderTitle(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private func splitBulletsIntoSections(defaultTitle: String, bullets: [Bullet]) -> [ReleaseSection] {
        var sections: [ReleaseSection] = []
        var currentTitle = defaultTitle
        var currentBullets: [Bullet] = []

        func flushCurrentSection() {
            guard !currentBullets.isEmpty else {
                return
            }
            sections.append(ReleaseSection(title: currentTitle, bullets: currentBullets))
            currentBullets = []
        }

        for bullet in bullets {
            if let sectionTitle = canonicalSectionHeader(from: bullet.text) {
                flushCurrentSection()
                currentTitle = sectionTitle
                currentBullets = bullet.subBullets.map { Bullet(text: $0) }
                continue
            }

            currentBullets.append(bullet)
        }

        flushCurrentSection()
        return sections
    }

    private func canonicalSectionHeader(from text: String) -> String? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let normalized = normalizeHeaderTitle(trimmed)

        switch normalized {
        case "highlights":
            return "Highlights"
        case "fixedissues":
            return "Fixed Issues"
        case "knownissues":
            return "Known Issues"
        default:
            return nil
        }
    }

    private func parseBulletsWithHierarchy(from html: String) -> [Bullet] {
        let sanitized = removeScriptAndStyleBlocks(html)
            .replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)

        guard let regex = try? NSRegularExpression(pattern: #"(?is)<[^>]+>"#) else {
            return []
        }

        let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
        let matches = regex.matches(in: sanitized, range: range)

        var bullets: [Bullet] = []
        var listDepth = 0
        var isInListItem = false
        var currentText = ""
        var cursor = sanitized.startIndex

        func flushCurrentText() {
            let text = normalizeListText(currentText)
            currentText = ""
            guard !text.isEmpty else {
                return
            }

            if listDepth > 1, !bullets.isEmpty {
                let parent = bullets.removeLast()
                let updated = Bullet(text: parent.text, subBullets: parent.subBullets + [text])
                bullets.append(updated)
            } else {
                bullets.append(Bullet(text: text))
            }
        }

        for match in matches {
            guard
                let tagRange = Range(match.range(at: 0), in: sanitized)
            else {
                continue
            }

            if cursor < tagRange.lowerBound, isInListItem {
                currentText += String(sanitized[cursor..<tagRange.lowerBound])
            }

            let tag = String(sanitized[tagRange])
            let tagName = parseTagName(tag)
            let isClosing = tag.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("</")

            switch tagName {
            case "br":
                if isInListItem {
                    currentText += "\n"
                }
            case "ul", "ol":
                if isClosing {
                    listDepth = max(0, listDepth - 1)
                } else {
                    if isInListItem {
                        flushCurrentText()
                    }
                    listDepth += 1
                }
            case "li":
                if isClosing {
                    flushCurrentText()
                    isInListItem = false
                } else {
                    isInListItem = true
                    currentText = ""
                }
            default:
                break
            }

            cursor = tagRange.upperBound
        }

        if cursor < sanitized.endIndex, isInListItem {
            currentText += String(sanitized[cursor..<sanitized.endIndex])
        }
        if isInListItem {
            flushCurrentText()
        }

        return bullets
    }

    private func fallbackSection(from html: String) -> ReleaseSection {
        if let firstParagraph = firstMeaningfulParagraph(in: html) {
            return ReleaseSection(
                title: "Release Information",
                bullets: [Bullet(text: firstParagraph)]
            )
        }

        if let description = firstCapture(
            pattern: #"(?is)<meta\s+property=\"og:description\"\s+content=\"([^\"]+)\""#,
            in: html
        ) {
            let clean = cleanHTML(description, preserveNewlines: false)
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

    private func firstMeaningfulParagraph(in html: String) -> String? {
        let pattern = #"(?is)<p[^>]*>(.*?)</p>"#
        for paragraph in allCaptures(pattern: pattern, in: html) {
            let text = cleanHTML(paragraph, preserveNewlines: true)
            guard isMeaningfulParagraph(text) else {
                continue
            }
            return text
        }

        let fallback = cleanHTML(html, preserveNewlines: true)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isMeaningfulParagraph)
        return fallback
    }

    private func isMeaningfulParagraph(_ text: String) -> Bool {
        guard text.count >= 20 else {
            return false
        }

        let lower = text.lowercased()
        if lower.hasPrefix("last updated") {
            return false
        }
        return true
    }

    private func parseTagName(_ tag: String) -> String {
        var token = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.hasPrefix("<"), token.count >= 2 else {
            return ""
        }

        token.removeFirst()
        if token.hasPrefix("/") {
            token.removeFirst()
        }

        let characters = token.prefix { character in
            character.isLetter || character.isNumber
        }
        return String(characters).lowercased()
    }

    private func normalizeListText(_ raw: String) -> String {
        let decoded = decodeHTMLEntities(raw)
        let withoutTags = decoded.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        let compactSpaces = withoutTags.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        let compactNewlines = compactSpaces
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return compactNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func removeScriptAndStyleBlocks(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: "", options: .regularExpression)
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

    private func cleanHTML(_ raw: String, preserveNewlines: Bool) -> String {
        var text = removeScriptAndStyleBlocks(raw)
        text = text.replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)</(p|div|h[1-6]|li|tr|table|section|article)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        text = decodeHTMLEntities(text)

        if preserveNewlines {
            text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        } else {
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

        if let numericRegex = try? NSRegularExpression(pattern: #"&#([0-9]{1,7});"#) {
            let matches = numericRegex.matches(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)).reversed()
            for match in matches {
                guard
                    match.numberOfRanges > 1,
                    let valueRange = Range(match.range(at: 1), in: output),
                    let fullRange = Range(match.range(at: 0), in: output),
                    let value = Int(output[valueRange]),
                    let scalar = UnicodeScalar(value)
                else {
                    continue
                }

                output.replaceSubrange(fullRange, with: String(scalar))
            }
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

private struct HeaderMatch {
    let title: String
    let normalizedTitle: String
    let range: Range<String.Index>
}

private struct SectionBlock {
    let title: String
    let content: String
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
