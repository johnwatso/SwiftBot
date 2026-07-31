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

    static func isSupportedTrackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        if host == "open.spotify.com" || host.hasSuffix(".spotify.com") {
            return path.contains("/track/")
        }
        if host == "music.apple.com" || host.hasSuffix(".music.apple.com") {
            return path.contains("/song/") || url.query?.contains("i=") == true
        }
        if host == "youtube.com" || host == "www.youtube.com" || host == "music.youtube.com" {
            return url.query?.contains("v=") == true && url.query?.contains("list=") != true
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
        } else if host == "youtube.com" || host == "www.youtube.com" || host == "music.youtube.com" || host == "youtu.be" {
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
                let artworkURL = (item["artworkUrl100"] as? String).flatMap(URL.init(string:))

                return MusicSearchResult(
                    title: title,
                    artist: artist,
                    album: album?.isEmpty == false ? album : nil,
                    artworkURL: artworkURL,
                    appleMusicURL: appleURL,
                    spotifyURL: nil,
                    youtubeMusicURL: nil,
                    youtubeURL: nil
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

    /// Resolve a supported shared link to the best Apple catalogue match. The
    /// returned track is then rendered using the existing stable platform
    /// search-link fallbacks, so automatic replies do not depend on song.link.
    func searchTrack(forMusicURL sourceURL: URL) async -> MusicSearchResult? {
        guard MusicLinkDetector.isSupportedTrackURL(sourceURL) else { return nil }

        let query: String?
        if let oEmbedURL = MusicLinkDetector.oEmbedURL(for: sourceURL) {
            query = await oEmbedTitle(from: oEmbedURL)
        } else {
            query = MusicLinkDetector.appleMusicSearchQuery(for: sourceURL)
        }
        guard let query, !query.isEmpty else { return nil }
        return await searchTracks(query: query, limit: 1).first
    }

    private func oEmbedTitle(from url: URL) async -> String? {
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
            return title
        } catch {
            return nil
        }
    }
}
