import Foundation

struct AppleService: Sendable {
    struct ReleaseInfo: Sendable {
        let releaseNotes: ReleaseNotes
        let embedJSON: String
        let rawDebug: String
        let releaseIdentifier: String
    }

    enum ServiceError: Error, Sendable {
        case invalidResponse
        case noReleaseFound
        case parseFailed
    }

    private let session: URLSession
    private let feedURL: URL
    private let formatter: EmbedFormatter

    init(
        session: URLSession = .shared,
        feedURL: URL = URL(string: "https://developer.apple.com/news/releases/rss/releases.rss")!,
        formatter: EmbedFormatter = EmbedFormatter()
    ) {
        self.session = session
        self.feedURL = feedURL
        self.formatter = formatter
    }

    func fetchLatestRelease(product: PatchyAppleProduct, includeBetas: Bool) async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL)
        request.timeoutInterval = 30
        request.setValue("application/rss+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServiceError.invalidResponse
        }

        let items = try AppleRSSParser.parse(data: data)
        let rawXML = String(data: data, encoding: .utf8) ?? ""

        let filtered = items.filter { item in
            guard matches(item: item, product: product) else { return false }
            if includeBetas { return true }
            return !item.isBeta
        }

        guard let latest = filtered.first else {
            throw ServiceError.noReleaseFound
        }

        let version = latest.versionLabel(for: product)
        let releaseIdentifier = "apple:\(product.rawValue):\(latest.guidOrTitle)"
        let dateString = latest.formattedDate

        let sections: [ReleaseSection] = {
            var bullets: [Bullet] = []
            if !latest.descriptionText.isEmpty {
                bullets.append(Bullet(text: latest.descriptionText))
            } else {
                bullets.append(Bullet(text: "New \(product.rawValue) release available from Apple Developer."))
            }
            if !latest.link.isEmpty {
                bullets.append(Bullet(text: "Details: \(latest.link)"))
            }
            return [ReleaseSection(title: "Release", bullets: bullets)]
        }()

        let releaseNotes = ReleaseNotes(
            title: latest.title,
            author: "Apple Developer",
            url: latest.link.isEmpty ? "https://developer.apple.com/news/releases/" : latest.link,
            version: version,
            date: dateString,
            sections: sections,
            thumbnailURL: "https://developer.apple.com/assets/elements/icons/apple-logo/apple-logo-128x128_2x.png",
            color: PatchyEmbedAccent.discordColorInt(hex: PatchySourceKind.apple.brandAccentColor.hex, source: .apple)
        )

        return ReleaseInfo(
            releaseNotes: releaseNotes,
            embedJSON: formatter.format(releaseNotes: releaseNotes),
            rawDebug: "Apple Releases RSS:\n\(rawXML)",
            releaseIdentifier: releaseIdentifier
        )
    }

    private func matches(item: AppleRSSItem, product: PatchyAppleProduct) -> Bool {
        let title = item.title
        let tokens = product.matchTokens
        for token in tokens {
            if matchToken(token, in: title) {
                if let exclusion = exclusionToken(for: product, against: title) {
                    return !title.localizedCaseInsensitiveContains(exclusion)
                }
                return true
            }
        }
        return false
    }

    /// Some product names overlap (e.g. iOS vs iPadOS). When matching iOS we must not pick up iPadOS entries.
    private func exclusionToken(for product: PatchyAppleProduct, against title: String) -> String? {
        switch product {
        case .iOS:
            return "iPadOS"
        default:
            return nil
        }
    }

    private func matchToken(_ token: String, in title: String) -> Bool {
        // Word-boundary-style match: the token followed by a space or digit.
        let lowered = title.lowercased()
        let needle = token.lowercased()
        guard let range = lowered.range(of: needle) else { return false }
        let nextIndex = range.upperBound
        if nextIndex == lowered.endIndex { return true }
        let nextChar = lowered[nextIndex]
        return nextChar == " " || nextChar.isNumber
    }
}

struct AppleRSSItem: Sendable {
    let title: String
    let link: String
    let guid: String
    let pubDate: String
    let descriptionText: String

    var guidOrTitle: String { guid.isEmpty ? title : guid }

    var isBeta: Bool {
        let lowered = title.lowercased()
        return lowered.contains("beta") || lowered.contains(" rc") || lowered.contains("release candidate")
    }

    var formattedDate: String {
        let trimmed = pubDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "-" }
        let inputFormatters: [DateFormatter] = [
            { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"; return f }(),
            { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"; return f }()
        ]
        for formatter in inputFormatters {
            if let date = formatter.date(from: trimmed) {
                let out = DateFormatter()
                out.locale = Locale(identifier: "en_US_POSIX")
                out.dateFormat = "yyyy-MM-dd"
                return out.string(from: date)
            }
        }
        return trimmed
    }

    func versionLabel(for product: PatchyAppleProduct) -> String {
        // Strip the product name from the title to leave just the version label.
        let stripped = matchTokens(for: product).reduce(title) { acc, token in
            acc.replacingOccurrences(of: token, with: "", options: .caseInsensitive)
        }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
            .ifEmpty(title)
    }

    private func matchTokens(for product: PatchyAppleProduct) -> [String] {
        product.matchTokens
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}

enum AppleRSSParser {
    static func parse(data: Data) throws -> [AppleRSSItem] {
        let parser = XMLParser(data: data)
        let delegate = RSSDelegate()
        parser.delegate = delegate
        if !parser.parse() {
            throw AppleService.ServiceError.parseFailed
        }
        return delegate.items
    }

    private final class RSSDelegate: NSObject, XMLParserDelegate {
        var items: [AppleRSSItem] = []

        private var currentElement: String = ""
        private var currentTitle: String = ""
        private var currentLink: String = ""
        private var currentGuid: String = ""
        private var currentPubDate: String = ""
        private var currentDescription: String = ""
        private var insideItem: Bool = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            if elementName == "item" {
                insideItem = true
                currentTitle = ""
                currentLink = ""
                currentGuid = ""
                currentPubDate = ""
                currentDescription = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard insideItem else { return }
            switch currentElement {
            case "title": currentTitle += string
            case "link": currentLink += string
            case "guid": currentGuid += string
            case "pubDate": currentPubDate += string
            case "description": currentDescription += string
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard insideItem else { return }
            let s = String(data: CDATABlock, encoding: .utf8) ?? ""
            switch currentElement {
            case "title": currentTitle += s
            case "description": currentDescription += s
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == "item" {
                items.append(AppleRSSItem(
                    title: currentTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                    link: currentLink.trimmingCharacters(in: .whitespacesAndNewlines),
                    guid: currentGuid.trimmingCharacters(in: .whitespacesAndNewlines),
                    pubDate: currentPubDate.trimmingCharacters(in: .whitespacesAndNewlines),
                    descriptionText: stripHTML(currentDescription).trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                insideItem = false
            }
            currentElement = ""
        }

        private func stripHTML(_ html: String) -> String {
            html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
    }
}
