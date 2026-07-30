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
}
