import Foundation
import SwiftSoup

actor WikiLookupService {
    private let session: URLSession
    private let finalsWikiAPI: URL
    private let duckDuckGoHTML: URL
    private let skycoachFinalsMetaURL: URL
    private var finalsWeaponAliasCache: [String: String] = [:]
    private var finalsWeaponAliasCacheAt: Date?

    init(
        session: URLSession,
        finalsWikiAPI: URL = URL(string: "https://www.thefinals.wiki/api.php")!,
        duckDuckGoHTML: URL = URL(string: "https://duckduckgo.com/html/")!,
        skycoachFinalsMetaURL: URL = URL(string: "https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds")!
    ) {
        self.session = session
        self.finalsWikiAPI = finalsWikiAPI
        self.duckDuckGoHTML = duckDuckGoHTML
        self.skycoachFinalsMetaURL = skycoachFinalsMetaURL
    }

    func lookupWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        let isFinalsSource = source.baseURL.lowercased().contains("thefinals.wiki")
        if isFinalsSource, let finalsResult = await lookupFinalsWiki(query: query) {
            return finalsResult
        }
        return await lookupGenericMediaWiki(query: query, source: source)
    }

    func lookupFinalsWiki(query: String) async -> FinalsWikiLookupResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }

        for candidate in await finalsBroadQueryCandidates(for: trimmedQuery) {
            if let result = await lookupFinalsWikiExact(query: candidate) {
                return result
            }
        }
        return nil
    }

    func fetchFinalsMetaFromSkycoach() async -> String? {
        do {
            var request = URLRequest(url: skycoachFinalsMetaURL)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let cleanedHTML = html
                .replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"<noscript[\s\S]*?</noscript>"#, with: " ", options: .regularExpression)

            let headingRegex = try NSRegularExpression(
                pattern: #"<h[2-4][^>]*>(.*?)</h[2-4]>(.*?)(?=<h[2-4][^>]*>|$)"#,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )

            func normalize(_ value: String) -> String {
                value
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            func cleanFieldValue(_ raw: String) -> String {
                var value = normalize(stripHTML(raw))
                value = value.replacingOccurrences(of: #"^[\-\:\•\s]+"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"\s+\|\s+.*$"#, with: "", options: .regularExpression)
                value = value.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                value = value.replacingOccurrences(of: "â€˜", with: "'")
                value = value.replacingOccurrences(of: "â€™", with: "'")
                if let cut = value.range(
                    of: #"(?i)\b(the reason|players|gameplay|balancing|this build|this class|speaking of|adding a few|it embodies|it epitomizes)\b"#,
                    options: .regularExpression
                ) {
                    value = String(value[..<cut.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let dot = value.firstIndex(of: ".") {
                    value = String(value[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return value
            }

            func plainTextForSection(_ bodyHTML: String) -> String {
                bodyHTML
                    .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</p>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</li>"#, with: "\n", options: .regularExpression)
                    .replacingOccurrences(of: #"(?i)</div>"#, with: "\n", options: .regularExpression)
            }

            func extractLabeledValue(from text: String, labelPattern: String, stopLabels: [String]) -> String? {
                let stopPattern = stopLabels.joined(separator: "|")
                let pattern = #"(?is)\b(?:best\s+)?"# + labelPattern + #"\b\s*:\s*(.+?)(?=\b(?:best\s+)?(?:"# + stopPattern + #")\b\s*:|[\n\r]|$)"#
                guard let raw = text.firstMatch(for: pattern) else { return nil }
                let cleaned = cleanFieldValue(raw)
                return cleaned.isEmpty ? nil : cleaned
            }

            func extractField(in bodyText: String, bodyItems: [String], labels: [String], stopLabels: [String]) -> String? {
                for label in labels {
                    if let match = extractLabeledValue(from: bodyText, labelPattern: label, stopLabels: stopLabels),
                       !match.isEmpty {
                        return match
                    }
                    for item in bodyItems where item.lowercased().contains(label.lowercased()) {
                        let pattern = #"(?i)(?:best\s+)?"# + label + #"\s*[:\-]\s*(.+)"#
                        guard let match = item.firstMatch(for: pattern) else { continue }
                        let value = cleanFieldValue(match)
                        if !value.isEmpty { return value }
                    }
                }
                return nil
            }

            struct MetaBuildSection {
                let title: String
                var weapon: String?
                var specialization: String?
                var gadgets: String?
            }

            var parsed: [String: MetaBuildSection] = [:]
            let range = NSRange(location: 0, length: (cleanedHTML as NSString).length)

            for match in headingRegex.matches(in: cleanedHTML, options: [], range: range) {
                guard match.numberOfRanges >= 3 else { continue }
                let headingRange = match.range(at: 1)
                let bodyRange = match.range(at: 2)
                guard headingRange.location != NSNotFound, bodyRange.location != NSNotFound else { continue }

                let heading = normalize(stripHTML((cleanedHTML as NSString).substring(with: headingRange)))
                let headingLower = heading.lowercased()

                let sectionKey: String
                if headingLower.contains("light") {
                    sectionKey = "Light"
                } else if headingLower.contains("medium") {
                    sectionKey = "Medium"
                } else if headingLower.contains("heavy") {
                    sectionKey = "Heavy"
                } else {
                    continue
                }

                let bodyHTML = (cleanedHTML as NSString).substring(with: bodyRange)
                let bodyText = normalize(stripHTML(plainTextForSection(bodyHTML)))
                let bodyItems = htmlMatches(for: #"<li[^>]*>(.*?)</li>"#, in: bodyHTML)
                    .map { normalize(stripHTML($0)) }
                    .filter { !$0.isEmpty && !$0.contains("{") && !$0.lowercased().contains("googletagmanager") }

                var section = parsed[sectionKey] ?? MetaBuildSection(title: sectionKey, weapon: nil, specialization: nil, gadgets: nil)
                section.weapon = section.weapon ?? extractField(
                    in: bodyText,
                    bodyItems: bodyItems,
                    labels: ["weapon"],
                    stopLabels: ["specialization", "specialisation", "special", "gadgets?", "utility"]
                )
                section.specialization = section.specialization ?? extractField(
                    in: bodyText,
                    bodyItems: bodyItems,
                    labels: ["specialization", "specialisation", "special"],
                    stopLabels: ["weapon", "gadgets?", "utility"]
                )
                section.gadgets = section.gadgets ?? extractField(
                    in: bodyText,
                    bodyItems: bodyItems,
                    labels: ["gadgets?", "utility"],
                    stopLabels: ["weapon", "specialization", "specialisation", "special"]
                )
                parsed[sectionKey] = section
            }

            let orderedKeys = ["Light", "Medium", "Heavy"]
            let sections = orderedKeys.compactMap { parsed[$0] }
                .filter { $0.weapon != nil || $0.specialization != nil || $0.gadgets != nil }
            guard !sections.isEmpty else { return nil }

            var lines: [String] = ["Current THE FINALS meta (Skycoach):"]
            for section in sections {
                lines.append("")
                lines.append("\(section.title):")
                lines.append("Best Weapon: \(section.weapon ?? "N/A")")
                lines.append("Best Specialization: \(section.specialization ?? "N/A")")
                lines.append("Best Gadgets: \(section.gadgets ?? "N/A")")
            }
            lines.append("")
            lines.append("Source: https://skycoach.gg/blog/the-finals/articles/the-finals-best-builds")
            return lines.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    private func lookupFinalsWikiExact(query: String) async -> FinalsWikiLookupResult? {
        if let direct = await fetchDirectFinalsWikiPage(query: query) {
            return await enrichFinalsResultWithWikitextStatsIfNeeded(direct)
        }

        if let title = await searchFinalsWikiTitle(query: query) {
            if let pageResult = await fetchFinalsWikiPage(forTitle: title),
               pageResult.weaponStats != nil {
                return pageResult
            }

            if let result = await fetchFinalsWikiSummary(title: title) {
                return await enrichFinalsResultWithWikitextStatsIfNeeded(result)
            }
        }

        if let result = await searchFinalsWikiViaSiteSearch(query: query) {
            return await enrichFinalsResultWithWikitextStatsIfNeeded(result)
        }

        if let result = await searchFinalsWikiViaWeb(query: query) {
            return await enrichFinalsResultWithWikitextStatsIfNeeded(result)
        }
        return nil
    }

    private func finalsBroadQueryCandidates(for query: String) async -> [String] {
        let cleaned = query
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let key = finalsLookupKey(cleaned)
        var candidates: [String] = [cleaned]
        var seen: Set<String> = [cleaned.lowercased()]
        let aliases = await finalsWeaponAliases()

        if let canonical = aliases[key] {
            let normalizedCanonical = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedCanonical.isEmpty, seen.insert(normalizedCanonical.lowercased()).inserted {
                candidates.append(normalizedCanonical)
            }
        }

        if cleaned.contains("-") {
            let spaced = cleaned.replacingOccurrences(of: "-", with: " ")
            if seen.insert(spaced.lowercased()).inserted {
                candidates.append(spaced)
            }
        } else if cleaned.contains(" ") {
            let hyphenated = cleaned.replacingOccurrences(of: " ", with: "-")
            if seen.insert(hyphenated.lowercased()).inserted {
                candidates.append(hyphenated)
            }
        }

        let compact = cleaned.replacingOccurrences(of: " ", with: "")
        if seen.insert(compact.lowercased()).inserted {
            candidates.append(compact)
        }

        return candidates
    }

    private func finalsWeaponAliases() async -> [String: String] {
        let now = Date()
        if let fetchedAt = finalsWeaponAliasCacheAt,
           now.timeIntervalSince(fetchedAt) < 6 * 60 * 60,
           !finalsWeaponAliasCache.isEmpty {
            return Self.finalsCanonicalAliases.merging(finalsWeaponAliasCache, uniquingKeysWith: { _, new in new })
        }

        let fetchedAliases = await fetchFinalsWeaponAliasesFromWiki()
        finalsWeaponAliasCache = fetchedAliases
        finalsWeaponAliasCacheAt = now
        return Self.finalsCanonicalAliases.merging(fetchedAliases, uniquingKeysWith: { _, new in new })
    }

    private func fetchFinalsWeaponAliasesFromWiki() async -> [String: String] {
        var aliases: [String: String] = [:]
        var cmcontinue: String?
        var pageCount = 0

        while pageCount < 4 {
            var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
            var items: [URLQueryItem] = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "list", value: "categorymembers"),
                URLQueryItem(name: "cmtitle", value: "Category:Weapons"),
                URLQueryItem(name: "cmtype", value: "page"),
                URLQueryItem(name: "cmlimit", value: "500"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "origin", value: "*")
            ]
            if let cmcontinue, !cmcontinue.isEmpty {
                items.append(URLQueryItem(name: "cmcontinue", value: cmcontinue))
            }
            components?.queryItems = items
            guard let url = components?.url else { break }

            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let query = json["query"] as? [String: Any],
                      let members = query["categorymembers"] as? [[String: Any]] else {
                    break
                }

                for member in members {
                    guard let title = member["title"] as? String else { continue }
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    aliases[finalsLookupKey(trimmed)] = trimmed
                    aliases[finalsLookupKey(trimmed.replacingOccurrences(of: "-", with: ""))] = trimmed
                    aliases[finalsLookupKey(trimmed.replacingOccurrences(of: "-", with: " "))] = trimmed
                    aliases[finalsLookupKey(trimmed.replacingOccurrences(of: " ", with: ""))] = trimmed
                }

                if let `continue` = json["continue"] as? [String: Any],
                   let next = `continue`["cmcontinue"] as? String,
                   !next.isEmpty {
                    cmcontinue = next
                    pageCount += 1
                    continue
                }
                break
            } catch {
                break
            }
        }

        return aliases
    }

    private func enrichFinalsResultWithWikitextStatsIfNeeded(_ result: FinalsWikiLookupResult) async -> FinalsWikiLookupResult {
        guard result.weaponStats == nil else { return result }
        guard let stats = await fetchFinalsWeaponStatsFromWikitext(title: result.title) else { return result }
        return FinalsWikiLookupResult(
            title: result.title,
            extract: result.extract,
            url: result.url,
            imageURL: result.imageURL,
            pageType: result.pageType,
            fields: result.fields,
            weaponStats: stats
        )
    }

    private func fetchFinalsWeaponStatsFromWikitext(title: String) async -> FinalsWeaponStats? {
        var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "revisions"),
            URLQueryItem(name: "rvprop", value: "content"),
            URLQueryItem(name: "rvslots", value: "main"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let query = object["query"] as? [String: Any],
                  let pages = query["pages"] as? [String: Any] else { return nil }

            var wikitext: String?
            for pageValue in pages.values {
                guard let page = pageValue as? [String: Any],
                      let revisions = page["revisions"] as? [[String: Any]],
                      let revision = revisions.first,
                      let slots = revision["slots"] as? [String: Any],
                      let main = slots["main"] as? [String: Any] else { continue }
                if let raw = main["*"] as? String, !raw.isEmpty {
                    wikitext = raw
                    break
                }
            }
            guard let wikitext, !wikitext.isEmpty else { return nil }
            return parseWeaponStatsFromWikitext(wikitext)
        } catch {
            return nil
        }
    }

    private func parseWeaponStatsFromWikitext(_ wikitext: String) -> FinalsWeaponStats? {
        let lines = wikitext.components(separatedBy: .newlines)

        func value(for labels: [String]) -> String? {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("|"),
                      let equals = trimmed.firstIndex(of: "=") else { continue }
                let rawKey = String(trimmed[trimmed.index(after: trimmed.startIndex)..<equals])
                let rawValue = String(trimmed[trimmed.index(after: equals)...])
                let key = rawKey
                    .lowercased()
                    .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
                let cleanedValue = cleanWikitextValue(rawValue)
                if cleanedValue.isEmpty { continue }
                for label in labels where key == label {
                    return cleanedValue
                }
            }
            return nil
        }

        let type = value(for: ["type", "class", "weapontype"])
        let bodyDamage = value(for: ["body", "damage", "damagepershot", "basedamage"])
        let headshotDamage = value(for: ["head", "headshot", "headshotdamage", "criticalhit"])
        let fireRate = value(for: ["rpm", "firerate", "rateoffire"])
        let dropoffStart = value(for: ["minrange", "dropoffstart", "effectiverangestart"])
        let dropoffEnd = value(for: ["maxrange", "dropoffend", "effectiverangeend"])
        let minimumDamage = value(for: ["minimumdamage", "mindamage"])
        let magazineSize = value(for: ["magazine", "magsize", "magazinesize", "ammo"])
        let shortReload = value(for: ["tacticalreload", "shortreload", "reloadpartial", "reloadtime"])
        let longReload = value(for: ["emptyreload", "longreload", "reloadempty"])
        let version = value(for: ["version", "patch", "gameversion", "updated"])
        let notes = value(for: ["notes", "note"])

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(minimumDamage),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload),
            version: cleanedStatValue(version),
            notes: cleanedStatValue(notes)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.headshotDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.shortReload,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }
        return hasUsefulData ? stats : nil
    }

    private func cleanWikitextValue(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(of: #"\{\{[^{}]*\|([^{}|]+)\}\}"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\[\[([^|\]]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\[\[([^\]]+)\]\]"#, with: "$1", options: .regularExpression)
        output = output.replacingOccurrences(of: #"'''"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"''"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\{\{[^{}]*\}\}"#, with: "", options: .regularExpression)
        output = output.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func finalsLookupKey(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private static let finalsCanonicalAliases: [String: String] = [
        "fcar": "FCAR",
        "akm": "AKM",
        "cl40": "CL-40",
        "model1887": "Model 1887",
        "pike556": "Pike-556",
        "r357": ".357",
        "357": ".357",
        "m11": "M11",
        "xp54": "XP-54",
        "v9s": "V9S",
        "v95": "V9S",
        "arn220": "ARN-220",
        "arn": "ARN-220",
        "arn220rifle": "ARN-220",
        "arnrifle": "ARN-220",
        "lh1": "LH1",
        "sr84": "SR-84",
        "recurvedbow": "Recurve Bow",
        "shak50": "SHaK-50",
        "shak": "SHaK-50",
        "m60": "M60",
        "lewismg": "Lewis Gun",
        "sa1216": "SA1216",
        "ks23": "KS-23",
        "sledgehammer": "Sledgehammer",
        "flamethrower": "Flamethrower"
    ]

    private func lookupGenericMediaWiki(query: String, source: WikiSource) async -> FinalsWikiLookupResult? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return nil }
        let searchScope = source.searchScope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let baseURL = normalizedWikiBaseURL(from: source.baseURL),
            let apiURL = mediaWikiAPIURL(baseURL: baseURL, apiPath: source.apiPath)
        else {
            return nil
        }

        if let direct = await fetchGenericWikiPage(baseURL: baseURL, query: trimmedQuery, searchScope: searchScope) {
            if direct.fields.isEmpty,
               let parsed = await fetchMediaWikiParsedPage(title: direct.title, apiURL: apiURL, baseURL: baseURL, searchScope: searchScope),
               !parsed.fields.isEmpty {
                return parsed
            }
            return direct
        }

        var title = await searchMediaWikiTitle(query: scopedSearchQuery(query: trimmedQuery, scope: searchScope), apiURL: apiURL)
        if title == nil {
            title = await searchMediaWikiTitle(query: trimmedQuery, apiURL: apiURL)
        }
        guard let title else {
            return nil
        }
        if let parsed = await fetchMediaWikiParsedPage(title: title, apiURL: apiURL, baseURL: baseURL, searchScope: searchScope) {
            return parsed
        }
        return await fetchMediaWikiSummary(title: title, apiURL: apiURL, baseURL: baseURL)
    }

    private func scopedSearchQuery(query: String, scope: String) -> String {
        let trimmedScope = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScope.isEmpty else { return query }
        return "\(query) \(trimmedScope)"
    }

    private func normalizedWikiBaseURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prefixed = trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ? trimmed : "https://\(trimmed)"
        return URL(string: prefixed)
    }

    private func mediaWikiAPIURL(baseURL: URL, apiPath: String) -> URL? {
        let cleanAPIPath = apiPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAPIPath.isEmpty { return baseURL.appendingPathComponent("api.php") }
        return URL(string: cleanAPIPath, relativeTo: baseURL)?.absoluteURL
    }

    private func searchMediaWikiTitle(query: String, apiURL: URL) async -> String? {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(MediaWikiSearchResponse.self, from: data)
            let title = decoded.query?.search.first?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        } catch {
            return nil
        }
    }

    private func fetchMediaWikiSummary(title: String, apiURL: URL, baseURL: URL) async -> FinalsWikiLookupResult? {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts|info|pageimages"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "piprop", value: "original|thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "600"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(MediaWikiPageResponse.self, from: data)
            guard let page = decoded.query?.pages.values.first, page.missing == nil else { return nil }

            let extract = page.extract?
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let finalURL = page.fullurl ?? baseURL.appendingPathComponent("wiki/\(title.replacingOccurrences(of: " ", with: "_"))").absoluteString
            return FinalsWikiLookupResult(
                title: page.title,
                extract: extract,
                url: finalURL,
                imageURL: page.original?.source ?? page.thumbnail?.source,
                pageType: nil,
                fields: [],
                weaponStats: nil
            )
        } catch {
            return nil
        }
    }

    private func fetchMediaWikiParsedPage(
        title: String,
        apiURL: URL,
        baseURL: URL,
        searchScope: String = ""
    ) async -> FinalsWikiLookupResult? {
        var components = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "text|displaytitle"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(MediaWikiParseResponse.self, from: data)
            guard let parsed = decoded.parse, !parsed.text.html.isEmpty else { return nil }

            let pageTitle = stripHTML(parsed.displayTitle ?? parsed.title)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let slug = (pageTitle.isEmpty ? title : pageTitle)
                .replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            let pageURL = baseURL.appendingPathComponent("wiki/\(slug)")
            return parseWikiHTMLPage(
                html: parsed.text.html,
                pageURL: pageURL,
                fallbackTitle: pageTitle.isEmpty ? title : pageTitle,
                searchScope: searchScope
            )
        } catch {
            return nil
        }
    }

    private func fetchGenericWikiPage(baseURL: URL, query: String, searchScope: String = "") async -> FinalsWikiLookupResult? {
        let slug = query
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard !slug.isEmpty else { return nil }
        let pageURL = baseURL.appendingPathComponent("wiki/\(slug)")

        do {
            var request = URLRequest(url: pageURL)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            return parseWikiHTMLPage(html: html, pageURL: pageURL, fallbackTitle: query, searchScope: searchScope)
        } catch {
            return nil
        }
    }

    private func searchFinalsWikiTitle(query: String) async -> String? {
        var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(MediaWikiSearchResponse.self, from: data)
            let title = decoded.query?.search.first?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        } catch {
            return nil
        }
    }

    private func fetchFinalsWikiSummary(title: String) async -> FinalsWikiLookupResult? {
        var components = URLComponents(url: finalsWikiAPI, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts|info|pageimages"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "piprop", value: "original|thumbnail"),
            URLQueryItem(name: "pithumbsize", value: "600"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "origin", value: "*")
        ]
        guard let url = components?.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            let decoded = try JSONDecoder().decode(MediaWikiPageResponse.self, from: data)
            guard let page = decoded.query?.pages.values.first, page.missing == nil else { return nil }

            return FinalsWikiLookupResult(
                title: page.title,
                extract: page.extract?
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                url: page.fullurl ?? "https://www.thefinals.wiki/wiki/\(page.title.replacingOccurrences(of: " ", with: "_"))",
                imageURL: page.original?.source ?? page.thumbnail?.source,
                pageType: nil,
                fields: [],
                weaponStats: nil
            )
        } catch {
            return nil
        }
    }

    private func fetchDirectFinalsWikiPage(query: String) async -> FinalsWikiLookupResult? {
        for candidate in directFinalsWikiCandidateURLs(for: query) {
            if let result = await fetchFinalsWikiPage(at: candidate) {
                return result
            }
        }
        return nil
    }

    private func fetchFinalsWikiPage(forTitle title: String) async -> FinalsWikiLookupResult? {
        let slug = title
            .replacingOccurrences(of: " ", with: "_")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        guard !slug.isEmpty,
              let url = URL(string: "https://www.thefinals.wiki/wiki/\(slug)") else { return nil }
        return await fetchFinalsWikiPage(at: url)
    }

    private func directFinalsWikiCandidateURLs(for query: String) -> [URL] {
        let cleaned = query
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }

        let variants = [
            cleaned,
            cleaned.localizedCapitalized,
            cleaned.uppercased(),
            cleaned.lowercased()
        ]

        var urls: [URL] = []
        var seen: Set<String> = []
        for variant in variants {
            let slug = variant
                .replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            guard !slug.isEmpty else { continue }
            let absolute = "https://www.thefinals.wiki/wiki/\(slug)"
            if seen.insert(absolute).inserted, let url = URL(string: absolute) {
                urls.append(url)
            }
        }
        return urls
    }

    private func fetchFinalsWikiPage(at pageURL: URL) async -> FinalsWikiLookupResult? {
        do {
            var request = URLRequest(url: pageURL)
            request.setValue("SwiftBot/1.0 (+https://www.thefinals.wiki/wiki/Main_Page)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let parsed = parseWikiHTMLPage(html: html, pageURL: pageURL, fallbackTitle: nil)
            if !isMeaningfulFinalsWikiTitle(parsed.title) {
                return nil
            }

            let weaponStats = extractWeaponStats(from: html)
            return FinalsWikiLookupResult(
                title: parsed.title,
                extract: parsed.extract,
                url: parsed.url,
                imageURL: parsed.imageURL,
                pageType: weaponStats == nil ? parsed.pageType : "weapon",
                fields: parsed.fields,
                weaponStats: weaponStats
            )
        } catch {
            return nil
        }
    }

    private func searchFinalsWikiViaSiteSearch(query: String) async -> FinalsWikiLookupResult? {
        var components = URLComponents(string: "https://www.thefinals.wiki/wiki/Special:Search")
        components?.queryItems = [
            URLQueryItem(name: "search", value: query)
        ]

        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let hrefMatches = html.matches(for: "href=\\\"(/wiki/[^\\\"#?]+)\\\"")
            for href in hrefMatches {
                guard let pageURL = URL(string: "https://www.thefinals.wiki\(href)"),
                      isAcceptableFinalsWikiPage(pageURL),
                      let result = await fetchFinalsWikiPage(at: pageURL) else { continue }
                return result
            }
        } catch {
            return nil
        }

        return nil
    }

    private func searchFinalsWikiViaWeb(query: String) async -> FinalsWikiLookupResult? {
        guard let pageURL = await searchFinalsWikiPageURL(query: query) else { return nil }
        return await fetchFinalsWikiPage(at: pageURL)
    }

    private func searchFinalsWikiPageURL(query: String) async -> URL? {
        var components = URLComponents(url: duckDuckGoHTML, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: "site:thefinals.wiki/wiki \(query)")
        ]

        guard let url = components?.url else { return nil }

        do {
            var request = URLRequest(url: url)
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let html = String(data: data, encoding: .utf8) else { return nil }

            let matches = html.matches(for: #"https?%3A%2F%2Fwww\.thefinals\.wiki%2Fwiki%2F[^"&<]+"#)
            for encoded in matches {
                let decoded = encoded.removingPercentEncoding ?? encoded
                if let url = URL(string: decoded),
                   isAcceptableFinalsWikiPage(url) {
                    return url
                }
            }

            let directMatches = html.matches(for: #"https://www\.thefinals\.wiki/wiki/[^"'&< ]+"#)
            for match in directMatches {
                if let url = URL(string: match),
                   isAcceptableFinalsWikiPage(url) {
                    return url
                }
            }
        } catch {
            return nil
        }

        return nil
    }

    private func isAcceptableFinalsWikiPage(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        if !path.hasPrefix("/wiki/") { return false }
        if path.contains("special:") || path.contains("/file:") || path.hasSuffix("/main_page") {
            return false
        }
        return true
    }

    private func parseWikiHTMLPage(
        html: String,
        pageURL: URL,
        fallbackTitle: String?,
        searchScope: String = ""
    ) -> FinalsWikiLookupResult {
        guard let document = try? SwiftSoup.parse(html, pageURL.absoluteString) else {
            let title = extractHTMLTitle(from: html)
                ?? fallbackTitle
                ?? pageURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
            let extract = extractSummaryParagraph(from: html)
            let resolvedURL = extractCanonicalWikiPageURL(from: html) ?? pageURL
            return FinalsWikiLookupResult(title: title, extract: extract, url: resolvedURL.absoluteString)
        }
        let scopedDocument = scopedMediaWikiDocument(from: document, scope: searchScope, baseURL: pageURL)
        let contentRoot: Element = scopedDocument ?? document

        let headingText = (try? document.select("h1#firstHeading, h1.page-header__title, h1").first()?.text()) ?? ""
        let docTitle = (try? document.title()) ?? ""
        let title = cleanedSoupText(headingText)
            .nonEmpty
            ?? cleanedSoupText(docTitle)
                .replacingOccurrences(of: " - THE FINALS Wiki", with: "")
                .replacingOccurrences(of: " | Fandom", with: "")
                .nonEmpty
            ?? fallbackTitle
            ?? pageURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")

        let canonical = firstSoupAttribute(
            in: document,
            selector: "link[rel=canonical]",
            attributes: ["href"],
            baseURL: pageURL
        ) ?? pageURL.absoluteString

        let summary = firstMeaningfulSoupText(
            in: contentRoot,
            selectors: [
                ".mw-parser-output > p",
                "#mw-content-text p",
                ".page-content p",
                "main p",
                "article p",
                "body > p",
                "p"
            ],
            minimumLength: 40
        )

        let imageURL = firstSoupAttribute(
            in: contentRoot,
            selector: "meta[property=og:image], meta[name=twitter:image]",
            attributes: ["content"],
            baseURL: pageURL
        ) ?? firstSoupAttribute(
            in: contentRoot,
            selector: ".portable-infobox img, .infobox img, figure img, a.image img, .mw-parser-output img",
            attributes: ["src", "data-src"],
            baseURL: pageURL
        ) ?? firstSoupAttribute(
            in: document,
            selector: "meta[property=og:image], meta[name=twitter:image]",
            attributes: ["content"],
            baseURL: pageURL
        )

        let fields = extractSoupFields(from: contentRoot)
        let pageType = inferredPageType(from: fields, title: title)

        return FinalsWikiLookupResult(
            title: title,
            extract: summary,
            url: canonical,
            imageURL: imageURL,
            pageType: pageType,
            fields: fields,
            weaponStats: nil
        )
    }

    private func scopedMediaWikiDocument(from document: Document, scope: String, baseURL: URL) -> Document? {
        let normalizedScopes = normalizedScopeCandidates(scope)
        guard !normalizedScopes.isEmpty else { return nil }
        guard let headings = try? document.select(".mw-parser-output h2, .mw-parser-output h3, h2, h3") else {
            return nil
        }

        for heading in headings.array() {
            let headingText = cleanedSoupText((try? heading.text()) ?? "")
            let normalizedHeading = normalizedScopeText(headingText)
            guard normalizedScopes.contains(where: { scopeMatchesHeading(scope: $0, heading: normalizedHeading) }) else {
                continue
            }

            let headingLevel = headingTagLevel(heading.tagName())
            var fragments: [String] = []
            var current: Element? = heading

            while let element = current {
                if element !== heading,
                   let level = headingTagLevel(element.tagName()),
                   let headingLevel,
                   level <= headingLevel {
                    break
                }
                if let outerHTML = try? element.outerHtml() {
                    fragments.append(outerHTML)
                }
                current = try? element.nextElementSibling()
            }

            guard !fragments.isEmpty,
                  let scoped = try? SwiftSoup.parseBodyFragment(fragments.joined(separator: "\n"), baseURL.absoluteString) else {
                continue
            }
            return scoped
        }
        return nil
    }

    private func scopeMatchesHeading(scope: String, heading: String) -> Bool {
        guard !scope.isEmpty, !heading.isEmpty else { return false }
        if scope == "modernwarfare",
           heading.contains("modernwarfare"),
           heading.rangeOfCharacter(from: .decimalDigits) != nil,
           !heading.contains("2019") {
            return false
        }
        return heading.contains(scope) || scope.contains(heading)
    }

    private func normalizedScopeCandidates(_ scope: String) -> [String] {
        let raw = scope.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        var values: [String] = [raw]
        let lower = raw.lowercased()
        if lower.contains("mw2019") || lower.contains("mw 2019") {
            values.append("Modern Warfare")
            values.append("Call of Duty Modern Warfare")
        }
        if lower.contains("modern warfare") {
            values.append(raw.replacingOccurrences(of: #"(?i)\b20\d{2}\b"#, with: "", options: .regularExpression))
        }

        var seen: Set<String> = []
        return values.compactMap { value in
            let normalized = normalizedScopeText(value)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func normalizedScopeText(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: "callofduty", with: "")
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private func headingTagLevel(_ tagName: String) -> Int? {
        switch tagName.lowercased() {
        case "h1": return 1
        case "h2": return 2
        case "h3": return 3
        case "h4": return 4
        case "h5": return 5
        case "h6": return 6
        default: return nil
        }
    }

    private func firstMeaningfulSoupText(in document: Element, selectors: [String], minimumLength: Int) -> String {
        for selector in selectors {
            guard let elements = try? document.select(selector) else { continue }
            for element in elements.array() {
                let text = cleanedSoupText((try? element.text()) ?? "")
                if text.count >= minimumLength,
                   !text.lowercased().contains("retrieved from"),
                   !text.lowercased().hasPrefix("main page:") {
                    return text
                }
            }
        }
        return ""
    }

    private func firstSoupAttribute(
        in document: Element,
        selector: String,
        attributes: [String],
        baseURL: URL
    ) -> String? {
        guard let elements = try? document.select(selector) else { return nil }
        for element in elements.array() {
            for attribute in attributes {
                let raw = ((try? element.attr(attribute)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { continue }
                if let absolute = absoluteWikiURL(from: raw, baseURL: baseURL) {
                    return absolute
                }
            }
        }
        return nil
    }

    private func extractSoupFields(from document: Element) -> [WikiResultField] {
        var fields: [WikiResultField] = []
        var seen: Set<String> = []

        func append(name rawName: String, value rawValue: String) {
            let name = cleanedSoupText(rawName)
            let value = cleanedSoupText(rawValue)
            guard !name.isEmpty, !value.isEmpty, name.count <= 40, value.count <= 180 else { return }
            let key = normalizedLabel(name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            fields.append(WikiResultField(name: name, value: value, inline: true))
        }

        if let items = try? document.select(".portable-infobox .pi-item.pi-data") {
            for item in items.array() {
                let label = (try? item.select(".pi-data-label").first()?.text()) ?? ""
                let value = (try? item.select(".pi-data-value").first()?.text()) ?? ""
                append(name: label, value: value)
            }
        }

        if let rows = try? document.select(".infobox tr, table.infobox tr, .mw-parser-output table.wikitable tr") {
            for row in rows.array() {
                let cells = (try? row.select("th, td").array()) ?? []
                guard cells.count >= 2 else { continue }
                let label = (try? cells[0].text()) ?? ""
                let value = (try? cells[1].text()) ?? ""
                append(name: label, value: value)
            }
        }

        return Array(fields.prefix(18))
    }

    private func inferredPageType(from fields: [WikiResultField], title: String) -> String? {
        let labels = Set(fields.map { normalizedLabel($0.name) })
        if labels.contains("damage") || labels.contains("body") || labels.contains("rpm") || labels.contains("magazine") {
            return "weapon"
        }
        let lowered = title.lowercased()
        if lowered.contains("weapon") { return "weapon" }
        return nil
    }

    private func absoluteWikiURL(from raw: String, baseURL: URL) -> String? {
        var value = decodeHTMLEntities(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") {
            value = "\(baseURL.scheme ?? "https"):\(value)"
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private func cleanedSoupText(_ text: String) -> String {
        decodeHTMLEntities(text)
            .replacingOccurrences(of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractHTMLTitle(from html: String) -> String? {
        guard let rawTitle = html.firstMatch(for: #"<title>(.*?)</title>"#) else { return nil }
        let cleaned = decodeHTMLEntities(rawTitle)
            .replacingOccurrences(of: " - THE FINALS Wiki", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func isMeaningfulFinalsWikiTitle(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return !lowered.contains("search results") &&
            !lowered.contains("create the page") &&
            !lowered.contains("main page")
    }

    private func extractCanonicalWikiPageURL(from html: String) -> URL? {
        guard let canonical = html.firstMatch(for: #"<link[^>]+rel=\"canonical\"[^>]+href=\"([^\"]+)\""#) else {
            return nil
        }
        return URL(string: decodeHTMLEntities(canonical))
    }

    private func extractSummaryParagraph(from html: String) -> String {
        let paragraphs = html.matches(for: #"<p\b[^>]*>(.*?)</p>"#)
        for paragraph in paragraphs {
            let stripped = stripHTML(paragraph)
                .replacingOccurrences(of: "\\[[^\\]]+\\]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if stripped.count >= 40,
               !stripped.lowercased().contains("retrieved from"),
               !stripped.lowercased().hasPrefix("main page:") {
                return stripped
            }
        }

        return ""
    }

    private func extractWeaponStats(from html: String) -> FinalsWeaponStats? {
        if let parsedFromText = extractWeaponStatsFromText(html: html) {
            return parsedFromText
        }

        if let parsedFromNormalizedText = extractWeaponStatsFromNormalizedText(html: html) {
            return parsedFromNormalizedText
        }

        if let parsedFromLooseLines = extractWeaponStatsFromLooseLines(html: html) {
            return parsedFromLooseLines
        }

        let profileSection = extractSectionHTML(named: "Profile", from: html)
        let damageSection = extractSectionHTML(named: "Damage", from: html)
        let falloffSection = extractSectionHTML(named: "Damage Falloff", from: html)
        let technicalSection = extractSectionHTML(named: "Technical", from: html)
        let notesSection = extractSectionHTML(named: "Notes", from: html)

        let type = profileSection.flatMap { extractTableValue(label: "Type", from: $0) }
        let version = extractTableValue(label: "Version", from: html)
            ?? extractTableValue(label: "Patch", from: html)
            ?? profileSection.flatMap { extractTableValue(label: "Version", from: $0) }
            ?? profileSection.flatMap { extractTableValue(label: "Patch", from: $0) }
        let bodyDamage = damageSection.flatMap { extractTableValue(label: "Body", from: $0) }
        let headshotDamage = damageSection.flatMap { extractTableValue(label: "Head", from: $0) }
        let fireRate = technicalSection.flatMap {
            extractTableValue(label: "RPM", from: $0) ?? extractTableValue(label: "Fire Rate", from: $0)
        }
        let dropoffStart = falloffSection.flatMap {
            extractTableValue(label: "Min Range", from: $0) ?? extractTableValue(label: "Dropoff Start", from: $0)
        }
        let dropoffEnd = falloffSection.flatMap {
            extractTableValue(label: "Max Range", from: $0) ?? extractTableValue(label: "Dropoff End", from: $0)
        }
        let minimumDamage = computeMinimumDamage(
            bodyDamage: bodyDamage,
            multiplier: falloffSection.flatMap {
                extractTableValue(label: "Multiplier", from: $0) ?? extractTableValue(label: "Min Damage Multiplier", from: $0)
            }
        )
        let magazineSize = technicalSection.flatMap {
            extractTableValue(label: "Magazine", from: $0) ?? extractTableValue(label: "Mag Size", from: $0)
        }
        let shortReload = technicalSection.flatMap {
            extractTableValue(label: "Tactical Reload", from: $0) ?? extractTableValue(label: "Short Reload", from: $0)
        }
        let longReload = technicalSection.flatMap {
            extractTableValue(label: "Empty Reload", from: $0) ?? extractTableValue(label: "Long Reload", from: $0)
        }
        let notes = extractTableValue(label: "Notes", from: html)
            ?? extractTableValue(label: "Note", from: html)
            ?? notesSection.map(stripHTML)

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(minimumDamage),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload),
            version: cleanedStatValue(version),
            notes: cleanedStatValue(notes)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.headshotDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.shortReload,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }

        return hasUsefulData ? stats : nil
    }

    private func extractWeaponStatsFromLooseLines(html: String) -> FinalsWeaponStats? {
        let lines = readableTextLines(from: html)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        func value(for labels: [String]) -> String? {
            for line in lines {
                guard let separator = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if rawValue.isEmpty { continue }
                for label in labels where normalizedLabel(key) == normalizedLabel(label) {
                    return rawValue
                }
            }

            for (index, line) in lines.enumerated() {
                for label in labels where normalizedLabel(line) == normalizedLabel(label) {
                    if let next = nextValue(in: lines, after: index) {
                        return next
                    }
                }
            }

            return nil
        }

        let type = value(for: ["Type", "Class", "Weapon Type"])
        let bodyDamage = value(for: ["Body", "Damage", "Damage per Shot", "Base Damage"])
        let headshotDamage = value(for: ["Head", "Headshot", "Headshot Damage", "Critical Hit"])
        let fireRate = value(for: ["RPM", "Fire Rate", "Rate of Fire"])
        let dropoffStart = value(for: ["Min Range", "Dropoff Start", "Effective Range Start"])
        let dropoffEnd = value(for: ["Max Range", "Dropoff End", "Effective Range End"])
        let minimumDamage = value(for: ["Minimum Damage", "Min Damage"])
        let magazineSize = value(for: ["Magazine", "Mag Size", "Magazine Size", "Ammo"])
        let shortReload = value(for: ["Tactical Reload", "Short Reload", "Reload (Partial)", "Reload Time"])
        let longReload = value(for: ["Empty Reload", "Long Reload", "Reload (Empty)"])
        let version = value(for: ["Version", "Patch", "Game Version", "Updated"])
        let notes = value(for: ["Notes", "Note"])

        let computedMinimum = minimumDamage ?? computeMinimumDamage(
            bodyDamage: bodyDamage,
            multiplier: value(for: ["Multiplier", "Min Damage Multiplier"])
        )

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(computedMinimum),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload),
            version: cleanedStatValue(version),
            notes: cleanedStatValue(notes)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.headshotDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.shortReload,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }

        return hasUsefulData ? stats : nil
    }

    private func extractWeaponStatsFromText(html: String) -> FinalsWeaponStats? {
        let rawLines = readableTextLines(from: html)
            .map {
                $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }

        let profileIndex = rawLines.firstIndex { normalizedLabel($0) == "profile" } ?? 0
        let slice = Array(rawLines[profileIndex...])

        let type = value(in: slice, labels: ["Type"])
        let bodyDamage = value(in: slice, labels: ["Body"])
        let fireRate = value(in: slice, labels: ["RPM", "Fire Rate"])
        let dropoffStart = value(in: slice, labels: ["Min Range", "Dropoff Start"])
        let dropoffEnd = value(in: slice, labels: ["Max Range", "Dropoff End"])
        let multiplier = value(in: slice, labels: ["Multiplier", "Min Damage Multiplier"])
        let magazineSize = value(in: slice, labels: ["Magazine", "Mag Size"])
        let longReload = value(in: slice, labels: ["Empty Reload", "Long Reload"])
        let shortReload = value(in: slice, labels: ["Tactical Reload", "Short Reload"])
        let version = value(in: slice, labels: ["Version", "Patch", "Game Version", "Updated"])
        let notes = value(in: slice, labels: ["Notes", "Note"])

        let headshotDamage: String?
        if let explicitHead = value(in: slice, labels: ["Head", "Critical Hit", "Headshot"]) {
            headshotDamage = explicitHead
        } else if slice.contains(where: { $0.localizedCaseInsensitiveContains("No Critical Hit") }) ||
                    slice.contains(where: { $0.localizedCaseInsensitiveContains("does not critically hit") }) {
            headshotDamage = "No critical hit"
        } else {
            headshotDamage = nil
        }

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(computeMinimumDamage(bodyDamage: bodyDamage, multiplier: multiplier)),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload),
            version: cleanedStatValue(version),
            notes: cleanedStatValue(notes)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }

        return hasUsefulData ? stats : nil
    }

    private func extractWeaponStatsFromNormalizedText(html: String) -> FinalsWeaponStats? {
        let normalized = stripHTML(html)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else { return nil }

        let profileText = sectionText(in: normalized, heading: "Profile", nextHeadings: ["Damage", "Stats", "Usage", "Technical"])
        let damageText = sectionText(in: normalized, heading: "Damage", nextHeadings: ["Damage Falloff", "Technical", "Stats", "Usage"])
        let falloffText = sectionText(in: normalized, heading: "Damage Falloff", nextHeadings: ["Technical", "Stats", "Usage"])
        let technicalText = sectionText(in: normalized, heading: "Technical", nextHeadings: ["Usage", "Stats", "Controls", "Properties"])
        let propertiesText = sectionText(in: normalized, heading: "Properties", nextHeadings: ["Item Mastery", "Weapon Skins", "Trivia", "History"])
        let notesText = sectionText(in: normalized, heading: "Notes", nextHeadings: ["Trivia", "History", "Weapon Skins", "Item Mastery"])

        let type = firstCapturedValue(
            in: profileText,
            patterns: [
                #"Type\s*:?\s*(.+?)(?=\s+Unlock\b|\s+Damage\b|\s+Build\b|$)"#
            ]
        )

        let version = firstCapturedValue(
            in: normalized,
            patterns: [
                #"Version\s*:?\s*([0-9]+(?:\.[0-9]+){1,3})(?=\s+Type\b|\s+Damage\b|\s+Patch\b|$)"#,
                #"Patch\s*:?\s*([0-9]+(?:\.[0-9]+){1,3})(?=\s+Type\b|\s+Damage\b|\s+Version\b|$)"#
            ]
        )

        let bodyDamage = firstCapturedValue(
            in: damageText,
            patterns: [
                #"Body\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*[x×]\s*[0-9]+(?:\.[0-9]+)?)?)(?=\s+Environmental\b|\s+Damage Falloff\b|\s+Technical\b|$)"#
            ]
        )

        let fireRate = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"RPM\s*:?\s*([0-9]+(?:\.[0-9]+)?)(?=\s+Magazine\b|\s+Empty Reload\b|\s+Tactical Reload\b|$)"#,
                #"Fire Rate\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*RPM)?)(?=\s+Magazine\b|\s+Reload\b|$)"#
            ]
        )

        let dropoffStart = firstCapturedValue(
            in: falloffText,
            patterns: [
                #"Min Range\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Max Range\b|\s+Multiplier\b|$)"#,
                #"Dropoff Start\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Dropoff End\b|\s+Multiplier\b|$)"#
            ]
        )

        let dropoffEnd = firstCapturedValue(
            in: falloffText,
            patterns: [
                #"Max Range\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Multiplier\b|\s+Technical\b|$)"#,
                #"Dropoff End\s*:?\s*([0-9]+(?:\.[0-9]+)?\s*m)(?=\s+Multiplier\b|\s+Technical\b|$)"#
            ]
        )

        let multiplier = firstCapturedValue(
            in: falloffText,
            patterns: [
                #"Multiplier\s*:?\s*([0-9]+(?:\.[0-9]+)?)(?=\s+Technical\b|\s+Usage\b|$)"#,
                #"Min Damage Multiplier\s*:?\s*([0-9]+(?:\.[0-9]+)?)(?=\s+Technical\b|\s+Usage\b|$)"#
            ]
        )

        let magazineSize = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"Magazine\s*:?\s*([0-9]+)(?=\s+Empty Reload\b|\s+Tactical Reload\b|\s+Controls\b|$)"#,
                #"Mag Size\s*:?\s*([0-9]+)(?=\s+Reload\b|\s+Controls\b|$)"#
            ]
        )

        let shortReload = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"Tactical Reload\s*:?\s*(Segmented|[0-9]+(?:\.[0-9]+)?s)(?=\s+Controls\b|\s+Usage\b|$)"#,
                #"Short Reload\s*:?\s*([0-9]+(?:\.[0-9]+)?s)(?=\s+Long Reload\b|\s+Controls\b|$)"#
            ]
        )

        let longReload = firstCapturedValue(
            in: technicalText,
            patterns: [
                #"Empty Reload\s*:?\s*([0-9]+(?:\.[0-9]+)?s)(?=\s+Tactical Reload\b|\s+Controls\b|\s+Usage\b|$)"#,
                #"Long Reload\s*:?\s*([0-9]+(?:\.[0-9]+)?s)(?=\s+Short Reload\b|\s+Controls\b|$)"#
            ]
        )
        let notes = notesText.isEmpty ? nil : notesText

        let headshotDamage: String?
        if propertiesText.localizedCaseInsensitiveContains("No Critical Hit") ||
            normalized.localizedCaseInsensitiveContains("does not critically hit") {
            headshotDamage = "No critical hit"
        } else {
            headshotDamage = firstCapturedValue(
                in: damageText,
                patterns: [
                    #"Head\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*[x×]\s*[0-9]+(?:\.[0-9]+)?)?)(?=\s+Environmental\b|\s+Damage Falloff\b|\s+Technical\b|$)"#,
                    #"Critical Hit\s*:?\s*([0-9]+(?:\.[0-9]+)?(?:\s*[x×]\s*[0-9]+(?:\.[0-9]+)?)?)(?=\s+Environmental\b|\s+Damage Falloff\b|\s+Technical\b|$)"#
                ]
            )
        }

        let stats = FinalsWeaponStats(
            type: cleanedStatValue(type),
            bodyDamage: cleanedStatValue(bodyDamage),
            headshotDamage: cleanedStatValue(headshotDamage),
            fireRate: cleanedStatValue(fireRate),
            dropoffStart: cleanedStatValue(dropoffStart),
            dropoffEnd: cleanedStatValue(dropoffEnd),
            minimumDamage: cleanedStatValue(computeMinimumDamage(bodyDamage: bodyDamage, multiplier: multiplier)),
            magazineSize: cleanedStatValue(magazineSize),
            shortReload: cleanedStatValue(shortReload),
            longReload: cleanedStatValue(longReload),
            version: cleanedStatValue(version),
            notes: cleanedStatValue(notes)
        )

        let hasUsefulData = [
            stats.bodyDamage,
            stats.headshotDamage,
            stats.fireRate,
            stats.magazineSize,
            stats.shortReload,
            stats.longReload
        ].contains { value in
            guard let value else { return false }
            return !value.isEmpty
        }
        return hasUsefulData ? stats : nil
    }

    private func readableTextLines(from html: String) -> [String] {
        let blockSeparated = html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)</(?:p|div|li|tr|h[1-6])>"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)<(?:p|div|li|tr|h[1-6])[^>]*>"#, with: "\n", options: .regularExpression)

        let text = stripHTML(blockSeparated)
        return text.components(separatedBy: .newlines)
    }

    private func normalizedLabel(_ text: String) -> String {
        text
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]"#, with: "", options: .regularExpression)
    }

    private func nextValue(in lines: [String], after index: Int) -> String? {
        guard index < lines.count - 1 else { return nil }
        for line in lines[(index + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix(":") { break }
            return trimmed
        }
        return nil
    }

    private func value(in lines: [String], labels: [String]) -> String? {
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if let separator = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rawValue.isEmpty,
                   labels.contains(where: { normalizedLabel(key) == normalizedLabel($0) }) {
                    return rawValue
                }
            }

            if labels.contains(where: { normalizedLabel(trimmed) == normalizedLabel($0) }),
               let next = nextValue(in: lines, after: index) {
                return next
            }
        }
        return nil
    }

    private func sectionText(in text: String, heading: String, nextHeadings: [String]) -> String {
        let headingPattern = NSRegularExpression.escapedPattern(for: heading)
        let nextPattern = nextHeadings.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(?is)\b"# + headingPattern + #"\b\s*(.+?)(?=\b(?:"# + nextPattern + #")\b|$)"#
        return text.firstMatch(for: pattern) ?? ""
    }

    private func firstCapturedValue(in text: String, patterns: [String]) -> String? {
        for pattern in patterns {
            if let match = text.firstMatch(for: pattern) {
                let cleaned = match
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return nil
    }

    private func extractSectionHTML(named sectionName: String, from html: String) -> String? {
        let headingPattern = NSRegularExpression.escapedPattern(for: sectionName)
        let pattern = #"(?is)<h[1-6][^>]*>\s*"# + headingPattern + #"\s*</h[1-6]>(.*?)(?=<h[1-6][^>]*>|$)"#
        return html.firstMatch(for: pattern)
    }

    private func extractTableValue(label: String, from html: String) -> String? {
        let labelPattern = NSRegularExpression.escapedPattern(for: label)
        let patterns = [
            #"(?is)<tr[^>]*>\s*<t[hd][^>]*>\s*"# + labelPattern + #"\s*</t[hd]>\s*<t[hd][^>]*>(.*?)</t[hd]>"#,
            #"(?is)<div[^>]*>\s*<[^>]+>\s*"# + labelPattern + #"\s*</[^>]+>\s*<[^>]+>(.*?)</[^>]+>\s*</div>"#
        ]

        for pattern in patterns {
            if let value = html.firstMatch(for: pattern) {
                let cleaned = stripHTML(value)
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        return nil
    }

    private func cleanedStatValue(_ value: String?) -> String? {
        guard var cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)^segmented\\s*$", with: "Segmented", options: .regularExpression)
        return cleaned
    }

    private func computeMinimumDamage(bodyDamage: String?, multiplier: String?) -> String? {
        guard let bodyDamage,
              let multiplier,
              let bodyValue = firstNumericValue(in: bodyDamage),
              let multiplierValue = firstNumericValue(in: multiplier) else { return nil }

        let scaled = bodyValue * multiplierValue
        guard scaled > 0 else { return nil }
        return formatDamageValue(scaled)
    }

    private func firstNumericValue(in text: String) -> Double? {
        text.matches(for: #"[0-9]+(?:\.[0-9]+)?"#).first.flatMap(Double.init)
    }

    private func formatDamageValue(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.1f", rounded)
    }

    private func stripHTML(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeHTMLEntities(withoutTags)
    }

    private func decodeHTMLEntities(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
              ) else {
            return text
        }
        return attributed.string
    }

    private func htmlMatches(for pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard match.numberOfRanges > 1 else { return nil }
            let capture = match.range(at: 1)
            guard capture.location != NSNotFound else { return nil }
            return (text as NSString).substring(with: capture)
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    func matches(for pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, options: [], range: range).compactMap { match in
            guard let range = Range(match.range(at: match.numberOfRanges > 1 ? 1 : 0), in: self) else { return nil }
            return String(self[range])
        }
    }

    func firstMatch(for pattern: String) -> String? {
        matches(for: pattern).first
    }
}

private struct MediaWikiSearchResponse: Decodable {
    let query: SearchQuery?

    struct SearchQuery: Decodable {
        let search: [SearchHit]
    }

    struct SearchHit: Decodable {
        let title: String
    }
}

private struct MediaWikiPageResponse: Decodable {
    let query: PageQuery?

    struct PageQuery: Decodable {
        let pages: [String: Page]
    }

    struct Page: Decodable {
        let title: String
        let extract: String?
        let fullurl: String?
        let original: ImageInfo?
        let thumbnail: ImageInfo?
        let missing: String?
    }

    struct ImageInfo: Decodable {
        let source: String?
    }
}

private struct MediaWikiParseResponse: Decodable {
    let parse: ParsedPage?

    struct ParsedPage: Decodable {
        let title: String
        let displayTitle: String?
        let text: ParsedText

        private enum CodingKeys: String, CodingKey {
            case title
            case displayTitle = "displaytitle"
            case text
        }
    }

    struct ParsedText: Decodable {
        let html: String

        private enum CodingKeys: String, CodingKey {
            case html = "*"
        }
    }
}
