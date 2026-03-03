import Foundation

public struct IntelService: Sendable {
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
    private let pageURL: URL
    private let modelURL: URL
    private let mirrorURL: URL
    private let userAgent: String
    private let formatter: EmbedFormatter

    public init(
        session: URLSession = .shared,
        pageURL: URL = URL(string: "https://www.intel.com/content/www/us/en/download/785597/intel-arc-graphics-windows.html")!,
        modelURL: URL? = nil,
        mirrorURL: URL? = nil,
        userAgent: String = "Mozilla/5.0 (UpdateEngine)",
        formatter: EmbedFormatter = EmbedFormatter()
    ) {
        self.session = session
        self.pageURL = pageURL
        self.modelURL = modelURL ?? Self.defaultModelURL(for: pageURL)
        self.mirrorURL = mirrorURL ?? Self.defaultMirrorURL(for: pageURL)
        self.userAgent = userAgent
        self.formatter = formatter
    }

    public func fetchLatestDriver() async throws -> DriverInfo {
        var debugParts: [String] = []
        var attemptFailures: [String] = []

        if let primaryResult = try await tryFetchAndParse(
            url: pageURL,
            label: "Primary Intel Arc page",
            debugParts: &debugParts,
            failures: &attemptFailures
        ) {
            return primaryResult
        }

        if let modelResult = try await tryFetchAndParse(
            url: modelURL,
            label: "Intel Arc model page",
            debugParts: &debugParts,
            failures: &attemptFailures
        ) {
            return modelResult
        }

        if let mirroredResult = try await tryFetchAndParse(
            url: mirrorURL,
            label: "Mirror Intel Arc page",
            debugParts: &debugParts,
            failures: &attemptFailures
        ) {
            return mirroredResult
        }

        let failureSummary = attemptFailures.isEmpty
            ? "No parse attempts succeeded."
            : attemptFailures.joined(separator: " | ")
        throw IntelServiceError.parseFailed(
            "Failed to parse Intel Arc driver metadata. \(failureSummary)"
        )
    }

    private func tryFetchAndParse(
        url: URL,
        label: String,
        debugParts: inout [String],
        failures: inout [String]
    ) async throws -> DriverInfo? {
        let payload = try await fetchPayload(from: url)
        let statusCode = payload.response?.statusCode ?? -1

        debugParts.append("\(label) status: \(statusCode)")
        debugParts.append("\(label) body:\n\(payload.body)")

        guard (200...299).contains(statusCode) else {
            failures.append("\(label) HTTP \(statusCode)")
            return nil
        }

        let content = extractMirrorMarkdownIfPresent(payload.body)
        let parsed: ParsedDriver
        do {
            parsed = try parse(content: content, baseURL: pageURL, response: payload.response)
        } catch {
            failures.append("\(label) parse error: \(error.localizedDescription)")
            return nil
        }

        let releaseNotes = ReleaseNotes(
            title: "Intel Arc Graphics Driver \(parsed.version)",
            author: "Intel Arc Drivers",
            url: parsed.releaseNotesURL.absoluteString,
            version: parsed.version,
            date: formatDate(parsed.releaseDate),
            sections: [parsed.summarySection],
            thumbnailURL: "https://cdn.patchbot.io/games/145/intel-gpu-drivers_sm.png",
            color: 0x0071C5
        )

        let rawDebug = debugParts.joined(separator: "\n\n")
        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatter.format(releaseNotes: releaseNotes),
            rawDebug: rawDebug,
            releaseIdentifier: parsed.version
        )
    }

    private func fetchPayload(from url: URL) async throws -> PagePayload {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        let body = String(data: data, encoding: .utf8) ?? ""
        return PagePayload(body: body, response: response as? HTTPURLResponse)
    }

    private func parse(
        content: String,
        baseURL: URL,
        response: HTTPURLResponse?
    ) throws -> ParsedDriver {
        guard let version = extractVersion(from: content) else {
            throw IntelServiceError.parseFailed("Version number not found in Intel Arc payload.")
        }

        guard let releaseDate = extractReleaseDate(from: content, response: response) else {
            throw IntelServiceError.parseFailed("Release date not found in Intel Arc payload.")
        }

        guard let summarySection = extractSummarySection(from: content) else {
            throw IntelServiceError.parseFailed("Summary section not found in Intel Arc payload.")
        }

        let releaseNotesURL = extractReleaseNotesURL(from: content, baseURL: baseURL) ?? baseURL
        return ParsedDriver(
            version: version,
            releaseDate: releaseDate,
            releaseNotesURL: releaseNotesURL,
            summarySection: summarySection
        )
    }

    private func extractMirrorMarkdownIfPresent(_ payload: String) -> String {
        guard let markerRange = payload.range(of: "Markdown Content:") else {
            return payload
        }

        let markdown = payload[markerRange.upperBound...]
        return String(markdown).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractVersion(from content: String) -> String? {
        let patterns = [
            #"(?i)\bdriver\s*[:\-]?\s*([0-9]{2,3}(?:\.[0-9]{1,4}){3})\b"#,
            #"(?i)\bversion\s*[:\-]?\s*([0-9]{2,3}(?:\.[0-9]{1,4}){3})\b"#,
            #"\b([0-9]{2,3}(?:\.[0-9]{1,4}){3})\b"#
        ]

        for pattern in patterns {
            if let match = firstCapture(pattern: pattern, in: content) {
                return match
            }
        }
        return nil
    }

    private func extractReleaseDate(from content: String, response: HTTPURLResponse?) -> Date? {
        if let isoDate = firstCapture(pattern: "\"datePublished\"\\s*:\\s*\"([^\"]+)\"", in: content),
           let parsed = parseDate(isoDate) {
            return parsed
        }

        let patterns = [
            #"(?is)dc-page-banner-actions-action-updated.*?<span[^>]*>\s*([0-9]{1,2}/[0-9]{1,2}/[0-9]{4})\s*</span>"#,
            #"(?i)\brelease\s*date\b[^0-9A-Za-z]{0,20}([0-9]{1,2}/[0-9]{1,2}/[0-9]{4})"#,
            #"(?i)\blast\s*updated\b[^0-9A-Za-z]{0,20}([0-9]{1,2}/[0-9]{1,2}/[0-9]{4})"#,
            #"(?i)\b(?:release\s*date|last\s*updated)\b[^A-Za-z0-9]{0,20}([A-Za-z]+\s+\d{1,2},\s*\d{4})"#
        ]

        for pattern in patterns {
            if let value = firstCapture(pattern: pattern, in: content),
               let parsed = parseDate(value) {
                return parsed
            }
        }

        if let headerDate = response?.value(forHTTPHeaderField: "Last-Modified"),
           let parsed = parseRFC1123Date(headerDate) {
            return parsed
        }

        return nil
    }

    private func extractReleaseNotesURL(from content: String, baseURL: URL) -> URL? {
        let htmlPattern = #"(?is)<a[^>]+href=["']([^"']+)["'][^>]*>.*?release\s*notes.*?</a>"#
        if let rawURL = firstCapture(pattern: htmlPattern, in: content),
           let resolved = normalizeIntelURL(rawURL, relativeTo: baseURL) {
            return resolved
        }

        let markdownPattern = #"(?i)\[[^\]]*release\s*notes[^\]]*\]\((https?://[^)\s]+)\)"#
        if let rawURL = firstCapture(pattern: markdownPattern, in: content),
           let resolved = normalizeIntelURL(rawURL, relativeTo: baseURL) {
            return resolved
        }

        return nil
    }

    private func normalizeIntelURL(_ rawURL: String, relativeTo baseURL: URL) -> URL? {
        guard let url = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL else {
            return nil
        }

        guard let host = url.host?.lowercased(), host.contains("intel.com") else {
            return nil
        }

        return url
    }

    private func extractSummarySection(from content: String) -> ReleaseSection? {
        if containsHTML(content) {
            return extractSummaryFromHTML(content)
        }
        return extractSummaryFromMarkdown(content)
    }

    private func extractSummaryFromHTML(_ html: String) -> ReleaseSection? {
        let cleaned = removeScriptAndStyleBlocks(html)

        if let highlightsHTML = extractStrongLabelSection(
            labelCandidates: ["Gaming Highlights", "Highlights"],
            stopLabels: ["OS Support", "Platform Support", "Notes"],
            from: cleaned
        ) {
            let bullets = parseBulletsFromHTML(highlightsHTML)
            if !bullets.isEmpty {
                return ReleaseSection(title: "Highlights", bullets: bullets)
            }

            if let paragraph = firstMeaningfulParagraph(inHTML: highlightsHTML) {
                return ReleaseSection(title: "Highlights", bullets: [Bullet(text: paragraph)])
            }
        }

        if let highlights = extractHTMLSection(
            headers: ["Gaming Highlights", "Highlights"],
            from: cleaned
        ) {
            let bullets = parseBulletsFromHTML(highlights.content)
            if !bullets.isEmpty {
                return ReleaseSection(title: "Highlights", bullets: bullets)
            }
        }

        if let detailed = extractHTMLSection(
            headers: ["Detailed Description", "Introduction"],
            from: cleaned
        ) {
            let bullets = parseBulletsFromHTML(detailed.content)
            if !bullets.isEmpty {
                return ReleaseSection(title: detailed.title, bullets: bullets)
            }

            if let paragraph = firstMeaningfulParagraph(inHTML: detailed.content) {
                return ReleaseSection(title: detailed.title, bullets: [Bullet(text: paragraph)])
            }
        }

        if let paragraph = firstMeaningfulParagraph(inHTML: cleaned) {
            return ReleaseSection(title: "Release Summary", bullets: [Bullet(text: paragraph)])
        }

        return nil
    }

    private func extractStrongLabelSection(
        labelCandidates: [String],
        stopLabels: [String],
        from html: String
    ) -> String? {
        for candidate in labelCandidates {
            let escapedCandidate = NSRegularExpression.escapedPattern(for: candidate)
            let stopPattern = stopLabels.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            let pattern = #"(?is)<strong>\s*"# + escapedCandidate + #"\s*:?\s*</strong>(.*?)(?:<strong>\s*(?:"# + stopPattern + #")\s*:?\s*</strong>|$)"#
            if let section = firstCapture(pattern: pattern, in: html) {
                return section
            }
        }

        return nil
    }

    private func extractSummaryFromMarkdown(_ markdown: String) -> ReleaseSection? {
        let sections = parseMarkdownSections(from: markdown)

        if let highlights = sections.first(where: { normalizeHeader($0.title).contains("highlights") }) {
            let bullets = parseBulletsFromMarkdown(lines: highlights.bodyLines)
            if !bullets.isEmpty {
                return ReleaseSection(title: "Highlights", bullets: bullets)
            }
        }

        if let firstSection = sections.first(where: isMeaningfulMarkdownSection) {
            let bullets = parseBulletsFromMarkdown(lines: firstSection.bodyLines)
            if !bullets.isEmpty {
                return ReleaseSection(title: firstSection.title, bullets: bullets)
            }

            if let paragraph = firstMeaningfulMarkdownParagraph(lines: firstSection.bodyLines) {
                return ReleaseSection(title: firstSection.title, bullets: [Bullet(text: paragraph)])
            }
        }

        if let paragraph = firstMeaningfulMarkdownParagraph(lines: markdown.components(separatedBy: .newlines)) {
            return ReleaseSection(title: "Release Summary", bullets: [Bullet(text: paragraph)])
        }

        return nil
    }

    private func containsHTML(_ content: String) -> Bool {
        content.range(of: #"(?is)<html|<!doctype|<body|<div|<p|<h[1-6]|<li"#, options: .regularExpression) != nil
    }

    private func extractHTMLSection(headers: [String], from html: String) -> HTMLSection? {
        guard let regex = try? NSRegularExpression(pattern: #"(?is)<h[1-6][^>]*>(.*?)</h[1-6]>"#) else {
            return nil
        }

        let matches = regex.matches(in: html, range: NSRange(html.startIndex..<html.endIndex, in: html)).compactMap { match -> HTMLHeaderMatch? in
            guard
                match.numberOfRanges > 1,
                let titleRange = Range(match.range(at: 1), in: html),
                let fullRange = Range(match.range(at: 0), in: html)
            else {
                return nil
            }

            let title = cleanHTML(String(html[titleRange]), preserveNewlines: false)
            return HTMLHeaderMatch(title: title, normalizedTitle: normalizeHeader(title), range: fullRange)
        }

        guard !matches.isEmpty else {
            return nil
        }

        let normalizedHeaders = Set(headers.map(normalizeHeader))
        guard let selectedIndex = matches.firstIndex(where: { normalizedHeaders.contains($0.normalizedTitle) }) else {
            return nil
        }

        let selected = matches[selectedIndex]
        let bodyStart = selected.range.upperBound
        let bodyEnd = selectedIndex + 1 < matches.count ? matches[selectedIndex + 1].range.lowerBound : html.endIndex
        guard bodyStart < bodyEnd else {
            return nil
        }

        let body = String(html[bodyStart..<bodyEnd])
        let title = headers.first(where: { normalizeHeader($0) == selected.normalizedTitle }) ?? selected.title
        return HTMLSection(title: title, content: body)
    }

    private func parseBulletsFromHTML(_ html: String) -> [Bullet] {
        let sanitized = removeScriptAndStyleBlocks(html)
            .replacingOccurrences(of: #"(?is)<br\s*/?>"#, with: "\n", options: .regularExpression)

        guard let regex = try? NSRegularExpression(pattern: #"(?is)<[^>]+>"#) else {
            return []
        }

        let matches = regex.matches(in: sanitized, range: NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized))
        var bullets: [Bullet] = []
        var listDepth = 0
        var isInListItem = false
        var currentText = ""
        var cursor = sanitized.startIndex

        func flushCurrentText() {
            let text = normalizePlainText(currentText)
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
            guard let tagRange = Range(match.range, in: sanitized) else {
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

    private func parseMarkdownSections(from markdown: String) -> [MarkdownSection] {
        let lines = markdown.components(separatedBy: .newlines)
        var sections: [MarkdownSection] = []
        var currentTitle: String?
        var currentBody: [String] = []
        var index = 0

        func finishCurrentSectionIfNeeded() {
            guard let title = currentTitle else {
                return
            }
            let body = currentBody.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            sections.append(MarkdownSection(title: title, bodyLines: body))
        }

        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if let title = markdownHeadingTitle(currentLine: line, nextLine: index + 1 < lines.count ? lines[index + 1] : nil) {
                finishCurrentSectionIfNeeded()
                currentTitle = title
                currentBody = []
                if index + 1 < lines.count, isMarkdownUnderline(lines[index + 1]) {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }

            if let title = markdownBoldHeadingTitle(from: line) {
                finishCurrentSectionIfNeeded()
                currentTitle = title
                currentBody = []
                index += 1
                continue
            }

            if currentTitle != nil {
                currentBody.append(lines[index])
            }
            index += 1
        }

        finishCurrentSectionIfNeeded()
        return sections.filter { section in
            !section.title.isEmpty && section.bodyLines.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    private func parseBulletsFromMarkdown(lines: [String]) -> [Bullet] {
        var bullets: [Bullet] = []

        for rawLine in lines {
            let line = rawLine.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let leadingSpaces = line.prefix { $0 == " " }.count
            if let listText = firstCapture(pattern: #"^(?:[-*+]|[0-9]+\.)\s+(.*)$"#, in: trimmed) {
                let cleaned = cleanMarkdownText(listText)
                guard !cleaned.isEmpty else {
                    continue
                }

                if leadingSpaces >= 2, !bullets.isEmpty {
                    let parent = bullets.removeLast()
                    let updated = Bullet(text: parent.text, subBullets: parent.subBullets + [cleaned])
                    bullets.append(updated)
                } else {
                    bullets.append(Bullet(text: cleaned))
                }
                continue
            }

            let cleaned = cleanMarkdownText(trimmed)
            guard !cleaned.isEmpty else {
                continue
            }

            if bullets.isEmpty {
                bullets.append(Bullet(text: cleaned))
            } else {
                let last = bullets.removeLast()
                if leadingSpaces >= 2 {
                    let updated = Bullet(text: last.text, subBullets: last.subBullets + [cleaned])
                    bullets.append(updated)
                } else {
                    let updatedText = "\(last.text) \(cleaned)"
                    bullets.append(Bullet(text: updatedText, subBullets: last.subBullets))
                }
            }
        }

        return bullets
    }

    private func firstMeaningfulParagraph(inHTML html: String) -> String? {
        let paragraphs = allCaptures(pattern: #"(?is)<p[^>]*>(.*?)</p>"#, in: html)
        for paragraph in paragraphs {
            let cleaned = cleanHTML(paragraph, preserveNewlines: true)
            if isMeaningfulParagraph(cleaned) {
                return cleaned
            }
        }

        let fallback = cleanHTML(html, preserveNewlines: true)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: isMeaningfulParagraph)
        return fallback
    }

    private func firstMeaningfulMarkdownParagraph(lines: [String]) -> String? {
        for line in lines {
            let cleaned = cleanMarkdownText(line)
            if isMeaningfulParagraph(cleaned) {
                return cleaned
            }
        }
        return nil
    }

    private func isMeaningfulMarkdownSection(_ section: MarkdownSection) -> Bool {
        let normalizedTitle = normalizeHeader(section.title)
        if normalizedTitle.contains("title") || normalizedTitle.contains("urlsource") || normalizedTitle.contains("availabledownloads") {
            return false
        }

        return firstMeaningfulMarkdownParagraph(lines: section.bodyLines) != nil
    }

    private func markdownHeadingTitle(currentLine: String, nextLine: String?) -> String? {
        guard !currentLine.isEmpty else {
            return nil
        }

        if let nextLine, isMarkdownUnderline(nextLine) {
            return cleanMarkdownText(currentLine)
        }
        return nil
    }

    private func markdownBoldHeadingTitle(from line: String) -> String? {
        guard
            line.hasPrefix("**"),
            line.hasSuffix("**"),
            line.count > 4
        else {
            return nil
        }

        let start = line.index(line.startIndex, offsetBy: 2)
        let end = line.index(line.endIndex, offsetBy: -2)
        let inner = line[start..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))

        let title = cleanMarkdownText(inner)
        return title.isEmpty ? nil : title
    }

    private func isMarkdownUnderline(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else {
            return false
        }
        return trimmed.allSatisfy { $0 == "-" || $0 == "=" }
    }

    private func isMeaningfulParagraph(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else {
            return false
        }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("title:") || lower.hasPrefix("url source:") {
            return false
        }
        return true
    }

    private func removeScriptAndStyleBlocks(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"(?is)<script[^>]*>.*?</script>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style[^>]*>.*?</style>"#, with: "", options: .regularExpression)
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

    private func cleanMarkdownText<S: StringProtocol>(_ raw: S) -> String {
        var text = String(raw)
        text = replaceRegex(pattern: #"\[([^\]]+)\]\([^)]+\)"#, in: text, with: "$1")
        text = replaceRegex(pattern: #"`([^`]+)`"#, in: text, with: "$1")
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "__", with: "")
        text = text.replacingOccurrences(of: "*", with: "")
        text = text.replacingOccurrences(of: "_", with: "")
        text = decodeHTMLEntities(text)
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func replaceRegex(pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }

    private func normalizePlainText(_ raw: String) -> String {
        let decoded = decodeHTMLEntities(raw)
        let compactSpaces = decoded.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        let compactNewlines = compactSpaces
            .replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{2,}"#, with: "\n", options: .regularExpression)
        return compactNewlines.trimmingCharacters(in: .whitespacesAndNewlines)
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

        let name = token.prefix { $0.isLetter || $0.isNumber }
        return String(name).lowercased()
    }

    private func normalizeHeader(_ title: String) -> String {
        title
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
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

    private func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = isoWithFractional.date(from: trimmed) {
            return parsed
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let parsed = iso.date(from: trimmed) {
            return parsed
        }

        let formats = [
            "MM/dd/yyyy",
            "M/d/yyyy",
            "MMMM d, yyyy",
            "MMM d, yyyy",
            "yyyy-MM-dd"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let parsed = formatter.date(from: trimmed) {
                return parsed
            }
        }

        return nil
    }

    private func parseRFC1123Date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
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

    private static func defaultMirrorURL(for pageURL: URL) -> URL {
        let source = pageURL.absoluteString.replacingOccurrences(of: "https://", with: "http://")
        return URL(string: "https://r.jina.ai/\(source)")!
    }

    private static func defaultModelURL(for pageURL: URL) -> URL {
        let base = pageURL.absoluteString
        if base.hasSuffix(".html") {
            let model = base.replacingOccurrences(of: ".html", with: ".model.json")
            if let url = URL(string: model) {
                return url
            }
        }

        return pageURL
    }
}

private struct PagePayload {
    let body: String
    let response: HTTPURLResponse?
}

private struct ParsedDriver {
    let version: String
    let releaseDate: Date
    let releaseNotesURL: URL
    let summarySection: ReleaseSection
}

private struct HTMLHeaderMatch {
    let title: String
    let normalizedTitle: String
    let range: Range<String.Index>
}

private struct HTMLSection {
    let title: String
    let content: String
}

private struct MarkdownSection {
    let title: String
    let bodyLines: [String]
}

public enum IntelServiceError: LocalizedError, Sendable {
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .parseFailed(let details):
            return "Intel Arc parsing failed: \(details)"
        }
    }
}
