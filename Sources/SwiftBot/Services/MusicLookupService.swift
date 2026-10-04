import Foundation

struct MusicSearchResult: Sendable, Hashable {
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let appleMusicURL: URL?
    let spotifyURL: URL?
    let youtubeMusicURL: URL?
    let youtubeURL: URL?
    var releaseYear: Int? = nil
    var durationSeconds: Int? = nil
}

/// What a share link's own page says about the track (oEmbed), cleaned up
/// for searching: YouTube titles carry "(Official Video)" and the artist is
/// often only in the channel name ("John Summit - Topic").
struct MusicLinkMetadata: Sendable, Hashable {
    let title: String
    let artist: String?
    let thumbnailURL: URL?
}

/// Restricts automatic link handling to known public music domains and only
/// recognises track-shaped URLs. Playlist links are intentionally left alone.
enum MusicLinkDetector {
    static func firstTrackURL(in content: String) -> URL? {
        let tokens = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        for token in tokens {
            let trimmed = token
                .trimmingCharacters(in: CharacterSet(charactersIn: "<>()[]{}.,!?\"'"))
            guard let url = URL(string: trimmed), isSupportedTrackURL(url) else { continue }
            return url
        }
        return nil
    }

    static let youTubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]

    static func queryValue(_ name: String, in url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    static func isSupportedTrackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "open.spotify.com" || host.hasSuffix(".spotify.com") {
            return path.contains("/track/")
        }
        if host == "music.apple.com" || host.hasSuffix(".music.apple.com") {
            return path.contains("/song/") || queryValue("i", in: url) != nil
        }
        if youTubeHosts.contains(host) {
            // A video id makes it one song, even when YouTube Music adds a
            // radio or album `list=` to the share link. Playlist-only links
            // (`/playlist?list=`) have no `v` and stay ignored.
            if path.hasPrefix("/shorts/") { return path.split(separator: "/").count >= 2 }
            return queryValue("v", in: url) != nil
        }
        if host == "youtu.be" {
            return !path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        }
        if host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") {
            return !path.contains("/sets/") && path.split(separator: "/").count >= 3
        }
        return false
    }

    static func oEmbedURL(for sourceURL: URL) -> URL? {
        guard let host = sourceURL.host?.lowercased() else { return nil }
        let endpoint: String
        if host == "open.spotify.com" || host.hasSuffix(".spotify.com") {
            endpoint = "https://open.spotify.com/oembed"
        } else if youTubeHosts.contains(host) || host == "youtu.be" {
            endpoint = "https://www.youtube.com/oembed"
        } else if host == "soundcloud.com" || host.hasSuffix(".soundcloud.com") {
            endpoint = "https://soundcloud.com/oembed"
        } else {
            return nil
        }

        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "url", value: sourceURL.absoluteString),
            URLQueryItem(name: "format", value: "json")
        ]
        return components?.url
    }

    /// Turns oEmbed's title and author into a searchable title and artist.
    static func cleanedMetadata(title rawTitle: String, author rawAuthor: String?, thumbnailURL: URL?, sourceURL: URL) -> MusicLinkMetadata {
        let isYouTube = sourceURL.host.map { youTubeHosts.contains($0.lowercased()) || $0.lowercased() == "youtu.be" } ?? false
        var title = stripVideoNoise(from: rawTitle)
        var artist: String?

        if isYouTube, let author = rawAuthor?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            if author.hasSuffix(" - Topic") {
                // Auto-generated "Artist - Topic" channels: the title is the
                // exact track name, so its " - " (e.g. "- Subtronics Remix")
                // is part of the name, not an artist separator.
                artist = String(author.dropLast(" - Topic".count))
            } else if let separator = title.range(of: " - ") {
                // "Artist - Title" uploads on artist or label channels.
                artist = String(title[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                title = String(title[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                artist = cleanedChannelName(author)
            }
        } else if let author = rawAuthor?.trimmingCharacters(in: .whitespacesAndNewlines), !author.isEmpty {
            artist = author
        }
        return MusicLinkMetadata(title: title, artist: artist?.isEmpty == true ? nil : artist, thumbnailURL: thumbnailURL)
    }

    /// "ArtistVEVO" / "Artist Official" → "Artist".
    static func cleanedChannelName(_ name: String) -> String {
        var result = name
        for suffix in ["VEVO", " Official", " - Official", " Music"] where result.hasSuffix(suffix) && result.count > suffix.count {
            result = String(result.dropLast(suffix.count))
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Drops "(Official Video)", "[4K Remaster]", "| Lyrics" and similar, keeping
    /// credits that are part of the track name ("(feat. X)", "(X Remix)").
    static func stripVideoNoise(from title: String) -> String {
        let noise = #"(?i)\s*[\(\[][^\)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|music video|mv|hd|hq|4k|remaster(ed)?|explicit|clean)\b[^\)\]]*[\)\]]"#
        var result = title.replacingOccurrences(of: noise, with: "", options: .regularExpression)
        if let bar = result.range(of: " | ") { result = String(result[..<bar.lowerBound]) }
        return result.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased, accent-free words without "feat"/"ft" markers.
    static func matchTokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !["feat", "ft", "featuring", "with", "the", "and"].contains($0) }
    }

    /// Whether a catalogue result is the shared track: most of the shared
    /// title's words appear in the result's, and the artists overlap.
    static func isConfidentMatch(_ candidate: MusicSearchResult, for metadata: MusicLinkMetadata) -> Bool {
        let wanted = Set(matchTokens(metadata.title))
        guard !wanted.isEmpty else { return false }
        let found = Set(matchTokens(candidate.title))
        let titleOverlap = Double(wanted.intersection(found).count) / Double(wanted.count)
        guard titleOverlap >= 0.75 else { return false }
        guard let artist = metadata.artist else { return true }
        let wantedArtist = Set(matchTokens(artist))
        let foundArtist = Set(matchTokens(candidate.artist)).union(found)
        return wantedArtist.isEmpty || !wantedArtist.isDisjoint(with: foundArtist)
    }

    static func appleMusicSearchQuery(for sourceURL: URL) -> String? {
        let parts = sourceURL.pathComponents
            .map { $0.removingPercentEncoding ?? $0 }
            .filter { $0 != "/" }
        guard let titlePart = parts.reversed().first(where: { !$0.allSatisfy(\.isNumber) }) else { return nil }
        let title = titlePart.replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

actor MusicLookupService {
    private let session: URLSession
    private let iTunesSearchURL: URL

    init(
        session: URLSession,
        iTunesSearchURL: URL = URL(string: "https://itunes.apple.com/search")!
    ) {
        self.session = session
        self.iTunesSearchURL = iTunesSearchURL
    }

    func searchTracks(query: String, limit: Int = 5) async -> [MusicSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var components = URLComponents(url: iTunesSearchURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 10))))
        ]

        guard let url = components?.url else { return [] }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return []
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                return []
            }

            let baseResults = results.compactMap { item -> MusicSearchResult? in
                guard let title = (item["trackName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      let artist = (item["artistName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty,
                      !artist.isEmpty else {
                    return nil
                }

                let album = (item["collectionName"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let appleURL = (item["trackViewUrl"] as? String).flatMap(URL.init(string:))
                // The 100 px thumbnail looks blurry in an embed; Apple serves
                // any size from the same path.
                let artworkURL = (item["artworkUrl100"] as? String)
                    .map { $0.replacingOccurrences(of: "100x100bb", with: "600x600bb") }
                    .flatMap(URL.init(string:))
                let releaseYear = (item["releaseDate"] as? String).flatMap { Int($0.prefix(4)) }
                let durationSeconds = (item["trackTimeMillis"] as? Int).map { $0 / 1000 }

                return MusicSearchResult(
                    title: title,
                    artist: artist,
                    album: album?.isEmpty == false ? album : nil,
                    artworkURL: artworkURL,
                    appleMusicURL: appleURL,
                    spotifyURL: nil,
                    youtubeMusicURL: nil,
                    youtubeURL: nil,
                    releaseYear: releaseYear,
                    durationSeconds: durationSeconds
                )
            }

            // The formerly used song.link endpoint now returns 400 responses
            // for valid Apple Music track URLs. Exact cross-platform mappings
            // are optional: callers already fall back to stable service search
            // links, so returning the Apple catalogue results directly keeps
            // lookup fast and dependable instead of serially waiting on a
            // failed secondary service.
            return baseResults
        } catch {
            return []
        }
    }

    /// Resolve a supported shared link to the Apple catalogue track it is,
    /// rendered with stable platform search-link fallbacks so replies don't
    /// depend on song.link. When the catalogue has no confident match, the
    /// link's own title, artist and thumbnail are used, so a shared track
    /// always gets a reply instead of silence.
    func searchTrack(forMusicURL sourceURL: URL) async -> MusicSearchResult? {
        guard MusicLinkDetector.isSupportedTrackURL(sourceURL) else { return nil }

        let metadata: MusicLinkMetadata?
        if let oEmbedURL = MusicLinkDetector.oEmbedURL(for: sourceURL) {
            metadata = await oEmbedMetadata(from: oEmbedURL, sourceURL: sourceURL)
        } else {
            metadata = MusicLinkDetector.appleMusicSearchQuery(for: sourceURL)
                .map { MusicLinkMetadata(title: $0, artist: nil, thumbnailURL: nil) }
        }
        guard let metadata, !metadata.title.isEmpty else { return nil }

        // Artist + title first; then without bracketed credits, which the
        // catalogue often formats differently ("- X Remix" vs "[X Remix]").
        let baseTitle = metadata.title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .components(separatedBy: " - ").first ?? metadata.title
        var queries = [[metadata.artist, metadata.title], [metadata.artist, baseTitle]]
            .map { $0.compactMap { $0 }.joined(separator: " ").trimmingCharacters(in: .whitespaces) }
        queries = queries.reduce(into: []) { if !$0.contains($1) && !$1.isEmpty { $0.append($1) } }

        for query in queries {
            let candidates = await searchTracks(query: query, limit: 5)
            if let match = candidates.first(where: { MusicLinkDetector.isConfidentMatch($0, for: metadata) }) {
                return match
            }
        }
        // Apple-only links have nothing better to show than the slug.
        if metadata.artist == nil && metadata.thumbnailURL == nil {
            return nil
        }
        return MusicSearchResult(
            title: metadata.title,
            artist: metadata.artist ?? "Unknown artist",
            album: nil,
            artworkURL: metadata.thumbnailURL,
            appleMusicURL: nil,
            spotifyURL: nil,
            youtubeMusicURL: nil,
            youtubeURL: nil
        )
    }

    private func oEmbedMetadata(from url: URL, sourceURL: URL) async -> MusicLinkMetadata? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("SwiftBot/1.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else {
                return nil
            }
            return MusicLinkDetector.cleanedMetadata(
                title: title,
                author: json["author_name"] as? String,
                thumbnailURL: (json["thumbnail_url"] as? String).flatMap(URL.init(string:)),
                sourceURL: sourceURL
            )
        } catch {
            return nil
        }
    }
}
