import Foundation
import SwiftSoup

public struct NVIDIAService: Sendable {
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
    private let apiEndpoint: URL
    private let formatter: EmbedFormatter

    public init(
        session: URLSession = .shared,
        apiEndpoint: URL = URL(string: "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php")!,
        formatter: EmbedFormatter = EmbedFormatter()
    ) {
        self.session = session
        self.apiEndpoint = apiEndpoint
        self.formatter = formatter
    }

    public func fetchLatestDriver() async throws -> DriverInfo {
        var request = URLRequest(url: apiEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let params = [
            "func": "DriverManualLookup",
            "psid": "120",
            "pfid": "929",
            "osID": "135",
            "languageCode": "1033",
            "beta": "0",
            "isWHQL": "1",
            "dltype": "-1",
            "dch": "1",
            "sort1": "0",
            "numberOfResults": "200"
        ]

        request.httpBody = params
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)

        let rawJSON = String(data: data, encoding: .utf8) ?? ""
        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NVIDIAServiceError.invalidJSONResponse
        }

        guard let idsArray = jsonObject["IDS"] as? [[String: Any]], !idsArray.isEmpty else {
            throw NVIDIAServiceError.noDriverFound
        }

        let candidates = try idsArray.compactMap { entry -> DriverCandidate? in
            guard let downloadInfo = entry["downloadInfo"] as? [String: Any] else {
                return nil
            }
            guard let versionString = downloadInfo["Version"] as? String else {
                return nil
            }
            guard let releaseDate = downloadInfo["ReleaseDateTime"] as? String else {
                return nil
            }
            let version = try extractVersionStrict(from: versionString)
            return DriverCandidate(version: version, releaseDate: releaseDate, info: decodedDriverInfo(downloadInfo))
        }

        guard let latestDriver = candidates.max(by: { compareVersions($0.version, $1.version) < 0 }) else {
            throw NVIDIAServiceError.noDriverFound
        }

        let version = latestDriver.version
        let releaseDate = latestDriver.releaseDate
        let releaseIdentifier = "nvidia:\(version)"
        let decodedInfo = latestDriver.info
        let sections = nvidiaReleaseSections(from: decodedInfo.releaseNotesHTML, fallback: decodedInfo)
        let title = nvidiaTitle(version: version, info: decodedInfo)

        let releaseNotes = ReleaseNotes(
            title: title,
            author: "NVIDIA GeForce Driver",
            url: decodedInfo.detailsURL ?? "https://www.nvidia.com/en-us/geforce/drivers/",
            version: version,
            date: releaseDate,
            sections: sections,
            thumbnailURL: "https://cdn.patchbot.io/games/142/nvidia-geforce_1710977247_sm.jpg",
            color: 5763719
        )

        return DriverInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatNVIDIAEmbed(releaseNotes: releaseNotes),
            rawDebug: "NVIDIA Driver API Response:\n\(rawJSON)",
            releaseIdentifier: releaseIdentifier
        )
    }

    private struct DriverCandidate: Sendable {
        let version: String
        let releaseDate: String
        let info: DecodedDriverInfo
    }

    private struct DecodedDriverInfo: Sendable {
        let name: String?
        let shortDescription: String?
        let displayVersion: String?
        let detailsURL: String?
        let downloadURL: String?
        let downloadSize: String?
        let releaseNotesHTML: String?
        let osNames: [String]
        let isWHQL: Bool
        let isDCH: Bool
    }

    private func decodedDriverInfo(_ downloadInfo: [String: Any]) -> DecodedDriverInfo {
        let osNames = (downloadInfo["OSList"] as? [[String: Any]] ?? [])
            .compactMap { decodeNVIDIAString($0["OSName"] as? String) }
            .filter { !$0.isEmpty }

        return DecodedDriverInfo(
            name: decodeNVIDIAString(downloadInfo["NameLocalized"] as? String) ?? decodeNVIDIAString(downloadInfo["Name"] as? String),
            shortDescription: decodeNVIDIAString(downloadInfo["ShortDescription"] as? String),
            displayVersion: decodeNVIDIAString(downloadInfo["DisplayVersion"] as? String),
            detailsURL: decodeNVIDIAString(downloadInfo["DetailsURL"] as? String),
            downloadURL: decodeNVIDIAString(downloadInfo["DownloadURL"] as? String),
            downloadSize: decodeNVIDIAString(downloadInfo["DownloadURLFileSize"] as? String),
            releaseNotesHTML: decodeNVIDIAString(downloadInfo["ReleaseNotes"] as? String),
            osNames: osNames,
            isWHQL: (downloadInfo["IsWHQL"] as? String) == "1",
            isDCH: (downloadInfo["IsDC"] as? String) == "1"
        )
    }

    private func nvidiaTitle(version: String, info: DecodedDriverInfo) -> String {
        if let name = info.name, !name.isEmpty, !name.lowercased().contains("release ") {
            return "\(name) v\(version)"
        }
        if let description = info.shortDescription, description.lowercased().contains("rtx") {
            return "NVIDIA RTX Driver v\(version)"
        }
        return "GeForce Game Ready Driver v\(version)"
    }

    private func nvidiaReleaseSections(from releaseNotesHTML: String?, fallback info: DecodedDriverInfo) -> [ReleaseSection] {
        guard let html = releaseNotesHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [nvidiaFallbackSection(info)]
        }

        let parsed = parseNVIDIAHTMLSections(html)
        guard !parsed.isEmpty else {
            return [nvidiaFallbackSection(info)]
        }
        return prioritizedNVIDIASections(parsed)
    }

    private func nvidiaFallbackSection(_ info: DecodedDriverInfo) -> ReleaseSection {
        var bullets = [Bullet]()
        if let description = info.shortDescription, !description.isEmpty {
            bullets.append(Bullet(text: description))
        }
        if let displayVersion = info.displayVersion, !displayVersion.isEmpty {
            bullets.append(Bullet(text: "Display version: \(displayVersion)"))
        }
        if bullets.isEmpty {
            bullets.append(Bullet(text: "Latest NVIDIA driver package."))
        }
        return ReleaseSection(title: "Driver Information", bullets: bullets)
    }

    private func prioritizedNVIDIASections(_ sections: [ReleaseSection]) -> [ReleaseSection] {
        var output = [ReleaseSection]()
        var usedIndexes = Set<Int>()

        if let explicitHighlightsIndex = sections.firstIndex(where: { isNVIDIAHighlightsTitle($0.title) }) {
            output.append(sections[explicitHighlightsIndex])
            usedIndexes.insert(explicitHighlightsIndex)
        } else if let leadHighlight = sections.enumerated().first(where: { isNVIDIAHighlightCandidate($0.element.title) }) {
            let section = leadHighlight.element
            let bullets = section.bullets.map { bullet in
                Bullet(text: "\(section.title): \(bullet.text)")
            }
            output.append(ReleaseSection(title: "Release Highlights", bullets: bullets))
            usedIndexes.insert(leadHighlight.offset)
        }

        for (index, section) in sections.enumerated() where !usedIndexes.contains(index) {
            output.append(section)
            if output.count == 3 { break }
        }

        return Array(output.prefix(3))
    }

    private func isNVIDIAHighlightsTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
        return normalized.contains("release highlight") || normalized == "highlights"
    }

    private func isNVIDIAHighlightCandidate(_ title: String) -> Bool {
        let normalized = title.lowercased()
        let excludedFragments = ["fixed", "known issue", "open issue", "additional information", "support"]
        return !excludedFragments.contains { normalized.contains($0) }
    }

    private func parseNVIDIAHTMLSections(_ html: String) -> [ReleaseSection] {
        let cleaned = html
            .replacingOccurrences(of: #"(?is)<script\b.*?</script>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)<style\b.*?</style>"#, with: " ", options: .regularExpression)
        let pattern = #"(?is)<(?:strong\b|b\b)[^>]*>(.*?)</(?:strong|b)>(.*?)(?=<(?:strong\b|b\b)[^>]*>|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        return regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)).compactMap { match in
            guard
                match.numberOfRanges > 2,
                let titleRange = Range(match.range(at: 1), in: cleaned),
                let bodyRange = Range(match.range(at: 2), in: cleaned)
            else {
                return nil
            }

            let title = cleanNVIDIAHTML(String(cleaned[titleRange]))
            guard !title.isEmpty, !title.lowercased().contains("subscribe") else { return nil }
            let bullets = nvidiaBullets(from: String(cleaned[bodyRange]))
            guard !bullets.isEmpty else { return nil }
            return ReleaseSection(title: title, bullets: Array(bullets.prefix(4)))
        }
    }

    private func nvidiaBullets(from html: String) -> [Bullet] {
        if let document = try? SwiftSoup.parseBodyFragment(html),
           let listItems = try? document.select("li").array().compactMap({ item -> String? in
               let text = try item.text()
               let cleaned = cleanNVIDIAText(text)
               return cleaned.isEmpty ? nil : cleaned
           }),
           !listItems.isEmpty {
            return listItems.prefix(4).map { Bullet(text: $0) }
        }

        let paragraphs = html
            .replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
            .components(separatedBy: .newlines)
            .map { cleanNVIDIAHTML($0) }
            .filter { text in
                text.count >= 20 && !text.lowercased().contains("subscribe here")
            }

        return paragraphs.prefix(2).map { Bullet(text: $0) }
    }

    private func formatNVIDIAEmbed(releaseNotes: ReleaseNotes) -> String {
        let fields: [[String: Any]] = [
            ["name": "Version", "value": releaseNotes.version, "inline": true],
            ["name": "Release Date", "value": releaseNotes.date, "inline": true]
        ]

        let embed: [String: Any] = [
            "author": ["name": releaseNotes.author],
            "title": releaseNotes.title,
            "url": releaseNotes.url,
            "description": nvidiaDescription(from: releaseNotes.sections),
            "color": releaseNotes.color,
            "thumbnail": ["url": releaseNotes.thumbnailURL],
            "fields": fields
        ]

        return encodeToJSON(["embeds": [embed]])
    }

    private func nvidiaDescription(from sections: [ReleaseSection]) -> String {
        let rendered = sections
            .map { section in
                var lines = ["**\(section.title)**"]
                lines += section.bullets.map { "• \($0.text)" }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n")

        return truncate(rendered, limit: 3600)
    }

    private func decodeNVIDIAString(_ value: String?) -> String? {
        guard let value else { return nil }
        let decoded = value.removingPercentEncoding ?? value
        let cleaned = decodeHTMLEntities(decoded)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func cleanNVIDIAHTML(_ raw: String) -> String {
        let decoded = decodeHTMLEntities(raw)
        if let document = try? SwiftSoup.parseBodyFragment(decoded),
           let text = try? document.text() {
            return cleanNVIDIAText(text)
        }

        return decoded.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanNVIDIAText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func allCaptures(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)).compactMap { match in
            guard
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
    }

    private func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 3)) + "..."
    }

    private func encodeToJSON(_ payload: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
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

    private func compareVersions(_ lhs: String, _ rhs: String) -> Int {
        let leftParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rightParts = rhs.split(separator: ".").compactMap { Int($0) }
        let maxCount = max(leftParts.count, rightParts.count)
        for index in 0..<maxCount {
            let left = index < leftParts.count ? leftParts[index] : 0
            let right = index < rightParts.count ? rightParts[index] : 0
            if left != right {
                return left < right ? -1 : 1
            }
        }
        return 0
    }

    private func extractVersionStrict(from text: String) throws -> String {
        let pattern = #"\b(\d{3}\.\d{2})\b"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        guard
            let match = regex.firstMatch(in: text, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: text)
        else {
            throw NVIDIAServiceError.versionExtractionFailed(text: text)
        }

        return String(text[captureRange])
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw NVIDIAServiceError.invalidResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw NVIDIAServiceError.httpError(statusCode: http.statusCode)
        }
    }
}

public enum NVIDIAServiceError: LocalizedError, Sendable {
    case invalidResponse
    case httpError(statusCode: Int)
    case invalidJSONResponse
    case noDriverFound
    case missingField(String)
    case versionExtractionFailed(text: String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "NVIDIA API returned an invalid response object."
        case .httpError(let statusCode):
            return "NVIDIA API request failed with HTTP \(statusCode)."
        case .invalidJSONResponse:
            return "NVIDIA API returned invalid JSON."
        case .noDriverFound:
            return "No NVIDIA driver entries were returned."
        case .missingField(let name):
            return "NVIDIA response missing required field '\(name)'."
        case .versionExtractionFailed(let text):
            return "Failed to extract NVIDIA version from '\(text)'."
        }
    }
}
