import Foundation

public struct AMDService: Sendable {
    private static let fetchCoordinator = AMDFetchCoordinator()
    private static let blockCoordinator = AMDBlockCoordinator()

    public struct DriverInfo: Sendable {
        public let releaseNotes: ReleaseNotes
        public let embedJSON: String
        public let rawDebug: String
        public let releaseIdentifier: String

        /// Non-fatal notes about how this release was discovered. AMD's sitemap
        /// regularly lags weeks behind the live release notes, so a fetch that
        /// quietly settles for a stale entry has to say so rather than looking
        /// like a healthy "no new driver" result.
        public let discoveryNotes: [String]

        public init(
            releaseNotes: ReleaseNotes,
            embedJSON: String,
            rawDebug: String,
            releaseIdentifier: String,
            discoveryNotes: [String] = []
        ) {
            self.releaseNotes = releaseNotes
            self.embedJSON = embedJSON
            self.rawDebug = rawDebug
            self.releaseIdentifier = releaseIdentifier
            self.discoveryNotes = discoveryNotes
        }
    }

    /// How far back the month scan may reach when the sitemap has gone stale.
    private static let maxLookbackMonths = 12
    /// Lookback used when the sitemap is unavailable entirely.
    private static let bootstrapLookbackMonths = 3
    /// Highest patch number probed within a release month. AMD has shipped
    /// 26-6-4, and skips numbers along the way (26-6-3 never existed), so the
    /// scan has to tolerate gaps rather than stop at the first miss.
    private static let maxPatchNumber = 6
    /// Consecutive misses within one month before that month is abandoned.
    /// Two is enough to step over a single skipped patch number.
    private static let patchMissTolerance = 2
    /// Upper bound on existence probes per fetch, so a bad day upstream cannot
    /// turn into a request storm against AMD.
    private static let maxProbesPerFetch = 40
    /// A sitemap entry older than this, with nothing newer found by probing,
    /// is reported as a warning instead of being passed off as healthy.
    private static let stalenessWarningDays = 45.0

    private struct ReleaseDiscovery {
        let entry: SitemapEntry
        /// Set when the page was already downloaded and verified while probing,
        /// so the caller does not pull the same ~160 KB page twice.
        let releaseHTML: String?
        let notes: [String]
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
        let discovery = try await discoverLatestRelease(
            sitemapEntries: sitemapResult.entries,
            fallbackError: sitemapResult.error
        )
        let latestEntry = discovery.entry

        let rawReleaseHTML: String
        if let prefetched = discovery.releaseHTML {
            rawReleaseHTML = prefetched
        } else {
            let (releaseData, _) = try await fetchData(url: latestEntry.url, timeoutInterval: 20)
            rawReleaseHTML = String(data: releaseData, encoding: .utf8) ?? ""
        }

        let cleanedReleaseHTML = removeScriptAndStyleBlocks(rawReleaseHTML)

        var notes = discovery.notes
        let urlVersion = latestEntry.version.replacingOccurrences(of: "-", with: ".")
        let detectedVersion = detectReleaseVersion(in: cleanedReleaseHTML)

        if let detectedVersion {
            if detectedVersion != urlVersion {
                notes.append("Release page reports \(detectedVersion) but its URL says \(urlVersion); trusting the page.")
            }
        } else {
            notes.append("Could not read a version from the release page, so the URL token \(urlVersion) was used. AMD may have changed the page layout.")
        }

        let version = detectedVersion ?? urlVersion
        let releaseDate = extractReleaseDate(
            from: cleanedReleaseHTML,
            structuredHTML: rawReleaseHTML,
            fallback: latestEntry.lastModified
        )
        let sections = parseSummarySections(from: cleanedReleaseHTML)

        if sections.allSatisfy({ $0.bullets.isEmpty }) {
            notes.append("Release page produced no readable sections. AMD may have changed the page layout.")
        }

        let releaseNotes = ReleaseNotes(
            title: releaseTitle(from: cleanedReleaseHTML, version: version),
            author: "AMD Radeon Drivers",
            url: latestEntry.url.absoluteString,
            version: version,
            date: releaseDate,
            sections: sections,
            thumbnailURL: "https://cdn.patchbot.io/games/140/amd-gpu-drivers_sm.webp",
            color: 16711680
        )

        let debugRaw = """
        AMD discovery:
        \(notes.isEmpty ? "resolved cleanly" : notes.joined(separator: "\n"))

        AMD sitemap XML:
        \(sitemapResult.rawSitemap)

        AMD release notes HTML:
        \(rawReleaseHTML)
        """

        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatter.format(releaseNotes: releaseNotes),
            rawDebug: debugRaw,
            releaseIdentifier: "amd:\(version)",
            discoveryNotes: notes
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

    /// Resolves the newest live Adrenalin release.
    ///
    /// The sitemap is treated as a floor, not as the answer: it routinely lags
    /// the live release notes by weeks and skips releases outright, so the scan
    /// walks months backwards from today until it either finds a release or
    /// reaches the sitemap's newest entry.
    private func discoverLatestRelease(
        sitemapEntries: [SitemapEntry],
        fallbackError: Error?
    ) async throws -> ReleaseDiscovery {
        var budget = Self.maxProbesPerFetch
        var trace: [String] = []

        let sitemapEntry = sitemapEntries.max(by: { compareSitemapEntries($0, $1) < 0 })
        let floorVersion = sitemapEntry.flatMap { parseSitemapVersion($0.version) }

        if let hit = await scanForNewestRelease(
            floorVersion: floorVersion,
            fallbackLastModified: sitemapEntry?.lastModified ?? now(),
            budget: &budget,
            trace: &trace
        ) {
            var notes: [String] = []
            if let sitemapEntry, sitemapEntry.version != hit.entry.version {
                notes.append("Found \(hit.entry.version) by probing; AMD's sitemap still lists \(sitemapEntry.version) as newest.")
            }
            return ReleaseDiscovery(entry: hit.entry, releaseHTML: hit.html, notes: notes)
        }

        guard let sitemapEntry else {
            if let fallbackError {
                throw enrich(error: fallbackError, trace: mergeTrace(from: fallbackError, additionalTrace: trace))
            }

            if !trace.isEmpty {
                throw enrich(error: AMDServiceError.noReleaseNotesFound, trace: trace.joined(separator: "\n"))
            }

            throw AMDServiceError.noReleaseNotesFound
        }

        var notes: [String] = []
        let ageInDays = now().timeIntervalSince(sitemapEntry.lastModified) / 86_400
        if ageInDays > Self.stalenessWarningDays {
            notes.append(String(
                format: "Nothing newer than %@ was found and AMD's sitemap entry for it is %.0f days old. AMD may have changed its release-notes URLs.",
                sitemapEntry.version,
                ageInDays
            ))
        }
        if budget <= 0 {
            notes.append("Probe budget exhausted before the month scan finished; the result may not be the newest release.")
        }
        if trace.contains(where: { $0.contains("AMD is blocking") }) {
            notes.append("AMD rate-limited the release-notes probes, so a newer driver may exist but be unreachable right now.")
        }

        return ReleaseDiscovery(entry: sitemapEntry, releaseHTML: nil, notes: notes)
    }

    /// Walks months newest-first so the first release found is the newest one.
    private func scanForNewestRelease(
        floorVersion: [Int]?,
        fallbackLastModified: Date,
        budget: inout Int,
        trace: inout [String]
    ) async -> (entry: SitemapEntry, html: String)? {
        let anchor = currentReleaseMonthAnchor()
        let anchorIndex = monthIndex(year: anchor.0, month: anchor.1)

        let floorIndex: Int
        if let floorVersion {
            floorIndex = max(
                monthIndex(year: floorVersion[0], month: floorVersion[1]),
                anchorIndex - Self.maxLookbackMonths
            )
        } else {
            floorIndex = anchorIndex - Self.bootstrapLookbackMonths
        }

        guard floorIndex <= anchorIndex else {
            return nil
        }

        for index in stride(from: anchorIndex, through: floorIndex, by: -1) {
            // Only the sitemap's own month is bounded from below: everything
            // above it is unexplored, so patch numbering restarts at 1.
            let lowestPatch: Int
            if let floorVersion, index == monthIndex(year: floorVersion[0], month: floorVersion[1]) {
                lowestPatch = floorVersion[2] + 1
            } else {
                lowestPatch = 1
            }

            if let hit = await scanMonth(
                index: index,
                lowestPatch: lowestPatch,
                fallbackLastModified: fallbackLastModified,
                budget: &budget,
                trace: &trace
            ) {
                return hit
            }

            if budget <= 0 {
                break
            }
        }

        return nil
    }

    /// Probes one release month upwards and returns its highest live patch.
    private func scanMonth(
        index: Int,
        lowestPatch: Int,
        fallbackLastModified: Date,
        budget: inout Int,
        trace: inout [String]
    ) async -> (entry: SitemapEntry, html: String)? {
        guard lowestPatch <= Self.maxPatchNumber else {
            return nil
        }

        let (year, month) = monthComponents(index)
        var best: (entry: SitemapEntry, html: String)?
        var consecutiveMisses = 0

        for patch in lowestPatch...Self.maxPatchNumber {
            guard budget > 0 else {
                break
            }
            budget -= 1

            if let hit = await probeRelease(
                version: "\(year)-\(month)-\(patch)",
                fallbackLastModified: fallbackLastModified,
                trace: &trace
            ) {
                best = hit
                consecutiveMisses = 0
                continue
            }

            consecutiveMisses += 1
            if consecutiveMisses >= Self.patchMissTolerance {
                break
            }
        }

        return best
    }

    private func monthIndex(year: Int, month: Int) -> Int {
        year * 12 + (month - 1)
    }

    private func monthComponents(_ index: Int) -> (year: Int, month: Int) {
        (index / 12, index % 12 + 1)
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
                if isDefinitiveFailure(error) {
                    break
                }
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

    /// A 404 is an answer, not a transport problem. Retrying it under two more
    /// User-Agents tripled the request count for every candidate that does not
    /// exist, which is most of them during a month scan.
    private func isDefinitiveFailure(_ error: Error) -> Bool {
        // Callers see this either raw, from inside the profile loop, or already
        // wrapped by `enrich(error:trace:)` on the way out.
        let statusCode: Int?
        if case AMDServiceError.httpError(let code) = error {
            statusCode = code
        } else {
            statusCode = (error as NSError).userInfo["statusCode"] as? Int
        }

        return statusCode == 404 || statusCode == 410
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
        // AMD's sitemap also lists special-case driver pages such as preview,
        // hotfix, hardware-specific, and Vulkan packages. Some of those have
        // longer version-looking suffixes (for example, 26-10-02-01) and can
        // sort above the current public Adrenalin release. Only accept the
        // canonical three-part release-note URLs that represent that channel.
        let pattern = #"(?is)<url>\s*<loc>(https://www\.amd\.com/en(?:/resources/support-articles/release-notes/RN-RAD-WIN-([0-9]{2}-[0-9]{1,2}-[0-9]{1,2})\.html|/support/kb/release-notes/rn-rad-win-([0-9]{2}-[0-9]{1,2}-[0-9]{1,2})(?:\.html)?))</loc>\s*<lastmod>([^<]+)</lastmod>\s*</url>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let xmlRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: xmlRange)

        return matches.compactMap { match in
            guard
                let urlRange = Range(match.range(at: 1), in: xml),
                let dateRange = Range(match.range(at: 4), in: xml)
            else {
                return nil
            }

            let urlString = String(xml[urlRange])
            guard
                let versionRange = Range(match.range(at: 2), in: xml)
                    ?? Range(match.range(at: 3), in: xml),
                let url = URL(string: urlString),
                let lastModified = parseISODate(String(xml[dateRange]))
            else {
                return nil
            }

            let version = String(xml[versionRange])

            return SitemapEntry(
                url: url,
                version: version,
                lastModified: lastModified
            )
        }
    }

    private func currentReleaseMonthAnchor() -> (Int, Int) {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month], from: now())
        return ((components.year ?? 2000) % 100, components.month ?? 1)
    }

    /// Existence probe for one release. A missing release is by far the common
    /// case, so it is answered with a HEAD; only a live URL costs a full page
    /// download, and that page is handed back so the caller need not refetch it.
    private func probeRelease(
        version: String,
        fallbackLastModified: Date,
        trace: inout [String]
    ) async -> (entry: SitemapEntry, html: String)? {
        guard let url = releaseNoteURL(for: version) else {
            return nil
        }

        do {
            _ = try await fetchData(url: url, method: "HEAD", timeoutInterval: 8)
        } catch {
            trace.append(contentsOf: probeTrace(version: version, url: url, error: error))
            // Only a hard 404 settles it. Anything else — a CDN that stops
            // answering HEAD, a transient 5xx — is inconclusive, so fall
            // through to a GET rather than declaring the release missing.
            if isDefinitiveFailure(error) {
                return nil
            }
        }

        do {
            let (data, _) = try await fetchData(url: url, timeoutInterval: 20)
            let html = String(data: data, encoding: .utf8) ?? ""
            guard isReleasePage(html, matching: version) else {
                trace.append("candidate \(version): \(url.absoluteString) -> page did not match release version")
                return nil
            }

            trace.append("candidate \(version): \(url.absoluteString) -> matched release page")
            return (SitemapEntry(url: url, version: version, lastModified: fallbackLastModified), html)
        } catch {
            trace.append(contentsOf: probeTrace(version: version, url: url, error: error))
            return nil
        }
    }

    private func probeTrace(version: String, url: URL, error: Error) -> [String] {
        let ns = error as NSError
        if let debug = ns.userInfo["amdDebugTrace"] as? String, !debug.isEmpty {
            return debug.components(separatedBy: .newlines)
                .filter { !$0.isEmpty }
                .map { "candidate \(version): \($0)" }
        }
        return ["candidate \(version): \(url.absoluteString) -> \(describe(error: error))"]
    }

    /// The canonical article URL. The older `support/kb/release-notes/...`
    /// forms now 301 to the generic drivers page, so probing them cost two
    /// extra requests per candidate and could pass a soft 404 off as a hit.
    private func releaseNoteURL(for version: String) -> URL? {
        URL(string: "https://www.amd.com/en/resources/support-articles/release-notes/RN-RAD-WIN-\(version.uppercased()).html")
    }

    private func isReleasePage(_ html: String, matching version: String) -> Bool {
        let folded = fold(cleanHTML(html, preserveNewlines: true))
        if folded.contains(fold("Article Number: RN-RAD-WIN-\(version)")) {
            return true
        }

        return detectReleaseVersion(inFoldedText: folded) == version.replacingOccurrences(of: "-", with: ".")
    }

    /// AMD renames this heading periodically — it currently reads
    /// "AMD Software: Adrenalin Edition 26.8.1 Driver Release Notes" where it
    /// once omitted "Driver" — so the version is matched between the two stable
    /// phrases instead of against a pinned full title.
    private func detectReleaseVersion(in html: String) -> String? {
        detectReleaseVersion(inFoldedText: fold(cleanHTML(html, preserveNewlines: true)))
    }

    private func detectReleaseVersion(inFoldedText text: String) -> String? {
        firstCapture(
            pattern: #"adrenalin edition\s+([0-9]+(?:\.[0-9]+)+)(?:\s+[a-z0-9.]+){0,3}\s+release notes"#,
            in: text
        )
    }

    /// Prefers the page's own heading so a renamed title is reported as AMD
    /// writes it, falling back to the constructed form if it looks wrong.
    private func releaseTitle(from html: String, version: String) -> String {
        let fallback = "AMD Software: Adrenalin Edition \(version) Release Notes"
        guard let heading = firstCapture(pattern: #"(?is)<h1[^>]*>(.*?)</h1>"#, in: html) else {
            return fallback
        }

        let text = cleanHTML(heading, preserveNewlines: false)
        guard text.contains(version), text.count <= 120 else {
            return fallback
        }

        return text
    }

    private func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
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

    /// `structuredHTML` is the unstripped page: AMD publishes `datePublished`
    /// inside a JSON-LD `<script>` block, which script removal deletes.
    private func extractReleaseDate(from html: String, structuredHTML: String, fallback: Date) -> String {
        // The date AMD prints on the page wins. It is a plain calendar date, so
        // unlike the machine-readable timestamps below it cannot slide a day
        // when the bot happens to run in a far-eastern timezone.
        let cleaned = cleanHTML(html, preserveNewlines: true)
        if let visibleDate = firstCapture(
            pattern: #"(?is)Last\s+Updated\s*:\s*([A-Za-z]+\s+\d{1,2}\s*(?:st|nd|rd|th)?\s*,?\s*\d{4})"#,
            in: cleaned
        ),
           let parsed = parseVisibleReleaseDate(visibleDate) {
            return formatDate(parsed, in: TimeZone(secondsFromGMT: 0))
        }

        if let published = firstCapture(pattern: #"\"datePublished\"\s*:\s*\"([^\"]+)\""#, in: structuredHTML),
           let parsed = parseISODate(published) {
            return formatDate(parsed, in: timeZone(fromOffsetIn: published))
        }

        if let updated = firstCapture(pattern: #"(?is)<meta\s+property=\"og:updated_time\"\s+content=\"([^\"]+)\""#, in: html),
           let parsed = parseDateWithZoneOffset(updated) {
            return formatDate(parsed, in: timeZone(fromOffsetIn: updated))
        }

        return formatDate(fallback, in: nil)
    }

    /// Renders a timestamp in the zone it was published in, so an evening
    /// release in California is not announced as the following day.
    private func timeZone(fromOffsetIn timestamp: String) -> TimeZone? {
        if timestamp.hasSuffix("Z") {
            return TimeZone(secondsFromGMT: 0)
        }

        guard let regex = try? NSRegularExpression(pattern: #"([+-])(\d{2}):?(\d{2})$"#),
              let match = regex.firstMatch(in: timestamp, range: NSRange(timestamp.startIndex..<timestamp.endIndex, in: timestamp)),
              match.numberOfRanges == 4,
              let signRange = Range(match.range(at: 1), in: timestamp),
              let hourRange = Range(match.range(at: 2), in: timestamp),
              let minuteRange = Range(match.range(at: 3), in: timestamp),
              let hours = Int(timestamp[hourRange]),
              let minutes = Int(timestamp[minuteRange])
        else {
            return nil
        }

        let sign = timestamp[signRange] == "-" ? -1 : 1
        return TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
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
        // AMD wraps the ordinal suffix in its own tag ("August 20<sup>th</sup>,
        // 2026"), so once tags are stripped the suffix and the comma arrive
        // surrounded by stray spaces.
        var normalized = value.replacingOccurrences(
            of: #"(\d{1,2})\s*(?:st|nd|rd|th)\b"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\s+,"#, with: ",", options: .regularExpression)
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMMM d, yyyy"

        if let parsed = formatter.date(from: normalized) {
            return parsed
        }

        formatter.dateFormat = "MMMM d yyyy"
        return formatter.date(from: normalized)
    }

    private func formatDate(_ date: Date, in timeZone: TimeZone?) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone {
            formatter.timeZone = timeZone
        }
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
