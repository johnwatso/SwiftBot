import Foundation

struct PatchyFetchResult: Sendable {
    let sourceName: String
    let title: String
    let version: String
    let date: String
    let formattedDescription: String
    let preview: String
    let embedJSON: String
    let debugOutput: String
    let statusSummary: String
    let identifier: String
    let cacheKey: String
}

enum PatchyRuntime {
    private static let lastPostedDriverVersionKey = "lastPostedDriverVersion"
    private static let lastPostedSteamIdentifierKey = "lastPostedSteamIdentifier"

    static func makeSource(from target: PatchySourceTarget) throws -> any UpdateSource {
        switch target.source {
        case .nvidia:
            return NVIDIAUpdateSource()
        case .amd:
            return AMDUpdateSource()
        case .intel:
            return IntelUpdateSource()
        case .steam:
            let appID = target.steamAppID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !appID.isEmpty else {
                throw NSError(domain: "Patchy", code: 0, userInfo: [NSLocalizedDescriptionKey: "Steam App ID is required."])
            }
            return SteamNewsUpdateSource(appID: appID)
        }
    }

    static func map(item: any UpdateItem, change: UpdateChangeResult) -> PatchyFetchResult {
        if let driver = item as? DriverUpdateItem {
            let description = renderSections(driver.releaseNotes.sections)
            let preview = driver.releaseNotes.sections
                .first?.bullets.first?.text
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PatchyFetchResult(
                sourceName: driver.releaseNotes.author,
                title: driver.releaseNotes.title,
                version: driver.releaseNotes.version,
                date: driver.releaseNotes.date,
                formattedDescription: description,
                preview: preview,
                embedJSON: driver.embedJSON,
                debugOutput: driver.rawDebug,
                statusSummary: "\(driver.releaseNotes.author): \(statusLabel(change))",
                identifier: item.identifier,
                cacheKey: item.sourceKey
            )
        }

        if let steam = item as? SteamUpdateItem {
            let preview = steam.newsItem.contents
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PatchyFetchResult(
                sourceName: steam.newsItem.feedLabel,
                title: steam.newsItem.title,
                version: steam.version,
                date: steam.newsItem.dateFormatted,
                formattedDescription: "",
                preview: String(preview.prefix(500)),
                embedJSON: steam.embedJSON,
                debugOutput: steam.rawDebug,
                statusSummary: "\(steam.newsItem.feedLabel): \(statusLabel(change))",
                identifier: item.identifier,
                cacheKey: item.sourceKey
            )
        }

        return PatchyFetchResult(
            sourceName: "Update",
            title: "Update detected",
            version: item.version,
            date: "-",
            formattedDescription: "",
            preview: "",
            embedJSON: "",
            debugOutput: "",
            statusSummary: statusLabel(change),
            identifier: item.identifier,
            cacheKey: item.sourceKey
        )
    }

    static func fallbackMessage(for result: PatchyFetchResult) -> String {
        if !result.formattedDescription.isEmpty {
            return "\(result.title)\nVersion: \(result.version)\nDate: \(result.date)\n\n\(result.formattedDescription)"
        }

        if !result.preview.isEmpty {
            return "\(result.title)\nVersion: \(result.version)\nDate: \(result.date)\n\n\(result.preview)"
        }

        return "\(result.title)\nVersion: \(result.version)\nDate: \(result.date)"
    }

    static func checkerStoreURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".swiftbot")
            .appendingPathComponent("update-engine")
            .appendingPathComponent("identifiers.json")
    }

    static func lastPostedDriverVersionKey(for sourceKey: String) -> String {
        "\(sourceKey):\(lastPostedDriverVersionKey)"
    }

    static func lastPostedSteamIdentifierKey(for sourceKey: String) -> String {
        "\(sourceKey):\(lastPostedSteamIdentifierKey)"
    }

    static func makeSteamOrderingStamp(item: SteamUpdateItem) -> String {
        "\(item.newsItem.date):\(item.newsItem.gid)"
    }

    static func compareSteamOrderingStamp(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = parseSteamOrderingStamp(lhs), let right = parseSteamOrderingStamp(rhs) else {
            return nil
        }

        if left.date != right.date {
            return left.date < right.date ? -1 : 1
        }
        if left.gid != right.gid {
            return left.gid < right.gid ? -1 : 1
        }
        return 0
    }

    static func compareDriverVersions(_ lhs: String, _ rhs: String) -> Int? {
        guard let left = parseDriverVersion(lhs), let right = parseDriverVersion(rhs) else {
            return nil
        }

        let maxCount = max(left.count, right.count)
        for index in 0..<maxCount {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue != rightValue {
                return leftValue < rightValue ? -1 : 1
            }
        }
        return 0
    }

    private static func parseDriverVersion(_ value: String) -> [Int]? {
        let pattern = #"[0-9]+(?:\.[0-9]+)+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let matchRange = Range(match.range(at: 0), in: value) else {
            return nil
        }

        let parts = value[matchRange].split(separator: ".").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    private static func parseSteamOrderingStamp(_ value: String) -> (date: Int, gid: UInt64)? {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let date = Int(parts[0]), let gid = UInt64(parts[1]) else {
            return nil
        }
        return (date, gid)
    }

    private static func renderSections(_ sections: [ReleaseSection]) -> String {
        let rendered = sections.map { section in
            var lines: [String] = ["\(section.title):"]
            for bullet in section.bullets {
                lines.append("- \(bullet.text)")
                for sub in bullet.subBullets {
                    lines.append("  - \(sub)")
                }
            }
            return lines.joined(separator: "\n")
        }

        return rendered.joined(separator: "\n\n")
    }

    private static func statusLabel(_ result: UpdateChangeResult) -> String {
        switch result {
        case .firstSeen(let id):
            return "firstSeen (\(id))"
        case .changed(let old, let new):
            return "changed (\(old) -> \(new))"
        case .unchanged(let id):
            return "unchanged (\(id))"
        }
    }
}
