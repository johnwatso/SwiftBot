import Foundation

public struct AMDService: Sendable {
    private static let fetchCoordinator = AMDFetchCoordinator()
    private static let blockCoordinator = AMDBlockCoordinator()

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
    private let now: @Sendable () -> Date

    public init(
        session: URLSession = .shared,
        sitemapURL: URL = URL(string: "https://www.amd.com/en.sitemap.xml")!,
        userAgent: String = "Mozilla/5.0 (UpdateEngine)",
        formatter: EmbedFormatter = EmbedFormatter(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.sitemapURL = sitemapURL
        self.userAgent = userAgent
        self.formatter = formatter
        self.now = now
    }

    public func fetchLatestDriver() async throws -> DriverInfo {
        try await Self.fetchCoordinator.fetch(
            key: coordinationKey(),
            ttl: 180,
            now: now
        ) {
            try await fetchLatestDriverUncoordinated()
        }
    }

    private func fetchLatestDriverUncoordinated() async throws -> DriverInfo {
        let sitemapResult = await fetchSitemapEntries()
        let latestEntry = try await discoverLatestReleaseEntry(
            sitemapEntries: sitemapResult.entries,
            fallbackError: sitemapResult.error
        )

        let (releaseData, _) = try await fetchData(url: latestEntry.url, timeoutInterval: 20)

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
        \(sitemapResult.rawSitemap)

        AMD release notes HTML:
        \(rawReleaseHTML)
        """

        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatter.format(releaseNotes: releaseNotes),
            rawDebug: debugRaw,
            releaseIdentifier: "amd:\(version)"
        )
    }

    private func coordinationKey() -> String {
        "\(sitemapURL.absoluteString)|\(userAgent)"
    }

    private func fetchSitemapEntries() async -> (rawSitemap: String, entries: [SitemapEntry], error: Error?) {
        do {
            let (data, _) = try await fetchData(url: sitemapURL, timeoutInterval: 12)
            let rawSitemap = String(data: data, encoding: .utf8) ?? ""
            return (rawSitemap, parseSitemapEntries(from: rawSitemap), nil)
        } catch {
            return ("<unavailable: \(error.localizedDescription)>", [], error)
        }
    }

    private func discoverLatestReleaseEntry(
        sitemapEntries: [SitemapEntry],
        fallbackError: Error?
    ) async throws -> SitemapEntry {
        if let latestSitemapEntry = sitemapEntries.max(by: { compareSitemapEntries($0, $1) < 0 }) {
            return await resolveLatestReleaseEntry(from: latestSitemapEntry)
        }

        let bootstrapped = await discoverLatestReleaseFromRecentCandidates()
        if let entry = bootstrapped.entry {
            return entry
        }

        if let fallbackError {
            throw enrich(error: fallbackError, trace: mergeTrace(from: fallbackError, additionalTrace: bootstrapped.trace))
        }

        if !bootstrapped.trace.isEmpty {
            throw enrich(error: AMDServiceError.noReleaseNotesFound, trace: bootstrapped.trace.joined(separator: "\n"))
        }

        throw AMDServiceError.noReleaseNotesFound
    }

    private func mergeTrace(from error: Error, additionalTrace: [String]) -> String {
        let ns = error as NSError
        let existing = (ns.userInfo["amdDebugTrace"] as? String)?
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty } ?? []
        return (existing + additionalTrace).joined(separator: "\n")
    }

    private func fetchData(
        url: URL,
        method: String = "GET",
        timeoutInterval: TimeInterval = 30
    ) async throws -> (Data, URLResponse) {
        if let host = url.host,
           let blockedMessage = await Self.blockCoordinator.activeMessage(for: host, now: now()) {
            throw enrich(error: AMDServiceError.blocked(message: blockedMessage), trace: "cooldown: \(blockedMessage)")
        }

        var lastError: Error?
        var attempts: [String] = []

        for (index, profile) in requestProfiles().enumerated() {
            let request = makeRequest(url: url, method: method, profile: profile, timeoutInterval: timeoutInterval)
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    let body = String(data: data, encoding: .utf8) ?? ""
                    if let blockMessage = blockMessage(statusCode: http.statusCode, body: body) {
                        if let host = url.host {
                            await Self.blockCoordinator.block(host: host, until: now().addingTimeInterval(30 * 60), message: blockMessage)
                        }
                        attempts.append("attempt \(index + 1): \(profile.label) \(url.absoluteString) -> \(blockMessage)")
                        lastError = AMDServiceError.blocked(message: blockMessage)
                        break
                    }
                }
                try validateHTTP(response)
                if let http = response as? HTTPURLResponse {
                    attempts.append("attempt \(index + 1): \(profile.label) \(url.absoluteString) -> HTTP \(http.statusCode)")
                } else {
                    attempts.append("attempt \(index + 1): \(profile.label) \(url.absoluteString) -> success")
                }
                return (data, response)
            } catch {
                attempts.append("attempt \(index + 1): \(profile.label) \(url.absoluteString) -> \(describe(error: error))")
                lastError = error
            }
        }

        let trace = attempts.joined(separator: "\n")
        if let error = lastError {
            throw enrich(error: error, trace: trace)
        }
        throw enrich(error: AMDServiceError.invalidResponse, trace: trace)
    }

    private func makeRequest(
        url: URL,
        method: String = "GET",
        profile: AMDRequestProfile,
        timeoutInterval: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(profile.userAgent, forHTTPHeaderField: "User-Agent")
        for (header, value) in profile.headers {
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.timeoutInterval = timeoutInterval
        return request
    }

    private func requestProfiles() -> [AMDRequestProfile] {
        let browserHeaders = [
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Cache-Control": "no-cache",
            "Pragma": "no-cache",
            "Referer": "https://www.amd.com/en/support.html",
            "Upgrade-Insecure-Requests": "1",
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-User": "?1"
        ]

        let profiles = [
            AMDRequestProfile(label: "default", userAgent: userAgent, headers: [:]),
            AMDRequestProfile(
                label: "safari-like",
                userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3 Safari/605.1.15",
                headers: browserHeaders
            ),
            AMDRequestProfile(
                label: "chrome-like",
                userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
                headers: browserHeaders
            )
        ]

        var seen: Set<String> = []
        return profiles.filter { seen.insert("\($0.label)|\($0.userAgent)|\($0.headers.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))").inserted }
    }

    private func describe(error: Error) -> String {
        let ns = error as NSError
        if let statusCode = ns.userInfo["statusCode"] as? Int {
            return "HTTP \(statusCode)"
        }
        if ns.domain == NSURLErrorDomain {
            return "network \(ns.code): \(error.localizedDescription)"
        }
        return error.localizedDescription
    }

    private func blockMessage(statusCode: Int, body: String) -> String? {
        guard statusCode == 403 else {
            return nil
        }

        let foldedBody = body.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        guard foldedBody.contains("access denied") || foldedBody.contains("edgesuite.net") else {
            return nil
        }

        let reference = firstCapture(pattern: #"Reference\s+#([^<\s]+)"#, in: body)
        if let reference, !reference.isEmpty {
            return "AMD is blocking this IP/session (Akamai Access Denied, ref \(reference)). Cooling down AMD retries for 30 minutes."
        }
        return "AMD is blocking this IP/session (Akamai Access Denied). Cooling down AMD retries for 30 minutes."
    }

    private func enrich(error: Error, trace: String) -> Error {
        let ns = error as NSError
        var userInfo = ns.userInfo
        userInfo["amdDebugTrace"] = trace

        if userInfo[NSLocalizedDescriptionKey] == nil {
            userInfo[NSLocalizedDescriptionKey] = error.localizedDescription
        }

        switch error {
        case AMDServiceError.blocked(let message):
            return NSError(
                domain: ns.domain,
                code: 403,
                userInfo: userInfo.merging([
                    NSLocalizedDescriptionKey: message
                ]) { _, new in new }
            )
        case AMDServiceError.httpError(let statusCode):
            userInfo["statusCode"] = statusCode
            return NSError(domain: ns.domain, code: statusCode, userInfo: userInfo)
        case AMDServiceError.invalidResponse:
            return NSError(domain: ns.domain, code: ns.code, userInfo: userInfo)
        case AMDServiceError.noReleaseNotesFound:
            return NSError(domain: ns.domain, code: ns.code, userInfo: userInfo)
        default:
            return NSError(domain: ns.domain, code: ns.code, userInfo: userInfo)
        }
    }

    private func parseSitemapEntries(from xml: String) -> [SitemapEntry] {
        let pattern = #"(?is)<url>\s*<loc>(https://www\.amd\.com/en(?:/resources/support-articles/release-notes/RN-RAD-WIN-[^<]+\.html|/support/kb/release-notes/rn-rad-win-[^<]+))</loc>\s*<lastmod>([^<]+)</lastmod>\s*</url>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let xmlRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: xmlRange)

        return matches.compactMap { match in
            guard
                let urlRange = Range(match.range(at: 1), in: xml),
                let dateRange = Range(match.range(at: 2), in: xml)
            else {
                return nil
            }

            let urlString = String(xml[urlRange])
            guard
                let version = extractReleaseVersionToken(from: urlString),
                let url = URL(string: urlString),
                let lastModified = parseISODate(String(xml[dateRange]))
            else {
                return nil
            }

            return SitemapEntry(
                url: url,
                version: version,
                lastModified: lastModified
            )
        }
    }

    private func resolveLatestReleaseEntry(from sitemapEntry: SitemapEntry) async -> SitemapEntry {
        guard let baseVersion = parseSitemapVersion(sitemapEntry.version) else {
            return sitemapEntry
        }

        var trace: [String] = []
        for candidateVersion in candidateVersionTokens(after: baseVersion) {
            if let candidate = await probeReleaseEntry(
                version: candidateVersion,
                fallbackLastModified: sitemapEntry.lastModified,
                trace: &trace
            ) {
                return candidate
            }
        }

        return sitemapEntry
    }

    private func discoverLatestReleaseFromRecentCandidates() async -> (entry: SitemapEntry?, trace: [String]) {
        var trace: [String] = []
        for candidateVersion in recentCandidateVersionTokens() {
            if let candidate = await probeReleaseEntry(
                version: candidateVersion,
                fallbackLastModified: now(),
                trace: &trace
            ) {
                return (candidate, trace)
            }
        }

        return (nil, trace)
    }

    private func recentCandidateVersionTokens() -> [String] {
        let calendar = Calendar(identifier: .gregorian)
        let anchorDate = now()
        let preferredPatches = [1, 0, 2, 3]
        var candidates: [(year: Int, month: Int, patch: Int)] = []

        for monthOffset in 0..<2 {
            guard let date = calendar.date(byAdding: .month, value: -monthOffset, to: anchorDate) else {
                continue
            }

            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else {
                continue
            }

            for patch in preferredPatches {
                candidates.append((year: year % 100, month: month, patch: patch))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.year != rhs.year {
                return lhs.year > rhs.year
            }
            if lhs.month != rhs.month {
                return lhs.month > rhs.month
            }
            return lhs.patch > rhs.patch
        }

        return candidates.map { "\($0.year)-\($0.month)-\($0.patch)" }
    }

    private func candidateVersionTokens(after baseVersion: [Int]) -> [String] {
        let preferredPatches = [1, 0, 2, 3]
        var candidates: [(year: Int, month: Int, patch: Int)] = []
        let currentMonthAnchor = currentReleaseMonthAnchor()

        for monthOffset in 0...2 {
            let (year, month) = addMonthOffset(
                year: baseVersion[0],
                month: baseVersion[1],
                offset: monthOffset
            )
            guard isCandidateMonth((year, month), notAfter: currentMonthAnchor) else {
                continue
            }
            let candidatePatches = monthOffset == 0
                ? preferredPatches.filter { $0 > baseVersion[2] }
                : preferredPatches
            for patch in candidatePatches {
                candidates.append((year: year, month: month, patch: patch))
            }
        }

        candidates.sort { lhs, rhs in
            if lhs.year != rhs.year {
                return lhs.year > rhs.year
            }
            if lhs.month != rhs.month {
                return lhs.month > rhs.month
            }
            return lhs.patch > rhs.patch
        }

        return candidates.map { "\($0.year)-\($0.month)-\($0.patch)" }
    }

    private func currentReleaseMonthAnchor() -> (Int, Int) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: now())
        return ((components.year ?? 2000) % 100, components.month ?? 1)
    }

    private func isCandidateMonth(_ lhs: (Int, Int), notAfter rhs: (Int, Int)) -> Bool {
        if lhs.0 != rhs.0 {
            return lhs.0 < rhs.0
        }
        return lhs.1 <= rhs.1
    }

    private func addMonthOffset(year: Int, month: Int, offset: Int) -> (Int, Int) {
        let totalMonths = year * 12 + (month - 1) + offset
        let nextYear = totalMonths / 12
        let nextMonth = totalMonths % 12 + 1
        return (nextYear, nextMonth)
    }

    private func probeReleaseEntry(
        version: String,
        fallbackLastModified: Date,
        trace: inout [String]
    ) async -> SitemapEntry? {
        for url in releaseNoteURLs(for: version) {
            let probe = await probeReleaseURL(at: url, version: version)
            trace.append(contentsOf: probe.trace)
            if probe.exists {
                return SitemapEntry(url: url, version: version, lastModified: fallbackLastModified)
            }
        }

        return nil
    }

    private func probeReleaseURL(at url: URL, version: String) async -> (exists: Bool, trace: [String]) {
        do {
            let (data, _) = try await fetchData(url: url, timeoutInterval: 8)
            let html = String(data: data, encoding: .utf8) ?? ""
            if isReleasePage(html, matching: version) {
                return (true, ["candidate \(version): \(url.absoluteString) -> matched release page"])
            }
            return (false, ["candidate \(version): \(url.absoluteString) -> page did not match release version"])
        } catch {
            let ns = error as NSError
            if let debug = ns.userInfo["amdDebugTrace"] as? String, !debug.isEmpty {
                return (
                    false,
                    debug.components(separatedBy: .newlines)
                        .filter { !$0.isEmpty }
                        .map { "candidate \(version): \($0)" }
                )
            }
            return (false, ["candidate \(version): \(url.absoluteString) -> \(describe(error: error))"])
        }
    }

    private func releaseNoteURLs(for version: String) -> [URL] {
        let upperVersion = version.uppercased()
        let lowerVersion = version.lowercased()
        let rawURLs = [
            "https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-\(upperVersion).html",
            "https://www.amd.com/en/support/kb/release-notes/rn-rad-win-\(lowerVersion)",
            "https://www.amd.com/en/support/kb/release-notes/rn-rad-win-\(lowerVersion).html"
        ]

        return rawURLs.compactMap(URL.init(string:))
    }

    private func isReleasePage(_ html: String, matching version: String) -> Bool {
        let articleNumber = "Article Number: RN-RAD-WIN-\(version)"
        let dottedVersion = version.replacingOccurrences(of: "-", with: ".")
        let releaseTitle = "AMD Software: Adrenalin Edition \(dottedVersion) Release Notes"
        let cleaned = cleanHTML(html, preserveNewlines: true)
        let folded = cleaned.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))

        return folded.contains(articleNumber.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
            || folded.contains(releaseTitle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")))
    }

    private func compareSitemapEntries(_ lhs: SitemapEntry, _ rhs: SitemapEntry) -> Int {
        if let left = parseSitemapVersion(lhs.version), let right = parseSitemapVersion(rhs.version), left != right {
            return left.lexicographicallyPrecedes(right) ? -1 : 1
        }
        if lhs.lastModified != rhs.lastModified {
            return lhs.lastModified < rhs.lastModified ? -1 : 1
        }
        return lhs.url.absoluteString < rhs.url.absoluteString ? -1 : 1
    }

    private func parseSitemapVersion(_ value: String) -> [Int]? {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? parts : nil
    }

    private func extractReleaseVersionToken(from value: String) -> String? {
        firstCapture(
            pattern: #"(?i)RN-RAD-WIN-([0-9]{2}-[0-9]{1,2}-[0-9]{1,2})"#,
            in: value
        )
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

        let cleaned = cleanHTML(html, preserveNewlines: true)
        if let visibleDate = firstCapture(
            pattern: #"(?is)Last\s+Updated:\s*([A-Za-z]+\s+\d{1,2}(?:st|nd|rd|th)?(?:,\s*|\s+)\d{4})"#,
            in: cleaned
        ),
           let parsed = parseVisibleReleaseDate(visibleDate) {
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

    private func parseVisibleReleaseDate(_ value: String) -> Date? {
        let normalized = value.replacingOccurrences(
            of: #"(\d{1,2})(st|nd|rd|th)"#,
            with: "$1",
            options: .regularExpression
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"

        if let parsed = formatter.date(from: normalized) {
            return parsed
        }

        formatter.dateFormat = "MMMM d yyyy"
        return formatter.date(from: normalized)
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

private struct AMDRequestProfile {
    let label: String
    let userAgent: String
    let headers: [String: String]
}

private actor AMDFetchCoordinator {
    private struct CachedValue {
        let value: AMDService.DriverInfo
        let fetchedAt: Date
    }

    private var cachedValues: [String: CachedValue] = [:]
    private var inFlightTasks: [String: Task<AMDService.DriverInfo, Error>] = [:]

    func fetch(
        key: String,
        ttl: TimeInterval,
        now: @escaping @Sendable () -> Date,
        operation: @escaping @Sendable () async throws -> AMDService.DriverInfo
    ) async throws -> AMDService.DriverInfo {
        let currentTime = now()
        if let cached = cachedValues[key], currentTime.timeIntervalSince(cached.fetchedAt) < ttl {
            return cached.value
        }

        if let existingTask = inFlightTasks[key] {
            return try await existingTask.value
        }

        let task = Task { try await operation() }
        inFlightTasks[key] = task
        defer { inFlightTasks[key] = nil }

        let value = try await task.value
        cachedValues[key] = CachedValue(value: value, fetchedAt: now())
        return value
    }
}

private actor AMDBlockCoordinator {
    private struct BlockEntry {
        let until: Date
        let message: String
    }

    private var blocks: [String: BlockEntry] = [:]

    func activeMessage(for host: String, now: Date) -> String? {
        guard let entry = blocks[host] else {
            return nil
        }
        if now < entry.until {
            return entry.message
        }
        blocks.removeValue(forKey: host)
        return nil
    }

    func block(host: String, until: Date, message: String) {
        blocks[host] = BlockEntry(until: until, message: message)
    }
}

public enum AMDServiceError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int)
    case noReleaseNotesFound
    case blocked(message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "AMD endpoint returned an invalid response object."
        case .httpError(let statusCode):
            return "AMD endpoint request failed with HTTP \(statusCode)."
        case .noReleaseNotesFound:
            return "No AMD Radeon Adrenalin release notes were found."
        case .blocked(let message):
            return message
        }
    }
}
